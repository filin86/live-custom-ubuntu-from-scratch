#!/bin/bash
# Настройка времени панели: часовой пояс (staff/timezone) + NTP-сервер
# (staff/ntp-server, генерим timesyncd.conf) + запуск systemd-timesyncd.
# Всё БЕЗ timedatectl — на immutable-панели он даёт 'Access denied' через
# timedated/polkit (нет сессии/агента в boot-контексте). Зона — прямым symlink'ом
# /etc/localtime (то же, что timedatectl под капотом), служба NTP — через systemctl.
set -euo pipefail

readonly TZ_FILE=/home/inauto/staff/timezone
readonly NTP_FILE=/home/inauto/staff/ntp-server

# --- Часовой пояс ---
if [[ -r "$TZ_FILE" ]]; then
    # Чистим CR/пробелы: CRLF-файл раньше молча не проходил проверку zoneinfo.
    read -r tz _ < "$TZ_FILE" || true
    tz="${tz//[$'\r\n\t ']/}"
    if [[ -n "$tz" && -e "/usr/share/zoneinfo/$tz" ]]; then
        ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
        printf '%s\n' "$tz" > /etc/timezone
        echo "timezone set to $tz"
    else
        echo "timezone: некорректный TZ '${tz:-<пусто>}' в $TZ_FILE — пропускаю" >&2
    fi
else
    echo "timezone: $TZ_FILE отсутствует — часовой пояс не меняю"
fi

# --- NTP-сервер: генерим timesyncd.conf из per-site параметра ---
# Первая строка файла (без CR и обрамляющих пробелов); внутренние пробелы —
# несколько серверов через пробел (синтаксис NTP=), поэтому их сохраняем.
ntp=""
if [[ -r "$NTP_FILE" ]]; then
    # read -r с одной переменной: первая строка, обрамляющие пробелы/табы срезаны,
    # внутренние (несколько серверов через пробел) сохранены. Плюс убираем CR.
    read -r ntp < "$NTP_FILE" || true
    ntp="${ntp//$'\r'/}"
fi

if [[ -n "$ntp" ]]; then
    cat > /etc/systemd/timesyncd.conf <<EOF
# Сгенерировано on_start/oneshot/005-time.sh из /home/inauto/staff/ntp-server.
[Time]
NTP=$ntp
FallbackNTP=ntp.ubuntu.com pool.ntp.org
EOF
    echo "ntp server set to: $ntp"
else
    echo "ntp: $NTP_FILE пуст/отсутствует — timesyncd.conf не трогаю (дефолт/fallback)"
fi

# --- Запуск службы NTP (без timedatectl) ---
systemctl enable systemd-timesyncd 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null \
    || echo "WARN: не удалось (пере)запустить systemd-timesyncd" >&2
