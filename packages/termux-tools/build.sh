TERMUX_PKG_HOMEPAGE=https://termux.dev/
TERMUX_PKG_DESCRIPTION="Basic system tools for Termux"
TERMUX_PKG_LICENSE="GPL-3.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="1.46.0+really1.45.0"
TERMUX_PKG_REVISION=3
TERMUX_PKG_SRCURL=https://github.com/termux/termux-tools/archive/refs/tags/v1.45.0.tar.gz
TERMUX_PKG_SHA256=1ae29b1b875d95cc626dae323b45a2ace759969862d96094b2fa6d13bffe20d2
TERMUX_PKG_ESSENTIAL=true
#TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_TAG_TYPE="newest-tag"
TERMUX_PKG_BREAKS="termux-keyring (<< 1.9)"
TERMUX_PKG_CONFLICTS="procps (<< 3.3.15-2)"
TERMUX_PKG_SUGGESTS="termux-api"

# Some of these packages are not dependencies and used only to ensure
# that core packages are installed after upgrading (we removed busybox
# from essentials).
TERMUX_PKG_DEPENDS="bzip2, coreutils, curl, dash, diffutils, findutils, gawk, grep, gzip, less, procps, psmisc, sed, tar, termux-am (>= 0.8.0), termux-am-socket (>= 1.5.0), termux-core, termux-exec, util-linux, xz-utils, dialog"

# Optional packages that are distributed as part of bootstrap archives.
TERMUX_PKG_RECOMMENDS="ed, dos2unix, inetutils, net-tools, patch, unzip"

termux_step_pre_configure() {
	autoreconf -vfi
}

termux_step_post_make_install() {
	TERMUX_PKG_CONFFILES="$(cat "$TERMUX_PKG_BUILDDIR/conffiles")"
}

termux_step_make_install() {
	# Install fork mirror files (upstream mirrors removed by patch).
	# Only a single fork mirror exists, so every region points to it.
	# This keeps termux-change-repo working with no errors and ensures
	# pkg never fetches from upstream termux repositories.
	local fork_main="https://apex-studio-dev.github.io/termux-packages/apt/termux-main"
	local fork_root="https://apex-studio-dev.github.io/termux-packages/apt/termux-root"
	local fork_x11="https://apex-studio-dev.github.io/termux-packages/apt/termux-x11"

	for region in all asia chinese_mainland europe north_america oceania russia; do
		mkdir -p $TERMUX_PREFIX/etc/termux/mirrors/${region}
		cat > $TERMUX_PREFIX/etc/termux/mirrors/${region}/apex-studio-dev <<- EOF
		# This file is sourced by pkg
		# ApexStudio fork repository
		WEIGHT=10
		MAIN="${fork_main}"
		ROOT="${fork_root}"
		X11="${fork_x11}"
		EOF
	done

	mkdir -p $TERMUX_PREFIX/etc/termux/mirrors
	cat > $TERMUX_PREFIX/etc/termux/mirrors/default <<- EOF
	# This file is sourced by pkg
	# ApexStudio fork repository
	WEIGHT=10
	MAIN="${fork_main}"
	ROOT="${fork_root}"
	X11="${fork_x11}"
	EOF
}

termux_step_create_debscripts() {
	cat <<- EOF > ./preinst
	$(cat "$TERMUX_PKG_BUILDDIR/preinst")
	EOF
}
