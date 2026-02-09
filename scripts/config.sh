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


function custom_conf() {
    mkdir -p "$HOMEPATH" "$ETCPATH"

    make_find_flash_script
    exec_files_in_folder

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

    exec_on_start
    journald_conf

    systemctl daemon-reload
    systemctl enable \
        MountHome.service \
        OnStartBeforeLogin.service \
        OnStartOneShot.service \
        OnStartForking.service \
        x11vnc.service

	echo -e "Inmark2026\nInmark2026" | passwd root

    remove_dangerous
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


    # useful tools
    apt-get install -y \
        curl \
        nano \
		mc \
        less \
        openssh-server \
        ethtool \
        kbd \
        mtools \
        iputils-ping \
        libxcb-cursor0 \
        rsync \
        ufw \
        x11vnc \
        dbus-x11
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
