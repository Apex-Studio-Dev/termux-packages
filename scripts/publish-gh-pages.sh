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
set -euo pipefail

PAGES_DIR=""
DEBS_DIR=""
GPG_KEY=""
PUBLIC_KEY=""
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
	sed -n '3,23p' "$0"
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

for repo in $(jq --raw-output 'del(.pkg_format) | keys | .[]' "$REPO_ROOT/repo.json"); do
	name=$(jq --raw-output ".[\"$repo\"].name" "$REPO_ROOT/repo.json")
	dist=$(jq --raw-output ".[\"$repo\"].distribution" "$REPO_ROOT/repo.json")
	builtlist="$DEBS_DIR/built_${name}_packages.txt"

	[[ -f "$builtlist" ]] || { echo "Skip $repo ($name): no built manifest"; continue; }

	# Stage only this repo's freshly built debs. gen-repo-files.sh copies them
	# into the pool (creating pool/main/<arch>), then regenerates Packages from
	# the WHOLE pool, so existing published debs merge with the new ones.
	merge_dir="$PAGES_DIR/.merge-${name}"
	mkdir -p "$merge_dir"
	# New debs for this repo.
	while IFS= read -r pkg; do
		[[ -n "$pkg" ]] || continue
		find "$DEBS_DIR" \( -name "${pkg}_*.deb" -o -name "${pkg}-static_*.deb" \) \
			-exec ln -sf {} "$merge_dir/" \; 2>/dev/null || true
	done < "$builtlist"

	if ! find "$merge_dir" -name '*.deb' | grep -q .; then
		echo "Skip $repo ($name): no debs to publish"
		rm -rf "$merge_dir"
		continue
	fi

	echo "Assembling $repo ($name) distribution '$dist'..."
	if [[ -n "$GPG_KEY" ]]; then
		bash "$gen_repo_files" --debs "$merge_dir" --out "$PAGES_DIR/apt/$name" \
			--suite "$dist" --gpg-key "$GPG_KEY"
	else
		bash "$gen_repo_files" --debs "$merge_dir" --out "$PAGES_DIR/apt/$name" \
			--suite "$dist"
	fi
	rm -rf "$merge_dir"
done

if [[ -n "$PUBLIC_KEY" && -f "$PUBLIC_KEY" ]]; then
	cp -f "$PUBLIC_KEY" "$PAGES_DIR/apexstudio-packages.asc"
	echo "Copied public key to $PAGES_DIR/apexstudio-packages.asc"
fi

echo "Done. GitHub Pages content staged in: $PAGES_DIR"
