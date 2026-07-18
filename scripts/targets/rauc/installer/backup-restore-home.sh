#!/bin/bash
# Backup / restore helper для /home/inauto во время миграции mutable -> immutable.
#
# Запускается install-to-disk.sh дважды:
#   1) backup   — перед разметкой target disk'а; ищет существующий
#                 /home/inauto (с маркером .inautolock) на fixed
#                 (non-removable) блок-устройствах. TARGET_DEVICE НЕ
#                 исключается — типичный single-disk reinstall хранит
#                 /home/inauto ровно на перезаписываемом диске, и до-wipe
#                 backup — единственный способ сохранить его содержимое.
#                 Removable-носители (USB stick, SD) пропускаются через
#                 /sys/block/<name>/removable — блокирует случайный
#                 backup Ubuntu Live USB с подложенным .inautolock.
#                 Выход: tar.zst + sha256 в $BACKUP_DIR.
#   2) restore  — после установки и mount'а нового inauto-data; распаковывает
#                 tarball прямо в <new_inauto_data_mount>, поверх свежего
#                 skeleton'а. Структура /home/inauto восстанавливается сразу
#                 в рабочий layout, без промежуточного backup/ подкаталога.
#
# Архив и его sha256 живут в $BACKUP_DIR (по умолчанию /tmp/inauto-backup —
# это tmpfs live-session, RAM-only, автоматически пропадает после reboot'а).
# Для больших /home/inauto переопределите BACKUP_DIR на внешнюю USB.
#
# Вызов:
#   ./backup-restore-home.sh backup
#   ./backup-restore-home.sh restore <TARGET_DIR>
#
# Env:
#   BACKUP_DIR       каталог для tar.zst (default /tmp/inauto-backup)
#   TARGET_DEVICE    disk, который будет перезаписан install'ом — пишется
#                    только в log для диагностики; из поиска .inautolock
#                    НЕ исключается (см. комментарий у find_home_inauto_device)
#   DRY_RUN=1        не выполнять destructive-команды, только печать

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/tmp/inauto-backup}"
BACKUP_TARBALL="${BACKUP_TARBALL:-$BACKUP_DIR/home-inauto.tar.zst}"
BACKUP_MARKER=".inautolock"
BACKUP_EXCLUDES=(
    "./backup"
    "./lost+found"
    "./staff/docker"
)

log()  { echo "[backup-restore-home] $*"; }
warn() { echo "[backup-restore-home] WARN: $*" >&2; }
fail() { echo "[backup-restore-home] ERROR: $*" >&2; exit 1; }

# Выполнить команду или напечатать её в DRY_RUN режиме.
run_cmd() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY-RUN: $*"
    else
        "$@"
    fi
}

# Глобальные переменные, выставляет find_home_inauto_device.
FOUND_PARTITION=""
FOUND_MOUNT=""
FOUND_HOME=""

# Проверить одну партицию: попытаться mount read-only и найти .inautolock.
# Stored at root of fs (/dev/<dev>/.inautolock) или как подкаталог /home/inauto.
check_partition() {
    local part="$1"
    local fstype mnt candidate=""

    fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    case "$fstype" in
        ext2|ext3|ext4|xfs|btrfs|f2fs) ;;
        *) return 1 ;;
    esac

    mnt=$(mktemp -d -t inauto-probe-XXXXXX)
    if ! mount -o ro "$part" "$mnt" 2>/dev/null; then
        rmdir "$mnt"
        return 1
    fi

    if [[ -f "$mnt/$BACKUP_MARKER" ]]; then
        candidate="$mnt"
    elif [[ -d "$mnt/home/inauto" && -f "$mnt/home/inauto/$BACKUP_MARKER" ]]; then
        candidate="$mnt/home/inauto"
    fi

    if [[ -z "$candidate" ]]; then
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt"
        return 1
    fi

    FOUND_PARTITION="$part"
    FOUND_MOUNT="$mnt"
    FOUND_HOME="$candidate"
    return 0
}

# Просканировать все fixed (non-removable) block devices и найти первый
# /home/inauto. Returns 0 если нашли (с выставленными FOUND_*), 1 иначе.
#
# TARGET_DEVICE здесь НЕ исключается: типичный single-disk reinstall
# имеет /home/inauto ровно на том диске, который мы собираемся перезаписать,
# и backup до wipe'а — единственный способ сохранить данные. BACKUP_DIR по
# умолчанию tmpfs (/tmp), значит tarball не страдает от dd target disk'а.
#
# Removable-носители (major 8 USB-stick / SD) пропускаются через
# /sys/block/<name>/removable — защита от случайного backup'а Ubuntu Live USB.
find_home_inauto_device() {
    local name dev parts p removable

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        dev="/dev/$name"
        [[ -b "$dev" ]] || continue

        # Пропустить removable-носители: USB-stick и SD-карты имеют
        # тот же major 8 (SCSI), что и SATA, поэтому `lsblk -e 7,11`
        # их не отсеивает — проверяем /sys/block/<name>/removable.
        # 0 — fixed disk (SATA/NVMe/eMMC), 1 — removable (USB/SD).
        removable=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 1)
        [[ "$removable" == "0" ]] || continue

        # Получить список партиций диска (lsblk -ln даёт parent+children).
        parts=$(lsblk -ln -o NAME "$dev" | tail -n +2 || true)
        if [[ -n "$parts" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                if check_partition "/dev/$p"; then
                    return 0
                fi
            done <<<"$parts"
        else
            # Whole-device filesystem (без GPT/MBR).
            if check_partition "$dev"; then
                return 0
            fi
        fi
    done < <(lsblk -dn -o NAME -e 7,11)

    return 1
}

cleanup_probe_mount() {
    if [[ -n "$FOUND_MOUNT" ]]; then
        if mountpoint -q "$FOUND_MOUNT" 2>/dev/null; then
            run_cmd umount "$FOUND_MOUNT" || warn "не удалось размонтировать $FOUND_MOUNT"
        fi
        rmdir "$FOUND_MOUNT" 2>/dev/null || true
    fi
}

do_backup() {
    command -v tar       >/dev/null || fail "нет tar"
    command -v zstd      >/dev/null || fail "нет zstd"
    command -v sha256sum >/dev/null || fail "нет sha256sum"
    command -v lsblk     >/dev/null || fail "нет lsblk"
    command -v blkid     >/dev/null || fail "нет blkid"

    mkdir -p "$BACKUP_DIR"

    log "ищу существующий /home/inauto (TARGET_DEVICE=${TARGET_DEVICE:-<any>})"
    if ! find_home_inauto_device; then
        log "не найдено существующего /home/inauto на non-removable устройствах"
        log "пропуск backup (предполагаем фабрично-новую панель)"
        return 0
    fi

    log "найден /home/inauto: partition=$FOUND_PARTITION, mount=$FOUND_HOME"

    trap cleanup_probe_mount EXIT

    # Оценка свободного места в BACKUP_DIR vs размера home (очень грубая).
    local home_size_kb free_kb exclude tar_excludes_str=""
    local tar_excludes=()
    local du_excludes=()
    for exclude in "${BACKUP_EXCLUDES[@]}"; do
        tar_excludes+=("--exclude=$exclude")
        du_excludes+=("--exclude=$exclude")
    done
    printf -v tar_excludes_str '%q ' "${tar_excludes[@]}"
    tar_excludes_str="${tar_excludes_str% }"

    home_size_kb="$(
        cd "$FOUND_HOME" && \
        du -sk --one-file-system "${du_excludes[@]}" . 2>/dev/null | awk 'NR == 1 { print $1 }'
    )"
    home_size_kb="${home_size_kb:-0}"
    free_kb=$(df --output=avail -k "$BACKUP_DIR" | tail -n1)
    log "размер /home/inauto: $(numfmt --to=iec --from-unit=1024 "$home_size_kb")B; свободно в $BACKUP_DIR: $(numfmt --to=iec --from-unit=1024 "$free_kb")B"
    # Запас на tar-overhead и сжатие ~1.2× исходника (zstd typical для mixed content).
    if (( free_kb * 4 < home_size_kb * 3 )); then
        warn "в $BACKUP_DIR может не хватить места; задайте BACKUP_DIR=<путь на внешней USB> и перезапустите"
    fi

    log "архивирую $FOUND_HOME → $BACKUP_TARBALL (исключая backup/, lost+found/, staff/docker/)"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY-RUN: tar -C $(printf '%q' "$FOUND_HOME") $tar_excludes_str --xattrs --acls -cf - . | zstd -T0 -3 -o $(printf '%q' "$BACKUP_TARBALL")"
        log "DRY-RUN: sha256sum $BACKUP_TARBALL > $BACKUP_TARBALL.sha256"
    else
        # backup/ исключаем от рекурсии при повторной миграции со старых
        # payload'ов, а staff/docker/ не забираем, потому что loopback ext4
        # c runtime-данными Docker/containerd на immutable-цели больше не нужен.
        tar -C "$FOUND_HOME" "${tar_excludes[@]}" \
            --xattrs --acls -cf - . | zstd -T0 -3 -o "$BACKUP_TARBALL"
        ( cd "$BACKUP_DIR" && \
          sha256sum "$(basename "$BACKUP_TARBALL")" > "$(basename "$BACKUP_TARBALL").sha256" )
    fi

    log "backup создан: $BACKUP_TARBALL ($(du -h "$BACKUP_TARBALL" 2>/dev/null | cut -f1 || echo '<dry-run>'))"
}

do_restore() {
    local target="${1:-}"

    command -v tar       >/dev/null || fail "нет tar"
    command -v zstd      >/dev/null || fail "нет zstd"
    command -v sha256sum >/dev/null || fail "нет sha256sum"

    [[ -n "$target" ]] || fail "restore требует явный TARGET_DIR"

    if [[ ! -f "$BACKUP_TARBALL" ]]; then
        log "tarball $BACKUP_TARBALL не найден; нечего восстанавливать (новая панель или backup пропущен)"
        return 0
    fi

    if [[ -f "$BACKUP_TARBALL.sha256" ]]; then
        log "проверяю sha256 $BACKUP_TARBALL"
        ( cd "$(dirname "$BACKUP_TARBALL")" && \
          sha256sum -c "$(basename "$BACKUP_TARBALL").sha256" >/dev/null ) \
            || fail "sha256 mismatch — tarball повреждён, прерываю restore"
    else
        warn "нет $BACKUP_TARBALL.sha256, пропускаю проверку целостности"
    fi

    run_cmd install -d -m 0755 "$target"

    log "распаковываю $BACKUP_TARBALL → $target"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY-RUN: zstd -dc $BACKUP_TARBALL | tar -C $target --acls --xattrs --xattrs-include='*' -xpf -"
        log "DRY-RUN: test -f $target/$BACKUP_MARKER"
    else
        zstd -dc "$BACKUP_TARBALL" | tar -C "$target" --acls --xattrs --xattrs-include='*' -xpf -
        [[ -f "$target/$BACKUP_MARKER" ]] \
            || fail "restore завершился, но $target/$BACKUP_MARKER не найден"
    fi

    log "restore выполнен: $target ($(du -sh "$target" 2>/dev/null | cut -f1 || echo '<dry-run>'))"
}

case "${1:-}" in
    backup)
        do_backup
        ;;
    restore)
        shift
        do_restore "${1:-}"
        ;;
    *)
        fail "usage: $0 backup | restore <target_dir>"
        ;;
esac
