#!/usr/bin/env bash
##
## gen-repo-files.sh - generate an APT repository (dists/Packages/Release/InRelease)
##                    from a directory of .deb files, using GPG signing.
##
## Generates the dists tree (Packages/Contents indexes) and produces
## Release/InRelease with the standard Debian tooling (apt-ftparchive release
## + gpg), so a forked termux-packages repo can host its own apt repos over
## static hosting (e.g. GitHub Pages) without needing an aptly server.
##
## Layout produced (under <output>):
##   dists/<dist>/<comp>/binary-<arch>/Packages[.gz]
##   dists/<dist>/<comp>/Contents-<arch>.gz   (file -> package map; used by
##                                            command-not-found's generate-db.js)
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
##
## Filenames in Packages are RELATIVE to the repository root
## (pool/<component>/<arch>/<file>.deb), so apt resolves downloads against the
## source's base URI. Large .deb files (e.g. openjdk) are hosted in the
## separate R2 "termux-big" repo (see publish-gh-pages.sh); pass them to the
## normal --debs flow there so they get the same relative pool Filenames.
set -euo pipefail

DEBS_DIR=""
OUT_DIR=""
GPG_KEY=""
SUITE="stable"
COMPONENT="main"
ARCHES=(aarch64 arm i686 x86_64 all)

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
		-h|-help|--help) usage;;
		*) echo "Unknown option: $1" >&2; usage;;
	esac
done

[[ -n "$DEBS_DIR" && -n "$OUT_DIR" ]] || { echo "Error: --debs and --out are required" >&2; usage; }
[[ -d "$DEBS_DIR" ]] || { echo "Error: debs dir '$DEBS_DIR' does not exist" >&2; exit 1; }

APT_ROOT="$OUT_DIR"
if ! command -v apt-ftparchive >/dev/null 2>&1; then
	echo "Error: apt-ftparchive not found in PATH (install apt-utils / the apt-ftparchive package)" >&2
	exit 1
fi
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
	local f arch dest
	for f in "${DEB_FILES[@]}"; do
		# Derive arch from the deb control file (Termux uses arch names like
		# x86_64 which contain '_', so filename parsing is unreliable).
		arch="$(dpkg-deb --field "$f" Architecture 2>/dev/null || true)"
		[[ -n "$arch" && " ${ARCHES[*]} " == *" $arch "* ]] || arch="all"
		dest="$APT_ROOT/pool/$COMPONENT/$arch/$(basename "$f")"
		# The caller may stage debs already in the pool (as symlinks pointing at
		# the pool itself); copying such a deb onto itself is a no-op.
		[[ "$(realpath -m "$f")" == "$(realpath -m "$dest")" ]] && continue
		mkdir -p "$APT_ROOT/pool/$COMPONENT/$arch"
		cp -f "$f" "$dest"
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
		gzip -9nc "$pkgfile" > "$pkgfile.gz"
		xz -9c "$pkgfile" > "$pkgfile.xz"
		echo "Generated: $pkgfile ($(wc -l < "$pkgfile") lines)"
	done
}

emit_stanza() {
	local deb="$1" fname="$2" pkgfile="$3"
	{
		if command -v dpkg-deb >/dev/null 2>&1; then
			dpkg-deb --info "$deb" > /dev/null 2>&1 || true
			# Mirror the control fields registered in dpkg/status (Installed-Size,
			# Homepage, Breaks, Replaces, ...) so apt's version-node hash matches the
			# installed record; otherwise the same version string is treated as a
			# different version node and packages show as "upgradable from: <same>".
			# Only fields actually present in the deb control are emitted (dpkg-deb
			# --showformat would synthesize empty / "no" defaults for absent fields).
			local f field val
			for field in Package Version Architecture Installed-Size Maintainer \
				Section Priority Depends Pre-Depends Recommends Suggests Conflicts \
				Breaks Replaces Provides Essential Multi-Arch Homepage Description; do
				val="$(dpkg-deb --field "$deb" "$field" 2>/dev/null)" || val=
				[[ -n "$val" ]] && [[ "$val" != "no" ]] && \
					printf '%s: %s\n' "$field" "$val"
			done
		fi
		echo "Filename: $fname"
		# -L: stat args may be symlinks (pool debs staged via symlink); GNU stat
		# defaults to lstat, which would report the link length, not the file size.
		echo "Size: $(stat -Lc %s "$deb")"
		echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
		echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
		echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
		echo "SHA512: $(sha512sum "$deb" | cut -d' ' -f1)"
	} >> "$pkgfile"
	echo >> "$pkgfile"
}

gen_contents() {
	# Generate dists/<SUITE>/<COMPONENT>/Contents-<arch>.gz for each real
	# architecture: one "path package" line per file shipped by every package
	# in the pool (paths relative to /, e.g.
	# data/data/com.termux/files/usr/bin/foo). command-not-found builds its
	# command database from these files; Contents lives under the component
	# dir (as in Debian / the working aurastudio reference repo) and is
	# collected by apt-ftparchive release. The "all" arch is skipped:
	# generate-db.js only ever requests the four real architectures
	# (TERMUX_ARCH).
	local arch deb pkg_name tmpf
	for arch in "${ARCHES[@]}"; do
		[[ "$arch" == "all" ]] && continue
		local contents_file="$APT_ROOT/dists/$SUITE/$COMPONENT/Contents-$arch"
		tmpf="$(mktemp)"
		: > "$tmpf"
		for deb in "$APT_ROOT"/pool/"$COMPONENT"/"$arch"/*.deb; do
			[[ -f "$deb" ]] || continue
			pkg_name="$(dpkg-deb --field "$deb" Package 2>/dev/null)" || continue
			[[ -n "$pkg_name" ]] || continue
			# tar -tf lists one path per line (symlinks included, directories
			# end with /); strip the leading "./" that tar emits.
			dpkg-deb --fsys-tarfile "$deb" 2>/dev/null | tar -tf - 2>/dev/null | \
				while IFS= read -r p; do
					[[ "$p" == */ ]] && continue
					p="${p#./}"
					[[ -n "$p" ]] && printf '%s %s\n' "$p" "$pkg_name"
				done >> "$tmpf" || true
		done
		sort -u "$tmpf" > "$contents_file"
		gzip -9nc "$contents_file" > "$contents_file.gz"
		xz -9c "$contents_file" > "$contents_file.xz"
		echo "Generated: $contents_file.gz ($(sort -u "$tmpf" | wc -l) entries)"
		rm -f "$tmpf"
	done
}

gen_release_and_sign() {
	local rel_dir="$APT_ROOT/dists/$SUITE"
	local rel_file="$rel_dir/Release"
	# Use the standard Debian tooling: apt-ftparchive scans the dists tree and
	# writes MD5Sum/SHA1/SHA256/SHA512 sections (plus a self "Release" entry),
	# which apt 2.8+ parses reliably. The hand-written hasher previously
	# produced an InRelease that this apt rejected with "No Hash entry".
	local opts=(
		-o "APT::FTPArchive::Release::Origin=ApexStudio"
		-o "APT::FTPArchive::Release::Label=ApexStudio"
		-o "APT::FTPArchive::Release::Suite=$SUITE"
		-o "APT::FTPArchive::Release::Codename=$SUITE"
		-o "APT::FTPArchive::Release::Components=$COMPONENT"
		-o "APT::FTPArchive::Release::Architectures=${ARCHES[*]}"
		-o "APT::FTPArchive::Release::Description=ApexStudio apt repository"
	)
	apt-ftparchive release "${opts[@]}" "$rel_dir" > "$rel_file"

	if (( HAS_GPG )); then
		gpg --batch --yes --armor --detach-sign -o "$rel_file.gpg" "$rel_file"
		gpg --batch --yes --armor --clearsign -o "$rel_dir/InRelease" "$rel_file"
		echo "Signed repository with key: $GPG_KEY"
	else
		echo "Warning: repository NOT signed (--gpg-key missing)"
	fi
}

copy_pool

# Keep only the highest version of each package per architecture, mirroring the
# upstream termux convention that their Packages index never lists a package
# more than once. Old versions otherwise accumulate in the pool forever because
# publish-gh-pages.sh re-merges every deb previously staged there.
prune_pool() {
	local arch dir deb pkg ver
	for arch in "${ARCHES[@]}"; do
		dir="$APT_ROOT/pool/$COMPONENT/$arch"
		[[ -d "$dir" ]] || continue
		declare -A best_ver=() best_file=()
		for deb in "$dir"/*.deb; do
			[[ -f "$deb" ]] || continue
			read -r pkg ver < <(dpkg-deb --showformat='${Package} ${Version}\n' --show "$deb" 2>/dev/null || true) || true
			[[ -n "$pkg" && -n "$ver" ]] || continue
			if [[ -n "${best_ver[$pkg]:-}" ]]; then
				if dpkg --compare-versions "$ver" gt "${best_ver[$pkg]}"; then
					rm -f "${best_file[$pkg]}"
					best_ver[$pkg]="$ver"
					best_file[$pkg]="$deb"
				else
					rm -f "$deb"
				fi
			else
				best_ver[$pkg]="$ver"
				best_file[$pkg]="$deb"
			fi
		done
	done
}

prune_pool
gen_packages
gen_contents
gen_release_and_sign

echo "Done. Repository written to: $APT_ROOT"
