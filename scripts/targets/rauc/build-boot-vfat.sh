#!/bin/bash
# Собирает boot-image (efi.vfat для pc-efi, boot.vfat для *-uboot) для RAUC bundle.
#
# Реализация MVP: pc-efi. U-Boot target остаётся placeholder (Phase 10).
#
# Для pc-efi создаётся FAT32 образ фиксированного размера
# (EFI_VFAT_SIZE_MIB, по умолчанию 512 MiB — соответствует efi_A/efi_B на диске)
# с двумя файлами:
#   \EFI\BOOT\BOOTX64.EFI         — EFI-stub kernel (copy LIVE_KERNEL_NAME)
#   \EFI\Linux\inauto-panel.efi   — compatibility copy for older bundles
#   \EFI\Linux\initrd.img         — external initrd (copy LIVE_INITRD_NAME)
#
# Никаких loop mount'ов: всё через mkfs.vfat + mtools (работает без root).
#
# Вызов:
#   ./build-boot-vfat.sh <OUT_DIR>
# Выход:
#   <OUT_DIR>/efi.vfat  (pc-efi) или <OUT_DIR>/boot.vfat (uboot)

set -euo pipefail

# shellcheck source=scripts/targets/rauc/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_repo_config
load_distro_profile
require_rauc_vars

OUT_DIR="${1:-${OUT_DIR:-}}"
[[ -n "$OUT_DIR" ]] || fail "укажите OUT_DIR первым аргументом или через env."
mkdir -p "$OUT_DIR"

EFI_VFAT_SIZE_MIB="${EFI_VFAT_SIZE_MIB:-512}"

for tool in mkfs.vfat mmd mcopy truncate rauc; do
    command -v "$tool" >/dev/null 2>&1 || fail "не найден инструмент '$tool'."
done

# Gate: pinned RAUC принимает efi-loader/efi-cmdline в [slot.efi.*]?
# Поля документированы начиная с RAUC 1.10 (EFI backend refactor).
# Production-сборка pin'ит актуальную RAUC-версию через RAUC_PINNED_VERSION.
rauc_version="$(rauc --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
if [[ -z "$rauc_version" || ! "$rauc_version" =~ ^([0-9]+)\.([0-9]+) ]]; then
    fail "не удалось определить версию RAUC; установите пакет rauc >= 1.10."
fi
rauc_major="${BASH_REMATCH[1]}"
rauc_minor="${BASH_REMATCH[2]}"

if (( rauc_major < 1 )) || { (( rauc_major == 1 )) && (( rauc_minor < 10 )); }; then
    fail "RAUC ${rauc_version} слишком стар: efi-loader/efi-cmdline требуют минимум 1.10."
fi
if command -v dpkg >/dev/null 2>&1 \
        && ! dpkg --compare-versions "$rauc_version" ge "${RAUC_PINNED_VERSION:-1.15.2}"; then
    log "WARNING: RAUC ${rauc_version} ниже pinned ${RAUC_PINNED_VERSION:-1.15.2}. Перед production обновите pinned-версию."
fi

case "${TARGET_PLATFORM}" in
    pc-efi)
        OUT_FILE="$OUT_DIR/efi.vfat"
        LABEL="INAUTO_EFI"
        ;;
    *-uboot)
        fail "build-boot-vfat.sh: boot.vfat для U-Boot ещё не реализовано (Phase 10)."
        ;;
    *)
        fail "Неизвестный TARGET_PLATFORM='${TARGET_PLATFORM}'."
        ;;
esac

KERNEL_SRC="$(live_kernel_path)"
INITRD_SRC="$(live_initrd_path)"

for src in "$KERNEL_SRC" "$INITRD_SRC"; do
    [[ -f "$src" ]] || fail "отсутствует boot-артефакт: $src (нужен chr_build_image перед build_rauc_bundle)"
done

log "создаю $OUT_FILE (${EFI_VFAT_SIZE_MIB} MiB)"
rm -f "$OUT_FILE"
truncate -s "${EFI_VFAT_SIZE_MIB}M" "$OUT_FILE"
mkfs.vfat -F 32 -n "$LABEL" "$OUT_FILE" >/dev/null

log "размещаю EFI-stub kernel + initrd в FAT32"
mmd -i "$OUT_FILE" ::/EFI ::/EFI/Linux ::/EFI/BOOT
mcopy -i "$OUT_FILE" "$KERNEL_SRC" "::/EFI/BOOT/BOOTX64.EFI"
mcopy -i "$OUT_FILE" "$KERNEL_SRC" "::/EFI/Linux/inauto-panel.efi"
mcopy -i "$OUT_FILE" "$INITRD_SRC" "::/EFI/Linux/initrd.img"

log "готово: $OUT_FILE"
mdir -i "$OUT_FILE" "::/EFI/BOOT"
mdir -i "$OUT_FILE" "::/EFI/Linux"
