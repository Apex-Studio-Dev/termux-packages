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
##                     [--externals-dir <dir>] [--external-base-url <url>]
##
## If --gpg-key is omitted (or gpg not available) the repository is generated
## unsigned (a warning is printed). Signing is required for a usable apt repo.
##
## Large .deb files may be hosted outside the pool (e.g. GitHub Releases) to
## keep the git-backed gh-pages tree small. Pass them via --externals-dir along
## with --external-base-url: they are NOT copied into the pool; instead each
## gets a Packages stanza whose "Filename:" is the full asset URL
## ("<external-base-url>/<file>"). Small debs in --debs are handled normally.
set -euo pipefail

DEBS_DIR=""
OUT_DIR=""
GPG_KEY=""
SUITE="stable"
COMPONENT="main"
ARCHES=(aarch64 arm i686 x86_64 all)
EXTERNALS_DIR=""
EXTERNAL_URL=""

usage() {
	sed -n '3,23p' "$0"
	echo
	exit 1
}

while (($#)); do
	case "$1" in
		--debs) DEBS_DIR="$2"; shift 2;;
		--out) OUT_DIR="$2"; shift 2;;
		--gpg-key) GPG_KEY="$2"; shift 2;;
		--suite) SUITE="$2"; shift 2;;
		--component) COMPONENT="$2"; shift 2;;
		--arch) IFS=' ' read -r -a ARCHES <<< "$2"; shift 2;;
		--externals-dir) EXTERNALS_DIR="$2"; shift 2;;
		--external-base-url) EXTERNAL_URL="$2"; shift 2;;
		-h|-help|--help) usage;;
		*) echo "Unknown option: $1" >&2; usage;;
	esac
done

[[ -n "$DEBS_DIR" && -n "$OUT_DIR" ]] || { echo "Error: --debs and --out are required" >&2; usage; }
[[ -d "$DEBS_DIR" ]] || { echo "Error: debs dir '$DEBS_DIR' does not exist" >&2; exit 1; }

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
# once per repo, passing --out out/apt/<repo-name>, --suite <distribution> and
# --component <component>. The repo NAME (e.g. termux-main) is not embedded by
# this script; the caller provides it via --out so the final path becomes
# out/apt/<name>/dists/<dist>/<comp>/.
declare -a DEB_FILES=()
while IFS= read -r -d '' f; do
	DEB_FILES+=("$f")
done < <(find "$DEBS_DIR" \( -name '*.deb' -o -name '*.deb' \) -print0)

# Allow generating an empty (but valid, signed) repository when no .deb files
# are present. This is useful to seed bootstrap metadata so that CI -I builds
# can resolve the repo URLs before any package has been published.
:

if (( ${#DEB_FILES[@]} )); then
	echo "Found ${#DEB_FILES[@]} .deb file(s)"
else
	echo "No .deb files found in '$DEBS_DIR'; generating empty repository"
fi

copy_pool() {
	local f arch
	for f in "${DEB_FILES[@]}"; do
		# Derive arch from the deb control file (Termux uses arch names like
		# x86_64 which contain '_', so filename parsing is unreliable).
		arch="$(dpkg-deb --field "$f" Architecture 2>/dev/null || true)"
		[[ -n "$arch" && " ${ARCHES[*]} " == *" $arch "* ]] || arch="all"
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
			emit_stanza "$deb" "pool/$COMPONENT/$arch/$(basename "$deb")" "$pkgfile"
		done
		# Large / externally-hosted debs: Filename is the full asset URL.
		if [[ -n "$EXTERNALS_DIR" && -n "$EXTERNAL_URL" ]]; then
			for ext in "$EXTERNALS_DIR"/*.deb; do
				[[ -f "$ext" ]] || continue
				earch="$(dpkg-deb --field "$ext" Architecture 2>/dev/null || true)"
				[[ -n "$earch" && " ${ARCHES[*]} " == *" $earch "* ]] || earch="all"
				[[ "$earch" == "$arch" ]] || continue
				emit_stanza "$ext" "$EXTERNAL_URL/$(basename "$ext")" "$pkgfile"
			done
		fi
		gzip -9c "$pkgfile" > "$pkgfile.gz"
		echo "Generated: $pkgfile ($(wc -l < "$pkgfile") lines)"
	done
}

emit_stanza() {
	local deb="$1" fname="$2" pkgfile="$3"
	{
		if command -v dpkg-deb >/dev/null 2>&1; then
			dpkg-deb --info "$deb" > /dev/null 2>&1 || true
			dpkg-deb --showformat \
				'Package: ${Package}\nVersion: ${Version}\nArchitecture: ${Architecture}\nSection: ${Section}\nPriority: ${Priority}\nMaintainer: ${Maintainer}\nDepends: ${Depends}\nDescription: ${Description}\n' \
				--show "$deb" >> "$pkgfile" || true
		fi
		echo "Filename: $fname"
		echo "Size: $(stat -c %s "$deb")"
		echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
		echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
		echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
		echo "SHA512: $(sha512sum "$deb" | cut -d' ' -f1)"
	} >> "$pkgfile"
	echo >> "$pkgfile"
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
