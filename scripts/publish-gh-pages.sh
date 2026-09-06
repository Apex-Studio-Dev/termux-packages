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
## Usage:
##   publish-gh-pages.sh --pages <dir> --debs <dir> [--gpg-key <id>]
##                       [--public-key <file>] [--repo-root <dir>]
##                       [--github-repo <owner/repo>] [--large-threshold <bytes>]
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
##   --github-repo  (optional) "owner/repo" used to host large .deb files as
##                  GitHub Release assets instead of committing them to the
##                  git-backed gh-pages tree. Requires gh + GH_TOKEN.
##   --large-threshold
##                  (optional) .deb files >= this many bytes are treated as
##                  large and uploaded to a GitHub Release (default 52428800 =
##                  50 MiB). Only used when --github-repo is given.
set -euo pipefail

PAGES_DIR=""
DEBS_DIR=""
GPG_KEY=""
PUBLIC_KEY=""
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITHUB_REPO=""
LARGE_THRESHOLD=104857600

usage() {
	sed -n '3,30p' "$0"
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

# Apt repo names (termux-main, termux-root, ...) from repo.json, used to tell
# repo-prefixed release tags apart from the legacy pkg-<pkg>-<ver> tags.
mapfile -t repo_names < <(jq -r 'del(.pkg_format) | to_entries[] | .value.name' "$REPO_ROOT/repo.json")

# Upload a large .deb to a GitHub Release (tag pkg-<repo>-<pkg>-<version>;
# termux-main predates the repo prefix and keeps pkg-<pkg>-<version> so its
# existing release URLs stay valid). Reuses an existing release if one exists.
# Prints "asset-url <url>" on success.
upload_large_deb() {
	local deb="$1" style="$2" fname pkgname ver tag
	fname="$(basename "$deb")"
	pkgname="${fname%%_*}"
	# Version never contains '_' (only '.', '-', '+', and ':' for epochs),
	# but architectures like 'x86_64' do, so trim at the FIRST underscore
	# after the name, not the last, otherwise the tag splits the arch.
	ver="${fname#*_}"
	ver="${ver%%_*}"
	tag="pkg-${style:+${style}-}${pkgname}-${ver}"
	if [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
		echo "Warning: no GH_TOKEN/GITHUB_TOKEN; large deb '$fname' left in pool" >&2
		return 1
	fi
	if ! gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
		gh release create "$tag" \
			--repo "$GITHUB_REPO" --title "$tag" --notes "Packages: $pkgname $ver" >/dev/null
	fi
	gh release upload "$tag" "$deb" --repo "$GITHUB_REPO" --clobber >/dev/null
	echo "Published large deb '$fname' to release '$tag'"
	echo "asset-url https://github.com/$GITHUB_REPO/releases/download/$tag/$fname"
}

for repo in $(jq --raw-output 'del(.pkg_format) | keys | .[]' "$REPO_ROOT/repo.json"); do
	# Read repo metadata (name/dist/component) from repo.json.
	name=$(jq --raw-output ".[\"$repo\"].name" "$REPO_ROOT/repo.json")
	dist=$(jq --raw-output ".[\"$repo\"].distribution" "$REPO_ROOT/repo.json")
	comp=$(jq --raw-output ".[\"$repo\"].component" "$REPO_ROOT/repo.json")
	builtlist="$DEBS_DIR/built_${name}_packages.txt"

	# Fresh staging dirs: merge_dir for pool debs, extern_dir for GitHub Release assets.
	merge_dir="$PAGES_DIR/.merge-${name}"
	extern_dir="$PAGES_DIR/.extern-${name}"
	rm -rf "$merge_dir" "$extern_dir"
	mkdir -p "$merge_dir" "$extern_dir"
	external_url="https://github.com/$GITHUB_REPO/releases/download"
	externals_present=0
	# Repo tag prefix for large-deb releases (empty keeps termux-main's legacy
	# pkg-<pkg>-<ver> format).
	external_style="$name"
	[[ "$external_style" == "termux-main" ]] && external_style=""

	# Step 1: retain all debs already in the published pool.
	find "$PAGES_DIR/apt/$name/pool" -name '*.deb' -type f -exec ln -sf {} "$merge_dir/" \; 2>/dev/null || true

	# Step 2: stage debs from this run's build manifests.
	if [[ -f "$builtlist" ]]; then
		while IFS= read -r pkg; do
			[[ -n "$pkg" ]] || continue
			while IFS= read -r -d '' deb; do
				size=$(stat -c %s "$deb")
				# Offload oversized binaries to GitHub Release assets to mitigate Git repository bloat
				if [[ -n "$GITHUB_REPO" && "$size" -ge "$LARGE_THRESHOLD" ]]; then
					if upload_large_deb "$deb" "$external_style" >/dev/null; then
						ln -sf "$deb" "$extern_dir/"
						externals_present=1
					else
						echo "Falling back: symlinking '$deb' into pool instead of a release" >&2
						ln -sf "$deb" "$merge_dir/"
					fi
				else
					ln -sf "$deb" "$merge_dir/"
				fi
			done < <(find "$DEBS_DIR" \( -name "${pkg}_*.deb" -o -name "${pkg}-static_*.deb" \) -print0)
		done < "$builtlist"
	fi

	# Step 3: re-fetch this repo's previously released large debs so they are
	# not evicted from metadata. Only tags for THIS repo are downloaded:
	#   pkg-<style>-...           repo-prefixed tags (style empty for termux-main)
	#   pkg-<pkg>-...             legacy unprefixed tags, all termux-main
	# repo-prefixed tags of other repos are skipped in both cases.
	if [[ -n "$GITHUB_REPO" && -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
		echo "Fetching previously published large debs ($name) from GitHub Releases..."
		while read -r tag; do
			[[ -n "$tag" ]] || continue
			case "$tag" in
				pkg-${external_style}-*) ;;
				pkg-*)
					[[ "$name" == "termux-main" ]] || continue
					for other in "${repo_names[@]}"; do
						[[ "$other" == "termux-main" ]] && continue
						case "$tag" in pkg-${other}-*) continue 2 ;; esac
					done
					;;
				*) continue ;;
			esac
			gh release download "$tag" --repo "$GITHUB_REPO" --dir "$extern_dir" --pattern '*.deb' 2>/dev/null || true
		done < <(gh release list --repo "$GITHUB_REPO" --limit 1000 | awk '/^pkg-/ {print $1}')

		if find "$extern_dir" -name '*.deb' -print -quit | grep -q .; then
			externals_present=1
		fi
	fi

	# Step 4: do NOT skip empty repos. Metadata (Packages/Release/InRelease)
	# is regenerated for every repo on every run, so previously-empty repos
	# (root/x11) also get fresh release indexes with correct suite/component.
	if ! find "$merge_dir" -name '*.deb' -print -quit | grep -q . && (( ! externals_present )); then
		echo "Info: $repo ($name): no debs to publish; regenerating empty repo index"
	fi

	# Step 5: generate apt metadata (Packages/Release/InRelease) via gen-repo-files.sh.
	echo "Assembling $repo ($name) distribution '$dist'..."
	gen_args=(--debs "$merge_dir" --out "$PAGES_DIR/apt/$name" --suite "$dist" --component "$comp")
	if [[ -n "$GPG_KEY" ]]; then
		gen_args+=(--gpg-key "$GPG_KEY")
	fi
	if (( externals_present )); then
		gen_args+=(--externals-dir "$extern_dir" --external-base-url "$external_url")
		gen_args+=(--external-repo "$external_style")
	fi
	bash "$gen_repo_files" "${gen_args[@]}"
	rm -rf "$merge_dir" "$extern_dir"
done

if [[ -n "$PUBLIC_KEY" && -f "$PUBLIC_KEY" ]]; then
	cp -f "$PUBLIC_KEY" "$PAGES_DIR/apexstudio-packages.asc"
	echo "Copied public key to $PAGES_DIR/apexstudio-packages.asc"
fi

echo "Done. GitHub Pages content staged in: $PAGES_DIR"
