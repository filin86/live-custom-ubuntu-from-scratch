#!/bin/bash

# This script provides common customization options for the ISO
# 
# Usage: Copy this file to config.sh and make changes there.  Keep this file (default_config.sh) as-is
#   so that subsequent changes can be easily merged from upstream.  Keep all customiations in config.sh

# The version of Ubuntu to generate.  Successfully tested LTS: bionic, focal, jammy, noble
# See https://wiki.ubuntu.com/DevelopmentCodeNames for details
export TARGET_UBUNTU_VERSION="noble"

# The Ubuntu Mirror URL. It's better to change for faster download.
# More mirrors see: https://launchpad.net/ubuntu/+archivemirrors
export TARGET_UBUNTU_MIRROR="http://ru.archive.ubuntu.com/ubuntu/"

# The packaged version of the Linux kernel to install on target image.
# See https://wiki.ubuntu.com/Kernel/LTSEnablementStack for details
export TARGET_KERNEL_PACKAGE="linux-generic"

# The file (no extension) of the ISO containing the generated disk image,
# the volume id, and the hostname of the live environment are set from this name.
export TARGET_NAME="inauto-ubuntu-livecd"

# The text label shown in GRUB for booting into the live environment
export GRUB_LIVEBOOT_LABEL="Inautomatic LiveCD"

# The text label shown in GRUB for starting installation
export GRUB_INSTALL_LABEL="Install Ubuntu FS"

# Packages to be removed from the target system after installation completes succesfully
export TARGET_PACKAGE_REMOVE="
    ubiquity \
    casper \
    discover \
    laptop-detect \
    os-prober \
"

HOMEPATH="/home/inauto"
ETCPATH="/etc/inauto"
USRPATH="/usr/storage"

FINDHOME="find-and-mount-home.sh"
FINDSTOR="find-and-mount-stor.sh"


function custom_conf() {


    mkdir -p $HOMEPATH
    mkdir -p $ETCPATH
    
    find_flash
    
    network_conf
    ssh_conf

    #apt-get install -y sshpass
    disable_services
    install_ldk

    service_mounthome
    service_mountlextnetdriver
    service_mountnetinterfaces
    service_startapp

    mkdir -p /etc/systemd/journald.conf.d
    journald_conf

    systemctl daemon-reload
    systemctl enable MountHome.service MountExtNetDriver.service MountNetInterfaces.service StartApp.service hasplmd.service aksusbd.service

    mc_selected_editor

    echo write the passwd: 123456
    passwd root

    disable_sudo

}

function disable_sudo() {
    #awk '{if ($0 ~ /    echo "${USERNAME}  ALL=(ALL) NOPASSWD: ALL" > /root/etc/sudoers) print "#" $0; else print}' usr/share/initramfs-tools/scripts/casper-bottom/25adduser
    #awk '{if ($0 ~ /    echo "${USERNAME}  ALL=(ALL) NOPASSWD: ALL"/) print "#" $0; else print}' /usr/share/initramfs-tools/scripts/casper-bottom/25adduser > /usr/share/initramfs-tools/scripts/casper-bottom/25adduser.tmp && mv /usr/share/initramfs-tools/scripts/casper-bottom/25adduser.tmp /usr/share/initramfs-tools/scripts/casper-bottom/25adduser
    #chmod +x /usr/share/initramfs-tools/scripts/casper-bottom/25adduser 
    sed -i '77s/^/#/' /usr/share/initramfs-tools/scripts/casper-bottom/25adduser
}

function install_ldk() {
# Variables
SFTP_HOST="172.16.88.24"
SFTP_USER="orpo_sftp"
SFTP_PASS="InAuto2024"
SFTP_PORT="22"
REMOTE_FILE="/uploads/images/ubuntu_livecd_files_for_build/aksusbd_10.12-1_amd64.deb"
LOCAL_DIR="/etc/inauto"

echo "downloading file"
# Use sshpass with scp to download the file
sshpass -p "$SFTP_PASS" scp -o "StrictHostKeyChecking accept-new" -P $SFTP_PORT "$SFTP_USER@$SFTP_HOST:$REMOTE_FILE" "$LOCAL_DIR"
echo "installing file"
dpkg -i "$LOCAL_DIR/aksusbd_10.12-1_amd64.deb"

}


function disable_services() {
    ### systemd-networkd.service is desable !!!
    systemctl disable systemd-networkd.socket
    systemctl disable systemd-networkd.service
    ### This daemon is similar to NetworkManager, but the limited nature of systemd-networkd
    systemctl disable networkd-dispatcher.service
    systemctl disable systemd-networkd-wait-online.service
    ### DNS !!! & ### tokmakov.msk.ru/blog/item/522
    # systemctl disable systemd-resolved.service
    # apt install -y resolvconf
    # systemctl enable resolvconf

    ### mounting a partition without a file system <system boot delay>
    #systemctl disable var-crash.mount
    #systemctl disable var-log.mount

    ### демон для управления установкой обновлений прошивки в системах на базе Linux
    systemctl disable fwupd-offline-update.service
    systemctl disable fwupd.service
    systemctl disable fwupd-refresh.service
    ### программная среда для обеспечения геопространственной осведомленности в приложениях
    # systemctl disable geoclue.service
    ### собирает информацию о сбое ядра, отправляет извлеченную подпись в kerneloops.org & canonical
    systemctl disable kerneloops.service
    systemctl disable whoopsie.service
    ### dbus and automount ???
    systemctl mask udisks2
    systemctl disable udisks2.service
    ### инструмент автоматической установки обновлений
    systemctl disable unattended-upgrades.service
    systemctl disable secureboot-db.service

}


function network_conf() {
    netwrokmanager_conf
    dpkg-reconfigure network-manager
}

# Package customisation function.  Update this function to customize packages
# present on the installed system.
function customize_image() {
    # install graphics and desktop
    apt-get install -y \
        xubuntu-desktop-minimal
        #xubuntu-wallpapers
        #plymouth-themes 

    # useful tools
    apt-get install -y \
        clamav-daemon \
        terminator \
        apt-transport-https \
        curl \
        vim \
        nano \
        less \
        mc \
        ssh \
        ethtool \
        net-tools \
        python3 \
        kbd \
        mtools \
        sshpass \
        iputils-ping \
        libxcb-cursor0


    # purge
    apt-get purge -y \
        "libreoffice*" \
        transmission-gtk \
        transmission-common \
        gnome-mahjongg \
        gnome-mines \
        gnome-sudoku \
        aisleriot \
        hitori
}

# Used to version the configuration.  If breaking changes occur, manual
# updates to this file from the default may be necessary.
export CONFIG_FILE_VERSION="0.4"

function mc_selected_editor() {
    cat <<EOF > /root/.selected_editor
# Generated by /usr/bin/select-editor
SELECTED_EDITOR="/usr/bin/mcedit"
EOF

#     cat <<EOF > /home/inauto/.selected_editor
# SELECTED_EDITOR="/usr/bin/mcedit"
# EOF

}

function netwrokmanager_conf() {
    # network manager
    cat <<EOF > /etc/NetworkManager/NetworkManager.conf
[main]
plugins=ifupdown,keyfile
### ++ disable polkit
###auth-polkit=root-only
### ++ quets after performing initial network configuration (Wi-Fi, WWAN, Bluetooth, ADSL, and PPPoE interfaces cannot be preserved)
configure-and-quit=true
### systemd-resolved is chosen automatically ???
dns=default
### disable systemd-resolved
rc-manager=resolvconf
### disable systemd-resolved
systemd-resolved=false
### ++ settings this value to 1 means to try action once without retry
autoconnect-retries-default=1

[ifupdown]
managed=false
EOF
}

function journald_conf() {
    cat <<EOF > /etc/systemd/journald.conf.d/journald.conf
[Journal]
SplitMode=false
SystemMaxUse=50M
SystemMaxFileSize=50M
ForwardToSyslog=no
EOF
}

function service_mounthome() {
    fname='/etc/systemd/system/MountHome.service'
    cat <<EOF > $fname
[Unit]
Description=find and mount device with .inautolock
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$ETCPATH/$FINDHOME
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod 644 $fname 
}

function service_mountnetinterfaces() {
    fname='/etc/systemd/system/MountNetInterfaces.service'
    cat <<EOF > $fname
[Unit]
Description=MountNetInterfaces
After=MountHome.service network.target network-online.target MountExtNetDriver.service

[Service]
Type=oneshot
ExecStart=$HOMEPATH/net/ifaces.sh

[Install]
WantedBy=multi-user.target
EOF

chmod 644 $fname 
}

function service_mountlextnetdriver() {
    fname='/etc/systemd/system/MountExtNetDriver.service'
    cat <<EOF > $fname
[Unit]
Description=MountExtNetDriver
After=MountHome.service
Before=networking.service

[Service]
Type=oneshot
ExecStart=$HOMEPATH/net/drv/netdriver_init
#
[Install]
WantedBy=multi-user.target
EOF

chmod 644 $fname 
}


function service_startapp() {
    fname='/etc/systemd/system/StartApp.service'
    cat <<EOF > $fname
[Unit]
Description=StartApp
After=MountNetInterfaces.service

[Service]
Type=forking
ExecStart=$HOMEPATH/inmark/app_init

[Install]
WantedBy=multi-user.target
EOF

chmod 644 $fname
}

function ssh_conf() {
    cat <<EOF > /etc/ssh/sshd_config

# This is the sshd server system-wide configuration file.  See
# sshd_config(5) for more information.

# This sshd was compiled with PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games

# The strategy used for options in the default sshd_config shipped with
# OpenSSH is to specify options with their default value where
# possible, but leave them commented.  Uncommented options override the
# default value.

Include /etc/ssh/sshd_config.d/*.conf

#HostKey /etc/ssh/ssh_host_rsa_key
#HostKey /etc/ssh/ssh_host_ecdsa_key
#HostKey /etc/ssh/ssh_host_ed25519_key


# Authentication:

LoginGraceTime 2m
PermitRootLogin yes
StrictModes yes

PubkeyAuthentication no

# Expect .ssh/authorized_keys2 to be disregarded by default in future.
#AuthorizedKeysFile	.ssh/authorized_keys .ssh/authorized_keys2

#AuthorizedPrincipalsFile none

#AuthorizedKeysCommand none
#AuthorizedKeysCommandUser nobody

# For this to work you will also need host keys in /etc/ssh/ssh_known_hosts
#HostbasedAuthentication no
# Change to yes if you don't trust ~/.ssh/known_hosts for
# HostbasedAuthentication
#IgnoreUserKnownHosts no
# Don't read the user's ~/.rhosts and ~/.shosts files
#IgnoreRhosts yes

# To disable tunneled clear text passwords, change to no here!
#PasswordAuthentication yes
#PermitEmptyPasswords no

# Change to yes to enable challenge-response passwords (beware issues with
# some PAM modules and threads)
KbdInteractiveAuthentication no

# Set this to 'yes' to enable PAM authentication, account processing,
# and session processing. If this is enabled, PAM authentication will
# be allowed through the KbdInteractiveAuthentication and
# PasswordAuthentication.  Depending on your PAM configuration,
# PAM authentication via KbdInteractiveAuthentication may bypass
# the setting of "PermitRootLogin prohibit-password".
# If you just want the PAM account and session checks to run without
# PAM authentication, then enable this but set PasswordAuthentication
# and KbdInteractiveAuthentication to 'no'.
UsePAM yes


X11Forwarding yes

PrintMotd no


# Allow client to pass locale environment variables
AcceptEnv LANG LC_*

# override default of no subsystems
Subsystem	sftp	/usr/lib/openssh/sftp-server

EOF
}


function find_flash() {
    fname=$ETCPATH/$FINDHOME
    cat <<EOF > $fname
#!/bin/bash

MOUNTPOINT="$HOMEPATH"
LOCKFILE=".inautolock"    

check_and_mount() {
    local device=\$1
    local tempmount=\$(mktemp -d)
    
    if mount "\$device" "\$tempmount"; then
        if [ -f "\$tempmount/\$LOCKFILE" ]; then
            echo "Found \$LOCKFILE on \$device. Mounting at \$MOUNTPOINT."
            umount "\$tempmount"
            mount "\$device" "\$MOUNTPOINT"
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
EOF

chmod +x $fname

}

