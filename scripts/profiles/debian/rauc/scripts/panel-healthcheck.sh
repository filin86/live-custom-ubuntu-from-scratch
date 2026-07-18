#!/bin/bash
# Панельный healthcheck перед rauc mark-good (RAUC EFI backend).
#
# Проверяет готовность ключевых сервисов и persistent-маунтов. Если что-то
# не поднялось — возвращает non-zero, и rauc-mark-boot-good.service НЕ вызовет
# `rauc status mark-good booted`. На следующем boot'е UEFI вернёт BootOrder на
# предыдущий slot (EFI BootNext probation).
#
# Переменные окружения:
#   INAUTO_HEALTHCHECK_DELAY   задержка перед проверками (секунды), по умолчанию 60
#
# Site-hook: если в /home/inauto/config/healthcheck.sh есть executable — он
# вызывается дополнительно. Его ненулевой exit также блокирует mark-good.

set -euo pipefail

log()  { echo "[panel-healthcheck] $*"; }
fail() { echo "[panel-healthcheck] FAIL: $*" >&2; exit 1; }

DELAY="${INAUTO_HEALTHCHECK_DELAY:-60}"
if [[ "$DELAY" =~ ^[0-9]+$ ]] && (( DELAY > 0 )); then
    log "ждём ${DELAY}s перед проверками"
    sleep "$DELAY"
fi

# --- systemd units --------------------------------------------------------

REQUIRED_UNITS=(
    lightdm
    docker
    containerd
    x11vnc
    ssh
)

for unit in "${REQUIRED_UNITS[@]}"; do
    if systemctl is-active --quiet "$unit"; then
        log "$unit: active"
    else
        fail "$unit не active"
    fi
done

# --- mountpoints ----------------------------------------------------------

REQUIRED_MOUNTS=(
    /home/inauto
    /var/lib/inauto/container-store
    /var/lib/docker
    /var/lib/containerd
)

for mnt in "${REQUIRED_MOUNTS[@]}"; do
    if mountpoint -q "$mnt"; then
        log "$mnt: mountpoint ok"
    else
        fail "$mnt не mountpoint"
    fi
done

# --- docker info с retry --------------------------------------------------
# docker.service может быть active раньше, чем daemon обрабатывает запросы —
# поэтому явный retry-loop, а не просто один раз.

DOCKER_RETRIES=10
DOCKER_SLEEP=3

for attempt in $(seq 1 "$DOCKER_RETRIES"); do
    if docker info >/dev/null 2>&1; then
        log "docker info: ok (attempt $attempt)"
        break
    fi
    if (( attempt == DOCKER_RETRIES )); then
        fail "docker info не отвечает после $DOCKER_RETRIES попыток"
    fi
    log "docker info не готов, повтор через ${DOCKER_SLEEP}s (attempt $attempt/$DOCKER_RETRIES)"
    sleep "$DOCKER_SLEEP"
done

# --- Site-specific hook ---------------------------------------------------

SITE_HOOK="/home/inauto/config/healthcheck.sh"
if [[ -x "$SITE_HOOK" ]]; then
    log "запускаю site healthcheck: $SITE_HOOK"
    "$SITE_HOOK"
    log "site healthcheck: ok"
fi

log "healthcheck passed"
