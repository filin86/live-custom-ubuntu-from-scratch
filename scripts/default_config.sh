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

# Build target selection.
# TARGET_FORMAT=iso  — classic Live ISO (default, unchanged workflow).
# TARGET_FORMAT=rauc — immutable firmware for operator panels via RAUC.
export TARGET_FORMAT="${TARGET_FORMAT:-iso}"

# Hardware platform for the rauc target (ignored when TARGET_FORMAT=iso).
# Supported for MVP: pc-efi (x86_64/amd64 UEFI).
# Tablet boards add <board>-uboot values once the BSP is identified.
export TARGET_PLATFORM="${TARGET_PLATFORM:-pc-efi}"

# Target CPU architecture. Informational — debootstrap/apt arch still follows the host.
export TARGET_ARCH="${TARGET_ARCH:-amd64}"

# Immutable firmware bundle version (rauc target only).
# CI derives this from a git tag vYYYY.MM.DD.N -> YYYY.MM.DD.N.
# Local dev builds may pass a clearly marked dev version (for example dev.2026.04.20.1);
# dev versions must never be published to candidate/stable channels.
# Target scripts validate production versions against ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$.
# No default is set on purpose: silent wall-clock defaults are not allowed for production artifacts.
export RAUC_BUNDLE_VERSION="${RAUC_BUNDLE_VERSION:-}"

# Size of the tmpfs overlay upper layer for the immutable RAUC rootfs.
# Controls the combined room for runtime writes to /etc, /var/log, /tmp, etc.
# Ignored when TARGET_FORMAT=iso.
export INAUTO_OVERLAY_SIZE="${INAUTO_OVERLAY_SIZE:-2G}"

# Conventional paths inside /home/inauto used by site integration hooks.
export INAUTO_SITE_CONFIG_DIR="${INAUTO_SITE_CONFIG_DIR:-/home/inauto/config}"
export INAUTO_AUTOSTART_SCRIPT="${INAUTO_AUTOSTART_SCRIPT:-/home/inauto/on_login}"
export INAUTO_JOURNAL_DIR="${INAUTO_JOURNAL_DIR:-/home/inauto/log/journal}"

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
export CONFIG_FILE_VERSION="0.6"

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
