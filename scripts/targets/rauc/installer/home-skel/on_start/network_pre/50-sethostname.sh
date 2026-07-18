#!/bin/bash
# network_pre: задаём hostname ДО старта NetworkManager и X.
# - до NM  -> DHCP/DNS регистрируются под правильным именем;
# - до X   -> имя не меняется под живой сессией (иначе ломается авторизация :0
#             и падает автологин).
# Используем /etc/hostname + hostname(1), а НЕ hostnamectl: на этой ранней фазе
# (DefaultDependencies=no) systemd-hostnamed/DBus может быть ещё не поднят.
# Префикс 50 (после 03/10) — чтобы возможный сбой здесь не оборвал раннер до
# сетевых скриптов; NM всё равно стартует после всей фазы network_pre.
set -euo pipefail

# Имя панели пишет установщик в /home/inauto/staff/hostname (install-to-disk.sh).
readonly HOSTNAME_FILE=/home/inauto/staff/hostname

if [[ ! -r "$HOSTNAME_FILE" ]]; then
    echo "WARN: $HOSTNAME_FILE недоступен — hostname не меняю" >&2
    exit 0
fi

# Только первая строка/слово: read -r не склеивает несколько слов в одно имя
# (в отличие от 'tr -d [:space:]'); лишнее уходит во второе поле и отбрасывается.
read -r name _ < "$HOSTNAME_FILE" || true

# Валидируем теми же правилами, что install-to-disk.sh::validate_panel_hostname,
# плюс лимит длины ядра (<=63). Некорректное/пустое имя — НЕ фейлимся (иначе
# раннер оборвёт остаток network_pre), а предупреждаем и выходим 0.
if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || ${#name} -gt 63 ]]; then
    echo "WARN: некорректный hostname '${name:-<пусто>}' в $HOSTNAME_FILE — пропускаю" >&2
    exit 0
fi

echo "$name" > /etc/hostname
hostname "$name"
echo "hostname set to $name"