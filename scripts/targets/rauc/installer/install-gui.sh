#!/bin/bash
# Friendly factory installer wizard for field technicians.
#
# This wraps install-to-disk.sh with a disk picker, dependency check,
# destructive confirmation, progress dialog and explicit reboot prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-to-disk.sh"
TITLE="Inauto Panel Installer"
MIN_DISK_GIB=32
GIB=$((1024 * 1024 * 1024))

LOG_DIR="${LOG_DIR:-/tmp/inauto-installer}"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
STATUS_FILE="$LOG_DIR/install.status"

mkdir -p "$LOG_DIR"

have_gui() {
    command -v zenity >/dev/null 2>&1 \
        && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]
}

info() {
    if have_gui; then
        zenity --info --title="$TITLE" --width=560 --text="$1"
    else
        printf '%s\n' "$1"
    fi
}

warn() {
    if have_gui; then
        zenity --warning --title="$TITLE" --width=620 --text="$1"
    else
        printf 'WARNING: %s\n' "$1" >&2
    fi
}

error_box() {
    if have_gui; then
        zenity --error --title="$TITLE" --width=680 --text="$1"
    else
        printf 'ERROR: %s\n' "$1" >&2
    fi
}

confirm() {
    if have_gui; then
        zenity --question --title="$TITLE" --width=620 --text="$1"
    else
        local reply
        printf '%s [y/N]: ' "$1" >&2
        read -r reply
        [[ "$reply" == "y" || "$reply" == "Y" ]]
    fi
}

reexec_as_root_if_needed() {
    if (( EUID == 0 )); then
        return 0
    fi

    if have_gui && command -v pkexec >/dev/null 2>&1; then
        exec pkexec env \
            "DISPLAY=${DISPLAY:-}" \
            "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" \
            "XAUTHORITY=${XAUTHORITY:-}" \
            "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" \
            "$0" "$@"
    fi

    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E "$0" "$@"
    fi

    error_box "Нужны права root. Запустите: sudo $0"
    exit 1
}

human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$bytes"
    else
        printf '%s bytes' "$bytes"
    fi
}

pair_value() {
    local key="$1"
    local line="$2"
    sed -n "s/.*${key}=\"\\([^\"]*\\)\".*/\\1/p" <<<"$line"
}

disk_rows() {
    lsblk -dn -P -b -o PATH,SIZE,MODEL,SERIAL,TRAN,RM,TYPE 2>/dev/null \
        | while IFS= read -r line; do
            local path size model serial tran rm type
            path="$(pair_value PATH "$line")"
            size="$(pair_value SIZE "$line")"
            model="$(pair_value MODEL "$line")"
            serial="$(pair_value SERIAL "$line")"
            tran="$(pair_value TRAN "$line")"
            rm="$(pair_value RM "$line")"
            type="$(pair_value TYPE "$line")"

            [[ "$type" == "disk" ]] || continue
            [[ "$rm" == "0" ]] || continue
            [[ "$size" =~ ^[0-9]+$ ]] || continue
            (( size >= MIN_DISK_GIB * GIB )) || continue

            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$path" "$(human_size "$size")" "${model:-unknown}" "${serial:-}" "${tran:-}"
        done
}

select_disk_gui() {
    local rows=()
    local path size model serial tran

    while IFS=$'\t' read -r path size model serial tran; do
        rows+=(FALSE "$path" "$size" "$model" "$serial" "$tran")
    done < <(disk_rows)

    if (( ${#rows[@]} == 0 )); then
        error_box "Не найден fixed-диск >= ${MIN_DISK_GIB} GiB.

Проверьте, что целевой SSD/eMMC виден в системе:
  lsblk -dpno NAME,SIZE,MODEL,RM,TYPE"
        exit 1
    fi

    # Select the only candidate by default; otherwise force an explicit choice.
    if (( ${#rows[@]} == 6 )); then
        rows[0]=TRUE
    fi

    zenity --list --radiolist \
        --title="$TITLE" \
        --width=980 --height=420 \
        --text="Выберите диск панели. Он будет полностью стёрт." \
        --column="" --column="Диск" --column="Размер" --column="Модель" --column="Serial" --column="Bus" \
        "${rows[@]}"
}

select_disk_tty() {
    local rows=()
    local path size model serial tran i choice

    while IFS=$'\t' read -r path size model serial tran; do
        rows+=("$path|$size|$model|$serial|$tran")
    done < <(disk_rows)

    if (( ${#rows[@]} == 0 )); then
        error_box "Не найден fixed-диск >= ${MIN_DISK_GIB} GiB."
        exit 1
    fi

    printf 'Выберите диск панели. Он будет полностью стёрт.\n\n'
    for i in "${!rows[@]}"; do
        IFS='|' read -r path size model serial tran <<<"${rows[$i]}"
        printf '%2d) %-16s %-8s %-28s %-16s %s\n' \
            "$((i + 1))" "$path" "$size" "$model" "$serial" "$tran"
    done
    printf '\nНомер диска: '
    read -r choice
    [[ "$choice" =~ ^[0-9]+$ ]] || exit 1
    (( choice >= 1 && choice <= ${#rows[@]} )) || exit 1
    IFS='|' read -r path _ <<<"${rows[$((choice - 1))]}"
    printf '%s\n' "$path"
}

select_disk() {
    if have_gui; then
        select_disk_gui
    else
        select_disk_tty
    fi
}

check_uefi() {
    [[ -d /sys/firmware/efi ]] && return 0
    error_box "Эта система загружена не в UEFI mode.

Перезагрузите Live USB и выберите UEFI boot entry. Legacy/CSM boot для pc-efi установки не подходит."
    exit 1
}

required_tool_packages() {
    case "$1" in
        rauc) echo rauc ;;
        sgdisk) echo gdisk ;;
        jq) echo jq ;;
        zstd) echo zstd ;;
        unsquashfs) echo squashfs-tools ;;
        efibootmgr) echo efibootmgr ;;
        mkfs.vfat) echo dosfstools ;;
        mkfs.ext4) echo e2fsprogs ;;
        partprobe) echo parted ;;
        uuidgen) echo uuid-runtime ;;
        ssh-keygen) echo openssh-client ;;
        udevadm) echo udev ;;
        blkid|blockdev|dd|findmnt|lsblk|mount|mountpoint|umount) echo util-linux ;;
        tar|sha256sum) echo coreutils ;;
        *) echo "$1" ;;
    esac
}

ensure_runtime_tools() {
    local tools=(
        rauc sgdisk blockdev partprobe udevadm efibootmgr dd lsblk jq findmnt
        mkfs.ext4 mkfs.vfat ssh-keygen uuidgen mountpoint tar zstd sha256sum
        unsquashfs blkid mount umount
    )
    local missing=()
    local packages=()
    local tool pkg

    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    (( ${#missing[@]} == 0 )) && return 0

    for tool in "${missing[@]}"; do
        pkg="$(required_tool_packages "$tool")"
        [[ " ${packages[*]} " == *" $pkg "* ]] || packages+=("$pkg")
    done

    if ! command -v apt-get >/dev/null 2>&1; then
        error_box "В Live-системе не хватает инструментов: ${missing[*]}

apt-get не найден. Используйте подготовленный Inauto Installer USB."
        exit 1
    fi

    if ! confirm "В Live-системе не хватает инструментов:

${missing[*]}

Установить пакеты из apt сейчас?

${packages[*]}"; then
        exit 1
    fi

    if have_gui; then
        (
            echo "# apt-get update"
            apt-get update
            echo "# apt-get install ${packages[*]}"
            apt-get install -y --no-install-recommends "${packages[@]}"
        ) 2>&1 | while IFS= read -r line; do
            echo "# $line"
        done | zenity --progress --pulsate --auto-close --no-cancel \
            --title="$TITLE" --width=620 --text="Готовлю Live-систему..."
    else
        apt-get update
        apt-get install -y --no-install-recommends "${packages[@]}"
    fi

    missing=()
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} != 0 )); then
        error_box "Не удалось подготовить Live-систему. Всё ещё отсутствует:
${missing[*]}"
        exit 1
    fi
}

choose_backup_dir() {
    local dir="/tmp/inauto-backup"

    if have_gui; then
        if confirm "Если на панели уже есть /home/inauto, installer попробует сохранить его перед разметкой.

По умолчанию backup временно пишется в RAM: /tmp/inauto-backup.

Выбрать внешний USB/другую папку для backup?"; then
            dir="$(zenity --file-selection --directory --title="Куда сохранить backup /home/inauto?" || true)"
            [[ -n "$dir" ]] || dir="/tmp/inauto-backup"
        fi
    else
        printf 'BACKUP_DIR [/tmp/inauto-backup]: '
        read -r dir
        [[ -n "$dir" ]] || dir="/tmp/inauto-backup"
    fi

    printf '%s\n' "$dir"
}

ensure_backup_dir_writable() {
    local dir="$1"
    local probe

    mkdir -p "$dir" 2>/dev/null || return 1
    probe="$dir/.inauto-write-test-$$"
    : > "$probe" 2>/dev/null || return 1
    rm -f "$probe"
}

confirm_destructive_install() {
    local target="$1"
    local details marker

    details="$(lsblk -dpno NAME,SIZE,MODEL,SERIAL,TRAN,RM,TYPE "$target" 2>/dev/null || echo "$target")"

    if have_gui; then
        marker="$(zenity --entry \
            --title="$TITLE" \
            --width=720 \
            --text="Будет полностью стёрт диск:

$details

Все разделы и данные на этом диске будут удалены.

Для подтверждения введите: ERASE" || true)"
    else
        printf '\nБудет полностью стёрт диск:\n%s\n\nДля подтверждения введите ERASE: ' "$details"
        read -r marker
    fi

    [[ "$marker" == "ERASE" ]]
}

run_installer() {
    local target="$1"
    local backup_dir="$2"
    local allow_no_backup="$3"
    local skip_backup="$4"
    local status=0
    local worker_status=0
    local zenity_status=0
    local -a pipe_status=()
    local -a cmd

    rm -f "$STATUS_FILE"

    cmd=(env "TARGET_DEVICE=$target" "BACKUP_DIR=$backup_dir" "SKIP_REBOOT=1" "FORCE_YES=1")
    if [[ "$allow_no_backup" == "1" ]]; then
        cmd+=("ALLOW_NO_BACKUP=1")
    fi
    if [[ "$skip_backup" == "1" ]]; then
        cmd+=("SKIP_BACKUP=1")
    fi
    cmd+=("$INSTALLER")

    if have_gui; then
        set +e
        (
            set +e
            "${cmd[@]}" >"$LOG_FILE" 2>&1 &
            local pid=$!
            local installer_status
            while kill -0 "$pid" 2>/dev/null; do
                local last
                last="$(tail -n 1 "$LOG_FILE" 2>/dev/null || true)"
                [[ -n "$last" ]] || last="Установка выполняется..."
                echo "# $last"
                sleep 1
            done
            wait "$pid"
            installer_status="$?"
            echo "$installer_status" > "$STATUS_FILE"
            if [[ "$installer_status" == "0" ]]; then
                echo "# Установка завершена"
            fi
        ) | zenity --progress --pulsate --auto-close --no-cancel \
            --title="$TITLE" --width=720 --text="Прошивка панели..."
        pipe_status=("${PIPESTATUS[@]}")
        worker_status="${pipe_status[0]:-0}"
        zenity_status="${pipe_status[1]:-0}"
        status="$(cat "$STATUS_FILE" 2>/dev/null || true)"
        set -e

        if [[ ! "$status" =~ ^[0-9]+$ ]]; then
            status=1
        fi

        if [[ "$status" != "0" ]] && grep -q 'SKIP_REBOOT=1' "$LOG_FILE" 2>/dev/null; then
            status=0
        fi

        if [[ "$status" != "0" ]]; then
            {
                echo "[install-gui] worker_status=$worker_status"
                echo "[install-gui] zenity_status=$zenity_status"
                echo "[install-gui] installer_status=$status"
            } >> "$LOG_FILE"
        fi
    else
        set +e
        "${cmd[@]}" 2>&1 | tee "$LOG_FILE"
        status="${PIPESTATUS[0]}"
        set -e
    fi

    return "$status"
}

main() {
    reexec_as_root_if_needed "$@"

    [[ -x "$INSTALLER" ]] || {
        error_box "Не найден installer: $INSTALLER"
        exit 1
    }

    check_uefi
    ensure_runtime_tools

    local target backup_dir="/tmp/inauto-backup" allow_no_backup=0 skip_backup=0
    if [[ -n "${TARGET_DEVICE:-}" ]]; then
        target="$TARGET_DEVICE"
        [[ -b "$target" ]] || {
            error_box "TARGET_DEVICE='$target' не является block device."
            exit 1
        }
    else
        target="$(select_disk)"
    fi
    [[ -n "$target" ]] || exit 1

    if confirm "Попробовать сохранить старый /home/inauto перед разметкой диска?

Если это новая или тестовая панель, можно выбрать \"Нет\" и полностью пропустить backup."; then
        while true; do
            backup_dir="$(choose_backup_dir)"
            if ensure_backup_dir_writable "$backup_dir"; then
                break
            fi
            warn "Папка backup недоступна для записи:

$backup_dir

Не выбирайте сам installer ISO/CD-ROM. Для сохранения старого /home/inauto выберите внешний USB-диск или оставьте /tmp/inauto-backup."
        done

        if confirm "Это новая/тестовая панель, и можно продолжить даже если backup старого /home/inauto не выполнится?

Для боевой миграции лучше выбрать \"Нет\"."; then
            allow_no_backup=1
        fi
    else
        skip_backup=1
        allow_no_backup=1
    fi

    if ! confirm_destructive_install "$target"; then
        warn "Установка отменена. Диск не изменён."
        exit 1
    fi

    info "Начинаю установку.

Диск: $target
Backup: $(if [[ "$skip_backup" == "1" ]]; then echo "пропущен"; else echo "$backup_dir"; fi)
Лог: $LOG_FILE"

    if run_installer "$target" "$backup_dir" "$allow_no_backup" "$skip_backup"; then
        info "Установка завершена успешно.

Лог: $LOG_FILE"
        if confirm "Перезагрузить панель сейчас?"; then
            systemctl reboot || reboot -f
        fi
    else
        local tail_log
        tail_log="$(tail -n 30 "$LOG_FILE" 2>/dev/null || true)"
        error_box "Установка завершилась ошибкой.

Лог: $LOG_FILE

Последние строки:
$tail_log"
        exit 1
    fi
}

main "$@"
