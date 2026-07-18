#!/bin/bash
# Debian profile hooks.

# CHROOT: install live-stack + GRUB from live-packages.list.
function profile_install_live_stack() {
    apt_install_list "$PROFILE_DIR/live-packages.list"
}

# CHROOT: simple kernel install for Debian.
function profile_kernel_install() {
    local kernel_pkg
    kernel_pkg="${TARGET_KERNEL_PACKAGE:-$KERNEL_PKG_DEFAULT}"

    apt-get update

    if DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "$kernel_pkg"; then
        return 0
    fi

    echo "WARNING: failed to install kernel package: $kernel_pkg"

    if [[ "$kernel_pkg" != "linux-image-amd64" ]]; then
        echo "Retrying with linux-image-amd64"
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends linux-image-amd64 || true
    fi

    if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
        >&2 echo "ERROR: unable to install a bootable kernel for Debian"
        return 1
    fi
}

# CHROOT: write GRUB search marker at /image/.disk/info.
function profile_write_image_marker() {
    install -d -m 0755 /image/.disk
    cat <<EOF > /image/.disk/info
Inautomatic Debian ${TARGET_VERSION}
EOF
}

# CHROOT: render grub.cfg and isolinux.cfg from templates.
function profile_write_boot_configs() {
    LIVE_BOOT_DIR="$LIVE_BOOT_DIR" envsubst '$LIVE_BOOT_DIR' \
        < "$PROFILE_DIR/iso-layout/grub.cfg.template" \
        > /image/isolinux/grub.cfg
    LIVE_BOOT_DIR="$LIVE_BOOT_DIR" envsubst '$LIVE_BOOT_DIR' \
        < "$PROFILE_DIR/iso-layout/isolinux.cfg.template" \
        > /image/isolinux/isolinux.cfg
}
