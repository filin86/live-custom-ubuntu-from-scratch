#!/bin/bash

# This script provides common customization options for the ISO
#
# Usage: Copy this file to config.sh and make changes there. Keep this file (default_config.sh) as-is
# so that subsequent changes can be easily merged from upstream. Keep all customizations in config.sh

# The version of Ubuntu to generate. Successfully tested LTS: bionic, focal, jammy, noble
# See https://wiki.ubuntu.com/DevelopmentCodeNames for details
export TARGET_UBUNTU_VERSION="noble"

# The Ubuntu Mirror URL. It's better to change for faster download.
# More mirrors see: https://launchpad.net/ubuntu/+archivemirrors
export TARGET_UBUNTU_MIRROR="https://archive.ubuntu.com/ubuntu/"

# Distro selector.
export TARGET_DISTRO="${TARGET_DISTRO:-ubuntu}"

# Debian parameters (active when TARGET_DISTRO=debian).
export TARGET_DEBIAN_VERSION="trixie"
export TARGET_DEBIAN_MIRROR="http://deb.debian.org/debian/"

# The packaged version of the Linux kernel to install on target image.
export TARGET_KERNEL_PACKAGE="linux-generic"

# The file (no extension) of the ISO containing the generated disk image,
# the volume id, and the hostname of the live environment are set from this name.
export TARGET_NAME="inauto-ubuntu-livecd"

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
export CONFIG_FILE_VERSION="0.5"

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
	configure_autologin
    enable_on_screen_kbd
    enable_vnc

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

	echo -e "Inmark2026\nInmark2026" | passwd root

    remove_unused_features
    remove_dangerous
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
        rsync \
        ufw \
        x11vnc \
        dbus-x11 \
        e2fsprogs

    install_docker_engine
}

function net_config() {
	apt-get install -y netplan.io util-linux network-manager
    systemctl enable NetworkManager.service
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

    chmod 755 "$ETCPATH/$DOCKER_STORAGE_SCRIPT"
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

    chmod 644 /etc/systemd/system/MountHome.service
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
