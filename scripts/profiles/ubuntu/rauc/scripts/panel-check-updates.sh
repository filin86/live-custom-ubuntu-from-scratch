#!/bin/bash
# Клиентский update-agent: опрашивает update server, при необходимости
# запускает `rauc install` и перезагружается. Отправляет heartbeat.
#
# Запускается panel-check-updates.timer.
#
# Источники конфигурации (persistent, /persist):
#   /etc/inauto/update-server    базовый URL API (без trailing /)
#   /etc/inauto/channel          "candidate" или "stable" (fallback "stable")
#   /etc/inauto/serial.txt       серийник панели (fallback: hostname)
#   /etc/inauto/firmware-version текущая версия (пишется builder'ом)
#   /etc/rauc/system.conf        compatible=... (читается первой строкой)
#
# Контракт сервера:
#   GET  /api/latest?channel=<channel>&compatible=<compatible>
#        -> {"version":"<v>","url":"<bundle_url>","force_downgrade":bool}
#   POST /api/heartbeat  (JSON body: compatible, version, slot|last_error)
#
# Exit codes: 0 — nothing to do / heartbeat sent; ненулевой — ошибка на стадии
# запроса к серверу или rauc install. panel-check-updates.service не failing
# сам по себе не должен помечать boot bad (mark-good уже сработал ранее).

set -euo pipefail

log()  { echo "[panel-check-updates] $*"; }
warn() { echo "[panel-check-updates] WARN: $*" >&2; }
fail() { echo "[panel-check-updates] ERROR: $*" >&2; exit 1; }

VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$'

read_required() {
    local path="$1" name="$2"
    [[ -s "$path" ]] || fail "$name отсутствует или пуст: $path"
    tr -d '[:space:]' < "$path"
}

read_optional() {
    local path="$1" fallback="$2"
    if [[ -s "$path" ]]; then
        tr -d '[:space:]' < "$path"
    else
        printf '%s' "$fallback"
    fi
}

SERVER="$(read_required /etc/inauto/update-server update-server)"
CHANNEL="$(read_optional /etc/inauto/channel stable)"
SERIAL="$(read_optional /etc/inauto/serial.txt "$(hostname)")"
CURRENT="$(read_required /etc/inauto/firmware-version firmware-version)"

COMPATIBLE="$(awk -F= '/^compatible=/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' /etc/rauc/system.conf)"
[[ -n "$COMPATIBLE" ]] || fail "compatible не найден в /etc/rauc/system.conf"

log "panel=$SERIAL compatible=$COMPATIBLE channel=$CHANNEL current=$CURRENT"

# Определяем booted slot (для heartbeat).
BOOTED_SLOT="$(sed -n 's/.*\brauc\.slot=\([^ ]*\).*/\1/p' /proc/cmdline)"
HEARTBEAT_SLOT_ERR=""
if [[ -z "$BOOTED_SLOT" ]]; then
    HEARTBEAT_SLOT_ERR="missing rauc.slot"
fi

# --- latest check --------------------------------------------------------

LATEST_URL="${SERVER%/}/api/latest?channel=${CHANNEL}&compatible=${COMPATIBLE}"
log "GET $LATEST_URL"

LATEST_JSON="$(curl -fsS --max-time 30 \
    -H "X-Panel-Serial: ${SERIAL}" \
    "$LATEST_URL" || true)"

if [[ -z "$LATEST_JSON" ]]; then
    warn "не удалось получить ответ /api/latest; отправлю только heartbeat"
fi

LATEST_VERSION=""
BUNDLE_URL=""
FORCE_DOWNGRADE="false"

if [[ -n "$LATEST_JSON" ]]; then
    LATEST_VERSION="$(jq -r '.version // empty' <<<"$LATEST_JSON")"
    BUNDLE_URL="$(jq -r '.url // empty' <<<"$LATEST_JSON")"
    FORCE_DOWNGRADE="$(jq -r '.force_downgrade // false' <<<"$LATEST_JSON")"
fi

# --- install gate --------------------------------------------------------

version_gt() {
    # true если $1 > $2 в sort -V ordering
    local a="$1" b="$2"
    [[ "$a" == "$b" ]] && return 1
    local top
    top="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)"
    [[ "$top" == "$a" ]]
}

should_install() {
    [[ -n "$LATEST_VERSION" && -n "$BUNDLE_URL" ]] || return 1

    # Обе версии — строго production-формата, иначе отказ.
    if ! [[ "$CURRENT" =~ $VERSION_RE ]]; then
        warn "current='$CURRENT' не соответствует production regex; отказ от обновления"
        return 1
    fi
    if ! [[ "$LATEST_VERSION" =~ $VERSION_RE ]]; then
        warn "latest='$LATEST_VERSION' не соответствует production regex; отказ"
        return 1
    fi

    if version_gt "$LATEST_VERSION" "$CURRENT"; then
        return 0
    fi

    if [[ "$FORCE_DOWNGRADE" == "true" ]]; then
        log "force_downgrade=true: устанавливаем $LATEST_VERSION поверх $CURRENT"
        return 0
    fi

    log "latest=$LATEST_VERSION не новее current=$CURRENT; пропуск"
    return 1
}

# --- heartbeat helpers ---------------------------------------------------
# Объявляем ДО блока install, чтобы не полагаться на bash forward-resolve'
# функций во время execute (его нет — bash читает линейно).

build_heartbeat_body() {
    local last_error="$1"
    if [[ -n "$HEARTBEAT_SLOT_ERR" ]]; then
        last_error="${last_error:+${last_error}; }${HEARTBEAT_SLOT_ERR}"
    fi
    local jq_args=(-nc
        --arg c "$COMPATIBLE"
        --arg v "$CURRENT"
        --arg s "$SERIAL"
    )
    local filter='{compatible:$c, version:$v, serial:$s'
    if [[ -z "$HEARTBEAT_SLOT_ERR" ]]; then
        jq_args+=(--arg slot "$BOOTED_SLOT")
        filter+=', slot:$slot'
    fi
    if [[ -n "$last_error" ]]; then
        jq_args+=(--arg err "$last_error")
        filter+=', last_error:$err'
    fi
    filter+='}'
    jq "${jq_args[@]}" "$filter"
}

# --- install gate (решение принято выше в should_install) ----------------
# При успешном install systemctl reboot'ится сразу — heartbeat не шлём
# (он всё равно уйдёт после reboot'а на следующем timer-tick'е).
# При неудаче install — нормальный heartbeat ниже с last_error.

INSTALL_EXIT=0
if should_install; then
    # RAUC собирается с -Dnetwork=false: передавать HTTP URL напрямую в
    # `rauc install` нельзя. Скачиваем bundle через curl, затем устанавливаем
    # из локального файла.
    BUNDLE_TMP="$(mktemp -t inauto-bundle-XXXXXX.raucb)"
    trap 'rm -f "$BUNDLE_TMP"' EXIT

    log "скачиваю bundle: $BUNDLE_URL"
    if ! curl -fSL --max-time 300 \
            -H "X-Panel-Serial: ${SERIAL}" \
            -o "$BUNDLE_TMP" "$BUNDLE_URL"; then
        INSTALL_EXIT=$?
        warn "curl завершился с кодом $INSTALL_EXIT; отправляю heartbeat с last_error"
    else
        log "rauc install $BUNDLE_TMP"
        if rauc install "$BUNDLE_TMP"; then
            log "rauc install успешен; перезагружаюсь"
            systemctl reboot
            exit 0
        else
            INSTALL_EXIT=$?
            warn "rauc install вернул $INSTALL_EXIT; отправляю heartbeat с last_error"
        fi
    fi
fi

# --- heartbeat -----------------------------------------------------------

LAST_ERROR=""
if (( INSTALL_EXIT != 0 )); then
    LAST_ERROR="rauc install exit=${INSTALL_EXIT}"
fi

HEARTBEAT_BODY="$(build_heartbeat_body "$LAST_ERROR")"

log "POST heartbeat: $HEARTBEAT_BODY"
curl -fsS --max-time 15 \
    -H "X-Panel-Serial: ${SERIAL}" \
    -H "Content-Type: application/json" \
    -d "$HEARTBEAT_BODY" \
    "${SERVER%/}/api/heartbeat" >/dev/null || warn "heartbeat не отправлен"

exit "$INSTALL_EXIT"