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
#  7. Инициализировать /persist и /home/inauto skeletons.
#  8. Reboot.
#
# Формат payload (рядом со скриптом в /opt/inauto-installer/):
#   bundle.raucb                     — подписанный RAUC bundle (ЕДИНСТВЕННЫЙ
#                                       источник raw-байт для efi_A/B и
#                                       rootfs_A/B: installer verify'ит
#                                       подпись и extract'ит efi.vfat +
#                                       rootfs.img в tmpdir перед dd).
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
#   DRY_RUN                "1" — не писать на диск, только показать команды (debug)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${INSTALLER_PAYLOAD_DIR:-$SCRIPT_DIR}"

log()  { echo "[installer] $*"; }
warn() { echo "[installer] WARN: $*" >&2; }
fail() { echo "[installer] ERROR: $*" >&2; exit 1; }

run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY-RUN: $*"
    else
        "$@"
    fi
}

# --- 1. Runtime checks ----------------------------------------------------

(( EUID == 0 )) || fail "запускать от root."

[[ -d /sys/firmware/efi ]] \
    || fail "не UEFI runtime: /sys/firmware/efi отсутствует (pc-efi поддерживается только на UEFI PC)."

for tool in sgdisk blockdev partprobe udevadm efibootmgr dd lsblk jq findmnt mkfs.ext4 mkfs.vfat ssh-keygen uuidgen mountpoint rauc; do
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
log "target disk: $TARGET_DEVICE ($(blockdev --getsize64 "$TARGET_DEVICE") байт)"

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

if [[ -x "$BACKUP_SCRIPT" ]]; then
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

for f in "$BUNDLE" "$KEYRING" "$SGDISK_SCRIPT"; do
    [[ -f "$f" ]] || fail "отсутствует payload artefact: $f"
done

# Verify подпись bundle'а. Если keyring не доверяет signing cert'у bundle'а —
# fail до того, как мы что-то напишем на диск.
log "проверяю подпись bundle'а: $BUNDLE (keyring=$KEYRING)"
rauc info --keyring="$KEYRING" "$BUNDLE" >/dev/null \
    || fail "подпись $BUNDLE не верифицируется через $KEYRING — аварийно прерываюсь"

# Извлекаем payload (efi.vfat + rootfs.img) из signed bundle в tmpdir.
# Именно эти байты пойдут на диск — никакого сокращения доверия между
# подписью и фактическим rootfs.
BUNDLE_EXTRACT_DIR="$(mktemp -d -t inauto-bundle-XXXXXX)"
trap 'rm -rf "$BUNDLE_EXTRACT_DIR"' EXIT

log "распаковываю signed bundle → $BUNDLE_EXTRACT_DIR"
rauc extract --keyring="$KEYRING" "$BUNDLE" "$BUNDLE_EXTRACT_DIR"

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
write_image_raw "$EFI_IMG"    /dev/disk/by-partlabel/efi_A
write_image_raw "$EFI_IMG"    /dev/disk/by-partlabel/efi_B

log "заливаю rootfs_A/rootfs_B из $ROOTFS_IMG"
write_image_raw "$ROOTFS_IMG" /dev/disk/by-partlabel/rootfs_A
write_image_raw "$ROOTFS_IMG" /dev/disk/by-partlabel/rootfs_B

run sync
run partprobe "$TARGET_DEVICE" || true
run udevadm settle --timeout=10 || true

# --- 6. UEFI boot entries --------------------------------------------------

# Вычисляем номер партиции efi_A/efi_B относительно диска.
part_number_for_label() {
    local label="$1"
    local part
    part="$(readlink -f "/dev/disk/by-partlabel/$label")"
    [[ -n "$part" ]] || return 1
    # /dev/sda3 -> 3; /dev/nvme0n1p3 -> 3; /dev/mmcblk0p3 -> 3
    echo "$part" | sed -E 's#.*[^0-9]([0-9]+)$#\1#'
}

EFI_A_PART="$(part_number_for_label efi_A)" || fail "не удалось определить partition # для efi_A"
EFI_B_PART="$(part_number_for_label efi_B)" || fail "не удалось определить partition # для efi_B"

log "регистрирую UEFI boot entries на $TARGET_DEVICE (efi_A=$EFI_A_PART, efi_B=$EFI_B_PART)"

# Удалим прежние system0/system1 если остались (idempotent re-install).
remove_existing_entry() {
    local label="$1"
    local existing
    existing="$(efibootmgr -v 2>/dev/null | awk -v lbl="$label" '$0 ~ lbl { sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1 }' || true)"
    for bootnum in $existing; do
        log "удаляю старую запись Boot$bootnum ($label)"
        run efibootmgr --bootnum "$bootnum" --delete-bootnum || true
    done
}

remove_existing_entry "system0"
remove_existing_entry "system1"

LOADER_PATH='\EFI\Linux\inauto-panel.efi'
# Kernel cmdline: тот же, что в system.conf:[slot.efi.N]::efi-cmdline.
# RAUC при install перепишет entry своим (с тем же cmdline), но на factory
# boot firmware использует ровно то, что мы положим сюда через --unicode.
# Без этого EFI-stub kernel не нашёл бы initrd и root, и первый boot после
# factory install'а упал бы.
CMDLINE_A='initrd=\EFI\Linux\initrd.img rauc.slot=system0 root=/dev/disk/by-partlabel/rootfs_A rootfstype=squashfs ro quiet panic=30'
CMDLINE_B='initrd=\EFI\Linux\initrd.img rauc.slot=system1 root=/dev/disk/by-partlabel/rootfs_B rootfstype=squashfs ro quiet panic=30'

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
run mount /dev/disk/by-partlabel/persist "$PERSIST_MNT"

init_persist_skeleton() {
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

    # x11vnc.pass placeholder (0600), пустой — настраивается отдельно
    local vnc="$PERSIST_MNT/etc/x11vnc.pass"
    if [[ ! -e "$vnc" ]]; then
        : > "$vnc"
        chmod 0600 "$vnc"
    fi
}

init_persist_skeleton

run umount "$PERSIST_MNT"
rmdir "$PERSIST_MNT"

# inauto-data: скелет home/inauto с site hooks
INAUTO_MNT="$(mktemp -d)"
run mount /dev/disk/by-partlabel/inauto-data "$INAUTO_MNT"

install -d -m 0755 \
    "$INAUTO_MNT/on_start/before_login" \
    "$INAUTO_MNT/on_start/oneshot" \
    "$INAUTO_MNT/on_start/forking" \
    "$INAUTO_MNT/on_login" \
    "$INAUTO_MNT/staff" \
    "$INAUTO_MNT/log"

[[ -e "$INAUTO_MNT/.inautolock" ]] || : > "$INAUTO_MNT/.inautolock"

# --- 7.5. Restore backup в /home/inauto/backup ---------------------------
# Архив (если есть) распаковывается в подкаталог backup/ — skeleton
# (.inautolock + on_start/on_login/staff/log) остаётся нетронутым.
# Наладчик вручную решает, что переносить из backup/ в active layout.

if [[ -x "$BACKUP_SCRIPT" ]]; then
    log "попытка восстановить $BACKUP_DIR → $INAUTO_MNT/backup"
    BACKUP_DIR="$BACKUP_DIR" "$BACKUP_SCRIPT" restore "$INAUTO_MNT/backup" \
        || warn "restore не выполнен; backup остаётся в $BACKUP_DIR до reboot'а"
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
