#!/bin/bash
# panel-update — ручное обновление immutable-панели из RAUC bundle (.raucb).
#
# Два режима (выбираются автоматически):
#
#  1. Обычное обновление (система уже на GRUB-схеме, bootloader=grub):
#     проверка sha256 -> диагностика -> остановка автообновлений ->
#     rauc info -> сводка -> подтверждение -> rauc install -> reboot.
#
#  2. МИГРАЦИЯ v1 -> v2 БЕЗ заводского инсталлятора (система на старой
#     EFI-схеме, bundle новой v2-схемы). Прошивка панелей переписывает
#     UEFI BootOrder на каждом POST, поэтому v2 переносит выбор слота в
#     единый GRUB на efi_A (см. docs/2026-07-04-grub-boot-selection-design.md).
#     Старый rauc откажет v2-bundle по compatible, поэтому миграция пишет
#     образы сама: rauc mount (verify подписи) -> dd rootfs.img в НЕактивный
#     rootfs-слот -> dd boot.vfat в оба ESP (сначала неактивный) ->
#     grubenv ORDER на новый слот -> reboot.
#     Для миграции рядом с bundle нужен boot.vfat (+ .sha256) из релиза.
#     ВНИМАНИЕ: старый слот после миграции незагружаем (в нём нет
#     grub-slot.cfg) — откат возможен только на следующую v2-версию.
#
# Использование:
#   sudo panel-update [/путь/к/bundle.raucb]
# Без аргумента ищет единственный *.raucb в /tmp, /home/inauto,
# /home/inauto/update, /media/*.
# На v1-панели новый скрипт запускают из /tmp (в старом образе его нет).

set -euo pipefail

FIRMWARE_VERSION_FILE="/etc/inauto/firmware-version"
SYSTEM_CONF="/etc/rauc/system.conf"
UPDATE_TIMER="panel-check-updates.timer"
UPDATE_SERVICE="panel-check-updates.service"
BOOTENV_GRUBENV="/run/inauto/bootenv/grubenv"

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

function restore_timer() {
    systemctl start "$UPDATE_TIMER" 2>/dev/null || true
}

MIG_MOUNT_DIR=""
MIG_ENV_MNT=""
function cleanup_migration_mounts() {
    if [[ -n "$MIG_MOUNT_DIR" ]] && mountpoint -q "$MIG_MOUNT_DIR/bundle" 2>/dev/null; then
        umount "$MIG_MOUNT_DIR/bundle" 2>/dev/null || true
    fi
    if [[ -n "$MIG_MOUNT_DIR" ]]; then
        rm -rf "$MIG_MOUNT_DIR" 2>/dev/null || true
    fi
    if [[ -n "$MIG_ENV_MNT" ]]; then
        umount "$MIG_ENV_MNT" 2>/dev/null || true
        rmdir "$MIG_ENV_MNT" 2>/dev/null || true
    fi
}

function verify_sha256_if_present() {
    local file="$1"
    if [[ -f "$file.sha256" ]]; then
        if ( cd "$(dirname "$file")" || exit 1; sha256sum -c "$(basename "$file").sha256" ); then
            info "sha256 $(basename "$file"): совпала"
        else
            die "контрольная сумма $(basename "$file") не совпала — файл повреждён, установка отменена."
        fi
    else
        warn "рядом нет $(basename "$file").sha256 — проверка целостности пропущена."
    fi
}

[[ "$(id -u)" -eq 0 ]] || die "нужны права root. Запустите: sudo panel-update ..."
command -v rauc >/dev/null 2>&1 || die "rauc не установлен."

# --- 1. Определить bundle ---
BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
    # /home/inauto/update указан отдельно: /home/inauto ограничен maxdepth 4,
    # а каталог update — штатное место доставки образов на панель.
    mapfile -t candidates < <(find /tmp /home/inauto /home/inauto/update /media -maxdepth 4 -type f -name '*.raucb' 2>/dev/null | sort -u)
    case "${#candidates[@]}" in
        0) die "путь к bundle не задан и *.raucb не найден в /tmp, /home/inauto (включая update/), /media." ;;
        1) BUNDLE="${candidates[0]}"; info "автоопределён bundle: $BUNDLE" ;;
        *) printf 'Найдено несколько *.raucb, укажите нужный явно:\n'; printf '  %s\n' "${candidates[@]}"; exit 1 ;;
    esac
fi
[[ -f "$BUNDLE" ]] || die "файл bundle не найден: $BUNDLE"

# --- 2. Контрольная сумма ---
log "Контрольная сумма"
verify_sha256_if_present "$BUNDLE"

# --- 3. Диагностика текущей системы ---
log "Текущая система"
current_version="$(cat "$FIRMWARE_VERSION_FILE" 2>/dev/null || echo '<неизвестно>')"
current_slot="$(grep -o 'rauc\.slot=[^ ]*' /proc/cmdline | cut -d= -f2 || true)"
sys_bootloader="$(awk -F= '/^bootloader=/{print $2; exit}' "$SYSTEM_CONF" 2>/dev/null || true)"
info "версия прошивки:  $current_version"
info "загруженный слот: ${current_slot:-<неизвестно>}"
if [[ "$sys_bootloader" == "efi" ]]; then
    info "boot-схема:       efi (старая, v1)"
else
    info "boot-схема:       ${sys_bootloader:-<неизвестно>}"
fi
echo
rauc status || warn "rauc status завершился с ошибкой"
echo
systemctl status rauc-mark-boot-good.service --no-pager || true

# --- 4. Остановить автообновления ---
log "Останавливаю автообновления на время установки"
systemctl stop "$UPDATE_TIMER" "$UPDATE_SERVICE" 2>/dev/null || true
trap 'cleanup_migration_mounts; restore_timer' EXIT

# --- 5. Прочитать bundle ---
log "Информация о RAUC-пакете"
if ! bundle_info="$(rauc info "$BUNDLE" 2>&1)"; then
    printf '%s\n' "$bundle_info" >&2
    die "rauc info не смог прочитать bundle (подпись/keyring?)."
fi
printf '%s\n' "$bundle_info"

# Устойчивый парсинг: machine-readable shell-формат (RAUC >=1.9), фолбэк — на
# человекочитаемый вывод, если формат/версия rauc отличаются.
bundle_shell="$(rauc info --output-format=shell "$BUNDLE" 2>/dev/null || true)"
bundle_version="$(sed -n "s/^RAUC_MF_VERSION=['\"]\{0,1\}\([^'\"]*\).*/\1/p" <<<"$bundle_shell" | head -n1)"
bundle_compat="$(sed -n "s/^RAUC_MF_COMPATIBLE=['\"]\{0,1\}\([^'\"]*\).*/\1/p" <<<"$bundle_shell" | head -n1)"
[[ -n "$bundle_version" ]] || bundle_version="$(awk -F\' '/^Version:/    {print $2; exit}' <<<"$bundle_info")"
[[ -n "$bundle_compat" ]]  || bundle_compat="$(awk -F\' '/^Compatible:/ {print $2; exit}' <<<"$bundle_info")"

sys_compat="$(awk -F= '/^compatible=/{gsub(/["[:space:]]/,"",$2); print $2; exit}' "$SYSTEM_CONF" 2>/dev/null || true)"

# ============================================================================
# Режим МИГРАЦИИ: система v1 (bootloader=efi) + v2 bundle
# ============================================================================
function run_migration() {
    local boot_img="$1"
    local active_slot="$2"
    local target_slot target_rootfs target_esp active_esp
    local rootfs_dev esp_target_dev esp_active_dev dev
    local rootfs_size img_size
    local f label n answer

    case "$active_slot" in
        system0) target_slot="system1"; target_rootfs="rootfs_B"; target_esp="efi_B"; active_esp="efi_A" ;;
        system1) target_slot="system0"; target_rootfs="rootfs_A"; target_esp="efi_A"; active_esp="efi_B" ;;
        *) die "не удалось определить загруженный слот из /proc/cmdline (rauc.slot='$active_slot')." ;;
    esac

    rootfs_dev="/dev/disk/by-partlabel/$target_rootfs"
    esp_target_dev="/dev/disk/by-partlabel/$target_esp"
    esp_active_dev="/dev/disk/by-partlabel/$active_esp"
    for dev in "$rootfs_dev" "$esp_target_dev" "$esp_active_dev"; do
        [[ -b "$dev" ]] || die "не найден раздел $dev — раскладка не pc-efi?"
    done

    log "МИГРАЦИЯ на GRUB-схему (v2) без инсталлятора"
    info "версия:         $current_version -> ${bundle_version:-<неизвестно>}"
    info "активный слот:  $active_slot (не трогается до перезагрузки)"
    info "целевой слот:   $target_slot ($target_rootfs)"
    info "загрузчик:      boot.vfat -> $target_esp, затем $active_esp"
    warn "после миграции старый слот незагружаем: откат — только установкой следующей версии."
    echo
    read -r -p "Выполнить миграцию и перезагрузить панель? [y/N] " answer
    case "$answer" in
        y|Y|yes|Yes|YES|да|Да|ДА) ;;
        *) info "Отменено. Автообновления возвращены."; exit 0 ;;
    esac

    # 1. Извлечь rootfs.img из подписанного bundle (verify через системный keyring).
    MIG_MOUNT_DIR="$(mktemp -d -t panel-migrate-XXXXXX)"
    log "Монтирую bundle (rauc mount, с проверкой подписи)"
    rauc mount --mount "$MIG_MOUNT_DIR" "$BUNDLE" \
        || die "rauc mount не смог смонтировать bundle (подпись/keyring?)."
    [[ -f "$MIG_MOUNT_DIR/bundle/rootfs.img" ]] \
        || die "bundle не содержит rootfs.img — это не v2 rootfs-only bundle."

    # 2. Проверка размеров до записи.
    img_size="$(stat -c %s "$MIG_MOUNT_DIR/bundle/rootfs.img")"
    rootfs_size="$(blockdev --getsize64 "$rootfs_dev")"
    (( img_size <= rootfs_size )) \
        || die "rootfs.img ($img_size байт) больше раздела $target_rootfs ($rootfs_size байт)."

    # 3. Записать rootfs в НЕактивный слот (текущая система не трогается).
    log "Пишу rootfs.img -> $rootfs_dev"
    dd if="$MIG_MOUNT_DIR/bundle/rootfs.img" of="$rootfs_dev" bs=4M conv=fsync,notrunc status=progress \
        || die "dd rootfs.img в $rootfs_dev не удался."

    umount "$MIG_MOUNT_DIR/bundle" || warn "не удалось размонтировать bundle (не критично)."

    # 4. Загрузчик: сначала НЕактивный ESP (при сбое питания старая схема ещё
    #    загрузится с активного), затем активный (ядро уже в RAM).
    log "Пишу boot.vfat -> $esp_target_dev, затем $esp_active_dev"
    dd if="$boot_img" of="$esp_target_dev" bs=4M conv=fsync,notrunc status=progress \
        || die "dd boot.vfat в $esp_target_dev не удался."
    dd if="$boot_img" of="$esp_active_dev" bs=4M conv=fsync,notrunc status=progress \
        || die "dd boot.vfat в $esp_active_dev не удался. НЕ перезагружайте панель, обратитесь к runbook."

    # 5. grubenv: новый слот первым, старый помечен небутабельным.
    #    Даже если шаг не пройдёт, grub.cfg каскадно уйдёт на новый слот
    #    (в старом нет /boot/grub-slot.cfg), просто на одну попытку дольше.
    if command -v grub-editenv >/dev/null 2>&1; then
        MIG_ENV_MNT="$(mktemp -d)"
        if mount /dev/disk/by-partlabel/efi_A "$MIG_ENV_MNT" 2>/dev/null; then
            # Заодно валидируем записанный загрузчик: обрезанный dd лучше
            # поймать до перезагрузки.
            for f in EFI/BOOT/BOOTX64.EFI grub.cfg grubenv; do
                [[ -s "$MIG_ENV_MNT/$f" ]] \
                    || die "после записи boot.vfat на efi_A нет $f — НЕ перезагружайте панель, повторите миграцию."
            done
            grub-editenv "$MIG_ENV_MNT/grubenv" set \
                ORDER="$target_slot $active_slot" \
                "${target_slot}_OK=1" "${target_slot}_TRY=0" \
                "${active_slot}_OK=0" "${active_slot}_TRY=0" \
                || warn "grub-editenv не смог записать grubenv (GRUB откатится каскадом)."
            umount "$MIG_ENV_MNT" || warn "не удалось размонтировать efi_A (не критично, уходим в reboot)."
        else
            warn "не удалось смонтировать efi_A для правки grubenv (GRUB откатится каскадом)."
        fi
        rmdir "$MIG_ENV_MNT" 2>/dev/null || true
        MIG_ENV_MNT=""
    else
        warn "grub-editenv отсутствует — пропускаю правку grubenv (GRUB откатится каскадом)."
    fi

    # 6. Устаревшие NVRAM-записи со старыми LoadOptions мешают GRUB — удаляем.
    #    Прошивка сама пересоздаст чистые записи для \EFI\BOOT\BOOTX64.EFI.
    if command -v efibootmgr >/dev/null 2>&1; then
        for label in system0 system1; do
            for n in $(efibootmgr 2>/dev/null | awk -v lbl="$label" '$2 == lbl { sub(/^Boot/,"",$1); sub(/\*$/,"",$1); print $1 }'); do
                efibootmgr --bootnum "$n" --delete-bootnum >/dev/null 2>&1 \
                    || warn "не удалось удалить устаревшую запись Boot$n"
            done
        done
    fi

    sync
    log "Миграция записана. Перезагрузка..."
    systemctl reboot \
        || die "не удалось выполнить перезагрузку. Миграция уже записана — перезагрузите панель вручную: systemctl reboot"
}

if [[ "$sys_bootloader" == "efi" ]]; then
    if [[ -n "$bundle_compat" && -n "$sys_compat" && "$bundle_compat" == "$sys_compat" ]]; then
        die "bundle совместим со старой схемой ($bundle_compat) — используйте штатный /usr/local/bin/panel-update старого образа."
    fi
    BOOT_IMG="$(dirname "$BUNDLE")/boot.vfat"
    [[ -f "$BOOT_IMG" ]] \
        || die "для миграции рядом с bundle нужен boot.vfat (из релиза, с .sha256). Не найден: $BOOT_IMG"
    log "Контрольная сумма загрузчика"
    verify_sha256_if_present "$BOOT_IMG"
    run_migration "$BOOT_IMG" "${current_slot:-}"
    exit 0
fi

# ============================================================================
# Обычный режим (v2, bootloader=grub)
# ============================================================================

if [[ -n "$sys_compat" && -n "$bundle_compat" && "$sys_compat" != "$bundle_compat" ]]; then
    warn "Compatible bundle ('$bundle_compat') != системе ('$sys_compat') — rauc install, скорее всего, отклонит пакет."
fi

log "Проверяю доступ к grubenv"
if [[ -f "$BOOTENV_GRUBENV" ]]; then
    info "grubenv доступен: $BOOTENV_GRUBENV"
else
    warn "grubenv не найден в $BOOTENV_GRUBENV (run-inauto-bootenv.mount не активен?) — rauc install может не переключить слот."
fi

# --- Сводка и подтверждение ---
log "Сводка обновления"
info "текущая версия:   $current_version"
info "новая версия:     ${bundle_version:-<неизвестно>}"
info "загруженный слот: ${current_slot:-<неизвестно>}"
info "установка пойдёт в НЕактивный слот; текущий останется точкой отката."
echo
read -r -p "Установить обновление и перезагрузить панель? [y/N] " answer
case "$answer" in
    y|Y|yes|Yes|YES|да|Да|ДА) ;;
    *) info "Отменено. Автообновления возвращены."; exit 0 ;;
esac

# --- Установка и перезагрузка ---
log "Устанавливаю RAUC-пакет"
systemctl start rauc.service 2>/dev/null || true
rauc install "$BUNDLE" || die "rauc install завершился с ошибкой — система не тронута."
sync

log "Обновление записано в неактивный слот. Перезагрузка..."
systemctl reboot \
    || die "не удалось выполнить перезагрузку. Обновление уже в неактивном слоте — перезагрузите панель вручную: systemctl reboot"
