#!/bin/bash
# Установка службы сетевого ключа HASP на текущую загрузку (root, systemd oneshot).
# Сбой установки логируется, но не прерывает остальные скрипты фазы oneshot.
set -euo pipefail

if /home/inauto/distr/install_hasplm.sh; then
    echo "hasplm install: OK"
else
    echo "ERROR: install_hasplm.sh завершился с ошибкой" >&2
fi

# Перечитываем udev-правила (HASP-ключ кладёт свои в /etc/udev).
udevadm control --reload
udevadm trigger