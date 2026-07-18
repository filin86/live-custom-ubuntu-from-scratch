#!/bin/bash
# Служебный пользователь redcheck (его SSH-ключ ставит 05-ssh-keys.sh).
# Выполняется от root (systemd oneshot), sudo не нужен.
set -euo pipefail

readonly USER_NAME=svc_redcheck_truesign

# Идемпотентно: создаём пользователя, только если его ещё нет.
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    useradd -m "$USER_NAME"
fi

# Служебному аккаунту нужен sudo (в отличие от ubuntu — см. 02-user-setup.sh).
# Было 'sudo -aG sudo ...' — сломанная команда; корректно usermod -aG.
usermod -aG sudo "$USER_NAME"

echo "redcheck user configured"