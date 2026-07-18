#!/bin/bash
# network_pre: выполняется ДО старта NetworkManager (см. OnStartNetworkPre.service).
# Кладём site netplan-конфиг и генерируем backend-конфиг (NM/networkd) из YAML.
# НЕ вызываем 'netplan apply' — NetworkManager ещё не запущен, применять нечего;
# он прочитает сгенерированный конфиг при своём старте (без churn/restart).
set -euo pipefail

readonly SRC=/home/inauto/staff/netplan

# Заменяем netplan только если site-конфиг реально есть — иначе не затираем
# дефолтный конфиг и не оставляем систему вовсе без сети.
if compgen -G "$SRC/*" > /dev/null; then
    # Своп через staging: рискованное чтение с persistent-раздела делаем в tmp,
    # и только при успехе стираем /etc/netplan. Иначе оборванный cp мог бы
    # оставить /etc/netplan пустым -> NM стартует вообще без сети.
    stage="$(mktemp -d)"
    cp -rf "$SRC"/* "$stage"/
    rm -rf /etc/netplan/*
    cp -rf "$stage"/* /etc/netplan/   # tmpfs->overlay, локально, практически не падает
    rm -rf "$stage"

    # Профили должны быть 600 — netplan игнорирует world-readable конфиги.
    for y in /etc/netplan/*.yaml; do
        [[ -e "$y" ]] && chmod 600 "$y"
    done
fi

netplan generate

# NetworkManager: не плодить авто-"Wired connection 1" на неконфигурированных
# интерфейсах — поднимаются только явные соединения (замена старому
# 'nmcli connection delete' из 03-fs-reload). Пишем ДО старта NM.
# БЕЗ [connection] autoconnect=false: иначе реальные соединения (из netplan) не
# поднимались бы автоматически — панель осталась бы без сети.
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/20-no-auto-default.conf <<'EOF'
[main]
no-auto-default=*
EOF