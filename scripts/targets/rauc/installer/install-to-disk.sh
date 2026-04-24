#!/bin/bash
# Factory-installer для immutable panel firmware (TARGET_PLATFORM=pc-efi).
#
# Запускается из USB installer-окружения с правами root. Требует UEFI runtime.
#
# Последовательность (согласно спеку, разделу "Factory provisioning"):
#  1. Проверить UEFI runtime и права root.
#  2. Выбрать target disk (TARGET_DEVICE или auto-detect non-removable >= 32 GiB).
#  3. Запустить pc-efi.sgdisk для GPT разметки.
#  4. Raw-write efi.vfat в efi_A и efi_B, rootfs.img в rootfs_A и rootfs_B
#     (без двух последовательных `rauc install` — при factory provisioning
#     оба slot-group'а заполняются напрямую).
#  5. Зарегистрировать UEFI boot entries system0/system1 через efibootmgr.
#  6. Установить BootOrder=system0,system1.
#  7. Инициализировать /persist и /home/inauto skeletons, затем (если есть)
#     восстановить backup прямо в inauto-data.
#  8. Reboot.
#
# Формат payload (рядом со скриптом в /opt/inauto-installer/):
#   bundle.raucb                     — подписанный RAUC bundle (ЕДИНСТВЕННЫЙ
#                                       источник raw-байт для efi_A/B и
#                                       rootfs_A/B: installer verify'ит
#                                       подпись и через `rauc mount`
#                                       получает efi.vfat + rootfs.img
#                                       перед dd).
#   keyring.pem                      — RAUC keyring для verify подписи
#   pc-efi.sgdisk                    — скрипт GPT разметки
#   install-to-disk.sh               — этот скрипт
#   backup-restore-home.sh           — helper для миграции /home/inauto
#   firmware-version                 — текстовая версия из bundle'а
#
# Управляющие env-переменные:
#   TARGET_DEVICE          явный путь к диску (/dev/sda, /dev/nvme0n1)
#   CONTAINER_STORE_SIZE   переопределение auto-size (передаётся pc-efi.sgdisk)
#   INSTALLER_PAYLOAD_DIR  путь к /opt/inauto-installer (по умолчанию рядом со скриптом)
#   SKIP_BACKUP            "1" — полностью пропустить backup/restore /home/inauto
#   FORCE_YES              "1" — не спрашивать подтверждение перед стиранием диска
#   DRY_RUN                "1" — не писать на диск, только показать команды (debug)
#   PANEL_HOSTNAME         логическое имя панели; пишется в /home/inauto/staff/hostname
#   UPDATE_CHANNEL         update-channel панели (stable/candidate)
#   UPDATE_SERVER          URL update-server, например http://172.16.88.80:9001

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${INSTALLER_PAYLOAD_DIR:-$SCRIPT_DIR}"

log()  { echo "[installer] $*"; }
warn() { echo "[installer] WARN: $*" >&2; }
fail() { echo "[installer] ERROR: $*" >&2; exit 1; }

is_dry_run() {
    [[ "${DRY_RUN:-0}" == "1" ]]
}

run() {
    if is_dry_run; then
        log "DRY-RUN: $*"
    else
        "$@"
    fi
}

trim_ws() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

validate_panel_hostname() {
    local hostname="$1"
    [[ "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

normalize_update_channel() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_update_channel() {
    local channel="$1"
    case "$channel" in
        stable|candidate) return 0 ;;
        *) return 1 ;;
    esac
}

validate_update_server() {
    local server="$1"
    [[ "$server" =~ ^https?://[^[:space:]]+$ ]]
}

prompt_value() {
    local label="$1"
    local current="$2"
    local answer

    [[ -t 0 ]] || fail "$label не задан и stdin не интерактивен. Передайте env-переменную."

    if [[ -n "$current" ]]; then
        read -r -p "[installer] $label [$current]: " answer || true
        printf '%s\n' "${answer:-$current}"
    else
        read -r -p "[installer] $label: " answer || true
        printf '%s\n' "$answer"
    fi
}

prompt_update_channel() {
    local current="$1"
    local answer

    [[ -t 0 ]] || fail "Update channel не задан и stdin не интерактивен. Передайте env-переменную."

    current="$(normalize_update_channel "${current:-stable}")"

    while true; do
        read -r -p "[installer] Update channel (stable/candidate) [$current]: " answer || true
        answer="$(trim_ws "${answer:-$current}")"
        answer="$(normalize_update_channel "$answer")"

        if validate_update_channel "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi

        warn "update-channel должен быть stable или candidate."
    done
}

serial_suffix_from_machine_id() {
    local machine_id_file="$1"
    local machine_id

    machine_id="$(tr -d '[:space:]' < "$machine_id_file" | tr '[:upper:]' '[:lower:]')"
    if [[ "$machine_id" =~ ^[0-9a-f]{32}$ ]]; then
        printf '%s-%s-%s-%s-%s\n' \
            "${machine_id:0:8}" "${machine_id:8:4}" "${machine_id:12:4}" \
            "${machine_id:16:4}" "${machine_id:20:12}"
    else
        uuidgen | tr '[:upper:]' '[:lower:]'
    fi
}

serial_prefix_from_hostname() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

collect_panel_settings() {
    PANEL_HOSTNAME="$(trim_ws "${PANEL_HOSTNAME:-}")"
    UPDATE_CHANNEL="$(normalize_update_channel "$(trim_ws "${UPDATE_CHANNEL:-}")")"
    UPDATE_SERVER="$(trim_ws "${UPDATE_SERVER:-}")"

    while [[ -z "$PANEL_HOSTNAME" ]] || ! validate_panel_hostname "$PANEL_HOSTNAME"; do
        [[ -n "$PANEL_HOSTNAME" ]] && warn "hostname панели должен содержать только латиницу, цифры, '.', '_' или '-'."
        PANEL_HOSTNAME="$(trim_ws "$(prompt_value "Hostname панели" "$PANEL_HOSTNAME")")"
    done

    while [[ -z "$UPDATE_CHANNEL" ]] || ! validate_update_channel "$UPDATE_CHANNEL"; do
        [[ -n "$UPDATE_CHANNEL" ]] && warn "update-channel должен быть stable или candidate."
        UPDATE_CHANNEL="$(prompt_update_channel "${UPDATE_CHANNEL:-stable}")"
    done

    while [[ -z "$UPDATE_SERVER" ]] || ! validate_update_server "$UPDATE_SERVER"; do
        [[ -n "$UPDATE_SERVER" ]] && warn "адрес update-server должен начинаться с http:// или https://"
        UPDATE_SERVER="$(trim_ws "$(prompt_value "Update server" "$UPDATE_SERVER")")"
    done

    export PANEL_HOSTNAME UPDATE_CHANNEL UPDATE_SERVER
    log "hostname панели: $PANEL_HOSTNAME"
    log "update channel: $UPDATE_CHANNEL"
    log "update server: $UPDATE_SERVER"
}

# --- 1. Runtime checks ----------------------------------------------------

(( EUID == 0 )) || fail "запускать от root."

[[ -d /sys/firmware/efi ]] \
    || fail "не UEFI runtime: /sys/firmware/efi отсутствует (pc-efi поддерживается только на UEFI PC)."

for tool in sgdisk blockdev partprobe udevadm efibootmgr dd lsblk jq findmnt mkfs.ext4 mkfs.vfat ssh-keygen uuidgen mountpoint rauc unsquashfs blkid mount umount; do
    command -v "$tool" >/dev/null 2>&1 || fail "не найден инструмент '$tool'."
done

# --- 2. Выбор target disk -------------------------------------------------

GIB=$((1024 * 1024 * 1024))
MIN_DISK_GIB=32

select_target_device() {
    if [[ -n "${TARGET_DEVICE:-}" ]]; then
        [[ -b "$TARGET_DEVICE" ]] || fail "TARGET_DEVICE='$TARGET_DEVICE' не block device."
        printf '%s\n' "$TARGET_DEVICE"
        return
    fi

    local candidates=()
    local disk rotational removable size name

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        disk="/dev/$name"
        [[ -b "$disk" ]] || continue
        removable="$(cat "/sys/block/$name/removable" 2>/dev/null || echo 1)"
        [[ "$removable" == "0" ]] || continue
        size="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
        (( size >= MIN_DISK_GIB * GIB )) || continue
        candidates+=("$disk")
    done < <(lsblk -dn -o NAME -e 7,11)

    if (( ${#candidates[@]} == 0 )); then
        fail "не найден non-removable диск >= ${MIN_DISK_GIB} GiB; укажите TARGET_DEVICE вручную."
    fi

    if (( ${#candidates[@]} > 1 )); then
        log "найдено несколько кандидатов: ${candidates[*]}"
        fail "несколько подходящих дисков. Укажите TARGET_DEVICE явно."
    fi

    printf '%s\n' "${candidates[0]}"
}

TARGET_DEVICE="$(select_target_device)"
TARGET_DEVICE="$(readlink -f "$TARGET_DEVICE")"
log "target disk: $TARGET_DEVICE ($(blockdev --getsize64 "$TARGET_DEVICE") байт)"

collect_panel_settings

confirm_destructive_target() {
    local target="$1"
    local size_bytes
    local details
    local confirm

    if is_dry_run; then
        log "DRY-RUN: подтверждение стирания $target пропущено"
        return 0
    fi

    if [[ "${FORCE_YES:-0}" == "1" ]]; then
        warn "FORCE_YES=1 — подтверждение стирания $target пропущено"
        return 0
    fi

    size_bytes="$(blockdev --getsize64 "$target" 2>/dev/null || printf 'unknown')"
    details="$(lsblk -dpno NAME,SIZE,MODEL,SERIAL,TRAN "$target" 2>/dev/null || printf '%s' "$target")"

    log "ВНИМАНИЕ: $target ($size_bytes байт) будет ПОЛНОСТЬЮ ПЕРЕЗАПИСАН."
    log "Детали диска: $details"
    if ! read -r -p "[installer] Продолжить? Введите 'yes': " confirm; then
        fail "не удалось прочитать подтверждение; для автоматического запуска задайте FORCE_YES=1."
    fi
    [[ "$confirm" == "yes" ]] || {
        log "Прерывание по запросу пользователя."
        exit 1
    }
}

confirm_destructive_target "$TARGET_DEVICE"

partition_path_by_label() {
    local label="$1"
    lsblk -rno PATH,PARTLABEL "$TARGET_DEVICE" \
        | awk -v label="$label" '$2 == label { print $1; exit }'
}

partition_number_by_label() {
    case "$1" in
        efi_A) printf '1\n' ;;
        efi_B) printf '2\n' ;;
        rootfs_A) printf '3\n' ;;
        rootfs_B) printf '4\n' ;;
        persist) printf '5\n' ;;
        container-store) printf '6\n' ;;
        inauto-data) printf '7\n' ;;
        *) return 1 ;;
    esac
}

dry_run_partition_path() {
    local label="$1"
    local part_num
    part_num="$(partition_number_by_label "$label")" \
        || fail "unknown pc-efi partition label '$label' in dry-run"

    if [[ "$TARGET_DEVICE" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$TARGET_DEVICE" "$part_num"
    else
        printf '%s%s\n' "$TARGET_DEVICE" "$part_num"
    fi
}

require_partition() {
    local label="$1"
    local path
    path="$(partition_path_by_label "$label")"
    if [[ -z "$path" || ! -b "$path" ]]; then
        if is_dry_run; then
            dry_run_partition_path "$label"
            return 0
        fi
        fail "не найден раздел '$label' на выбранном диске $TARGET_DEVICE"
    fi
    printf '%s\n' "$path"
}

# --- 2.5. Backup существующего /home/inauto -------------------------------
# Запускается ДО разметки target disk'а, чтобы успеть сохранить данные
# существующей mutable-панели (если установка делается как миграция).
# Helper ищет .inautolock на fixed (non-removable) устройствах;
# TARGET_DEVICE при этом НЕ исключается — типичный single-disk reinstall
# хранит /home/inauto ровно на перезаписываемом диске. Removable-носители
# (USB stick, SD) отфильтровываются через /sys/block/<name>/removable.
# tarball живёт в BACKUP_DIR (по умолчанию tmpfs /tmp).

BACKUP_SCRIPT="$PAYLOAD_DIR/backup-restore-home.sh"
BACKUP_DIR="${BACKUP_DIR:-/tmp/inauto-backup}"
export BACKUP_DIR

if [[ "${SKIP_BACKUP:-0}" == "1" ]]; then
    warn "SKIP_BACKUP=1 — backup/restore старого /home/inauto полностью пропущен"
elif [[ -x "$BACKUP_SCRIPT" ]]; then
    log "попытка сохранить существующий /home/inauto (см. $BACKUP_DIR)"
    # Fail-by-default: helper успешно завершается, когда либо (а) backup
    # создан, либо (б) /home/inauto не найден (фабрично-новая панель).
    # Любой иной non-zero (полный BACKUP_DIR, tar/zstd error, повреждённая
    # ФС) означает, что данные НЕ сохранены, а install ниже их сотрёт.
    # Поэтому ненулевой exit => остановка, если оператор не подтвердил
    # осознанное продолжение через ALLOW_NO_BACKUP=1.
    if ! TARGET_DEVICE="$TARGET_DEVICE" "$BACKUP_SCRIPT" backup; then
        if [[ "${ALLOW_NO_BACKUP:-0}" == "1" ]]; then
            warn "backup не выполнен, но ALLOW_NO_BACKUP=1 — продолжаю (данные будут ПОТЕРЯНЫ)"
        else
            fail "backup существующего /home/inauto не выполнен. Варианты:
  1. Задайте BACKUP_DIR=/media/<external-usb>/inauto-backup с достаточным местом и перезапустите.
  2. Если это фабрично-новая панель и backup осознанно не нужен, передайте ALLOW_NO_BACKUP=1."
        fi
    fi
elif [[ "${ALLOW_NO_BACKUP:-0}" == "1" ]]; then
    warn "$BACKUP_SCRIPT отсутствует, ALLOW_NO_BACKUP=1 — продолжаю без backup helper'а"
else
    fail "$BACKUP_SCRIPT отсутствует или не executable — payload повреждён.
Варианты:
  1. Перегенерировать installer payload и перепрошить USB.
  2. Если известно, что backup не нужен (свежая панель), передайте ALLOW_NO_BACKUP=1."
fi

# --- 3. Payload ------------------------------------------------------------

BUNDLE="$PAYLOAD_DIR/bundle.raucb"
KEYRING="$PAYLOAD_DIR/keyring.pem"
SGDISK_SCRIPT="$PAYLOAD_DIR/pc-efi.sgdisk"
FIRMWARE_VERSION_FILE="$PAYLOAD_DIR/firmware-version"
TARGET_COMPATIBLE_FILE="$PAYLOAD_DIR/target-compatible"
RAUC_INSTALLER_CONF="$(mktemp -t inauto-rauc-installer-XXXXXX.conf)"
BUNDLE_INFO_FILE="$(mktemp -t inauto-rauc-info-XXXXXX.env)"
RAUC_DATA_DIR="$(mktemp -d -t inauto-rauc-state-XXXXXX)"
BUNDLE_EXTRACT_DIR=""
RAUC_MOUNT_PREFIX=""
BUNDLE_MOUNT_DIR=""

cleanup() {
    if [[ -n "$BUNDLE_MOUNT_DIR" ]] && mountpoint -q "$BUNDLE_MOUNT_DIR"; then
        umount "$BUNDLE_MOUNT_DIR" 2>/dev/null || true
    fi
    rm -rf "$BUNDLE_EXTRACT_DIR" "$RAUC_MOUNT_PREFIX" "$RAUC_INSTALLER_CONF" "$BUNDLE_INFO_FILE" "$RAUC_DATA_DIR"
}

trap cleanup EXIT

for f in "$BUNDLE" "$KEYRING" "$SGDISK_SCRIPT" "$TARGET_COMPATIBLE_FILE"; do
    [[ -f "$f" ]] || fail "отсутствует payload artefact: $f"
done

: > "$RAUC_DATA_DIR/central.raucs"

cat > "$RAUC_INSTALLER_CONF" <<EOF_RAUC_CONF
[system]
compatible=inauto-panel-installer
bootloader=noop
bundle-formats=-plain
data-directory=$RAUC_DATA_DIR

[keyring]
path=$KEYRING
EOF_RAUC_CONF

# Verify подпись bundle'а. Если keyring не доверяет signing cert'у bundle'а —
# fail до того, как мы что-то напишем на диск.
log "проверяю подпись bundle'а: $BUNDLE (keyring=$KEYRING)"
rauc info --conf="$RAUC_INSTALLER_CONF" --keyring="$KEYRING" \
    --output-format=shell "$BUNDLE" > "$BUNDLE_INFO_FILE" \
    || fail "подпись $BUNDLE не верифицируется через $KEYRING — аварийно прерываюсь"

parse_rauc_shell_value() {
    local key="$1"
    local file="$2"
    sed -n "s/^${key}='\\([^']*\\)'$/\\1/p" "$file" | head -n1
}

EXPECTED_COMPATIBLE="$(tr -d '[:space:]' < "$TARGET_COMPATIBLE_FILE")"
BUNDLE_COMPATIBLE="$(parse_rauc_shell_value RAUC_MF_COMPATIBLE "$BUNDLE_INFO_FILE")"
[[ -n "$BUNDLE_COMPATIBLE" ]] || fail "не удалось прочитать RAUC_MF_COMPATIBLE из $BUNDLE"

if [[ "$BUNDLE_COMPATIBLE" != "$EXPECTED_COMPATIBLE" ]]; then
    fail "bundle compatible='$BUNDLE_COMPATIBLE' не совпадает с ожидаемым '$EXPECTED_COMPATIBLE'"
fi
log "bundle compatible OK: $BUNDLE_COMPATIBLE"

# Извлекаем payload (efi.vfat + rootfs.img) из signed bundle в tmpdir.
# Для verity bundle `rauc extract` требует exclusive access к файлу bundle'а
# во время userspace payload-check. Для bundle'а, лежащего на /cdrom live ISO,
# это ломается. `rauc mount` идёт по install-like пути (loop + verity) и
# корректно работает с bundle'ом на смонтированном носителе.
extract_bundle_images() {
    local bundle="$1"
    local out_dir="$2"

    RAUC_MOUNT_PREFIX="$(mktemp -d -t inauto-rauc-mount-XXXXXX)"
    BUNDLE_MOUNT_DIR="$RAUC_MOUNT_PREFIX/bundle"

    log "монтирую signed bundle → $BUNDLE_MOUNT_DIR"
    rauc mount --conf="$RAUC_INSTALLER_CONF" --keyring="$KEYRING" \
        --mount "$RAUC_MOUNT_PREFIX" "$bundle" \
        || fail "не удалось смонтировать bundle через rauc mount"

    [[ -d "$BUNDLE_MOUNT_DIR" ]] \
        || fail "rauc mount не создал ожидаемый mountpoint: $BUNDLE_MOUNT_DIR"

    cp -f "$BUNDLE_MOUNT_DIR/efi.vfat" "$out_dir/efi.vfat" \
        || fail "не удалось скопировать efi.vfat из mounted bundle"
    cp -f "$BUNDLE_MOUNT_DIR/rootfs.img" "$out_dir/rootfs.img" \
        || fail "не удалось скопировать rootfs.img из mounted bundle"

    umount "$BUNDLE_MOUNT_DIR" \
        || fail "не удалось размонтировать mounted bundle: $BUNDLE_MOUNT_DIR"
    rmdir "$BUNDLE_MOUNT_DIR" 2>/dev/null || true
    rmdir "$RAUC_MOUNT_PREFIX" 2>/dev/null || true
    BUNDLE_MOUNT_DIR=""
    RAUC_MOUNT_PREFIX=""
}

BUNDLE_EXTRACT_DIR="$(mktemp -d -t inauto-bundle-XXXXXX)"
log "извлекаю images из signed bundle → $BUNDLE_EXTRACT_DIR"
extract_bundle_images "$BUNDLE" "$BUNDLE_EXTRACT_DIR"

EFI_IMG="$BUNDLE_EXTRACT_DIR/efi.vfat"
ROOTFS_IMG="$BUNDLE_EXTRACT_DIR/rootfs.img"

for f in "$EFI_IMG" "$ROOTFS_IMG"; do
    [[ -f "$f" ]] || fail "bundle не содержит ожидаемого image: $f"
done

if [[ -f "$FIRMWARE_VERSION_FILE" ]]; then
    FIRMWARE_VERSION="$(tr -d '[:space:]' < "$FIRMWARE_VERSION_FILE")"
else
    FIRMWARE_VERSION="unknown"
fi

log "firmware version: $FIRMWARE_VERSION"

# --- 4. GPT layout + форматирование ---------------------------------------

log "создаю GPT разметку ($SGDISK_SCRIPT)"
run env TARGET_DEVICE="$TARGET_DEVICE" bash "$SGDISK_SCRIPT"

# pc-efi.sgdisk уже форматирует vfat/ext4 — нам остаётся писать rootfs.

EFI_A_DEV="$(require_partition efi_A)"
EFI_B_DEV="$(require_partition efi_B)"
ROOTFS_A_DEV="$(require_partition rootfs_A)"
ROOTFS_B_DEV="$(require_partition rootfs_B)"
PERSIST_DEV="$(require_partition persist)"
INAUTO_DATA_DEV="$(require_partition inauto-data)"

# --- 5. Raw-write efi + rootfs в оба slot-group ---------------------------

write_image_raw() {
    local src="$1"
    local dst="$2"
    local bs="${3:-4M}"
    log "dd $src -> $dst (bs=$bs)"
    run dd if="$src" of="$dst" bs="$bs" conv=fsync,notrunc status=progress
}

log "заливаю efi_A/efi_B из $EFI_IMG"
# После mkfs.vfat в pc-efi.sgdisk на efi_A/efi_B уже лежит пустой FAT32.
# Raw dd затирает пустой FAT32 нашим образом EFI-stub kernel + initrd.
write_image_raw "$EFI_IMG"    "$EFI_A_DEV"
write_image_raw "$EFI_IMG"    "$EFI_B_DEV"

log "заливаю rootfs_A/rootfs_B из $ROOTFS_IMG"
write_image_raw "$ROOTFS_IMG" "$ROOTFS_A_DEV"
write_image_raw "$ROOTFS_IMG" "$ROOTFS_B_DEV"

run sync
run partprobe "$TARGET_DEVICE" || true
run udevadm settle --timeout=10 || true

validate_efi_slot() {
    local label="$1"
    local device
    local mnt

    device="$(require_partition "$label")"

    is_dry_run && return 0

    mnt="$(mktemp -d)"
    if ! mount -o ro "$device" "$mnt"; then
        rmdir "$mnt" 2>/dev/null || true
        fail "не удалось смонтировать $label после записи EFI image"
    fi

    if [[ ! -s "$mnt/EFI/BOOT/BOOTX64.EFI" ]]; then
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
        fail "$label не содержит EFI loader: \\EFI\\BOOT\\BOOTX64.EFI"
    fi

    if [[ ! -s "$mnt/EFI/Linux/initrd.img" ]]; then
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
        fail "$label не содержит initrd: \\EFI\\Linux\\initrd.img"
    fi

    umount "$mnt"
    rmdir "$mnt"
}

validate_rootfs_slot() {
    local label="$1"
    local device
    local fs_type

    device="$(require_partition "$label")"

    is_dry_run && return 0

    fs_type="$(blkid -o value -s TYPE "$device" 2>/dev/null || true)"
    [[ "$fs_type" == "squashfs" ]] \
        || fail "$label после записи не определяется как squashfs (blkid TYPE='${fs_type:-<empty>}')"
}

log "проверяю записанные boot/rootfs slot'ы"
validate_efi_slot efi_A
validate_efi_slot efi_B
validate_rootfs_slot rootfs_A
validate_rootfs_slot rootfs_B

# --- 6. UEFI boot entries --------------------------------------------------

# Вычисляем номер партиции efi_A/efi_B относительно выбранного диска.
part_number_for_device() {
    local part="$1"
    local label="${2:-}"
    local part_num

    if is_dry_run; then
        [[ -n "$label" ]] || return 1
        partition_number_by_label "$label"
        return
    fi

    part_num="$(lsblk -dn -o PARTN "$part" | tr -d '[:space:]' || true)"
    if [[ -n "$part_num" ]]; then
        printf '%s\n' "$part_num"
        return 0
    fi
    # /dev/sda3 -> 3; /dev/nvme0n1p3 -> 3; /dev/mmcblk0p3 -> 3
    part_num="$(echo "$part" | sed -E 's#.*[^0-9]([0-9]+)$#\1#')"
    [[ "$part_num" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$part_num"
}

partuuid_for_device() {
    local part="$1"
    local label="${2:-}"
    local partuuid

    if is_dry_run; then
        [[ -n "$label" ]] || return 1
        printf 'DRYRUN-PARTUUID-%s\n' "$label"
        return 0
    fi

    partuuid="$(blkid -s PARTUUID -o value "$part" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$partuuid" ]] || return 1
    printf '%s\n' "$partuuid"
}

EFI_A_PART="$(part_number_for_device "$EFI_A_DEV" efi_A)" || fail "не удалось определить partition # для efi_A"
EFI_B_PART="$(part_number_for_device "$EFI_B_DEV" efi_B)" || fail "не удалось определить partition # для efi_B"
ROOTFS_A_PARTUUID="$(partuuid_for_device "$ROOTFS_A_DEV" rootfs_A)" || fail "не удалось определить PARTUUID для rootfs_A"
ROOTFS_B_PARTUUID="$(partuuid_for_device "$ROOTFS_B_DEV" rootfs_B)" || fail "не удалось определить PARTUUID для rootfs_B"

log "регистрирую UEFI boot entries на $TARGET_DEVICE (efi_A=$EFI_A_PART, efi_B=$EFI_B_PART)"

# Удалим прежние system0/system1 если остались (idempotent re-install).
remove_existing_entry() {
    local label="$1"
    local existing

    if is_dry_run; then
        log "DRY-RUN: пропускаю чтение/удаление существующих UEFI entries для $label"
        return 0
    fi

    existing="$(efibootmgr -v 2>/dev/null | awk -v lbl="$label" '$0 ~ lbl { sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1 }' || true)"
    for bootnum in $existing; do
        log "удаляю старую запись Boot$bootnum ($label)"
        run efibootmgr --bootnum "$bootnum" --delete-bootnum || true
    done
}

remove_existing_entry "system0"
remove_existing_entry "system1"

LOADER_PATH='\EFI\BOOT\BOOTX64.EFI'
# EFI stub должен получить cmdline, с которым kernel может смонтировать
# squashfs root даже если initramfs не поднялся. Поэтому root= задаём через
# PARTUUID, а не через /dev/disk/by-partlabel/* (такие symlink'и доступны
# только после userspace/udev).
CMDLINE_A="initrd=\\EFI\\Linux\\initrd.img rauc.slot=system0 root=PARTUUID=${ROOTFS_A_PARTUUID} rootfstype=squashfs ro quiet panic=30"
CMDLINE_B="initrd=\\EFI\\Linux\\initrd.img rauc.slot=system1 root=PARTUUID=${ROOTFS_B_PARTUUID} rootfstype=squashfs ro quiet panic=30"

run efibootmgr \
    --create \
    --disk "$TARGET_DEVICE" \
    --part "$EFI_A_PART" \
    --label "system0" \
    --loader "$LOADER_PATH" \
    --unicode "$CMDLINE_A"

run efibootmgr \
    --create \
    --disk "$TARGET_DEVICE" \
    --part "$EFI_B_PART" \
    --label "system1" \
    --loader "$LOADER_PATH" \
    --unicode "$CMDLINE_B"

# Вытащим bootnum'ы new'ых entries для установки BootOrder.
get_bootnum() {
    local label="$1"
    if is_dry_run; then
        case "$label" in
            system0) printf '0000\n' ;;
            system1) printf '0001\n' ;;
            *) return 1 ;;
        esac
        return
    fi

    efibootmgr -v 2>/dev/null | awk -v lbl="$label" '$0 ~ lbl { sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1; exit }'
}

BOOTNUM_A="$(get_bootnum system0)"
BOOTNUM_B="$(get_bootnum system1)"

[[ -n "$BOOTNUM_A" && -n "$BOOTNUM_B" ]] \
    || fail "не удалось вычислить bootnum'ы после efibootmgr --create."

log "устанавливаю BootOrder=$BOOTNUM_A,$BOOTNUM_B"
run efibootmgr --bootorder "$BOOTNUM_A,$BOOTNUM_B"

# --- 7. Инициализация persist и inauto-data -------------------------------

# persist: machine-id, ssh host keys, x11vnc.pass placeholder, /etc/inauto/*
PERSIST_MNT="$(mktemp -d)"
run mount "$PERSIST_DEV" "$PERSIST_MNT"

init_persist_skeleton() {
    local serial_suffix serial_prefix panel_serial

    install -d -m 0755 "$PERSIST_MNT/etc" "$PERSIST_MNT/etc/ssh" \
        "$PERSIST_MNT/etc/NetworkManager" \
        "$PERSIST_MNT/etc/NetworkManager/system-connections" \
        "$PERSIST_MNT/etc/inauto" \
        "$PERSIST_MNT/var/lib/rauc" \
        "$PERSIST_MNT/var/lib/systemd"

    chmod 0700 "$PERSIST_MNT/etc/NetworkManager/system-connections"

    # machine-id
    if [[ ! -s "$PERSIST_MNT/etc/machine-id" ]]; then
        uuidgen | tr -d '-' > "$PERSIST_MNT/etc/machine-id"
        chmod 0444 "$PERSIST_MNT/etc/machine-id"
    fi

    # hostname
    if [[ ! -s "$PERSIST_MNT/etc/hostname" ]]; then
        echo "inauto-panel" > "$PERSIST_MNT/etc/hostname"
    fi

    # SSH host keys (rsa/ecdsa/ed25519)
    for kt in rsa ecdsa ed25519; do
        local key="$PERSIST_MNT/etc/ssh/ssh_host_${kt}_key"
        if [[ ! -s "$key" ]]; then
            ssh-keygen -q -t "$kt" -N "" -f "$key"
            chmod 0600 "$key"
            chmod 0644 "${key}.pub"
        fi
    done

    # /etc/inauto placeholders
    for f in serial.txt channel update-server; do
        local p="$PERSIST_MNT/etc/inauto/$f"
        [[ -e "$p" ]] || : > "$p"
    done

    serial_suffix="$(serial_suffix_from_machine_id "$PERSIST_MNT/etc/machine-id")"
    serial_prefix="$(serial_prefix_from_hostname "$PANEL_HOSTNAME")"
    panel_serial="${serial_prefix}-${serial_suffix}"

    printf '%s\n' "$panel_serial" > "$PERSIST_MNT/etc/inauto/serial.txt"
    printf '%s\n' "$UPDATE_CHANNEL" > "$PERSIST_MNT/etc/inauto/channel"
    printf '%s\n' "$UPDATE_SERVER" > "$PERSIST_MNT/etc/inauto/update-server"
    chmod 0644 \
        "$PERSIST_MNT/etc/inauto/serial.txt" \
        "$PERSIST_MNT/etc/inauto/channel" \
        "$PERSIST_MNT/etc/inauto/update-server"
    log "persist metadata: serial=$panel_serial channel=$UPDATE_CHANNEL update-server=$UPDATE_SERVER"

    # x11vnc.pass placeholder (0600), пустой — настраивается отдельно
    local vnc="$PERSIST_MNT/etc/x11vnc.pass"
    if [[ ! -e "$vnc" ]]; then
        : > "$vnc"
        chmod 0600 "$vnc"
    fi
}

if is_dry_run; then
    log "DRY-RUN: пропускаю инициализацию persist skeleton в $PERSIST_MNT"
else
    init_persist_skeleton
fi

run umount "$PERSIST_MNT"
rmdir "$PERSIST_MNT"

# inauto-data: скелет home/inauto с site hooks
INAUTO_MNT="$(mktemp -d)"
run mount "$INAUTO_DATA_DEV" "$INAUTO_MNT"

if is_dry_run; then
    log "DRY-RUN: пропускаю инициализацию inauto-data skeleton и restore backup в $INAUTO_MNT"
else
    install -d -m 0755 \
        "$INAUTO_MNT/on_start/before_login" \
        "$INAUTO_MNT/on_start/oneshot" \
        "$INAUTO_MNT/on_start/forking" \
        "$INAUTO_MNT/on_login" \
        "$INAUTO_MNT/staff" \
        "$INAUTO_MNT/log"

    [[ -e "$INAUTO_MNT/.inautolock" ]] || : > "$INAUTO_MNT/.inautolock"

    # --- 7.5. Restore backup прямо в /home/inauto ----------------------------
    # Архив (если есть) накатывается поверх свежего skeleton'а inauto-data.
    # staff/docker в tarball не попадает: loopback ext4 runtime-store нам
    # здесь не нужен, container-store живёт на отдельном разделе.

    if [[ "${SKIP_BACKUP:-0}" == "1" ]]; then
        log "restore backup пропущен (SKIP_BACKUP=1)"
    elif [[ -x "$BACKUP_SCRIPT" ]]; then
        log "попытка восстановить $BACKUP_DIR → $INAUTO_MNT"
        BACKUP_DIR="$BACKUP_DIR" "$BACKUP_SCRIPT" restore "$INAUTO_MNT" \
            || warn "restore не выполнен; backup остаётся в $BACKUP_DIR до reboot'а"
    fi

    printf '%s\n' "$PANEL_HOSTNAME" > "$INAUTO_MNT/staff/hostname"
    chmod 0644 "$INAUTO_MNT/staff/hostname"
    log "записан /home/inauto/staff/hostname = $PANEL_HOSTNAME"
fi

run umount "$INAUTO_MNT"
rmdir "$INAUTO_MNT"

# --- 8. Reboot -------------------------------------------------------------

if [[ "${SKIP_REBOOT:-0}" == "1" ]]; then
    log "SKIP_REBOOT=1 — установка завершена, reboot не выполняется."
    exit 0
fi

log "установка завершена; перезагружаюсь через 10 секунд"
sleep 10
run systemctl reboot || run reboot -f
