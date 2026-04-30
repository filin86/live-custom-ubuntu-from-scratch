#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

CMD=(setup_host install_pkg customize_image custom_conf postpkginst build_image finish_up)

# Profile is installed into chroot by build.sh::prechroot.
PROFILE_DIR="/root/profile"
if [[ ! -d "$PROFILE_DIR" ]]; then
    >&2 echo "ERROR: $PROFILE_DIR missing inside chroot; build.sh::prechroot must copy it"
    exit 1
fi
# shellcheck source=/dev/null
. "$PROFILE_DIR/profile.env"
# shellcheck source=/dev/null
. "$PROFILE_DIR/hooks.sh"

# Resolve target version/mirror from profile-indirected variable names.
TARGET_VERSION="${!VERSION_VAR_NAME}"
TARGET_MIRROR="${!MIRROR_VAR_NAME}"

# Helper — apt-install from a text-file list (lines, # comments).
function apt_install_list() {
    local list_file="$1"
    local -a pkgs=()
    local line

    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && pkgs+=("$line")
    done < "$list_file"

    if (( ${#pkgs[@]} == 0 )); then
        echo "No packages in $list_file"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

function help() {
    # if $1 is set, use $1 as headline message in help()
    if [[ -z "${1+x}" ]]; then
        printf '%s\n\n' "This script builds Ubuntu from scratch"
    else
        printf '%s\n\n' "$1"
    fi
    printf '%s\n\n' "Supported commands : ${CMD[*]}"
    printf '%s\n' "Syntax: $0 [start_cmd] [-] [end_cmd]"
    printf '\t%s\n' "run from start_cmd to end_end"
    printf '\t%s\n' "if start_cmd is omitted, start from first command"
    printf '\t%s\n' "if end_cmd is omitted, end with last command"
    printf '\t%s\n' "enter single cmd to run the specific command"
    printf '\t%s\n\n' "enter '-' as only argument to run all commands"
    exit 0
}

function find_index() {
    local i;
    for ((i=0; i<${#CMD[*]}; i++)); do
        if [ "${CMD[i]}" == "$1" ]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}

function require_efi_loader() {
    local loader="$1"
    local package_hint="$2"

    if [[ ! -s "$loader" ]]; then
        >&2 printf 'ERROR: required EFI loader not found: %s\n' "$loader"
        >&2 printf '       Check that profile live-packages.list installs %s.\n' "$package_hint"
        exit 1
    fi
}

function check_host() {
    if [ $(id -u) -ne 0 ]; then
        echo "This script should be run as 'root'"
        exit 1
    fi

    export HOME=/root
    export LC_ALL=C
    export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
    export DEBCONF_NONINTERACTIVE_SEEN=true
}

function setup_host() {
    echo "=====> running setup_host ..."

    TARGET_MIRROR="$TARGET_MIRROR" TARGET_VERSION="$TARGET_VERSION" \
        envsubst '$TARGET_MIRROR $TARGET_VERSION' \
        < "$PROFILE_DIR/sources.list.template" \
        > /etc/apt/sources.list

    echo "$TARGET_NAME" > /etc/hostname

    apt-get update
    apt-get install -y libterm-readline-gnu-perl systemd-sysv dbus-bin

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    if ! dpkg-divert --list /sbin/initctl | grep -q 'local diversion'; then
        dpkg-divert --local --rename --add /sbin/initctl
    fi
    rm -f /sbin/initctl
    ln -s /bin/true /sbin/initctl
}

# Load configuration values from file
function load_config() {
    if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
        >&2 echo "ERROR: $SCRIPT_DIR/config.sh не найден — build.sh должен был его скопировать в chroot."
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/config.sh"
}


function install_pkg() {
    echo "=====> running install_pkg ... will take a long time ..."

    if declare -F preseed_debconf >/dev/null 2>&1; then
        preseed_debconf
    fi

    apt-get -y upgrade

    # Install live-stack and GRUB packages from profile.
    profile_install_live_stack

    # Install kernel via profile-specific hook.
    profile_kernel_install

    # graphic installer - ubiquity (intentionally disabled in this fork)
    #apt-get install -y \
    #    ubiquity \
    #    ubiquity-casper \
    #    ubiquity-frontend-gtk \
    #    ubiquity-slideshow-ubuntu \
    #    ubiquity-ubuntu-artwork
}

function postpkginst() {
    # remove unused and clean up apt cache
    apt-get autoremove -y

    # final touch
    dpkg-reconfigure -f noninteractive locales keyboard-configuration console-setup

    if [[ "${LIVECD_KEEP_APT_CACHE:-0}" == "1" ]]; then
        echo "Keeping apt package cache for faster rebuilds (LIVECD_KEEP_APT_CACHE=1)"
    else
        apt-get clean -y
    fi
}

function build_image() {
    echo "=====> running build_image ..."

    rm -rf /image

    mkdir -p /image/{$LIVE_BOOT_DIR,isolinux,install}

    pushd /image

    # copy kernel files
    local kernel_src
    local initrd_src

    kernel_src=""
    initrd_src=""

    if [[ -e /vmlinuz ]]; then
        kernel_src="$(readlink -f /vmlinuz)"
    fi
    if [[ -e /initrd.img ]]; then
        initrd_src="$(readlink -f /initrd.img)"
    fi

    if [[ -z "$kernel_src" ]]; then
        kernel_src=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1 || true)
    fi
    if [[ -z "$initrd_src" ]]; then
        initrd_src=$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)
    fi

    if [[ -z "$kernel_src" || -z "$initrd_src" ]]; then
        >&2 echo "ERROR: unable to locate kernel/initrd in chroot"
        >&2 echo "kernel_src=$kernel_src initrd_src=$initrd_src"
        exit 1
    fi

    cp "$kernel_src" "$LIVE_BOOT_DIR/$LIVE_KERNEL_NAME"
    cp "$initrd_src" "$LIVE_BOOT_DIR/$LIVE_INITRD_NAME"

    # memtest86+ comes from the distro package instead of an unverified network archive.
    if [[ ! -s /boot/memtest86+x64.bin || ! -s /boot/memtest86+x64.efi ]]; then
        >&2 echo "ERROR: memtest86+ package files not found in /boot"
        >&2 echo "Install the memtest86+ package in the live profile before building the ISO"
        exit 1
    fi
    install -m 0644 /boot/memtest86+x64.bin install/memtest86+.bin
    install -m 0644 /boot/memtest86+x64.efi install/memtest86+.efi

    # grub
    profile_write_image_marker
    profile_write_boot_configs

    # generate manifest
    dpkg-query -W --showformat='${Package} ${Version}\n' | tee $LIVE_BOOT_DIR/filesystem.manifest

    cp -v $LIVE_BOOT_DIR/filesystem.manifest $LIVE_BOOT_DIR/filesystem.manifest-desktop

    for pkg in $TARGET_PACKAGE_REMOVE; do
        sed -i "/$pkg/d" $LIVE_BOOT_DIR/filesystem.manifest-desktop
    done

    # create diskdefines
    cat <<EOF > README.diskdefines
#define DISKNAME  ${GRUB_LIVEBOOT_LABEL}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

    # copy EFI loaders
    local efi_grub_dir="${EFI_GRUB_DIR:-ubuntu}"
    local shim_loader="/usr/lib/shim/shimx64.efi.signed"
    local mok_manager="/usr/lib/shim/mmx64.efi"
    local grub_loader="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"

    if [[ ! "$efi_grub_dir" =~ ^[A-Za-z0-9._-]+$ ]]; then
        >&2 echo "ERROR: EFI_GRUB_DIR contains unsupported characters: $efi_grub_dir"
        exit 1
    fi

    require_efi_loader "$shim_loader" "shim-signed"
    require_efi_loader "$mok_manager" "shim-signed"
    require_efi_loader "$grub_loader" "grub-efi-amd64-signed"

    cp "$shim_loader" isolinux/bootx64.efi
    cp "$mok_manager" isolinux/mmx64.efi
    cp "$grub_loader" isolinux/grubx64.efi

    # create a FAT16 UEFI boot disk image containing the EFI bootloaders
    (
        cd isolinux && \
        dd if=/dev/zero of=efiboot.img bs=1M count=10 && \
        mkfs.vfat -F 16 efiboot.img && \
        LC_CTYPE=C mmd -i efiboot.img efi "efi/$efi_grub_dir" efi/boot && \
        LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/bootx64.efi && \
        LC_CTYPE=C mcopy -i efiboot.img ./mmx64.efi ::efi/boot/mmx64.efi && \
        LC_CTYPE=C mcopy -i efiboot.img ./grubx64.efi ::efi/boot/grubx64.efi && \
        LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg "::efi/$efi_grub_dir/grub.cfg"
    )

    # create a grub BIOS image
    grub-mkstandalone \
      --format=i386-pc \
      --output=isolinux/core.img \
      --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
      --modules="linux16 linux normal iso9660 biosdisk search" \
      --locales="" \
      --fonts="" \
      "boot/grub/grub.cfg=isolinux/grub.cfg"

    # combine a bootable Grub cdboot.img
    cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img

    # generate md5sum.txt
    /bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'isolinux' > md5sum.txt)"

    popd # return initial directory
}

function finish_up() { 
    echo "=====> finish_up"

    # truncate machine id (why??)
    truncate -s 0 /etc/machine-id

    # remove diversion (why??)
    rm -f /sbin/initctl
    if dpkg-divert --list /sbin/initctl | grep -q 'local diversion'; then
        dpkg-divert --rename --remove /sbin/initctl
    fi

    rm -rf /tmp/* ~/.bash_history
}

# =============   main  ================

load_config
check_host

# check number of args
if (( $# == 0 || $# > 3 )); then help; fi

# loop through args
dash_flag=false
start_index=0
end_index=${#CMD[*]}
cmd_index=0
for ii in "$@";
do
    if [[ $ii == "-" ]]; then
        dash_flag=true
        continue
    fi
    if ! cmd_index="$(find_index "$ii")"; then
        help "Command not found : $ii"
    fi
    if [[ $dash_flag == false ]]; then
        start_index=$cmd_index
    else
        end_index=$((cmd_index + 1))
    fi
done
if [[ $dash_flag == false ]]; then
    end_index=$((start_index + 1))
fi

# loop through the commands
for ((ii=$start_index; ii<$end_index; ii++)); do
    ${CMD[ii]}
done

echo "$0 - Step is complete!"
