TERMUX_PKG_HOMEPAGE=https://github.com/termux/glibc-packages
TERMUX_PKG_DESCRIPTION="A package repository containing glibc-based programs and libraries"
TERMUX_PKG_LICENSE="Apache-2.0"
TERMUX_PKG_MAINTAINER="@termux-pacman"
TERMUX_PKG_VERSION=1.0
TERMUX_PKG_AUTO_UPDATE=false
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_PLATFORM_INDEPENDENT=true

termux_step_make_install() {
	mkdir -p $TERMUX_PREFIX/etc/apt/sources.list.d
	{
		echo "# ApexStudio fork glibc repository"
		echo "deb https://apex-studio-dev.github.io/glibc-packages/apt/termux-glibc/ glibc stable"
	} > $TERMUX_PREFIX/etc/apt/sources.list.d/glibc.list
}

termux_step_create_debscripts() {
	[ "$TERMUX_PACKAGE_FORMAT" = "pacman" ] && return 0
	echo "#!$TERMUX_PREFIX/bin/sh" > postinst
	echo "echo Downloading updated package list ..." >> postinst
	echo "apt update" >> postinst
	echo "exit 0" >> postinst
}
