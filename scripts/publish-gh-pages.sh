#!/usr/bin/env bash
##
## publish-gh-pages.sh - assemble a self-hosted apt repository for static
## hosting (GitHub Pages) from freshly built *.deb artifacts, merging into any
## existing pool previously published on the gh-pages branch.
##
## This is the fork replacement for scripts/aptly_api.sh: instead of uploading
## to an aptly server, it builds the dists/Packages/Release/InRelease tree
## locally and stages it for a git push to the gh-pages branch. The actual push
## is done by the CI workflow (needs a GITHUB_TOKEN / deploy key).
##
## Large .deb files (>= --large-threshold, e.g. openjdk) cannot be served from
## GitHub Pages (100 MiB per-file / 1 GiB per-repo limits). They are moved to a
## separate apt repo "termux-big" hosted on Cloudflare R2: the index AND the
## deb contents both live in the R2 bucket, exposed via the R2 custom domain,
## with RELATIVE pool Filenames so apt resolves them under the single source
## URI "deb [trusted] https://<custom-domain> stable main". Needs the rclone
## binary plus the R2_* secrets; when they are absent, large debs fall back
## into the regular pool (and may exceed GitHub Pages limits).
##
## Usage:
##   publish-gh-pages.sh --pages <dir> --debs <dir> [--gpg-key <id>]
##                       [--public-key <file>] [--repo-root <dir>]
##                       [--github-repo <owner/repo>]
##                       [--large-threshold <bytes>]
##
##   --pages        existing gh-pages working tree (contains apt/... from prior
##                  publishes, or empty). This is where output is assembled.
##   --debs         directory with all *.deb files plus the
##                  built_<repo>_packages.txt manifest files produced by the
##                  build job. Each repo's debs are selected by its manifest.
##   --gpg-key      (optional) GPG key id used to sign. Omit to skip signing.
##   --public-key   (optional) armored public key copied to the pages root so
##                  devices can fetch it.
##   --repo-root    directory containing repo.json (default: this script's
##                  parent).
##   --github-repo  (optional) "owner/repo"; legacy large debs previously
##                  released under pkg-* tags are re-fetched from GitHub
##                  Releases and migrated into the R2 termux-big repo.
##   --large-threshold
##                  (optional) .deb files >= this many bytes are treated as
##                  large and moved to the R2 termux-big repo (default
##                  104857600 = 100 MiB).
##
## Environment (needed for the R2 termux-big repo):
##   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_BUCKET,
##   R2_PUBLIC_URL (custom domain base URI, informational)
set -euo pipefail

PAGES_DIR=""
DEBS_DIR=""
GPG_KEY=""
PUBLIC_KEY=""
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITHUB_REPO=""
LARGE_THRESHOLD=104857600

usage() {
	sed -n '3,48p' "$0"
	echo
	exit 1
}

while (($#)); do
	case "$1" in
		--pages) PAGES_DIR="$2"; shift 2;;
		--debs) DEBS_DIR="$2"; shift 2;;
		--gpg-key) GPG_KEY="$2"; shift 2;;
		--public-key) PUBLIC_KEY="$2"; shift 2;;
		--repo-root) REPO_ROOT="$2"; shift 2;;
		--github-repo) GITHUB_REPO="$2"; shift 2;;
		--large-threshold) LARGE_THRESHOLD="$2"; shift 2;;
		-h|-help|--help) usage;;
		*) echo "Unknown option: $1" >&2; usage;;
	esac
done

[[ -n "$PAGES_DIR" && -n "$DEBS_DIR" ]] || { echo "Error: --pages and --debs are required" >&2; usage; }
[[ -f "$REPO_ROOT/repo.json" ]] || { echo "Error: repo.json not found in '$REPO_ROOT'" >&2; exit 1; }

# Normalize to absolute paths so the symlinks created below resolve correctly.
mkdir -p "$PAGES_DIR"
PAGES_DIR="$(realpath "$PAGES_DIR")"
DEBS_DIR="$(realpath "$DEBS_DIR")"
REPO_ROOT="$(realpath "$REPO_ROOT")"

gen_repo_files="$(dirname "${BASH_SOURCE[0]}")/gen-repo-files.sh"

# Detect the "large" repo (termux-big), hosted on Cloudflare R2.
BIG_REPO_KEY=""
BIG_NAME=""
BIG_DIST=""
BIG_COMP=""
for key in $(jq --raw-output 'del(.pkg_format) | keys | .[]' "$REPO_ROOT/repo.json"); do
	[[ "$(jq --raw-output ".[\"$key\"].name" "$REPO_ROOT/repo.json")" == "termux-big" ]] || continue
	BIG_REPO_KEY="$key"
	BIG_NAME="$(jq --raw-output ".[\"$key\"].name" "$REPO_ROOT/repo.json")"
	BIG_DIST="$(jq --raw-output ".[\"$key\"].distribution" "$REPO_ROOT/repo.json")"
	BIG_COMP="$(jq --raw-output ".[\"$key\"].component" "$REPO_ROOT/repo.json")"
	break
done

# R2 availability: rclone binary + all R2_* secrets. A remote WITHOUT a bucket
# config is created so the bucket name can be passed explicitly as the first
# path component (a remote with a configured bucket + a leading bucket-name
# path component makes rclone treat the first component as a bucket name and
# silently creates a junk bucket).
R2_AVAILABLE=0
R2_REMOTE=""
r2_missing=0
if [[ -z "$BIG_REPO_KEY" ]]; then
	echo "Warning: no 'termux-big' repo in repo.json; skipping R2 large-deb repo" >&2
	r2_missing=1
else
	for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
		[[ -n "${!var:-}" ]] || { echo "Warning: $var not set; large debs stay in the regular pool" >&2; r2_missing=1; }
	done
	command -v rclone >/dev/null 2>&1 || { echo "Warning: rclone not found in PATH; large debs stay in the regular pool" >&2; r2_missing=1; }
fi

if (( ! r2_missing )); then
	R2_REMOTE="apexr2"
	rclone config delete "$R2_REMOTE" >/dev/null 2>&1 || true
	rclone config create "$R2_REMOTE" s3 \
		provider Cloudflare \
		access_key_id "$R2_ACCESS_KEY_ID" \
		secret_access_key "$R2_SECRET_ACCESS_KEY" \
		region auto \
		endpoint "$R2_ENDPOINT" >/dev/null
	R2_AVAILABLE=1
	# root of the termux-big repo tree: pool/<comp>/<arch>/... + dists/. This
	# mirrors 1:1 to the R2 bucket, exposed at https://<r2-custom-domain>/
	# (repo.json url). --debs and --out point at the same root so existing
	# pool debs (restored below) are reused in place instead of re-copied.
	big_root="$(mktemp -d)"
	trap 'rm -rf "$big_root"' EXIT
	echo "R2 termux-big repo enabled (bucket: $R2_BUCKET)"
fi

# Stage a large .deb into the termux-big repo root at pool/<comp>/<arch>/<file>.
stage_large_deb() {
	local deb="$1" comp="$2" arch dest
	arch="$(dpkg-deb --field "$deb" Architecture 2>/dev/null || true)"
	[[ -n "$arch" ]] || arch="all"
	mkdir -p "$big_root/pool/$comp/$arch"
	ln -sf "$deb" "$big_root/pool/$comp/$arch/$(basename "$deb")"
}

for repo in $(jq --raw-output 'del(.pkg_format) | keys | .[]' "$REPO_ROOT/repo.json"); do
	# The large repo (termux-big) is assembled separately, after the main loop.
	[[ "$repo" == "$BIG_REPO_KEY" ]] && continue

	# Read repo metadata (name/dist/component) from repo.json.
	name=$(jq --raw-output ".[\"$repo\"].name" "$REPO_ROOT/repo.json")
	dist=$(jq --raw-output ".[\"$repo\"].distribution" "$REPO_ROOT/repo.json")
	comp=$(jq --raw-output ".[\"$repo\"].component" "$REPO_ROOT/repo.json")
	builtlist="$DEBS_DIR/built_${name}_packages.txt"

	# Fresh staging dir: merge_dir for pool debs.
	merge_dir="$PAGES_DIR/.merge-${name}"
	rm -rf "$merge_dir"
	mkdir -p "$merge_dir"
	staged_large=0

	# Step 1: retain all debs already in the published pool.
	find "$PAGES_DIR/apt/$name/pool" -name '*.deb' -type f -exec ln -sf {} "$merge_dir/" \; 2>/dev/null || true

	# Step 2: stage debs from this run's build manifests.
	if [[ -f "$builtlist" ]]; then
		while IFS= read -r pkg; do
			[[ -n "$pkg" ]] || continue
			while IFS= read -r -d '' deb; do
				size=$(stat -c %s "$deb")
				# Offload oversized binaries to the R2 termux-big repo (no
				# GitHub Pages file/repo size limits); fall back to the
				# regular pool when R2 is unavailable.
				if [[ "$size" -ge "$LARGE_THRESHOLD" ]]; then
					if (( R2_AVAILABLE )); then
						stage_large_deb "$deb" "$comp"
						staged_large=1
					else
						echo "Warning: large deb '$deb' has no R2 termux-big target; leaving it in the regular pool" >&2
						ln -sf "$deb" "$merge_dir/"
					fi
				else
					ln -sf "$deb" "$merge_dir/"
				fi
			done < <(find "$DEBS_DIR" \( -name "${pkg}_*.deb" -o -name "${pkg}-static_*.deb" \) -print0)
		done < "$builtlist"
	fi

	# Step 3: do NOT skip empty repos. Metadata (Packages/Release/InRelease)
	# is regenerated for every repo on every run, so previously-empty repos
	# (root/x11) also get fresh release indexes with correct suite/component.
	if ! find "$merge_dir" -name '*.deb' -print -quit | grep -q . && (( ! staged_large )); then
		echo "Info: $repo ($name): no debs to publish; regenerating empty repo index"
	fi

	# Step 4: generate apt metadata (Packages/Release/InRelease) via gen-repo-files.sh.
	echo "Assembling $repo ($name) distribution '$dist'..."
	gen_args=(--debs "$merge_dir" --out "$PAGES_DIR/apt/$name" --suite "$dist" --component "$comp")
	if [[ -n "$GPG_KEY" ]]; then
		gen_args+=(--gpg-key "$GPG_KEY")
	fi
	bash "$gen_repo_files" "${gen_args[@]}"
	rm -rf "$merge_dir"
done

# Assemble the R2 termux-big repo (index AND deb contents both in the R2
# bucket, base URI from repo.json url) so a single apt source line
# "deb [trusted] https://<custom-domain> stable main" works. Filenames are
# relative (pool/<comp>/<arch>/<file>) and resolve under that base URI.
if (( ! R2_AVAILABLE )); then
	echo "Info: R2 not configured; no termux-big repo generated"
else
	# Restore previously published pool content so old large debs stay
	# available; re-generated metadata below covers the union of old + new.
	echo "Restoring previously published R2 termux-big pool..."
	rclone copy "$R2_REMOTE:$R2_BUCKET/pool" "$big_root/" 2>/dev/null || true

	# Migrate legacy large debs previously hosted as GitHub Release assets
	# (tags pkg-<pkg>-<ver> / pkg-<repo>-<pkg>-<ver>) into the R2 pool, except
	# tags prefixed with another termux repo's name (root/x11). Debs already
	# present in the restored R2 pool are skipped to avoid re-downloading.
	if [[ -n "$GITHUB_REPO" && -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
		echo "Fetching legacy large debs from GitHub Releases (migration)..."
		mapfile -t legacy_tags < <(gh release list --repo "$GITHUB_REPO" --limit 1000 | awk '/^pkg-/ {print $1}')
		for tag in "${legacy_tags[@]:-}"; do
			[[ -n "$tag" ]] || continue
			case "$tag" in
				pkg-termux-root-*|pkg-termux-x11-*) continue ;;
				pkg-*) ;;
				*) continue ;;
			esac
			# Skip the download when every asset of this tag already lives in
			# the pool tree restored from R2 above.
			have_all=1
			while IFS= read -r aname; do
				[[ -n "$aname" ]] || continue
				if ! find "$big_root/pool" -name "$aname" -print -quit | grep -q .; then
					have_all=0
					break
				fi
			done < <(gh release view "$tag" --repo "$GITHUB_REPO" --json assets -q '.assets[].name' 2>/dev/null)
			if (( have_all )); then
				echo "  skipping '$tag' (already in R2 pool)"
				continue
			fi
			echo "  downloading release '$tag'"
			gh release download "$tag" --repo "$GITHUB_REPO" --dir "$big_root" --pattern '*.deb' 2>/dev/null || true
		done
		# Relocate legacy debs into the correct pool/<comp>/<arch> layout (they
		# were downloaded flat into the root).
		while IFS= read -r -d '' deb; do
			larch="$(dpkg-deb --field "$deb" Architecture 2>/dev/null || true)"
			[[ -n "$larch" ]] || larch="all"
			mkdir -p "$big_root/pool/$BIG_COMP/$larch"
			mv -f "$deb" "$big_root/pool/$BIG_COMP/$larch/$(basename "$deb")"
		done < <(find "$big_root" -maxdepth 1 -name '*.deb' -print0)
	fi

	echo "Generating R2 termux-big repository metadata..."
	gen_args=(--debs "$big_root" --out "$big_root" --suite "$BIG_DIST" --component "$BIG_COMP")
	if [[ -n "$GPG_KEY" ]]; then
		gen_args+=(--gpg-key "$GPG_KEY")
	fi
	bash "$gen_repo_files" "${gen_args[@]}"

	echo "Uploading R2 termux-big repository (pool + dists) to bucket '$R2_BUCKET'..."
	# -L dereferences the staged pool symlinks (debs are symlinked into the
	# pool to avoid copying; rclone otherwise skips them).
	rclone copy "$big_root/." "$R2_REMOTE:$R2_BUCKET/" -L
	if [[ -n "${R2_PUBLIC_URL:-}" ]]; then
		echo "R2 termux-big repository published at: $R2_PUBLIC_URL"
	else
		echo "R2 termux-big repository published (custom domain from repo.json url)"
	fi
fi

if [[ -n "$PUBLIC_KEY" && -f "$PUBLIC_KEY" ]]; then
	cp -f "$PUBLIC_KEY" "$PAGES_DIR/apexstudio-packages.asc"
	echo "Copied public key to $PAGES_DIR/apexstudio-packages.asc"
fi

echo "Done. GitHub Pages content staged in: $PAGES_DIR"