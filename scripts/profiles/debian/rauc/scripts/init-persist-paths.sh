#!/bin/sh
# Инициализирует /persist и проецирует persistent paths в overlay-rootfs.
# Запускается из initramfs (local-bottom/panel-boot) после того, как:
#  - /persist примонтирован (ext4, RW);
#  - /lower примонтирован (squashfs rootfs текущего slot'а, RO);
#  - /overlay смонтирован поверх lower+tmpfs.
#
# Аргументы:
#   $1  PERSIST_ROOT (например /run/panel/persist)
#   $2  LOWER_ROOT   (например /run/panel/lower)
#   $3  OVERLAY_ROOT (например /run/panel/overlay)
#
# Список persistent-путей должен совпадать со spec'ом
# (docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md, раздел "Persistent paths").

set -eu

PERSIST_ROOT="${1:?panel-init-persist-paths: PERSIST_ROOT не задан}"
LOWER_ROOT="${2:?panel-init-persist-paths: LOWER_ROOT не задан}"
OVERLAY_ROOT="${3:?panel-init-persist-paths: OVERLAY_ROOT не задан}"
CONSOLE_LOG=0

if [ -r /proc/cmdline ]; then
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            inauto.debug=1|inauto.initramfs_debug=1|debug)
                CONSOLE_LOG=1
                ;;
        esac
    done
fi

log() {
    msg="[panel-init-persist-paths] $*"

    if [ -w /dev/kmsg ]; then
        printf '<6>%s\n' "$msg" > /dev/kmsg 2>/dev/null || true
    fi

    if [ "$CONSOLE_LOG" -eq 1 ]; then
        printf '%s\n' "$msg"
    fi
}

# Маркер "dir" — ожидаем директорию, "file" — файл.
# Формат: "<kind>:<relative-path>".
#
# Директории публикуем в overlay через bind-mount, а файлы — через symlink на
# /run/panel/persist/<path>. File bind-mount'ы из initramfs под parent overlay
# оказались ненадёжны после switch_root; symlink'и на persist переживают boot
# стабильно и при этом не делают /etc/inauto целиком persistent.
PERSIST_ENTRIES="
file:etc/machine-id
file:etc/hostname
dir:etc/ssh
file:etc/NetworkManager/NetworkManager.conf
dir:etc/NetworkManager/system-connections
file:etc/inauto/serial.txt
file:etc/inauto/channel
file:etc/inauto/update-server
file:etc/x11vnc.pass
dir:var/lib/rauc
file:var/lib/systemd/random-seed
"

ensure_dir() { mkdir -p "$1"; }

ensure_file() {
    ensure_dir "$(dirname "$1")"
    [ -e "$1" ] || : > "$1"
}

ensure_absent() {
    path="$1"

    if [ -L "$path" ] || [ -f "$path" ]; then
        rm -f "$path"
    fi
}

init_entry() {
    kind="$1"
    rel="$2"
    persist_path="${PERSIST_ROOT}/${rel}"
    lower_path="${LOWER_ROOT}/${rel}"

    if [ -e "$persist_path" ]; then
        return 0
    fi

    if [ -e "$lower_path" ]; then
        ensure_dir "$(dirname "$persist_path")"
        cp -a "$lower_path" "$persist_path"
        return 0
    fi

    case "$kind" in
        dir)  ensure_dir "$persist_path" ;;
        file) ensure_file "$persist_path" ;;
    esac
}

project_entry() {
    kind="$1"
    rel="$2"
    persist_path="${PERSIST_ROOT}/${rel}"
    overlay_path="${OVERLAY_ROOT}/${rel}"
    runtime_persist_path="/run/panel/persist/${rel}"

    if [ ! -e "$persist_path" ]; then
        return 0
    fi

    case "$kind" in
        dir)
            ensure_dir "$overlay_path"
            mount --bind "$persist_path" "$overlay_path"
            ;;
        file)
            ensure_dir "$(dirname "$overlay_path")"
            ensure_absent "$overlay_path"
            ln -s "$runtime_persist_path" "$overlay_path"
            ;;
    esac
}

parse_and_run() {
    action="$1"
    echo "$PERSIST_ENTRIES" | while IFS= read -r raw; do
        entry="$(echo "$raw" | tr -d '[:space:]')"
        [ -n "$entry" ] || continue
        kind="${entry%%:*}"
        rel="${entry#*:}"
        "$action" "$kind" "$rel"
    done
}

log "init missing persistent entries from $LOWER_ROOT"
parse_and_run init_entry

log "project persistent entries into $OVERLAY_ROOT"
parse_and_run project_entry

log "done"
