#!/usr/bin/env bash
##
## gen-repo-files.sh - generate an APT repository (dists/Packages/Release/InRelease)
##                    from a directory of .deb files, using GPG signing.
##
## Mirrors the output that Termux's aptly server produces, so that a forked
## termux-packages repo can host its own apt repos over static hosting
## (e.g. GitHub Pages) without needing an aptly server.
##
## Layout produced (under <output>):
##   dists/<dist>/<comp>/binary-<arch>/Packages[.gz]
##   dists/<dist>/Release
##   dists/<dist>/Release.gpg   (detached signature)
##   dists/<dist>/InRelease     (clearsigned Release)
##   pool/<comp>/<arch>/<file>.deb
##
## <output> is the repository's own root. To host multiple repos under one
## static site, pass --out <site>/<repo-name> (e.g. site/apt/termux-main).
##
## Usage:
##   gen-repo-files.sh --debs <dir> --out <repo-root> [--gpg-key <id>]
##                     [--suite <suite>] [--arch <arch>...]
##
## If --gpg-key is omitted (or gpg not available) the repository is generated
## unsigned (a warning is printed). Signing is required for a usable apt repo.
set -euo pipefail

DEBS_DIR=""
OUT_DIR=""
GPG_KEY=""
SUITE="stable"
ARCHES=(aarch64 arm i686 x86_64 all)

usage() {
	sed -n '3,19p' "$0"
	echo
	exit 1
}

while (($#)); do
	case "$1" in
		--debs) DEBS_DIR="$2"; shift 2;;
		--out) OUT_DIR="$2"; shift 2;;
		--gpg-key) GPG_KEY="$2"; shift 2;;
		--suite) SUITE="$2"; shift 2;;
		--arch) IFS=' ' read -r -a ARCHES <<< "$2"; shift 2;;
		-h|-help|--help) usage;;
		*) echo "Unknown option: $1" >&2; usage;;
	esac
done

[[ -n "$DEBS_DIR" && -n "$OUT_DIR" ]] || { echo "Error: --debs and --out are required" >&2; usage; }
[[ -d "$DEBS_DIR" ]] || { echo "Error: debs dir '$DEBS_DIR' does not exist" >&2; exit 1; }

COMPONENT="main"
APT_ROOT="$OUT_DIR"
HAS_GPG=0
if [[ -n "$GPG_KEY" ]]; then
	if command -v gpg >/dev/null 2>&1; then
		HAS_GPG=1
	else
		echo "Warning: gpg not available; producing unsigned repo" >&2
	fi
fi

mkdir -p "$APT_ROOT"

# Gather .deb files into the pool. This script generates ONE apt repo tree.
# To publish multiple repos (main/root/x11 from repo.json), the caller runs it
# once per repo, passing --out out/apt/<repo-name> and --suite <distribution>.
# The repo NAME (e.g. termux-main) is not embedded by this script; the caller
# provides it via --out so the final path becomes out/apt/<name>/dists/<dist>/.
# COMPONENT is hardcoded to "main" here (matches repo.json for main & x11;
# root-packages uses component "stable" in repo.json but that only matters for
# the device-side apt sources.list, the on-disk pool layout is identical).
declare -a DEB_FILES
while IFS= read -r -d '' f; do
	DEB_FILES+=("$f")
done < <(find "$DEBS_DIR" \( -name '*.deb' -o -name '*.deb' \) -print0)

(( ${#DEB_FILES[@]} )) || { echo "Error: no .deb files found in '$DEBS_DIR'" >&2; exit 1; }

copy_pool() {
	local f arch comp
	for f in "${DEB_FILES[@]}"; do
		# derive arch from filename (Termux names: <name>_<ver>_<arch>.deb)
		arch="${f##*_}"
		arch="${arch%.deb}"
		[[ " ${ARCHES[*]} " == *" $arch "* ]] || arch="all"
		mkdir -p "$APT_ROOT/pool/$COMPONENT/$arch"
		cp -f "$f" "$APT_ROOT/pool/$COMPONENT/$arch/"
	done
}

gen_packages() {
	local arch pkgfile
	for arch in "${ARCHES[@]}"; do
		local dir="$APT_ROOT/dists/$SUITE/$COMPONENT/binary-$arch"
		mkdir -p "$dir"
		pkgfile="$dir/Packages"
		: > "$pkgfile"
		for deb in "$APT_ROOT"/pool/"$COMPONENT"/"$arch"/*.deb; do
			[[ -f "$deb" ]] || continue
			# extract fields with dpkg-deb; fall back to awk on control if absent
			if command -v dpkg-deb >/dev/null 2>&1; then
				dpkg-deb --info "$deb" > /dev/null 2>&1 || true
				dpkg-deb --showformat \
					'Package: ${Package}\nVersion: ${Version}\nArchitecture: ${Architecture}\nSection: ${Section}\nPriority: ${Priority}\nMaintainer: ${Maintainer}\nDepends: ${Depends}\nDescription: ${Description}\n' \
					--show "$deb" >> "$pkgfile" || true
			fi
			{
				echo "Filename: pool/$COMPONENT/$arch/$(basename "$deb")"
				echo "Size: $(stat -c %s "$deb")"
				echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
				echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
				echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
				echo "SHA512: $(sha512sum "$deb" | cut -d' ' -f1)"
			} >> "$pkgfile"
			echo >> "$pkgfile"
		done
		gzip -9c "$pkgfile" > "$pkgfile.gz"
		echo "Generated: $pkgfile ($(wc -l < "$pkgfile") lines)"
	done
}

gen_release_and_sign() {
	local rel_file="$APT_ROOT/dists/$SUITE/Release"
	{
		echo "Origin: ApexStudio"
		echo "Label: ApexStudio"
		echo "Suite: $SUITE"
		echo "Codename: $SUITE"
		echo "Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
		echo "Architectures: ${ARCHES[*]}"
		echo "Components: $COMPONENT"
		echo "Description: ApexStudio apt repository"
		echo
		echo "MD5Sum:"
		for f in $(find "$APT_ROOT/dists/$SUITE" -type f -name 'Packages*'); do
			printf ' %s %16s %s\n' \
				"$(md5sum "$f" | cut -d' ' -f1)" \
				"$(stat -c %s "$f")" \
				"${f#"$APT_ROOT"/dists/$SUITE/}"
		done | sort -k3
		echo "SHA1:"
		for f in $(find "$APT_ROOT/dists/$SUITE" -type f -name 'Packages*'); do
			printf ' %s %16s %s\n' \
				"$(sha1sum "$f" | cut -d' ' -f1)" \
				"$(stat -c %s "$f")" \
				"${f#"$APT_ROOT"/dists/$SUITE/}"
		done | sort -k3
		echo "SHA256:"
		for f in $(find "$APT_ROOT/dists/$SUITE" -type f -name 'Packages*'); do
			printf ' %s %16s %s\n' \
				"$(sha256sum "$f" | cut -d' ' -f1)" \
				"$(stat -c %s "$f")" \
				"${f#"$APT_ROOT"/dists/$SUITE/}"
		done | sort -k3
	} > "$rel_file"

	if (( HAS_GPG )); then
		gpg --batch --yes --armor --detach-sign -o "$rel_file.gpg" "$rel_file"
		gpg --batch --yes --armor --clearsign -o "$APT_ROOT/dists/$SUITE/InRelease" "$rel_file"
		echo "Signed repository with key: $GPG_KEY"
	else
		echo "Warning: repository NOT signed (--gpg-key missing)"
	fi
}

copy_pool
gen_packages
gen_release_and_sign

echo "Done. Repository written to: $APT_ROOT"
