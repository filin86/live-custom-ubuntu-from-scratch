#!/bin/bash
# Нормализует права и владельца /home/inauto после засева из home-skel payload'а.
#
# Зачем. /home/inauto собирается из двух источников с разными правами:
#   - install -d в install-to-disk.sh создаёт скелет как root:root;
#   - cp -a поверх кладёт home-skel как есть из репозитория, а там всё
#     принадлежит uid сборщика (1000) с umask 002 (0775/0664).
# Плюс вендорские комплекты (hasplm, MVS, IDMVS) приезжают архивом, который не
# сохраняет unix-права, и после распаковки .sh и бинарники лежат как 0644.
# cp -a честно доносит это до панели, и получаем:
#   - postinst hasplm симлинкает /usr/sbin/aksusbd_x86_64 на неисполняемый файл
#     -> systemd не стартует aksusbd.service (203/EXEC), следом по Requires=
#        падает hasplmd.service и сетевой ключ не поднимается;
#   - setup.sh MVS/IDMVS сыплет "Permission denied" на своих же под-скриптах;
#   - код, который systemd исполняет от root, принадлежит ubuntu -> локальная
#     эскалация до root.
#
# Правим на установке, а не на сборке: права в чекауте чинить бесполезно (git
# хранит только бит +x и никогда — владельца, а distr/ вообще не в git), так что
# нормализация здесь — единственная точка, переживающая свежий клон и CI.

set -euo pipefail

log()  { echo "[normalize-home-perms] $*"; }
warn() { echo "[normalize-home-perms] WARN: $*" >&2; }
fail() { echo "[normalize-home-perms] ERROR: $*" >&2; exit 1; }

# Панельный ubuntu. Числом, а не именем: скрипт исполняется в окружении
# installer-ISO, где имя 'ubuntu' может резолвиться в другой uid, чем на панели.
PANEL_UID="${PANEL_UID:-1000}"
PANEL_GID="${PANEL_GID:-1000}"

# Код — root:root, чтобы ubuntu не мог подменить то, что systemd исполняет от
# root. Данные — ubuntu:ubuntu, чтобы оператор правил site-конфиг без sudo.
#
# inmark (приложение панели) — намеренно в данных, а не в коде: его запускает
# on_login/03 application.sh уже в сессии ubuntu, поэтому root-владение ничего
# не защищало бы, а приложению нужна запись в собственный каталог.
CODE_ENTRIES=(on_start on_login distr)
DATA_ENTRIES=(staff config log inmark)

# Исполняемый ли это payload-файл. Расширение признаком быть НЕ может:
# aksusbd_x86_64 и save_virnic_settings — бинарники без расширения. Считаем:
#   - файл с shebang ('#!');
#   - ELF с сегментом INTERP — так опознаются и обычные, и PIE-бинарники
#     (PIE в ELF-заголовке неотличим от .so по e_type).
# Библиотеки .so и модули ядра .ko INTERP не имеют и +x не получают.
#
# ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: статически слинкованный бинарник (gcc -static, Go)
# тоже не имеет INTERP и этим тестом неотличим от .so — он молча не получит +x
# и воспроизведёт ровно тот же 203/EXEC. В текущем payload таких нет (проверено
# на всех ELF в distr/), а усиление эвристики стоило бы ложных срабатываний на
# библиотеках. Если вендор пришлёт статический бинарник — правится добавлением
# явного пути в отдельный список, а не ослаблением проверки.
is_executable_payload() {
    local file="$1"
    local magic=""

    # Первые 4 байта без fork'а; LC_ALL=C — чтобы read -N считал байты.
    LC_ALL=C IFS= read -r -N 4 magic < "$file" 2>/dev/null || true

    case "$magic" in
        '#!'*)
            return 0
            ;;
    esac

    if [[ "$magic" != $'\x7fELF' ]]; then
        return 1
    fi

    # Ищем INTERP по имени типа program header'а: оно не переводится.
    # Человекочитаемое "[Requesting program interpreter: ...]" искать НЕЛЬЗЯ —
    # вывод readelf локализуется, а installer живёт под ru_RU.UTF-8, где этой
    # строки нет; grep по ней молча не находил бы ни одного бинарника.
    LC_ALL=C readelf -l -- "$file" 2>/dev/null \
        | grep -qE '^[[:space:]]*INTERP[[:space:]]'
}

normalize_exec_bits() {
    local root="$1"
    local marked=0
    local file

    while IFS= read -r -d '' file; do
        # Уже исполняемый — не трогаем: скрипт переживает повторный запуск.
        if [[ -x "$file" ]]; then
            continue
        fi

        if ! is_executable_payload "$file"; then
            continue
        fi

        chmod a+x "$file"
        marked=$((marked + 1))
    done < <(find "$root" -type f -print0)

    log "проставлен +x: $marked файл(ов)"
}

normalize_ownership() {
    local root="$1"
    local entry path

    chown "0:0" "$root"
    chmod 0755 "$root"

    for entry in "${CODE_ENTRIES[@]}"; do
        path="$root/$entry"
        [[ -e "$path" ]] || continue
        chown -R "0:0" "$path"
        # Снимаем групповую/чужую запись (в репозитории umask 002 -> 0775/0664),
        # но не трогаем биты исполнения, выставленные выше.
        chmod -R go-w "$path"
        log "код    root:root            $entry"
    done

    for entry in "${DATA_ENTRIES[@]}"; do
        path="$root/$entry"
        [[ -e "$path" ]] || continue
        chown -R "$PANEL_UID:$PANEL_GID" "$path"
        log "данные $PANEL_UID:$PANEL_GID  $entry"
    done

    # Лок-файл принадлежит root: это маркер, а не пользовательские данные.
    if [[ -e "$root/.inautolock" ]]; then
        chown "0:0" "$root/.inautolock"
        chmod 0644 "$root/.inautolock"
    fi

    # Всё, что не попало ни в один список, остаётся с владельцем из cp -a
    # (uid сборщика). Молчать об этом нельзя: новый каталог с кодом иначе
    # тихо приедет на панель принадлежащим ubuntu.
    local known=" ${CODE_ENTRIES[*]} ${DATA_ENTRIES[*]} "
    while IFS= read -r -d '' path; do
        entry="$(basename "$path")"
        if [[ "$entry" == ".inautolock" ]]; then
            continue
        fi
        if [[ "$known" != *" $entry "* ]]; then
            warn "'$entry' не в списках CODE_ENTRIES/DATA_ENTRIES — владелец не нормализован."
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
}

main() {
    local root="${1:-}"

    [[ -n "$root" ]] || fail "usage: normalize-home-perms.sh <inauto-root>"
    [[ -d "$root" ]] || fail "каталог не найден: $root"
    command -v readelf >/dev/null 2>&1 || fail "не найден readelf (пакет binutils)."

    log "нормализую $root"
    normalize_exec_bits "$root"
    normalize_ownership "$root"
    log "готово"
}

main "$@"