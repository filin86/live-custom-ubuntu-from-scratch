#!/bin/bash
# Настройки сетевого ключа HASP (oneshot). Часовой пояс — в 005-time.sh.
set -euo pipefail

# Без hasplm.ini ключ может не найтись.
if [[ -r /home/inauto/staff/hasplm/hasplm.ini ]]; then
    cp /home/inauto/staff/hasplm/hasplm.ini /etc/hasplm
    # Перезапуск службы сетевого ключа. Возможно дублирует ExecStartPre hasplmd —
    # см. комментарий в 090-preconfiguration.sh.
    systemctl restart hasplmd || echo "WARN: не удалось перезапустить hasplmd" >&2
else
    echo "WARN: /home/inauto/staff/hasplm/hasplm.ini не найден" >&2
fi

echo "hasplm preconf done"