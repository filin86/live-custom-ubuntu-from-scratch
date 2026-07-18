#!/bin/bash
# Устанавливает authorized_keys для всех аккаунтов из /home/inauto/staff/ssh/<user>.
# Выполняется от root (systemd oneshot) ПОСЛЕ создания пользователей (01-...) и ДО
# входа пользователя (10-kiosk).
# sshd (StrictModes) требует .ssh=700, authorized_keys=600 и владельца — самого
# пользователя, иначе ключ молча игнорируется.
set -euo pipefail

# Ставит pubkey как authorized_keys с нужными правами/владельцем одним атомарным
# install(1). Перезапись (не дозапись) — идемпотентность при повторных загрузках.
function install_authorized_key() {
    local user="$1" home="$2"
    local pubkey="/home/inauto/staff/ssh/$user/.ssh/id_rsa.pub"
    if [[ ! -f "$pubkey" ]]; then
        echo "WARN: $pubkey не найден — ключ для $user не установлен" >&2
        return 0
    fi
    install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
    install -m 600 -o "$user" -g "$user" "$pubkey" "$home/.ssh/authorized_keys"
}

install_authorized_key root                  /root
install_authorized_key ubuntu               /home/ubuntu
install_authorized_key svc_redcheck_truesign /home/svc_redcheck_truesign

echo "SSH keys installed"