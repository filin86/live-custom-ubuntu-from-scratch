#!/bin/bash

# Основной конфиг сборки. Обязателен — build.sh падает при его отсутствии.
# Для заводского образа-инсталлятора используется scripts/config-installer.sh.

# The version of Ubuntu to generate. Successfully tested LTS: bionic, focal, jammy, noble
# See https://wiki.ubuntu.com/DevelopmentCodeNames for details
export TARGET_UBUNTU_VERSION="noble"

# The Ubuntu Mirror URL. It's better to change for faster download.
# More mirrors see: https://launchpad.net/ubuntu/+archivemirrors
export TARGET_UBUNTU_MIRROR="https://archive.ubuntu.com/ubuntu/"

# Distro selector.
export TARGET_DISTRO="${TARGET_DISTRO:-ubuntu}"

# Build profile selector. Defaults to TARGET_DISTRO for normal images.
export TARGET_PROFILE="${TARGET_PROFILE:-$TARGET_DISTRO}"

# Debian parameters (active when TARGET_DISTRO=debian).
export TARGET_DEBIAN_VERSION="trixie"
export TARGET_DEBIAN_MIRROR="http://deb.debian.org/debian/"

# The packaged version of the Linux kernel to install on target image.
export TARGET_KERNEL_PACKAGE="linux-generic"

# The file (no extension) of the ISO containing the generated disk image,
# the volume id, and the hostname of the live environment are set from this name.
export TARGET_NAME="${TARGET_NAME:-inauto-${TARGET_DISTRO:-ubuntu}-livecd}"

# Build target selection.
# TARGET_FORMAT=iso  — classic Live ISO (default, current workflow).
# TARGET_FORMAT=rauc — immutable firmware via RAUC; see docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md.
export TARGET_FORMAT="${TARGET_FORMAT:-iso}"

# panel             — обычный образ панели;
# factory-installer — отдельная live-среда для прошивки панели из RAUC payload.
export INAUTO_IMAGE_ROLE="${INAUTO_IMAGE_ROLE:-panel}"

# Hardware platform for the rauc target (ignored when TARGET_FORMAT=iso).
# Supported for MVP: pc-efi (x86_64/amd64 UEFI).
export TARGET_PLATFORM="${TARGET_PLATFORM:-pc-efi}"

# Target CPU architecture for debootstrap and target metadata.
export TARGET_ARCH="${TARGET_ARCH:-amd64}"

# Immutable firmware bundle version (rauc target only).
# Must be provided explicitly for release builds; CI derives it from the git tag.
# Production versions must match ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$.
export RAUC_BUNDLE_VERSION="${RAUC_BUNDLE_VERSION:-}"

# RAUC CLI/runtime version built from upstream source.
export RAUC_PINNED_VERSION="${RAUC_PINNED_VERSION:-1.15.2}"

# Version suffix for RAUC compatible strings:
# inauto-panel-<distro>-<arch>-<platform>-<RAUC_COMPATIBLE_VERSION>.
# v2: загрузка через единый GRUB на efi_A (bundle rootfs-only); v1-панели
# мигрируются заводским инсталлятором (см. docs/2026-07-04-grub-boot-selection-design.md).
export RAUC_COMPATIBLE_VERSION="${RAUC_COMPATIBLE_VERSION:-v2}"

# Size of the tmpfs overlay upper layer for the immutable RAUC rootfs.
export INAUTO_OVERLAY_SIZE="${INAUTO_OVERLAY_SIZE:-2G}"

# Conventional paths inside /home/inauto used by site integration hooks.
export INAUTO_SITE_CONFIG_DIR="${INAUTO_SITE_CONFIG_DIR:-/home/inauto/config}"
export INAUTO_AUTOSTART_SCRIPT="${INAUTO_AUTOSTART_SCRIPT:-/home/inauto/on_login}"
export INAUTO_JOURNAL_DIR="${INAUTO_JOURNAL_DIR:-/home/inauto/log/journal}"

# The text label shown in GRUB for booting into the live environment
export GRUB_LIVEBOOT_LABEL="Inautomatic LiveCD"

# The text label shown in GRUB for starting installation
export GRUB_INSTALL_LABEL="Install Ubuntu FS"

# Packages to be removed from the target system after installation completes successfully
export TARGET_PACKAGE_REMOVE="
    ubiquity \
    casper \
    discover \
    laptop-detect \
    os-prober
"

# Used to version the configuration. If breaking changes occur, manual
# updates to this file from the default may be necessary.
export CONFIG_FILE_VERSION="0.7"

HOMEPATH="/home/inauto"
ETCPATH="/etc/inauto"

FINDHOME="find-and-mount-home.sh"
EXECFILESINFOLDER="exec-files-in-folder.sh"

ONLOGIN="on_login"
ONSTART="on_start"

XDG_CONFIG_DIRS="/etc/xdg"

AUTOLOGIN_USER="ubuntu"
AUTOLOGIN_SESSION="xfce"
DOCKER_DATA_ROOT="/var/lib/docker"
CONTAINERD_DATA_ROOT="/var/lib/containerd"
DOCKER_STATE_ROOT="$HOMEPATH/staff/docker"
DOCKER_DATA_IMAGE="$DOCKER_STATE_ROOT/docker-data.ext4"
DOCKER_STORAGE_MOUNT="/var/lib/inauto/container-store"
DOCKER_DATA_IMAGE_SIZE="20G"
DOCKER_SYSTEM_CONFIG="$HOMEPATH/staff/docker-config/root"
DOCKER_USER_CONFIG_ROOT="$HOMEPATH/staff/docker-config"
DOCKER_STORAGE_SCRIPT="setup-docker-storage.sh"
DOCKER_PROFILE_SCRIPT="inauto-docker-env.sh"
DOCKER_COMPOSE_RESTORE_SCRIPT="restore-docker-compose.sh"

DEFAULT_LOCALE="ru_RU.UTF-8"
FALLBACK_LOCALE="en_US.UTF-8"
DEFAULT_LANGUAGE="ru_RU:ru:en_US:en"
KEYBOARD_MODEL="pc105"
KEYBOARD_LAYOUTS="us,ru"
KEYBOARD_VARIANTS=","
KEYBOARD_OPTIONS="grp:caps_toggle"


function custom_conf() {
    mkdir -p "$HOMEPATH" "$ETCPATH"

    make_find_flash_script
    exec_files_in_folder

    configure_locale_keyboard
    net_config
	ensure_network_manager_renderer
    ssh_conf
    ensure_panel_autologin_user
	configure_autologin
    configure_live_username
    enable_on_screen_kbd
    enable_vnc
    configure_power_button

    disable_updates
    disable_oopsie
    disable_automount

    service_mounthome
    service_onstartbeforelogin
    service_onstartoneshot
    service_onstartforking
    configure_docker

    exec_on_start
    journald_conf

    configure_rauc_target

    systemctl daemon-reload
    systemctl enable \
        MountHome.service \
        OnStartBeforeLogin.service \
        OnStartOneShot.service \
        OnStartForking.service \
        DockerPersistentStorage.service \
        DockerComposeRestore.service \
        containerd.service \
        docker.service \
        docker.socket \
        x11vnc.service

	printf '%s\n%s\n' "Inmark2026" "Inmark2026" | passwd root

    remove_unused_features
    remove_dangerous
    quiet_boot_noise
}

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

function purge_present_packages() {
    local packages_to_purge=()
    local package_name
    local package_state

    for package_name in "$@"; do
        package_state=$(dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null || true)
        if [[ "$package_state" == "installed" || "$package_state" == "config-files" ]]; then
            packages_to_purge+=("$package_name")
        fi
    done

    if [[ ${#packages_to_purge[@]} -gt 0 ]]; then
        apt-get purge -y "${packages_to_purge[@]}"
    fi
}

function remove_unused_features() {
    purge_installed_packages \
        bluez \
        bluez-obexd \
        gnome-bluetooth \
        gnome-bluetooth-sendto \
        indicator-bluetooth \
        avahi-daemon \
        cups \
        cups-browsed \
        cups-client \
        cups-common \
        cups-core-drivers \
        cups-daemon \
        cups-filters \
        cups-filters-core-drivers \
        cups-ipp-utils \
        cups-pk-helper \
        cups-ppdc \
        cups-server-common \
        indicator-printers \
        ipp-usb \
        libnss-mdns \
        python3-cups \
        python3-cupshelpers \
        sane-airscan \
        system-config-printer \
        system-config-printer-common \
        system-config-printer-udev \
        yelp \
        yelp-xsl \
        libyelp0 \
        gvfs-backends \
        pulseaudio \
        pulseaudio-utils \
        pavucontrol \
        indicator-sound \
        libasound2-plugins \
        libcanberra-pulse \
        xfce4-pulseaudio-plugin \
        xfce4-weather-plugin
}

function remove_dangerous() {
    apt-get purge -y \
        "libreoffice*" \
        transmission-gtk \
        transmission-common \
        gnome-mahjongg \
        gnome-mines \
        gnome-sudoku \
        aisleriot \
        hitori \
        7zip \
        ffmpeg
}

# Глушит косметический шум на загрузке/выключении, не влияющий на работу панели.
#  - snd_hda_intel: на этих платах HDA-кодек не отвечает → таймауты
#    azx_get_response (~3с к выключению). Звук панелям не нужен — блокируем модуль.
#  - casper-md5check.service: проверка контрольных сумм live-ISO, на immutable
#    RAUC-системе (squashfs на разделе) бессмысленна и всегда падает — маскируем.
function quiet_boot_noise() {
    install -d -m 0755 /etc/modprobe.d
    cat <<'EOF_SND' > /etc/modprobe.d/blacklist-inauto-audio.conf
# Панелям звук не нужен; HDA-кодек не отвечает и вешает таймауты azx_get_response.
blacklist snd_hda_intel
install snd_hda_intel /bin/true
EOF_SND
    chmod 0644 /etc/modprobe.d/blacklist-inauto-audio.conf

    # casper-md5check осмыслен только на live-ISO; на RAUC-target — мусор.
    if rauc_enabled; then
        systemctl mask casper-md5check.service 2>/dev/null || true
    fi
}

function exec_files_in_folder() {
    cat <<EOF_SCRIPT > "$ETCPATH/$EXECFILESINFOLDER"
#!/bin/bash
set -euo pipefail

TARGET_DIR="$HOMEPATH/\$1"
if [[ ! -d "\$TARGET_DIR" ]]; then
    exit 0
fi

find "\$TARGET_DIR" -maxdepth 1 -type f -name '*.sh' -executable | sort | while read -r script; do
    echo "start executing \"\$script\""
    timeout 300 "\$script"
    echo "executing \"\$script\" is complete"
done
EOF_SCRIPT

    chmod 755 "$ETCPATH/$EXECFILESINFOLDER"
}

function exec_on_start() {
    cat <<EOF_DESKTOP > "${XDG_CONFIG_DIRS}/autostart/exec_on_start.desktop"
[Desktop Entry]
Name=Exec scripts in $HOMEPATH/$ONLOGIN
Exec=$ETCPATH/$EXECFILESINFOLDER $ONLOGIN
StartupNotify=false
Type=Application
EOF_DESKTOP
}

# Package customisation function. Update this function to customize packages
# present on the installed system.
function customize_image() {
    # install graphics and desktop (XFCE based)
    apt-get install -y \
        xorg \
        lightdm \
        xfce4 \
        xfce4-goodies

    # Keep the core XFCE shell installed explicitly so autoremove doesn't
    # delete the panel, menu, or file manager when we purge some goodies.
    apt-get install -y \
        xfce4-session \
        xfce4-settings \
        xfdesktop4 \
        xfwm4 \
        thunar \
        xfce4-panel \
        xfce4-appfinder \
        xfce4-whiskermenu-plugin


    # useful tools
    apt-get install -y \
        ca-certificates \
        curl \
        nano \
		mc \
        less \
        openssh-server \
        ethtool \
        kbd \
        keyboard-configuration \
        console-setup \
        mtools \
        iputils-ping \
        libxcb-cursor0 \
        pciutils \
        usbutils \
        rsync \
        ufw \
        x11vnc \
        dbus-x11 \
        e2fsprogs

    install_r8125_driver

    install_docker_engine

    install_rauc_packages
}


function ensure_panel_autologin_user() {
    local group_name
    local groups=(
        adm
        cdrom
        sudo
        dip
        plugdev
        video
        audio
        netdev
    )

    if ! rauc_enabled; then
        return 0
    fi

    if ! id -u "$AUTOLOGIN_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$AUTOLOGIN_USER"
        passwd -d "$AUTOLOGIN_USER" >/dev/null 2>&1 || true
    fi

    for group_name in "${groups[@]}"; do
        ensure_group_member "$group_name" "$AUTOLOGIN_USER"
    done

    install -d -m 0755 /etc/sudoers.d
    cat > "/etc/sudoers.d/90-inauto-panel-user" <<EOF_SUDOERS
$AUTOLOGIN_USER ALL=(ALL) NOPASSWD:ALL
EOF_SUDOERS
    chmod 0440 "/etc/sudoers.d/90-inauto-panel-user"
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
    systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service || true
    systemctl mask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service || true
}

function ensure_network_manager_renderer() {
    mkdir -p /etc/netplan
    rm -f /etc/netplan/*.yaml /etc/netplan/*.yml
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

function configure_live_username() {
    if [[ "${TARGET_DISTRO:-ubuntu}" != "debian" ]]; then
        return 0
    fi
    mkdir -p /etc/live/config
    printf 'LIVE_USERNAME="%s"\n' "$AUTOLOGIN_USER" > /etc/live/config/user-setup.conf
}

function enable_vnc() {
    if [[ ! -f /etc/x11vnc.pass ]]; then
        x11vnc -storepasswd inmark /etc/x11vnc.pass
        chmod 600 /etc/x11vnc.pass
    fi

    cat <<EOF_UNIT > /etc/systemd/system/x11vnc.service
[Unit]
Description=X11VNC server
After=display-manager.service network-online.target
Wants=display-manager.service

[Service]
Type=simple
Environment=DISPLAY=:0
ExecStart=/usr/bin/x11vnc -loop -forever -noxdamage -rfbauth /etc/x11vnc.pass -display :0 -shared -auth /var/run/lightdm/root/:0
#Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF_UNIT

    ufw allow 5900/tcp
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

function install_docker_engine() {
    local docker_arch
    local docker_codename

    purge_present_packages \
        docker.io \
        docker-compose \
        docker-compose-v2 \
        docker-doc \
        podman-docker \
        containerd \
        runc

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$DOCKER_APT_DISTRO/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    docker_arch=$(dpkg --print-architecture)
    docker_codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

    cat <<EOF_DOCKER_APT > /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/$DOCKER_APT_DISTRO
Suites: $docker_codename
Components: stable
Architectures: $docker_arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER_APT

    apt-get update
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    install_docker_compose_compat
}

function install_docker_compose_compat() {
    install -d /usr/local/bin
    cat <<'EOF_DOCKER_COMPOSE' > /usr/local/bin/docker-compose
#!/bin/sh
exec docker compose "$@"
EOF_DOCKER_COMPOSE

    chmod 755 /usr/local/bin/docker-compose
}

function make_docker_storage_script() {
    if rauc_enabled; then
        make_docker_storage_script_rauc
    else
        make_docker_storage_script_iso
    fi

    chmod 755 "$ETCPATH/$DOCKER_STORAGE_SCRIPT"
}

# ISO-вариант: историческое поведение.
# Персистентное хранилище — loopback ext4 файл под /home/inauto/staff/docker.
function make_docker_storage_script_iso() {
    cat <<EOF_SCRIPT > "$ETCPATH/$DOCKER_STORAGE_SCRIPT"
#!/bin/bash
set -euo pipefail

PERSISTENT_ROOT="$HOMEPATH"
LOCKFILE=".inautolock"
CONTAINER_STORE_MOUNT="$DOCKER_STORAGE_MOUNT"
DOCKER_ROOT="$DOCKER_DATA_ROOT"
CONTAINERD_ROOT="$CONTAINERD_DATA_ROOT"
DOCKER_STATE_ROOT="$DOCKER_STATE_ROOT"
DOCKER_IMAGE="$DOCKER_DATA_IMAGE"
DOCKER_IMAGE_SIZE="$DOCKER_DATA_IMAGE_SIZE"
DOCKER_SYSTEM_CONFIG="$DOCKER_SYSTEM_CONFIG"

log() {
    echo "[docker-storage] \$*"
}

ensure_system_config() {
    mkdir -p "\$DOCKER_SYSTEM_CONFIG"
    chmod 700 "\$DOCKER_SYSTEM_CONFIG"
}

if [[ ! -f "\$PERSISTENT_ROOT/\$LOCKFILE" ]] || ! mountpoint -q "\$PERSISTENT_ROOT"; then
    log "persistent storage is unavailable, Docker and containerd will use ephemeral storage"
    mkdir -p "\$DOCKER_ROOT" "\$CONTAINERD_ROOT"
    exit 0
fi

mkdir -p "\$DOCKER_ROOT" "\$CONTAINERD_ROOT" "\$DOCKER_STATE_ROOT" "\$CONTAINER_STORE_MOUNT"
ensure_system_config

if mountpoint -q "\$CONTAINER_STORE_MOUNT" && mountpoint -q "\$DOCKER_ROOT" && mountpoint -q "\$CONTAINERD_ROOT"; then
    log "persistent container storage is already mounted"
    exit 0
fi

if [[ ! -f "\$DOCKER_IMAGE" ]]; then
    log "creating container storage image \$DOCKER_IMAGE (\$DOCKER_IMAGE_SIZE)"
    truncate -s "\$DOCKER_IMAGE_SIZE" "\$DOCKER_IMAGE"
    mkfs.ext4 -F -L INAUTO_DOCKER "\$DOCKER_IMAGE"
fi

if e2fsck -p "\$DOCKER_IMAGE"; then
    :
else
    fsck_status=\$?
    if (( fsck_status > 1 )); then
        log "e2fsck failed for \$DOCKER_IMAGE with code \$fsck_status"
        exit "\$fsck_status"
    fi
fi

if ! mountpoint -q "\$CONTAINER_STORE_MOUNT"; then
    mount -o loop,noatime "\$DOCKER_IMAGE" "\$CONTAINER_STORE_MOUNT"
fi

mkdir -p "\$CONTAINER_STORE_MOUNT/docker" "\$CONTAINER_STORE_MOUNT/containerd"

if ! mountpoint -q "\$DOCKER_ROOT"; then
    mount --bind "\$CONTAINER_STORE_MOUNT/docker" "\$DOCKER_ROOT"
fi

if ! mountpoint -q "\$CONTAINERD_ROOT"; then
    mount --bind "\$CONTAINER_STORE_MOUNT/containerd" "\$CONTAINERD_ROOT"
fi

log "mounted persistent Docker storage at \$DOCKER_ROOT"
log "mounted persistent containerd storage at \$CONTAINERD_ROOT"
EOF_SCRIPT
}

# RAUC-вариант: container-store — выделенный GPT-раздел
# /dev/disk/by-partlabel/container-store, примонтированный из initramfs
# в /var/lib/inauto/container-store. Bind-mounts на /var/lib/docker и
# /var/lib/containerd также сделаны в initramfs (scripts/local-bottom/panel-boot).
# Этот скрипт — только валидация и идемпотентный ensure subdirs/config.
# Никаких silent-fallback в ephemeral storage: если layout неправильный — fail.
function make_docker_storage_script_rauc() {
    cat <<EOF_SCRIPT > "$ETCPATH/$DOCKER_STORAGE_SCRIPT"
#!/bin/bash
set -euo pipefail

CONTAINER_STORE_MOUNT="$DOCKER_STORAGE_MOUNT"
DOCKER_ROOT="$DOCKER_DATA_ROOT"
CONTAINERD_ROOT="$CONTAINERD_DATA_ROOT"
DOCKER_SYSTEM_CONFIG="$DOCKER_SYSTEM_CONFIG"
CONTAINER_STORE_DEVICE="/dev/disk/by-partlabel/container-store"

log() {
    echo "[docker-storage] \$*"
}

fail() {
    echo "[docker-storage] ERROR: \$*" >&2
    exit 1
}

ensure_system_config() {
    mkdir -p "\$DOCKER_SYSTEM_CONFIG"
    chmod 700 "\$DOCKER_SYSTEM_CONFIG"
}

[[ -b "\$CONTAINER_STORE_DEVICE" ]] \
    || fail "раздел \$CONTAINER_STORE_DEVICE отсутствует; immutable layout не активен"

mountpoint -q "\$CONTAINER_STORE_MOUNT" \
    || fail "\$CONTAINER_STORE_MOUNT не смонтирован (должно быть сделано initramfs)"

mkdir -p "\$CONTAINER_STORE_MOUNT/docker" "\$CONTAINER_STORE_MOUNT/containerd"

ensure_system_config

mountpoint -q "\$DOCKER_ROOT" \
    || fail "\$DOCKER_ROOT не является bind-mount из container-store"

mountpoint -q "\$CONTAINERD_ROOT" \
    || fail "\$CONTAINERD_ROOT не является bind-mount из container-store"

log "container-store ok: \$CONTAINER_STORE_MOUNT -> \$DOCKER_ROOT, \$CONTAINERD_ROOT"
EOF_SCRIPT
}

function make_docker_profile_script() {
    mkdir -p /etc/profile.d
    cat <<EOF_PROFILE > "/etc/profile.d/$DOCKER_PROFILE_SCRIPT"
#!/bin/sh

if [ -f "$HOMEPATH/.inautolock" ] && [ -d "$DOCKER_USER_CONFIG_ROOT" ]; then
    docker_user=\${USER:-\$(id -un 2>/dev/null || echo default)}
    export DOCKER_CONFIG="$DOCKER_USER_CONFIG_ROOT/\$docker_user"
fi
EOF_PROFILE

    chmod 644 "/etc/profile.d/$DOCKER_PROFILE_SCRIPT"
}

function make_docker_compose_restore_script() {
    cat <<EOF_SCRIPT > "$ETCPATH/$DOCKER_COMPOSE_RESTORE_SCRIPT"
#!/bin/bash
set -euo pipefail

export DOCKER_CONFIG="$DOCKER_SYSTEM_CONFIG"

log() {
    echo "[docker-compose-restore] \$*"
}

if ! command -v docker >/dev/null 2>&1; then
    log "docker CLI is unavailable"
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    log "docker daemon is unavailable"
    exit 0
fi

mapfile -t container_ids < <(docker container ls -aq --filter label=com.docker.compose.project | sort -u)
if [[ \${#container_ids[@]} -eq 0 ]]; then
    log "no compose-managed containers found"
    exit 0
fi

declare -A seen_projects=()

for container_id in "\${container_ids[@]}"; do
    project_key=\$(docker container inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}|{{ index .Config.Labels "com.docker.compose.project.working_dir" }}|{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "\$container_id" 2>/dev/null || true)
    project_name=\${project_key%%|*}
    rest=\${project_key#*|}
    working_dir=\${rest%%|*}
    config_files=\${rest#*|}

    if [[ -z "\$project_name" || -z "\$working_dir" ]]; then
        continue
    fi

    seen_projects["\$project_name|\$working_dir|\$config_files"]=1
done

for project in "\${!seen_projects[@]}"; do
    project_name=\${project%%|*}
    rest=\${project#*|}
    working_dir=\${rest%%|*}
    config_files=\${rest#*|}
    compose_args=(-p "\$project_name" --project-directory "\$working_dir")
    missing_file=0

    if [[ ! -d "\$working_dir" ]]; then
        log "skip \$project_name: project directory \$working_dir is missing"
        continue
    fi

    if [[ -n "\$config_files" ]]; then
        IFS=',' read -r -a config_file_list <<< "\$config_files"
        for config_file in "\${config_file_list[@]}"; do
            [[ -n "\$config_file" ]] || continue

            if [[ "\$config_file" != /* ]]; then
                config_file="\$working_dir/\$config_file"
            fi

            if [[ ! -f "\$config_file" ]]; then
                log "skip \$project_name: compose file \$config_file is missing"
                missing_file=1
                break
            fi

            compose_args+=(-f "\$config_file")
        done
    fi

    if (( missing_file )); then
        continue
    fi

    log "restoring compose project \$project_name"
    docker compose "\${compose_args[@]}" up -d
done
EOF_SCRIPT

    chmod 755 "$ETCPATH/$DOCKER_COMPOSE_RESTORE_SCRIPT"
}

function ensure_group_member() {
    local group_name="$1"
    local user_name="$2"
    local group_line
    local group_gid
    local members
    local new_members

    getent group "$group_name" >/dev/null || groupadd "$group_name"

    if id -u "$user_name" >/dev/null 2>&1; then
        usermod -aG "$group_name" "$user_name"
        return 0
    fi

    group_line=$(getent group "$group_name")
    group_gid=$(echo "$group_line" | cut -d: -f3)
    members=$(echo "$group_line" | cut -d: -f4)

    if [[ ",$members," == *",$user_name,"* ]]; then
        return 0
    fi

    if [[ -n "$members" ]]; then
        new_members="$members,$user_name"
    else
        new_members="$user_name"
    fi

    awk -F: -v OFS=: -v target_group="$group_name" -v target_gid="$group_gid" -v target_members="$new_members" '
        $1 == target_group {
            $2 = "x"
            $3 = target_gid
            $4 = target_members
        }
        { print }
    ' /etc/group > /etc/group.tmp

    mv /etc/group.tmp /etc/group
}

function configure_docker() {
    make_docker_storage_script
    make_docker_profile_script
    make_docker_compose_restore_script

    mkdir -p /etc/docker
    cat <<EOF_DOCKER > /etc/docker/daemon.json
{
  "data-root": "$DOCKER_DATA_ROOT",
  "storage-driver": "overlay2"
}
EOF_DOCKER

    mkdir -p /etc/systemd/system/docker.service.d
    cat <<EOF_DOCKER_OVERRIDE > /etc/systemd/system/docker.service.d/10-inauto.conf
[Unit]
After=MountHome.service DockerPersistentStorage.service
Requires=DockerPersistentStorage.service

[Service]
ExecStartPre=/bin/mkdir -p $DOCKER_DATA_ROOT
EOF_DOCKER_OVERRIDE

    mkdir -p /etc/systemd/system/containerd.service.d
    cat <<EOF_CONTAINERD_OVERRIDE > /etc/systemd/system/containerd.service.d/10-inauto.conf
[Unit]
After=DockerPersistentStorage.service
Requires=DockerPersistentStorage.service

[Service]
ExecStartPre=/bin/mkdir -p $CONTAINERD_DATA_ROOT
EOF_CONTAINERD_OVERRIDE

    if rauc_enabled; then
        cat <<EOF_UNIT > /etc/systemd/system/DockerPersistentStorage.service
[Unit]
Description=Validate persistent container-store mounts (RAUC immutable target)
After=local-fs.target MountHome.service
Requires=MountHome.service
RequiresMountsFor=/var/lib/inauto/container-store /var/lib/docker /var/lib/containerd
Before=containerd.service docker.service

[Service]
Type=oneshot
ExecStart=$ETCPATH/$DOCKER_STORAGE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
    else
        cat <<EOF_UNIT > /etc/systemd/system/DockerPersistentStorage.service
[Unit]
Description=Prepare persistent Docker and containerd storage
After=MountHome.service
Wants=MountHome.service
Before=containerd.service docker.service

[Service]
Type=oneshot
ExecStart=$ETCPATH/$DOCKER_STORAGE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
    fi

    cat <<EOF_UNIT > /etc/systemd/system/DockerComposeRestore.service
[Unit]
Description=Restore Docker Compose projects from persistent storage
After=docker.service network-online.target OnStartOneShot.service
Wants=docker.service network-online.target OnStartOneShot.service

[Service]
Type=oneshot
Environment=DOCKER_CONFIG=$DOCKER_SYSTEM_CONFIG
ExecStart=$ETCPATH/$DOCKER_COMPOSE_RESTORE_SCRIPT

[Install]
WantedBy=multi-user.target
EOF_UNIT

    # The live user is created by casper at boot, so keep docker-group membership by name.
    ensure_group_member docker "$AUTOLOGIN_USER"
}

function service_mounthome() {
    if rauc_enabled; then
        service_mounthome_rauc
    else
        service_mounthome_iso
    fi

    chmod 644 /etc/systemd/system/MountHome.service
}

# ISO-вариант: историческое поведение.
# Скрипт find-and-mount-home.sh сканирует подключённые устройства по .inautolock
# и монтирует найденное в /home/inauto.
function service_mounthome_iso() {
    cat <<EOF_UNIT > /etc/systemd/system/MountHome.service
[Unit]
Description=Find and mount device with .inautolock
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$ETCPATH/$FINDHOME
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

# RAUC-вариант: /home/inauto уже подмонтирован initramfs-скриптом
# (scripts/local-bottom/panel-boot + inauto-data раздел).
# Этот unit только проверяет факт mountpoint и является dependency-точкой
# для OnStart*/DockerComposeRestore. Если /home/inauto не смонтирован —
# service падает, остальная immutable-цепочка не стартует.
#
# find-and-mount-home.sh остаётся установленным (make_find_flash_script),
# но только для ручного импорта/service engineering, не в normal boot.
function service_mounthome_rauc() {
    cat <<EOF_UNIT > /etc/systemd/system/MountHome.service
[Unit]
Description=Verify /home/inauto is mounted from the immutable initramfs
After=local-fs.target
DefaultDependencies=no
RequiresMountsFor=/home/inauto

[Service]
Type=oneshot
ExecStart=/usr/bin/mountpoint -q /home/inauto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

function service_onstartbeforelogin() {
    cat <<EOF_UNIT > /etc/systemd/system/OnStartBeforeLogin.service
[Unit]
Description=Exec scripts in $HOMEPATH/$ONSTART/before_login
After=MountHome.service
Before=networking.service display-manager.service

[Service]
Type=oneshot
ExecStart=$ETCPATH/$EXECFILESINFOLDER $ONSTART/before_login

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 644 /etc/systemd/system/OnStartBeforeLogin.service
}

function service_onstartoneshot() {
    cat <<EOF_UNIT > /etc/systemd/system/OnStartOneShot.service
[Unit]
Description=Exec scripts in $HOMEPATH/$ONSTART/oneshot
After=OnStartBeforeLogin.service network.target network-online.target

[Service]
Type=oneshot
ExecStart=$ETCPATH/$EXECFILESINFOLDER $ONSTART/oneshot

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 644 /etc/systemd/system/OnStartOneShot.service
}

function service_onstartforking() {
    cat <<EOF_UNIT > /etc/systemd/system/OnStartForking.service
[Unit]
Description=Exec scripts in $HOMEPATH/$ONSTART/forking
After=OnStartOneShot.service

[Service]
Type=forking
ExecStart=$ETCPATH/$EXECFILESINFOLDER $ONSTART/forking

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 644 /etc/systemd/system/OnStartForking.service
}

function ssh_conf() {
    cat <<EOF_SSH > /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf

LoginGraceTime 2m
PermitRootLogin yes
StrictModes yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF_SSH

    systemctl enable ssh
}

function make_find_flash_script() {
    cat <<EOF_SCRIPT > "$ETCPATH/$FINDHOME"
#!/bin/bash
set -euo pipefail

MOUNTPOINT="$HOMEPATH"
LOCKFILE=".inautolock"

check_and_mount() {
    local device=\$1
    local tempmount
    tempmount=\$(mktemp -d)

    if mount "\$device" "\$tempmount"; then
        if [ -f "\$tempmount/\$LOCKFILE" ]; then
            echo "Found \$LOCKFILE on \$device. Mounting at \$MOUNTPOINT."
            umount "\$tempmount"
            mount "\$device" "\$MOUNTPOINT"
            rm -rf "\$tempmount"
            return 0
        fi
        umount "\$tempmount"
    fi
    rm -rf "\$tempmount"
    return 1
}

for device in /dev/sd* /dev/nvme* /dev/mmc*; do
    if [ -b "\$device" ]; then
        if check_and_mount "\$device"; then
            echo "Device \$device mounted successfully."
            exit 0
        fi
    fi
done

echo "No device with \$LOCKFILE found."
exit 1
EOF_SCRIPT

    chmod +x "$ETCPATH/$FINDHOME"
}

function journald_conf() {
    mkdir -p /etc/systemd/journald.conf.d

    cat <<EOF_JOURNAL > /etc/systemd/journald.conf.d/journald.conf
[Journal]
SplitMode=false
SystemMaxUse=50M
SystemMaxFileSize=50M
ForwardToSyslog=no
EOF_JOURNAL
}

function disable_updates() {
    systemctl disable fwupd-offline-update.service || true
    systemctl disable fwupd.service || true
    systemctl disable fwupd-refresh.service || true
    systemctl disable unattended-upgrades.service || true
    systemctl disable secureboot-db.service || true
}

function disable_oopsie() {
    systemctl disable kerneloops.service || true
    systemctl disable whoopsie.service || true
}

function disable_automount() {
    systemctl mask udisks2 || true
    systemctl disable udisks2.service || true
}

function enable_on_screen_kbd() {
    apt-get install -y onboard
}

# Кнопка питания -> действие выключения XFCE.
#
# По умолчанию в Ubuntu 24.04 systemd-logind обрабатывает power-key сам
# (HandlePowerKey=poweroff), а xfce4-power-manager в это не вмешивается. Здесь мы
# задаём СИСТЕМНЫЙ xfconf-дефолт (в /etc/xdg, т.к. XDG_CONFIG_DIRS=/etc/xdg):
# xfce4-power-manager перехватывает power-key у logind (logind-handle-power-key=true,
# ставит inhibitor, logind делегирует событие) и выполняет заданное действие
# (power-button-action=4 = XFPM_DO_SHUTDOWN — корректное выключение без диалога;
# 3 = XFPM_ASK, если понадобится вернуть диалог-меню).
#
# Файл read-only и лежит в системном каталоге, поэтому корректно работает и на
# immutable RAUC-панели с tmpfs-overlay поверх домашнего каталога.
function configure_power_button() {
    local xfconf_dir="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"

    install -d -m 0755 "$xfconf_dir"
    cat <<'EOF_XFPM' > "$xfconf_dir/xfce4-power-manager.xml"
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <!-- power-button-action=4 -> XFPM_DO_SHUTDOWN (выключить сразу, без диалога) -->
    <property name="power-button-action" type="uint" value="4"/>
    <!-- xfce4-power-manager перехватывает power-key у systemd-logind -->
    <property name="logind-handle-power-key" type="bool" value="true"/>
  </property>
</channel>
EOF_XFPM
    chmod 0644 "$xfconf_dir/xfce4-power-manager.xml"
}

# ============================================================================
# Драйвер сетевого контроллера Realtek RTL8125 (2.5GbE).
#
# In-kernel r8169 в noble не поддерживает нашу ревизию RTL8125 (в dmesg
# "unknown chip XID ... error -ENODEV"), а пакетный r8125-dkms в multiverse —
# старая ветка 9.011 (2022): на новых ревизиях чипа у неё битый RX (линк
# поднимается, но DHCP не получает ответа, интерфейс вечно "connecting").
# Поэтому собираем вендорный r8125 из ЗАКРЕПЛЁННЫХ исходников (pinned версия +
# URL + sha256, как в scripts/targets/rauc/install-rauc-source.sh). Мирор
# awesometic/realtek-r8125-dkms содержит официальные исходники Realtek + dkms.conf.
#
# Модуль ОБЯЗАН собраться на этапе билда внутри chroot: на immutable RAUC-панели
# rootfs read-only и dkms на целевой системе уже ничего не пересоберёт. При этом
# `uname -r` в chroot указывает на ядро билдера, а не образа, поэтому собираем
# явно под каждое целевое ядро (определяем по наличию /lib/modules/<kver>/build).
function install_r8125_driver() {
    local kver
    local found_ko
    local built_count=0
    local target_kernels=()

    # Закреплённая версия вендорного драйвера (source build). Тег на мирроре —
    # <ver>-<pkgrel>; внутри архива dkms.conf уже с PACKAGE_NAME/PACKAGE_VERSION.
    local r8125_version="9.016.01"
    local r8125_src_url="https://github.com/awesometic/realtek-r8125-dkms/archive/refs/tags/9.016.01-1.tar.gz"
    local r8125_src_sha256="7dd086213b4ac151532dc826283f3cd86ee23111d394ca47e575c1574bf71b15"
    local r8125_dkms_name="realtek-r8125"   # = PACKAGE_NAME в dkms.conf тарбола
    local work_dir src_dir extracted

    # Целевые ядра образа — все установленные в chroot (ядро билдера сюда не
    # попадает, его модулей в chroot нет). find -printf даёт чистые имена без
    # возни с nullglob/shopt (который при сорсинге менял бы состояние вызвавшей
    # оболочки).
    mapfile -t target_kernels < <(
        find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V
    )

    if [[ ${#target_kernels[@]} -eq 0 ]]; then
        echo "[r8125] ERROR: в /lib/modules нет ни одного установленного ядра" >&2
        exit 1
    fi

    # Тулчейн DKMS + инструменты для загрузки исходников.
    apt-get install -y --no-install-recommends \
        dkms \
        build-essential \
        ca-certificates \
        curl \
        xz-utils
    # Заголовки под каждое целевое ядро (в chroot uname -r — ядро билдера).
    for kver in "${target_kernels[@]}"; do
        apt-get install -y --no-install-recommends "linux-headers-$kver" \
            || echo "[r8125] WARNING: не удалось поставить linux-headers-$kver; dkms может не собраться" >&2
    done

    # Разворачиваем закреплённые исходники в /usr/src и регистрируем в dkms.
    # Идемпотентно: если дерево уже на месте (установлено атомарно через mv),
    # повторно не качаем.
    src_dir="/usr/src/${r8125_dkms_name}-${r8125_version}"
    if [[ ! -f "$src_dir/dkms.conf" ]]; then
        echo "[r8125] загружаю исходники r8125 ${r8125_version}"
        # Фиксированный work_dir с очисткой на входе: при прерванной сборке
        # (set -e выйдет мимо rm ниже) следующий запуск сам подчистит
        # осиротевший каталог перед повторной загрузкой — без глобального trap.
        work_dir="/tmp/r8125-src"
        rm -rf "$work_dir"
        mkdir -p "$work_dir"
        curl -fsSL "$r8125_src_url" -o "$work_dir/r8125.tar.gz"
        printf '%s  %s\n' "$r8125_src_sha256" "$work_dir/r8125.tar.gz" | sha256sum -c -
        tar -C "$work_dir" -xzf "$work_dir/r8125.tar.gz"
        # В архиве один каталог верхнего уровня realtek-r8125-dkms-<tag>.
        extracted="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
        [[ -n "$extracted" ]] || { echo "[r8125] ERROR: не найден каталог исходников в архиве" >&2; exit 1; }
        # Атомарная установка дерева: cp во временный каталог, затем mv. Иначе
        # прерывание посреди cp могло бы оставить dkms.conf без остального src/,
        # и re-run пропустил бы перекачку (guard проверяет только dkms.conf).
        rm -rf "$src_dir" "${src_dir}.tmp"
        cp -a "$extracted" "${src_dir}.tmp"
        mv "${src_dir}.tmp" "$src_dir"
        rm -rf "$work_dir"
    fi

    # Регистрируем модуль в dkms (идемпотентно).
    if ! dkms status -m "$r8125_dkms_name" -v "$r8125_version" | grep -q .; then
        dkms add -m "$r8125_dkms_name" -v "$r8125_version"
    fi

    # Сборка/установка под каждое целевое ядро + проверка результата.
    # В chroot uname -r указывает на ядро билдера, поэтому -k обязателен.
    for kver in "${target_kernels[@]}"; do
        if [[ ! -e "/lib/modules/$kver/build" ]]; then
            echo "[r8125] WARNING: нет заголовков для $kver, пропускаю" >&2
            continue
        fi

        echo "[r8125] сборка модуля r8125 ${r8125_version} для ядра $kver"
        # dkms install сам соберёт модуль, если он ещё не собран.
        if ! dkms status -m "$r8125_dkms_name" -v "$r8125_version" -k "$kver" | grep -q 'installed'; then
            dkms install -m "$r8125_dkms_name" -v "$r8125_version" -k "$kver" --force
        fi
        depmod -a "$kver"

        # -print -quit: без пайпа (иначе pipefail ловит SIGPIPE find'а как ошибку).
        found_ko="$(find "/lib/modules/$kver" -name 'r8125.ko*' -print -quit)"
        if [[ -z "$found_ko" ]]; then
            echo "[r8125] ERROR: модуль r8125 не собрался для ядра $kver" >&2
            exit 1
        fi
        built_count=$((built_count + 1))
    done

    if [[ "$built_count" -eq 0 ]]; then
        echo "[r8125] ERROR: r8125 не собран ни для одного ядра (нет заголовков)" >&2
        exit 1
    fi

    # ТОЧЕЧНОЕ предпочтение r8125 ТОЛЬКО для устройства RTL8125 (PCI 10ec:8125).
    #
    # НЕ блокируем r8169 глобально: на той же плате гигабитная карта Realtek
    # (RTL8111/8168) обслуживается именно r8169, и blacklist убивал её (1GbE
    # пропадал). Вместо этого через udev перепривязываем к r8125 только 8125-е
    # устройство, если его успел захватить r8169. Все остальные Realtek остаются
    # на r8169.
    install -D -m 0755 /dev/stdin /usr/local/sbin/inauto-prefer-r8125 <<'EOF_HELPER'
#!/bin/sh
# Перепривязка одного PCI-устройства RTL8125 с r8169 на вендорный r8125.
set -eu
dev="$1"
modprobe r8125 2>/dev/null || true
if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
    cur="$(basename "$(readlink "/sys/bus/pci/devices/$dev/driver")")"
    [ "$cur" = "r8125" ] && exit 0
    echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null || true
fi
echo r8125 > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
echo "$dev" > /sys/bus/pci/drivers/r8125/bind 2>/dev/null || true
EOF_HELPER

    install -d -m 0755 /etc/udev/rules.d
    cat <<'EOF_UDEV' > /etc/udev/rules.d/70-inauto-r8125.rules
# RTL8125 (2.5GbE): предпочитаем вендорный r8125, не трогая r8169 для остальных
# Realtek-карт. Срабатывает, когда r8169 привязался к устройству 10ec:8125.
ACTION=="bind", SUBSYSTEM=="pci", DRIVER=="r8169", ATTR{vendor}=="0x10ec", ATTR{device}=="0x8125", RUN+="/usr/local/sbin/inauto-prefer-r8125 %k"
EOF_UDEV
    chmod 0644 /etc/udev/rules.d/70-inauto-r8125.rules

    echo "[r8125] драйвер ${r8125_version} собран для ядер: ${target_kernels[*]}; r8169 оставлен для прочих Realtek"
}

# ============================================================================
# RAUC immutable firmware target.
# Активируется, когда TARGET_FORMAT=rauc. Для TARGET_FORMAT=iso функции
# превращаются в no-op, поэтому классический ISO-путь остаётся без изменений.
# ============================================================================

function rauc_enabled() {
    [[ "${TARGET_FORMAT:-iso}" == "rauc" ]]
}

# Устанавливает пакеты, нужные внутри rootfs при RAUC target'е.
function install_rauc_packages() {
    if ! rauc_enabled; then
        return 0
    fi

    echo "[rauc] устанавливаю пакеты RAUC target'а"
    apt-get install -y --no-install-recommends \
        rauc \
        jq \
        curl \
        efibootmgr \
        openssh-server
    install_pinned_rauc
}

# Рендерит /etc/rauc/system.conf из платформо-специфичного шаблона.
function render_rauc_system_conf() {
    local platform="${TARGET_PLATFORM:-}"
    local distro="${TARGET_DISTRO:-}"
    local arch="${TARGET_ARCH:-}"
    local compatible_version="${RAUC_COMPATIBLE_VERSION:-v1}"
    local compatible
    local template

    if [[ -z "$distro" || -z "$arch" || -z "$platform" ]]; then
        echo "[rauc] ERROR: TARGET_DISTRO/TARGET_ARCH/TARGET_PLATFORM обязательны для RAUC target'а" >&2
        exit 1
    fi
    if [[ ! "$compatible_version" =~ ^v[0-9]+$ ]]; then
        echo "[rauc] ERROR: RAUC_COMPATIBLE_VERSION должен иметь формат v<N>, получено '$compatible_version'" >&2
        exit 1
    fi
    compatible="inauto-panel-${distro}-${arch}-${platform}-${compatible_version}"

    case "$platform" in
        pc-efi)
            template="/root/profile/rauc/system-efi.conf.template"
            ;;
        *-uboot)
            template="/root/profile/rauc/system-uboot.conf.template"
            ;;
        *)
            echo "[rauc] ERROR: неизвестный TARGET_PLATFORM='$platform' (ожидается pc-efi или <board>-uboot)" >&2
            exit 1
            ;;
    esac

    if [[ ! -f "$template" ]]; then
        echo "[rauc] ERROR: шаблон system.conf не найден: $template" >&2
        exit 1
    fi

    install -d -m 0755 /etc/rauc
    sed \
        -e "s|@COMPATIBLE@|$compatible|g" \
        -e "s|@DISTRO@|$distro|g" \
        -e "s|@ARCH@|$arch|g" \
        -e "s|@PLATFORM@|$platform|g" \
        "$template" > /etc/rauc/system.conf
    chmod 0644 /etc/rauc/system.conf
    echo "[rauc] /etc/rauc/system.conf отрендерен из $template"
}

# Копирует keyring, подготовленный хостом (build.sh::prechroot).
function install_rauc_keyring() {
    local src="/root/rauc-keyring.pem"

    if [[ ! -f "$src" ]]; then
        echo "[rauc] ERROR: keyring не найден: $src. build.sh::prechroot должен его скопировать." >&2
        exit 1
    fi

    install -D -m 0644 "$src" /etc/rauc/keyring.pem
    echo "[rauc] /etc/rauc/keyring.pem установлен"
}

# Пишет /etc/inauto/firmware-version с версией bundle'а.
# Для dev-сборок (пустой RAUC_BUNDLE_VERSION) — placeholder с маркером dev.
function write_firmware_version_file() {
    local version="${RAUC_BUNDLE_VERSION:-}"

    if [[ -z "$version" ]]; then
        version="dev.unknown"
        echo "[rauc] WARNING: RAUC_BUNDLE_VERSION не задан; записан placeholder '$version'. Не публиковать такую сборку." >&2
    fi

    install -d -m 0755 /etc/inauto
    printf '%s\n' "$version" > /etc/inauto/firmware-version
    chmod 0644 /etc/inauto/firmware-version
    echo "[rauc] /etc/inauto/firmware-version = $version"
}

# Устанавливает initramfs-hook + local-bottom boot script + panel-init-persist-paths
# и пересобирает initramfs. Должен запускаться уже после установки ядра.
function install_rauc_initramfs() {
    local hook_src="/root/profile/rauc/initramfs-hooks/panel-boot"
    local script_src="/root/profile/rauc/initramfs-scripts/panel-boot"
    local persist_src="/root/profile/rauc/scripts/init-persist-paths.sh"

    if [[ ! -f "$hook_src" || ! -f "$script_src" || ! -f "$persist_src" ]]; then
        echo "[rauc] ERROR: отсутствуют initramfs-артефакты профиля (hook/script/init-persist-paths)" >&2
        exit 1
    fi

    install -D -m 0755 "$persist_src" /usr/local/sbin/panel-init-persist-paths
    install -D -m 0755 "$hook_src"    /etc/initramfs-tools/hooks/panel-boot
    install -D -m 0755 "$script_src"  /etc/initramfs-tools/scripts/local-bottom/panel-boot

    if compgen -G "/boot/vmlinuz-*" >/dev/null; then
        echo "[rauc] пересобираю initramfs через update-initramfs -u -k all"
        update-initramfs -u -k all
    else
        echo "[rauc] WARNING: ядро не установлено; initramfs сгенерируется при установке kernel-пакета" >&2
    fi
}

# Устанавливает update-agent (panel-check-updates.sh + timer/service).
# Агент опрашивает update server, ставит новые bundle'ы, шлёт heartbeat.
function install_rauc_update_agent() {
    local agent_src="/root/profile/rauc/scripts/panel-check-updates.sh"
    local service_src="/root/profile/rauc/systemd-units/panel-check-updates.service"
    local timer_src="/root/profile/rauc/systemd-units/panel-check-updates.timer"

    for f in "$agent_src" "$service_src" "$timer_src"; do
        [[ -f "$f" ]] || { echo "[rauc] ERROR: update-agent артефакт отсутствует: $f" >&2; exit 1; }
    done

    install -D -m 0755 "$agent_src"   /usr/local/bin/panel-check-updates.sh
    install -D -m 0644 "$service_src" /etc/systemd/system/panel-check-updates.service
    install -D -m 0644 "$timer_src"   /etc/systemd/system/panel-check-updates.timer

    systemctl enable panel-check-updates.timer
    echo "[rauc] panel-check-updates.timer включён"
}

# Устанавливает интерактивный помощник ручного обновления из .raucb
# (диагностика -> проверка bundle/sha256 -> правка EFI -> подтверждение ->
# rauc install -> reboot). Автоматизирует docs/runbooks/update-from-raucb.md.
function install_rauc_update_helper() {
    local src="/root/profile/rauc/scripts/panel-update.sh"

    [[ -f "$src" ]] || { echo "[rauc] ERROR: panel-update.sh отсутствует: $src" >&2; exit 1; }

    install -D -m 0755 "$src" /usr/local/bin/panel-update
    echo "[rauc] /usr/local/bin/panel-update установлен"
}


# Конфигурирует systemd watchdog для production rollout'ов.
# Kernel panic timeout уже в kernel cmdline через system.conf.template (panic=30).
# systemd следит за userspace зависаниями через /dev/watchdog (если есть).
function install_rauc_watchdog() {
    install -d -m 0755 /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/10-inauto-watchdog.conf <<'EOF_WD'
[Manager]
# Если ядро предоставляет /dev/watchdog (Intel iTCO, i6300esb в QEMU и т.п.),
# systemd будет пинать его каждые RuntimeWatchdogSec/2. Стоп-пинг = hard reboot.
RuntimeWatchdogSec=60s
# Сколько ждать graceful shutdown до принудительной перезагрузки.
RebootWatchdogSec=5min
# Защита от долгих kexec-переходов (если понадобятся).
KExecWatchdogSec=10min
EOF_WD

    chmod 0644 /etc/systemd/system.conf.d/10-inauto-watchdog.conf
    echo "[rauc] systemd watchdog настроен (RuntimeWatchdogSec=60s)"
}

# Устанавливает panel-healthcheck.sh + rauc-mark-boot-good.service.
# Только для RAUC builds — unit опирается на RAUC check-style MountHome.service
# (см. service_mounthome_rauc), иначе rollback-цепочка не работает.
function install_rauc_mark_good() {
    local hc_src="/root/profile/rauc/scripts/panel-healthcheck.sh"
    local unit_src="/root/profile/rauc/systemd-units/rauc-mark-boot-good.service"

    [[ -f "$hc_src" ]]   || { echo "[rauc] ERROR: panel-healthcheck.sh отсутствует: $hc_src" >&2; exit 1; }
    [[ -f "$unit_src" ]] || { echo "[rauc] ERROR: rauc-mark-boot-good.service отсутствует: $unit_src" >&2; exit 1; }

    install -D -m 0755 "$hc_src"   /usr/local/bin/panel-healthcheck.sh
    install -D -m 0644 "$unit_src" /etc/systemd/system/rauc-mark-boot-good.service

    systemctl enable rauc-mark-boot-good.service
    echo "[rauc] rauc-mark-boot-good.service включён"
}

# Mount unit для grubenv: efi_A (FAT32 с GRUB/grub.cfg/grubenv) монтируется
# в /run/inauto/bootenv. Через него RAUC grub backend (grub-editenv) читает и
# пишет ORDER/OK/TRY; сам GRUB работает с тем же файлом на ранней загрузке.
function install_rauc_bootenv_mount() {
    cat <<'EOF_UNIT' > /etc/systemd/system/run-inauto-bootenv.mount
[Unit]
Description=Mount efi_A (GRUB env) for RAUC grub backend
DefaultDependencies=no
After=local-fs-pre.target
Before=umount.target
Conflicts=umount.target

[Mount]
What=/dev/disk/by-partlabel/efi_A
Where=/run/inauto/bootenv
Type=vfat
Options=rw,umask=0077

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 /etc/systemd/system/run-inauto-bootenv.mount

    # rauc.service должен видеть grubenv с самого старта.
    install -d -m 0755 /etc/systemd/system/rauc.service.d
    cat <<'EOF_DROPIN' > /etc/systemd/system/rauc.service.d/10-inauto-bootenv.conf
[Unit]
After=run-inauto-bootenv.mount
Requires=run-inauto-bootenv.mount
EOF_DROPIN
    chmod 0644 /etc/systemd/system/rauc.service.d/10-inauto-bootenv.conf

    systemctl enable run-inauto-bootenv.mount
    echo "[rauc] run-inauto-bootenv.mount включён (grubenv на efi_A)"
}

# Boot-артефакты внутри squashfs для единого GRUB (см.
# docs/2026-07-04-grub-boot-selection-design.md):
#   /boot/vmlinuz, /boot/initrd.img — стабильные симлинки на новейшее ядро;
#   /boot/grub-slot.cfg             — сниппет, который source'ит главный
#                                     grub.cfg с efi_A ($slotdev/$bootname/
#                                     $rootpart выставляет он же).
function install_rauc_boot_artifacts() {
    local kver kernel initrd

    kernel="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sort -V | tail -n1)"
    [[ -n "$kernel" ]] || { echo "[rauc] ERROR: в /boot нет vmlinuz-*; ядро должно быть установлено раньше" >&2; exit 1; }
    kver="${kernel#vmlinuz-}"
    initrd="initrd.img-$kver"
    [[ -f "/boot/$initrd" ]] || { echo "[rauc] ERROR: нет /boot/$initrd (initramfs не собрана?)" >&2; exit 1; }

    ln -sf "$kernel" /boot/vmlinuz
    ln -sf "$initrd" /boot/initrd.img

    # loglevel=3: quiet скрывает только INFO/WARN, а KERN_ERR (например,
    # косметические ACPI BIOS Error из кривого DSDT панели) всё равно печатается
    # на консоль. loglevel=3 оставляет на экране только CRIT и хуже; полный лог
    # по-прежнему в dmesg/journald.
    cat <<'EOF_SLOT' > /boot/grub-slot.cfg
linux ${slotdev}/boot/vmlinuz rauc.slot=${bootname} root=PARTLABEL=${rootpart} rootfstype=squashfs ro quiet loglevel=3 panic=30
initrd ${slotdev}/boot/initrd.img
EOF_SLOT
    chmod 0644 /boot/grub-slot.cfg
    echo "[rauc] /boot/{vmlinuz,initrd.img} -> $kernel/$initrd; grub-slot.cfg записан"
}

# Полная настройка RAUC target'а. Вызывается из custom_conf().
# No-op для TARGET_FORMAT=iso.
function configure_rauc_target() {
    if ! rauc_enabled; then
        return 0
    fi

    echo "[rauc] настройка RAUC target'а начата"
    render_rauc_system_conf
    install_rauc_keyring
    install_rauc_initramfs
    install_rauc_bootenv_mount
    install_rauc_boot_artifacts
    install_rauc_mark_good
    install_rauc_watchdog
    install_rauc_update_agent
    install_rauc_update_helper
    write_firmware_version_file
    echo "[rauc] настройка RAUC target'а завершена"
}
