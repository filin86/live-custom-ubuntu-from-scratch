#!/bin/bash
# network_pre: выполняется ДО старта NetworkManager (см. OnStartNetworkPre.service).
# Раскладываем fs-overlay (в т.ч. профили NM в /etc/NetworkManager/system-connections)
# ДО подъёма сети, чтобы NetworkManager прочитал их при старте.
# Поэтому здесь БОЛЬШЕ НЕ нужно удалять соединения через nmcli и перезапускать
# NetworkManager — на этой фазе его ещё нет.
set -euo pipefail

if compgen -G "/home/inauto/staff/fs/*" > /dev/null; then
    # -a сохраняет права/владельца: NM игнорирует *.nmconnection не с режимом 600.
    cp -a /home/inauto/staff/fs/* /
fi

# Перечитываем unit-файлы, если overlay принёс/изменил systemd-юниты.
systemctl daemon-reload