#!/bin/bash
# Собирает boot.vfat — образ загрузочного раздела (пишется в efi_A, копия —
# в efi_B как резерв; раскладка GPT НЕ меняется относительно v1):
#   \EFI\BOOT\BOOTX64.EFI  — GRUB standalone (все модули в memdisk)
#   \grub.cfg              — логика выбора RAUC-слота (targets/rauc/grub/grub.cfg)
#   \grubenv               — преднастроенное окружение (ORDER/OK/TRY)
#
# Прошивка панели регенерирует BootOrder на каждом POST, поэтому выбор слота
# перенесён из UEFI NVRAM в GRUB (см. docs/2026-07-04-grub-boot-selection-design.md).
# Kernel/initrd GRUB читает из squashfs rootfs-раздела слота — этот образ
# статичен, OTA его не трогает.
#
# Всё без root: mkfs.vfat + mtools, как в build-boot-vfat.sh.
#
# Вызов:
#   ./build-boot-grub.sh <OUT_DIR>
# Выход:
#   <OUT_DIR>/boot.vfat

set -euo pipefail

# shellcheck source=scripts/targets/rauc/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_repo_config
load_distro_profile
require_rauc_vars

OUT_DIR="${1:-${OUT_DIR:-}}"
[[ -n "$OUT_DIR" ]] || fail "укажите OUT_DIR первым аргументом или через env."
mkdir -p "$OUT_DIR"

BOOT_VFAT_SIZE_MIB="${BOOT_VFAT_SIZE_MIB:-128}"
BOOT_FAT_LABEL="INAUTOBOOT"   # embedded-конфиг GRUB ищет раздел по этой метке
GRUB_CFG_SRC="$RAUC_TARGETS_DIR/grub/grub.cfg"

case "${TARGET_PLATFORM}" in
    pc-efi) ;;
    *) fail "build-boot-grub.sh поддерживает только pc-efi (получено '${TARGET_PLATFORM}')." ;;
esac

for tool in grub-mkstandalone grub-editenv mkfs.vfat mmd mcopy mlabel truncate; do
    command -v "$tool" >/dev/null 2>&1 || fail "не найден инструмент '$tool' (нужны grub-common, grub-efi-amd64-bin, dosfstools, mtools)."
done

[[ -f "$GRUB_CFG_SRC" ]] || fail "grub.cfg не найден: $GRUB_CFG_SRC"

WORK_DIR="$(mktemp -d -t boot-grub-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Embedded-конфиг standalone-образа: найти раздел загрузчика и передать
# управление основному /grub.cfg. Модули остаются в memdisk ($prefix не трогаем).
#
# Порядок поиска (проверено в QEMU/OVMF):
#  1. \$cmdpath — раздел, с которого прошивка ФАКТИЧЕСКИ загрузила BOOTX64.EFI
#     (вид "(hdX,gptY)/EFI/BOOT"). Самый надёжный источник: не зависит от
#     количества дисков и нумерации (у панелей бывает второй диск с Windows).
#  2. Перебор (hdX,gpt1) по маркерам нашего образа (/grub.cfg + /grubenv).
#  3. search по FAT-метке (метку в корневой каталог кладёт mlabel ниже;
#     mkfs.vfat -n пишет её только в boot-сектор, который GRUB не читает).
# ВАЖНО: при неудаче search переменная root остаётся "memdisk" (standalone),
# поэтому проверять её на пустоту нельзя — сначала явно очищаем.
# sleep --interruptible: ESC прерывает ожидание и оставляет консоль GRUB
# для полевой диагностики.
cat > "$WORK_DIR/early.cfg" <<EOF_EARLY
set root=
regexp --set=bootdev '^\\(([^)]+)\\)' "\$cmdpath"
if [ -n "\$bootdev" ]; then
    if [ -e (\$bootdev)/grub.cfg -a -e (\$bootdev)/grubenv ]; then
        set root=(\$bootdev)
    fi
fi
if [ -z "\$root" ]; then
    for d in hd0 hd1 hd2 hd3; do
        if [ -e (\$d,gpt1)/grub.cfg -a -e (\$d,gpt1)/grubenv ]; then
            set root=(\$d,gpt1)
            break
        fi
    done
fi
if [ -z "\$root" ]; then
    search --no-floppy --label $BOOT_FAT_LABEL --set=root
fi
if [ -z "\$root" -o "\$root" = "memdisk" ]; then
    echo "inauto: раздел загрузчика не найден (cmdpath=\$cmdpath)"
    echo "inauto: перезагрузка через 30 секунд (ESC — консоль GRUB)"
    if sleep --interruptible 30; then
        reboot
    fi
else
    configfile (\$root)/grub.cfg
fi
EOF_EARLY

# Preload-модули. КРИТИЧНО: модули partition map (part_gpt) GRUB НЕ
# автозагружает — без явного preload (hdX,gptN) даёт "disk not found",
# search не видит ФС внутри разделов, и панель падает в консоль grub>
# (воспроизведено и проверено в QEMU/OVMF). Остальные — детерминированный
# preload всего, что используют early.cfg и grub.cfg; зависимости
# (например, xzio для squash4) grub-mkstandalone дорезолвит по moddep.lst.
GRUB_PRELOAD_MODULES="part_gpt fat search search_label test regexp loadenv squash4 xzio gzio linux boot echo sleep reboot normal configfile"

log "собираю GRUB standalone (x86_64-efi; preload: $GRUB_PRELOAD_MODULES)"
grub-mkstandalone \
    -O x86_64-efi \
    --modules="$GRUB_PRELOAD_MODULES" \
    -o "$WORK_DIR/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$WORK_DIR/early.cfg"

[[ -s "$WORK_DIR/BOOTX64.EFI" ]] || fail "grub-mkstandalone не создал BOOTX64.EFI"

# Преднастроенный grubenv: оба слота считаются исправными, порядок A->B.
# Заводской инсталлятор пишет оба слота одинаковым bundle'ом, так что любой
# исход первой загрузки корректен.
log "генерирую grubenv (ORDER=\"system0 system1\")"
grub-editenv "$WORK_DIR/grubenv" create
grub-editenv "$WORK_DIR/grubenv" set \
    ORDER="system0 system1" \
    system0_OK=1 system1_OK=1 \
    system0_TRY=0 system1_TRY=0

OUT_FILE="$OUT_DIR/boot.vfat"
log "создаю $OUT_FILE (${BOOT_VFAT_SIZE_MIB} MiB, метка $BOOT_FAT_LABEL)"
rm -f "$OUT_FILE"
truncate -s "${BOOT_VFAT_SIZE_MIB}M" "$OUT_FILE"
mkfs.vfat -F 32 -n "$BOOT_FAT_LABEL" "$OUT_FILE" >/dev/null
# mkfs.vfat -n пишет метку только в boot-сектор; GRUB же читает метку из записи
# корневого каталога — её создаёт mlabel. Без этого search --label не работает.
mlabel -i "$OUT_FILE" "::$BOOT_FAT_LABEL"

mmd -i "$OUT_FILE" ::/EFI ::/EFI/BOOT
mcopy -i "$OUT_FILE" "$WORK_DIR/BOOTX64.EFI" "::/EFI/BOOT/BOOTX64.EFI"
mcopy -i "$OUT_FILE" "$GRUB_CFG_SRC"         "::/grub.cfg"
mcopy -i "$OUT_FILE" "$WORK_DIR/grubenv"     "::/grubenv"

log "готово: $OUT_FILE"
mdir -i "$OUT_FILE" "::/EFI/BOOT"
mdir -i "$OUT_FILE" "::/"
