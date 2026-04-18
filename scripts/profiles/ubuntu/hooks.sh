#!/bin/bash
# Ubuntu profile hooks.

# CHROOT: install live-stack packages from live-packages.list.
function profile_install_live_stack() {
    apt_install_list "$PROFILE_DIR/live-packages.list"
}

# CHROOT: install kernel with Ubuntu-specific fallback retries.
function profile_kernel_install() {
    local kernel_pkg
    local concrete_generic
    local concrete_virtual
    kernel_pkg="${TARGET_KERNEL_PACKAGE:-$KERNEL_PKG_DEFAULT}"

    try_install_kernel_pkg() {
        local pkg="$1"
        apt-get install -y --no-install-recommends "$pkg" && return 0
        apt-get install -y --no-install-recommends -t "$TARGET_VERSION" "$pkg" && return 0
        return 1
    }

    apt-get update

    if try_install_kernel_pkg "$kernel_pkg"; then
        return 0
    fi

    echo "WARNING: failed to install kernel package: $kernel_pkg"

    if [[ "$kernel_pkg" != "linux-image-generic" ]]; then
        echo "WARNING: retrying with linux-image-generic"
        try_install_kernel_pkg linux-image-generic || true
    fi

    if ! dpkg -s linux-image-generic >/dev/null 2>&1 \
            && [[ "$TARGET_MIRROR" != "https://archive.ubuntu.com/ubuntu/" ]]; then
        echo "WARNING: retrying kernel install from fallback mirror: archive.ubuntu.com"
        cat <<EOF > /etc/apt/sources.list

deb https://archive.ubuntu.com/ubuntu/ $TARGET_VERSION main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu/ $TARGET_VERSION-security main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu/ $TARGET_VERSION-updates main restricted universe multiverse
EOF
        apt-get update
        try_install_kernel_pkg linux-image-generic || true
    fi

    if ! dpkg -s linux-image-generic >/dev/null 2>&1; then
        concrete_generic=$(apt-cache search '^linux-image-[0-9].*-generic$' \
            | awk '{print $1}' | sort -Vr | head -n1 || true)
        if [[ -n "$concrete_generic" ]]; then
            echo "WARNING: retrying with concrete package: $concrete_generic"
            try_install_kernel_pkg "$concrete_generic" || true
        fi
    fi

    if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
        concrete_virtual=$(apt-cache search '^linux-image-[0-9].*-virtual$' \
            | awk '{print $1}' | sort -Vr | head -n1 || true)
        if [[ -n "$concrete_virtual" ]]; then
            echo "WARNING: retrying with concrete package: $concrete_virtual"
            try_install_kernel_pkg "$concrete_virtual" || true
        fi
        try_install_kernel_pkg linux-image-virtual || true
    fi

    if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
        >&2 echo "ERROR: unable to install a bootable kernel package"
        return 1
    fi
}

# CHROOT: write marker file used by GRUB `search --file`.
# For Ubuntu: /image/ubuntu (empty file at image root).
function profile_write_image_marker() {
    touch /image/ubuntu
}

# CHROOT: render isolinux/grub.cfg and isolinux/isolinux.cfg from templates.
# Restricted envsubst variable list preserves $grub_platform in the template.
function profile_write_boot_configs() {
    LIVE_BOOT_DIR="$LIVE_BOOT_DIR" envsubst '$LIVE_BOOT_DIR' \
        < "$PROFILE_DIR/iso-layout/grub.cfg.template" \
        > /image/isolinux/grub.cfg
    LIVE_BOOT_DIR="$LIVE_BOOT_DIR" envsubst '$LIVE_BOOT_DIR' \
        < "$PROFILE_DIR/iso-layout/isolinux.cfg.template" \
        > /image/isolinux/isolinux.cfg
}
