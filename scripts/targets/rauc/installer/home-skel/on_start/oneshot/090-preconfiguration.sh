#!/bin/bash
# Сетевой воркэраунд панели (oneshot, после подъёма сети).
# Время (NTP + часовой пояс) — в 005-time.sh.
set -euo pipefail

# Шлюз периодически шлёт ICMP "Network Unreachable", что отравляет dst-cache ядра:
# connect() начинает возвращать ENETUNREACH из кеша, не отправляя пакет. Блокируем
# ICMP unreachable от шлюза. Требует поднятую сеть (маршрут по умолчанию) — потому
# скрипт в oneshot. (ip route flush cache + restart hasplmd — в ExecStartPre hasplmd.)
# TODO(firewall): пока ufw отключён (001-idmvs.sh), правило живёт как raw iptables.
# При переходе на управляемый ufw — перенести в /etc/ufw/before.rules.
GW=$(ip route show default | awk '/default/ {print $3; exit}')
if [[ -n "$GW" ]]; then
    iptables -C INPUT -s "$GW" -p icmp --icmp-type network-unreachable -j DROP 2>/dev/null || \
        iptables -I INPUT -s "$GW" -p icmp --icmp-type network-unreachable -j DROP
fi

echo "preconf (net) done"