#!/bin/bash

# This script provides common customization options for the ISO
#
# Usage: Copy this file to config.sh and make changes there. Keep this file (default_config.sh) as-is
# so that subsequent changes can be easily merged from upstream. Keep all customisations in config.sh

# Distro selector. Allowed: ubuntu, debian.
export TARGET_DISTRO="${TARGET_DISTRO:-ubuntu}"

# Ubuntu: tested >= noble (24.04). Older releases not supported.
# See https://wiki.ubuntu.com/DevelopmentCodeNames for details
export TARGET_UBUNTU_VERSION="noble"
export TARGET_UBUNTU_MIRROR="https://archive.ubuntu.com/ubuntu/"

# Debian: tested >= trixie (13). forky (testing) and sid (unstable) accepted but experimental.
export TARGET_DEBIAN_VERSION="trixie"
export TARGET_DEBIAN_MIRROR="http://deb.debian.org/debian/"

# Kernel package name. Override in config.sh if needed.
# Ubuntu default: linux-generic. Debian default: linux-image-amd64.
# If unset, the profile's KERNEL_PKG_DEFAULT is used.
# export TARGET_KERNEL_PACKAGE="linux-generic"

# The file (no extension) of the ISO containing the generated disk image,
# the volume id, and the hostname of the live environment are set from this name.
export TARGET_NAME="ubuntu-from-scratch"

# The text label shown in GRUB for booting into the live environment
export GRUB_LIVEBOOT_LABEL="Try Ubuntu FS without installing"

# The text label shown in GRUB for starting installation
export GRUB_INSTALL_LABEL="Install Ubuntu FS"

# Packages to be removed from the manifest shown to the installer (legacy ubiquity integration).
# Not an apt purge - only affects casper/filesystem.manifest-desktop.
export TARGET_PACKAGE_REMOVE="
    ubiquity \
    casper \
    discover \
    laptop-detect \
    os-prober \
"

# Used to version the configuration. If breaking changes occur, manual
# updates to this file from the default may be necessary.
export CONFIG_FILE_VERSION="0.5"

# Package customisation function.  Update this function to customize packages
# present on the installed system.
function customize_image() {
    # install graphics and desktop
    apt-get install -y \
        plymouth-themes \
        ubuntu-gnome-desktop \
        ubuntu-gnome-wallpapers

    # useful tools
    apt-get install -y \
        clamav-daemon \
        terminator \
        apt-transport-https \
        curl \
        vim \
        nano \
        less

    # purge
    apt-get purge -y \
        transmission-gtk \
        transmission-common \
        gnome-mahjongg \
        gnome-mines \
        gnome-sudoku \
        aisleriot \
        hitori
}
