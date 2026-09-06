#!/usr/bin/env bash
##
## cleanup-stale-apt.sh - remove stale artifacts from a gh-pages apt worktree,
## leaving only what matches the current repo.json layout.
##
## Works directly on a gh-pages worktree (no git history manipulation):
##   * for each repo, keeps dists/<dist>/<component>/ for the repo's declared
##     component; every other component dir and stray dist-level files (legacy
##     Contents-* beside the component) are removed;
##   * non-live pool component dirs are removed only when EMPTY so real debs of
##     a previous component are never dropped; Release/InRelease/Release.gpg
##     are always kept.
##
## Usage:
##   cleanup-stale-apt.sh --pages <gh-pages-dir> [--repo-root <dir>] [--dry-run]
##
##   --pages      gh-pages working tree containing apt/
##   --repo-root  directory containing repo.json (default: repo root)
##   --dry-run    only report what would be removed
set -euo pipefail

PAGES_DIR=""
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0

usage() {
	sed -n '3,22p' "$0"
	echo
	exit 1
}

while (($#)); do
	case "$1" in
		--pages) PAGES_DIR="$2"; shift 2;;
		--repo-root) REPO_ROOT="$2"; shift 2;;
		--dry-run) DRY_RUN=1; shift;;
		-h|-help|--help) usage;;
		*) echo "Unknown option: $1" >&2; usage;;
	esac
done

[[ -n "$PAGES_DIR" ]] || { echo "Error: --pages is required" >&2; usage; }
[[ -f "$REPO_ROOT/repo.json" ]] || { echo "Error: repo.json not found in '$REPO_ROOT'" >&2; exit 1; }
PAGES_DIR="$(realpath "$PAGES_DIR")"

removed_total=0

for repo in $(jq --raw-output 'del(.pkg_format) | keys | .[]' "$REPO_ROOT/repo.json"); do
	name=$(jq --raw-output ".[\"$repo\"].name" "$REPO_ROOT/repo.json")
	dist=$(jq --raw-output ".[\"$repo\"].distribution" "$REPO_ROOT/repo.json")
	comp=$(jq --raw-output ".[\"$repo\"].component" "$REPO_ROOT/repo.json")
	dists_dir="$PAGES_DIR/apt/$name/dists/$dist"
	pool_dir="$PAGES_DIR/apt/$name/pool"

	if [[ -d "$dists_dir" ]]; then
		# Stray legacy files at dist level (old Contents-* layout).
		while IFS= read -r -d '' f; do
			echo "rm file: ${f#"$PAGES_DIR"}"
			removed_total=$((removed_total + 1))
			[[ $DRY_RUN -eq 1 ]] || rm -f "$f"
		done < <(find "$dists_dir" -maxdepth 1 -type f \
			! -name Release ! -name InRelease ! -name Release.gpg -print0)

		# Component dirs other than the repo's current component.
		while IFS= read -r -d '' d; do
			[[ "$(basename "$d")" != "$comp" ]] || continue
			echo "rm dir:  ${d#"$PAGES_DIR"}"
			removed_total=$((removed_total + 1))
			[[ $DRY_RUN -eq 1 ]] || rm -rf "$d"
		done < <(find "$dists_dir" -mindepth 1 -maxdepth 1 -type d -print0)
	fi

	# Non-live pool component dirs, only when empty.
	if [[ -d "$pool_dir" ]]; then
		while IFS= read -r -d '' d; do
			[[ "$(basename "$d")" != "$comp" ]] || continue
			if [[ -n "$(find "$d" -mindepth 1 -print -quit)" ]]; then
				echo "keep (non-empty pool): ${d#"$PAGES_DIR"}"
				continue
			fi
			echo "rm empty pool dir: ${d#"$PAGES_DIR"}"
			removed_total=$((removed_total + 1))
			[[ $DRY_RUN -eq 1 ]] || rm -rf "$d"
		done < <(find "$pool_dir" -mindepth 1 -maxdepth 1 -type d -print0)
	fi
done

echo "Stale cleanup done (${removed_total} items${DRY_RUN:+ [dry-run]})"