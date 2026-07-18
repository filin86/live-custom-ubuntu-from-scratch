#!/bin/bash
# Раскатываем kiosk-конфиг в /home/ubuntu ДО входа пользователя.
set -euo pipefail

readonly SRC=/home/inauto/staff/kiosk

mkdir -p /home/ubuntu

if [[ -d "$SRC" ]]; then
    # rsync берёт и dotfiles, но НЕ '.'/'..' (в отличие от 'cp -rf .*',
    # который тащил родительский staff/ целиком — вплоть до ssh-ключей).
    # X-auth runtime исключаем явно: это привязанное к хосту/дисплею состояние
    # сессии — попав сюда, оно ломает авторизацию X и автологин; lightdm создаст
    # свежий cookie сам.
    rsync -a --exclude='.Xauthority' --exclude='.ICEauthority' "$SRC"/ /home/ubuntu/
fi

chown -R ubuntu:ubuntu /home/ubuntu

echo "Kiosk mode is on"