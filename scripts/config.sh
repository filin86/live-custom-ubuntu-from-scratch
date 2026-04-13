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
export TARGET_UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu/"

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
export CONFIG_FILE_VERSION="0.4"

HOMEPATH="/home/inauto"
ETCPATH="/etc/inauto"

FINDHOME="find-and-mount-home.sh"
EXECFILESINFOLDER="exec-files-in-folder.sh"

ONLOGIN="on_login"
ONSTART="on_start"

XDG_CONFIG_DIRS="/etc/xdg"

AUTOLOGIN_USER="ubuntu"
AUTOLOGIN_SESSION="xfce"
DOCKER_DATA_ROOT="$HOMEPATH/docker"

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
    # install graphics and desktop (LXQt based)
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
        dbus-x11

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
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    docker_arch=$(dpkg --print-architecture)
    docker_codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

    cat <<EOF_DOCKER_APT > /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
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
    mkdir -p /etc/docker
    cat <<EOF_DOCKER > /etc/docker/daemon.json
{
  "data-root": "$DOCKER_DATA_ROOT"
}
EOF_DOCKER

    mkdir -p /etc/systemd/system/docker.service.d
    cat <<EOF_DOCKER_OVERRIDE > /etc/systemd/system/docker.service.d/10-inauto.conf
[Unit]
After=MountHome.service

[Service]
ExecStartPre=/bin/mkdir -p $DOCKER_DATA_ROOT
EOF_DOCKER_OVERRIDE

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
