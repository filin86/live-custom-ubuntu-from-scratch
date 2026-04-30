#!/bin/bash
# Factory installer live image configuration.
# Copied into chroot as /root/config.sh when INAUTO_IMAGE_ROLE=factory-installer.
# Do NOT source this for panel image builds — use config.sh instead.

export CONFIG_FILE_VERSION="0.6"

# This file configures only the live environment that runs the installer.
# Target OS/platform metadata is kept in config.sh and passed through build.sh.
export TARGET_NAME="${TARGET_NAME:-inauto-factory-installer-live}"
export INAUTO_IMAGE_ROLE="factory-installer"
export RAUC_PINNED_VERSION="${RAUC_PINNED_VERSION:-1.15.2}"
export GRUB_LIVEBOOT_LABEL="Inauto Panel Installer"
export TARGET_PACKAGE_REMOVE=""

AUTOLOGIN_USER="ubuntu"
AUTOLOGIN_SESSION="xfce"

DEFAULT_LOCALE="ru_RU.UTF-8"
FALLBACK_LOCALE="en_US.UTF-8"
DEFAULT_LANGUAGE="ru_RU:ru:en_US:en"
KEYBOARD_MODEL="pc105"
KEYBOARD_LAYOUTS="us,ru"
KEYBOARD_VARIANTS=","
KEYBOARD_OPTIONS="grp:caps_toggle"

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

function purge_installed_packages() {
    local packages_to_purge=()
    local package_name

    for package_name in "$@"; do
        if dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q '^install ok installed$'; then
            packages_to_purge+=("$package_name")
        fi
    done

    if [[ ${#packages_to_purge[@]} -gt 0 ]]; then
        apt-get purge -y "${packages_to_purge[@]}"
    fi
}

function install_pinned_rauc() {
    local installer="/root/install-rauc-source.sh"
    local actual

    if [[ ! -x "$installer" ]]; then
        echo "[rauc] ERROR: $installer отсутствует; build.sh::prechroot должен его скопировать." >&2
        exit 1
    fi

    RAUC_PINNED_VERSION="${RAUC_PINNED_VERSION:-1.15.2}" "$installer"

    actual="$(rauc --version 2>/dev/null | awk 'NR == 1 { print $NF }' || true)"
    if [[ "$actual" != "${RAUC_PINNED_VERSION:-1.15.2}" ]]; then
        echo "[rauc] ERROR: ожидался RAUC ${RAUC_PINNED_VERSION:-1.15.2}, получено '${actual:-<missing>}'" >&2
        exit 1
    fi
}

function net_config() {
    apt-get install -y netplan.io util-linux network-manager
    systemctl enable NetworkManager.service
#    systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service || true
#    systemctl mask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service || true
}

function ensure_network_manager_renderer() {
    mkdir -p /etc/netplan
    cat <<EOF_NETPLAN > /etc/netplan/01-network-manager-all.yaml
network:
  version: 2
  renderer: NetworkManager
EOF_NETPLAN
}

function configure_autologin() {
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat <<EOF_LIGHTDM > /etc/lightdm/lightdm.conf.d/50-inauto-autologin.conf
[Seat:*]
autologin-user=$AUTOLOGIN_USER
autologin-user-timeout=0
user-session=$AUTOLOGIN_SESSION
greeter-hide-users=true
allow-guest=false
EOF_LIGHTDM
}

function preseed_debconf() {
    cat <<EOF_DEBCONF | debconf-set-selections
locales locales/default_environment_locale select $DEFAULT_LOCALE
locales locales/locales_to_be_generated multiselect $DEFAULT_LOCALE UTF-8, $FALLBACK_LOCALE UTF-8
keyboard-configuration keyboard-configuration/modelcode string $KEYBOARD_MODEL
keyboard-configuration keyboard-configuration/layoutcode string $KEYBOARD_LAYOUTS
keyboard-configuration keyboard-configuration/variantcode string $KEYBOARD_VARIANTS
keyboard-configuration keyboard-configuration/optionscode string $KEYBOARD_OPTIONS
keyboard-configuration keyboard-configuration/store_defaults_in_debconf_db boolean true
keyboard-configuration keyboard-configuration/xkb-keymap select $KEYBOARD_LAYOUTS
EOF_DEBCONF
}

function configure_locale_keyboard() {
    preseed_debconf

    cat <<EOF_LOCALE_GEN > /etc/locale.gen
$DEFAULT_LOCALE UTF-8
$FALLBACK_LOCALE UTF-8
EOF_LOCALE_GEN

    locale-gen "$DEFAULT_LOCALE" "$FALLBACK_LOCALE"
    update-locale LANG="$DEFAULT_LOCALE" LANGUAGE="$DEFAULT_LANGUAGE"

    cat <<EOF_DEFAULT_LOCALE > /etc/default/locale
LANG=$DEFAULT_LOCALE
LANGUAGE=$DEFAULT_LANGUAGE
EOF_DEFAULT_LOCALE

    cat <<EOF_KEYBOARD > /etc/default/keyboard
XKBMODEL="$KEYBOARD_MODEL"
XKBLAYOUT="$KEYBOARD_LAYOUTS"
XKBVARIANT="$KEYBOARD_VARIANTS"
XKBOPTIONS="$KEYBOARD_OPTIONS"
BACKSPACE="guess"
EOF_KEYBOARD

    mkdir -p /etc/X11/Xsession.d
    cat <<EOF_XKB > /etc/X11/Xsession.d/90inauto-keyboard
#!/bin/sh

if command -v setxkbmap >/dev/null 2>&1; then
    setxkbmap -model "$KEYBOARD_MODEL" -layout "$KEYBOARD_LAYOUTS" -variant "$KEYBOARD_VARIANTS" -option "$KEYBOARD_OPTIONS"
fi
EOF_XKB

    chmod 755 /etc/X11/Xsession.d/90inauto-keyboard

    dpkg-reconfigure -f noninteractive locales keyboard-configuration console-setup
    setupcon --save-only || true
}

function configure_installer_initramfs() {
    install -d -m 0755 /etc/initramfs-tools/hooks /etc/initramfs-tools/scripts/init-top
    cat > /etc/initramfs-tools/hooks/inauto-live-casper <<'EOF_INITRAMFS_HOOK'
#!/bin/sh
# Force casper live-boot filesystem modules into the installer initramfs.
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
    prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
for mod in overlay squashfs loop isofs vfat nls_cp437 nls_ascii nls_utf8; do
    manual_add_modules "$mod" || true
done
EOF_INITRAMFS_HOOK
    chmod 0755 /etc/initramfs-tools/hooks/inauto-live-casper

    cat > /etc/initramfs-tools/scripts/init-top/inauto-live-casper <<'EOF_INITRAMFS_INIT_TOP'
#!/bin/sh
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
    prereqs) prereqs; exit 0 ;;
esac

modprobe overlay 2>/dev/null || true
modprobe squashfs 2>/dev/null || true
modprobe loop 2>/dev/null || true
modprobe isofs 2>/dev/null || true
EOF_INITRAMFS_INIT_TOP
    chmod 0755 /etc/initramfs-tools/scripts/init-top/inauto-live-casper

    # Запись в modules-list надёжнее хука: manual_add_modules с || true молча
    # пропустит модуль, если хук не смог разрешить путь к ko-файлу.
    grep -qxF 'overlay' /etc/initramfs-tools/modules 2>/dev/null \
        || printf 'overlay\nsquashfs\n' >> /etc/initramfs-tools/modules

    if compgen -G "/boot/vmlinuz-*" >/dev/null; then
        echo "[installer] пересобираю initramfs с casper overlay modules"
        update-initramfs -u -k all
    else
        echo "[installer] WARNING: ядро не установлено; initramfs обновится при установке kernel-пакета" >&2
    fi
}

function patch_casper_overlay_probe() {
    local casper_script="/usr/share/initramfs-tools/scripts/casper"
    local tmp

    if [[ ! -f "$casper_script" ]]; then
        echo "[installer] WARNING: $casper_script не найден; overlay probe patch пропущен" >&2
        return 0
    fi

    tmp="$(mktemp)"
    awk '
        index($0, "modprobe \"${MP_QUIET}\" -b overlay || panic \"/cow format specified as '\''overlay'\'' and no support found\"") {
            print "    if ! grep -qw overlay /proc/filesystems; then"
            print "        modprobe \"${MP_QUIET}\" -b overlay || true"
            print "    fi"
            print "    grep -qw overlay /proc/filesystems \\"
            print "        || panic \"/cow format specified as '\''overlay'\'' and no support found\""
            next
        }
        { print }
    ' "$casper_script" > "$tmp"

    if cmp -s "$casper_script" "$tmp"; then
        rm -f "$tmp"
        echo "[installer] casper overlay probe already patched"
        return 0
    fi

    mv "$tmp" "$casper_script"
    chmod 0644 "$casper_script"
    echo "[installer] patched casper overlay probe"
}

function install_rauc_factory_installer_launcher() {
    install -d -m 0755 /usr/local/sbin /etc/xdg/autostart /etc/skel/Desktop

    cat > /usr/local/sbin/inauto-factory-installer-autostart <<'EOF_FACTORY_INSTALLER'
#!/bin/sh
set -eu

MODE="${1:-manual}"
MARKER="${XDG_RUNTIME_DIR:-/tmp}/inauto-factory-installer-started"
SHORTCUT_NAME="Inauto Panel Installer.desktop"

ensure_desktop_shortcut() {
    user_home="${HOME:-}"
    [ -n "$user_home" ] || return 0

    desktop_dir="$user_home/Desktop"
    shortcut="$desktop_dir/$SHORTCUT_NAME"

    mkdir -p "$desktop_dir" 2>/dev/null || return 0
    cat > "$shortcut" <<'EOF_SHORTCUT'
[Desktop Entry]
Type=Application
Name=Inauto Panel Installer
Comment=Install Inauto panel firmware
Exec=/usr/local/sbin/inauto-factory-installer-autostart
Terminal=false
Categories=System;
EOF_SHORTCUT
    chmod 0755 "$shortcut" 2>/dev/null || true

    if command -v gio >/dev/null 2>&1; then
        gio set "$shortcut" metadata::trusted true >/dev/null 2>&1 || true
    fi
}

run_payload() {
    if [ "$(id -u)" -eq 0 ]; then
        exec "$PAYLOAD"
    fi

    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec env \
            "DISPLAY=${DISPLAY:-}" \
            "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" \
            "XAUTHORITY=${XAUTHORITY:-}" \
            "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" \
            "$PAYLOAD"
    fi

    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E "$PAYLOAD"
    fi

    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        zenity --error \
            --title="Inauto Panel Installer" \
            --width=620 \
            --text="Нужны права root, но pkexec/sudo не найдены."
    else
        echo "ERROR: root privileges required, but pkexec/sudo not found" >&2
    fi
    exit 1
}

PAYLOAD=""
for _try in $(seq 1 30); do
    for _base in /cdrom /media/cdrom /run/live/medium /media/*/*; do
        if [ -x "$_base/inauto-installer/START-INSTALLER.sh" ]; then
            PAYLOAD="$_base/inauto-installer/START-INSTALLER.sh"
            break 2
        fi
    done
    sleep 1
done

ensure_desktop_shortcut

[ -n "$PAYLOAD" ] || exit 0

if [ "$MODE" = "--autostart" ]; then
    [ -e "$MARKER" ] && exit 0
    touch "$MARKER"

    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        if zenity --question \
            --title="Inauto Panel Installer" \
            --width=620 \
            --text="Запустить мастер установки Inauto Panel?\n\nВнимание: мастер форматирует выбранный диск панели."; then
            run_payload
        fi
        exit 0
    fi

    if command -v x-terminal-emulator >/dev/null 2>&1; then
        exec x-terminal-emulator -e "$0"
    fi
fi

run_payload
EOF_FACTORY_INSTALLER
    chmod 0755 /usr/local/sbin/inauto-factory-installer-autostart

    cat > /etc/xdg/autostart/inauto-factory-installer.desktop <<'EOF_FACTORY_DESKTOP'
[Desktop Entry]
Type=Application
Name=Inauto Factory Installer
Exec=/usr/local/sbin/inauto-factory-installer-autostart --autostart
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF_FACTORY_DESKTOP
    chmod 0644 /etc/xdg/autostart/inauto-factory-installer.desktop

    cat > "/etc/skel/Desktop/Inauto Panel Installer.desktop" <<'EOF_FACTORY_DESKTOP_SHORTCUT'
[Desktop Entry]
Type=Application
Name=Inauto Panel Installer
Comment=Install Inauto panel firmware
Exec=/usr/local/sbin/inauto-factory-installer-autostart
Terminal=false
Categories=System;
EOF_FACTORY_DESKTOP_SHORTCUT
    chmod 0755 "/etc/skel/Desktop/Inauto Panel Installer.desktop"

    echo "[rauc] factory installer launcher установлен"
}

# ---------------------------------------------------------------
# Build hooks (called by chroot_build.sh)
# ---------------------------------------------------------------

function customize_image() {
    # Keep the installer desktop as close as possible to a stock XFCE live
    # environment to reduce surprises during boot and session startup.
    apt-get install -y \
        xorg \
        lightdm \
        xfce4 \
        xfce4-goodies

    apt-get install -y --no-install-recommends \
        ca-certificates \
        locales \
        kbd \
        keyboard-configuration \
        console-setup \
        dbus-x11 \
        sudo \
        udisks2 \
        gvfs \
        libglib2.0-bin \
        rauc \
        jq \
        zstd \
        gdisk \
        dosfstools \
        e2fsprogs \
        parted \
        uuid-runtime \
        util-linux \
        coreutils \
        tar \
        squashfs-tools \
        openssh-client \
        efibootmgr \
        zenity \
        pkexec

    install_pinned_rauc

    purge_installed_packages \
        apport \
        apport-core-dump-handler \
        apport-gtk \
        cloud-init \
        cups \
        cups-browsed \
        cups-daemon \
        firefox \
        fwupd \
        fwupd-signed \
        gnome-remote-desktop \
        openssh-server \
        openssh-sftp-server \
        snapd \
        task-gnome-desktop \
        ubuntu-desktop-minimal \
        unattended-upgrades \
        update-manager \
        update-notifier

    apt-get autoremove --purge -y
}

function custom_conf() {
    # Desktop session: casper creates user from USERNAME in casper.conf
    cat > /etc/casper.conf <<EOF_CASPER
export USERNAME="$AUTOLOGIN_USER"
export USERFULLNAME="Inauto Factory Installer"
export HOST="$TARGET_NAME"
EOF_CASPER

    configure_autologin
    systemctl enable lightdm.service || true
    ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
    systemctl set-default graphical.target

    # Overlay module must be in initramfs for casper COW to work
    patch_casper_overlay_probe
    configure_installer_initramfs

    install_rauc_factory_installer_launcher

    # RAUC identity for the installer environment
    install -d -m 0755 /etc/rauc
    cat > /etc/rauc/system.conf <<'EOF_RAUC_INSTALLER_CONF'
[system]
compatible=inauto-panel-installer
bootloader=noop
bundle-formats=-plain
data-directory=/var/lib/rauc
EOF_RAUC_INSTALLER_CONF
    chmod 0644 /etc/rauc/system.conf

    # Passwordless sudo for installer session user
    install -d -m 0755 /etc/sudoers.d
    cat > "/etc/sudoers.d/90-inauto-factory-installer" <<EOF_SUDOERS
$AUTOLOGIN_USER ALL=(ALL) NOPASSWD:ALL
EOF_SUDOERS
    chmod 0440 "/etc/sudoers.d/90-inauto-factory-installer"

    configure_locale_keyboard
    net_config
    ensure_network_manager_renderer

    systemctl daemon-reload
    systemctl enable NetworkManager.service
}
