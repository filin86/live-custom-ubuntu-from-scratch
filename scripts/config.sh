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
    ffmpeg \
    os-prober \
"

# Used to version the configuration.  If breaking changes occur, manual
# updates to this file from the default may be necessary.
export CONFIG_FILE_VERSION="0.4"

HOMEPATH="/home/inauto"
ETCPATH="/etc/inauto"
USRPATH="/usr/storage"

FINDHOME="find-and-mount-home.sh"
FINDSTOR="find-and-mount-stor.sh"

EXECFILESINFOLDER="exec-files-in-folder.sh"

ONLOGIN="on_login"
ONSTART="on_start"

XDG_CONFIG_DIRS="/etc/xdg/xdg-xubuntu"


function custom_conf() {


    mkdir -p $HOMEPATH
    mkdir -p $ETCPATH
    
    make_find_flash_script
    
    net_config
    ssh_conf

    enable_on_screen_kbd
    enable_vnc

    #apt-get install -y sshpass
    #disable_network
    disable_updates
    disable_oopsie
    disable_automount
    #install_ldk

    service_mounthome
    service_onstartbeforelogin
    service_onstartoneshot
    service_onstartforking

    exec_on_start
    exec_files_in_folder

    journald_conf

    systemctl daemon-reload
    systemctl enable MountHome.service OnStartBeforeLogin.service OnStartOneShot.service OnStartForking.service 
    #hasplmd.service aksusbd.service

    echo write the passwd: 123456
    passwd root

    disable_sudo

    remove_dangerous

}

function disable_sudo() {
    #awk '{if ($0 ~ /    echo "${USERNAME}  ALL=(ALL) NOPASSWD: ALL" > /root/etc/sudoers) print "#" $0; else print}' usr/share/initramfs-tools/scripts/casper-bottom/25adduser
    #awk '{if ($0 ~ /    echo "${USERNAME}  ALL=(ALL) NOPASSWD: ALL"/) print "#" $0; else print}' /usr/share/initramfs-tools/scripts/casper-bottom/25adduser > /usr/share/initramfs-tools/scripts/casper-bottom/25adduser.tmp && mv /usr/share/initramfs-tools/scripts/casper-bottom/25adduser.tmp /usr/share/initramfs-tools/scripts/casper-bottom/25adduser
    #chmod +x /usr/share/initramfs-tools/scripts/casper-bottom/25adduser 
    sed -i '77s/^/#/' /usr/share/initramfs-tools/scripts/casper-bottom/25adduser
}

function remove_dangerous() {
    apt-get purge -y \
        hitori\
        7zip \
        ffmpeg
}

# function install_ldk() {
# # Variables
# SFTP_HOST="172.16.88.24"
# SFTP_USER="orpo_sftp"
# SFTP_PASS="InAuto2024"
# SFTP_PORT="22"
# REMOTE_FILE="/uploads/images/ubuntu_livecd_files_for_build/aksusbd_10.12-1_amd64.deb"
# LOCAL_DIR="$ETCPATH"

# echo "downloading file"
# # Use sshpass with scp to download the file
# sshpass -p "$SFTP_PASS" scp -o "StrictHostKeyChecking accept-new" -P $SFTP_PORT "$SFTP_USER@$SFTP_HOST:$REMOTE_FILE" "$LOCAL_DIR"
# echo "installing file"
# dpkg -i "$LOCAL_DIR/aksusbd_10.12-1_amd64.deb"

# }

function exec_files_in_folder() {
    echo "#!/bin/bash

find $HOMEPATH/\$1 -maxdepth 1 -type f -executable | sort | while read script; do 
echo start executing \"\$script\"
    \"\$script\"
echo executing \"\$script\" is complete
done
" | sudo tee "$ETCPATH/$EXECFILESINFOLDER"

chmod 755 "$ETCPATH/$EXECFILESINFOLDER"
}


function exec_on_start() {
    echo "[Desktop Entry]
Name=Exec scripts in $HOMEPATH/$ONLOGIN
Exec=$ETCPATH/$EXECFILESINFOLDER $ONLOGIN
StartapNotify=false
Type=Application
" | sudo tee "${XDG_CONFIG_DIRS}"/autostart/exec_on_start.desktop
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
        nano \
        less \
        mc \
        ssh \
        ethtool \
        python3 \
        kbd \
        mtools \
        sshpass \
        iputils-ping \
        ncat \
        libxcb-cursor0
        #net-tools \
        #scite \
        #vim \

    # purge
    apt-get purge -y \
        "libreoffice*" \
        transmission-gtk \
        transmission-common \
        gnome-mahjongg \
        gnome-mines \
        gnome-sudoku \
        aisleriot \
        hitori\
        7zip \
        ffmpeg
#        webkit2gtk \

}

function net_config() {
    apt-get install -y netplan.io util-linux
    # netplan.io : для настройки сетевых интерфейсов.
    # util-linux : содержит утилиты для работы с разделами (например, blkid).
}

function enable_vnc() {
    sudo apt-get install -y x11vnc xfce4-goodies xfce4-settings xfce4-session xfce4-panel libxfconf-0-3 dbus dbus-x11
    # x11vnc : сервер VNC для подключения к текущей X-сессии.
    # xfce4-vnc-plugin : плагин для интеграции VNC с XFCE.
    # xfce4-settings : настройки XFCE (для управления плагинами).

    # настройка запуска без пароля
    #echo "x11vnc -forever -loop -noxdamage -nopw -display :0" | sudo tee /etc/init.d/x11vnc
    #echo "x11vnc -forever -loop -noxdamage -usepw -display :0" | sudo tee /etc/init.d/x11vnc
    # установка пароля:
    # x11vnc -storepasswd /etc/x11vnc.pass

    echo "dbus-launch --exit-with-session" | sudo tee -a /etc/X11/Xsession.d/40xfce4
    
    # добавить в автозагрузку скрипт
    echo "[Desktop Entry]
Name=X11VNC Server
Exec=/usr/bin/x11vnc -forever -loop -noxdamage -nopw  -display :0
Type=Application
" | sudo tee "${XDG_CONFIG_DIRS}"/autostart/x11vnc.desktop
    
    # Разрешите входящие соединения на порт VNC (по умолчанию 5900 )
    sudo ufw allow 5900/tcp
    sudo ufw enable

    # /usr/bin/x11vnc -forever -loop -usepw -display :0

#     mkdir -p /usr/lib/x86_64-linux-gnu/xfce4/xfce4-session-save

#     echo "[Desktop Entry]
# Name=X11 VNC
# Exec=xfconf-query -c xfce4-session -p /General/SavedSetup | xargs xfce4-session-save -l -p

# Type=Application
# " | sudo tee /etc/xdg/autostart/x11vnc.desktop
#     # чтобы VNC интегрирован с текущей сессией XFCE:

    # автозапуск
#     echo "[Unit]
# Description=X11VNC Server
# After=network.target display-manager.service

# [Service]
# Type=forking
# ExecStart=/usr/bin/x11vnc -forever -loop -noxdamage -nopw -display :0
# Restart=on-failure
# User=root

# [Install]
# WantedBy=multi-user.target" | sudo tee /etc/systemd/system/x11vnc.service

    # sudo systemctl enable x11vnc.service
}

function service_mounthome() {
    fname='/etc/systemd/system/MountHome.service'
    cat <<EOF > $fname
[Unit]
Description=Find and mount device with .inautolock
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

function service_onstartbeforelogin() {
    fname='/etc/systemd/system/OnStartBeforeLogin.service'
    cat <<EOF > $fname
[Unit]
Description=Exec scripts in $HOMEPATH/$ONSTART/before_login
After=MountHome.service
Before=networking.service

[Service]
Type=oneshot
ExecStart=$ETCPATH/$EXECFILESINFOLDER $ONSTART/before_login

[Install]
WantedBy=multi-user.target
EOF

#
chmod 644 $fname 
}

function service_onstartoneshot() {
    fname='/etc/systemd/system/OnStartOneShot.service'
    cat <<EOF > $fname
[Unit]
Description=Exec scripts in $HOMEPATH/$ONSTART/oneshot
After=MountHome.service network.target network-online.target OnStartBeforeLogin.service

[Service]
Type=oneshot
ExecStart=$ETCPATH/$EXECFILESINFOLDER $ONSTART/oneshot 

[Install]
WantedBy=multi-user.target
EOF

chmod 644 $fname 

#ExecStart=$HOMEPATH/$ONSTART/configure_network
}

function service_onstartforking() {
    fname='/etc/systemd/system/OnStartForking.service'
    cat <<EOF > $fname
[Unit]
Description=Exec scripts in $HOMEPATH/$ONSTART/forking
After=OnStartOneShot.service

[Service]
Type=forking
ExecStart=$ETCPATH/$EXECFILESINFOLDER $ONSTART/forking 

[Install]
WantedBy=multi-user.target
EOF

#ExecStart=$HOMEPATH/$ONSTART/start_app
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

PubkeyAuthentication yes

# Expect .ssh/authorized_keys2 to be disregarded by default in future.
AuthorizedKeysFile	.ssh/authorized_keys .ssh/authorized_keys2

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
PasswordAuthentication no
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


function make_find_flash_script() {
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

function journald_conf() {
    mkdir -p /etc/systemd/journald.conf.d
    
    cat <<EOF > /etc/systemd/journald.conf.d/journald.conf
[Journal]
SplitMode=false
SystemMaxUse=50M
SystemMaxFileSize=50M
ForwardToSyslog=no
EOF
}

function disable_network() {
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
    ### программная среда для обеспечения геопространственной осведомленности в приложениях
    # systemctl disable geoclue.service
}

function disable_updates() {
    ### демон для управления установкой обновлений прошивки в системах на базе Linux
    systemctl disable fwupd-offline-update.service
    systemctl disable fwupd.service
    systemctl disable fwupd-refresh.service

    ### инструмент автоматической установки обновлений
    systemctl disable unattended-upgrades.service
    systemctl disable secureboot-db.service
}

function disable_oopsie() {
    ### собирает информацию о сбое ядра, отправляет извлеченную подпись в kerneloops.org & canonical
    systemctl disable kerneloops.service
    systemctl disable whoopsie.service
}

function disable_automount(){
    ### dbus and automount ???
    systemctl mask udisks2
    systemctl disable udisks2.service
}


function enable_on_screen_kbd(){
    apt-get install -y \
    onboard 
    # \
    # xserver-xorg-input-libinput \
    # x11-xserver-utils \
    # x11-utils
    # onboard : экранная клавиатура.
    # xserver-xorg-input-libinput : драйвер для сенсорных экранов и других вводных устройств.
    # x11-xserver-utils  (необязательно, но полезно для диагностики).

    # xserver-xorg-input-synaptics # дополнительные драйверы
    # xinput-calibrator  # Для калибровки сенсорных экранов

    # Autostart for osk
#     echo "[Desktop Entry]
# Name=Onboard
# Exec=onboard
# Type=Application
# " | sudo tee /etc/xdg/autostart/onboard.desktop
}

