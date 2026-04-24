#!/bin/bash
# Собирает installer-payload для factory provisioning: tar.zst с
# install-to-disk.sh, backup-restore-home.sh, pc-efi.sgdisk, keyring.pem
# и подписанным bundle.raucb. Raw boot- и rootfs-образы в payload
# НЕ кладутся: installer после verify'а подписи монтирует bundle через
# RAUC и копирует из него efi.vfat + rootfs.img, так что подпись
# защищает именно те байты, которые физически записываются на диск.
#
# Полный bootable USB-ISO (Ubuntu live + встроенный payload) — отдельная фаза:
# после этого stage вручную прошивается обычный Ubuntu Live USB, и payload
# разворачивается в /opt/inauto-installer/ оператором.
#
# Файл payload:
#   out/inauto-panel-installer-<distro>-<arch>-<platform>-<version>.tar.zst
#
# Управляющие env-переменные:
#   OUT_DIR                     выход (по умолчанию $REPO_ROOT/out)
#   INSTALLER_KEYRING_SRC       путь к keyring.pem. Обязателен для release;
#                               dev-ok сборки по умолчанию берут pki/dev-keyring.pem.

set -euo pipefail

# shellcheck source=scripts/targets/rauc/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_repo_config
load_distro_profile
require_rauc_vars
validate_rauc_version "${RAUC_VERSION_MODE:-release}"

for tool in tar zstd sha256sum rauc; do
    command -v "$tool" >/dev/null 2>&1 || fail "не найден инструмент '$tool'."
done

OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
WORK_DIR="$(mktemp -d -t rauc-installer-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

PAYLOAD_DIR="$WORK_DIR/inauto-installer"
mkdir -p "$PAYLOAD_DIR" "$OUT_DIR"

# --- Артефакты, которые требует installer-runtime -------------------------

BUNDLE_NAME="$(artifact_name)"
BUNDLE_SRC="$OUT_DIR/$BUNDLE_NAME"
[[ -f "$BUNDLE_SRC" ]] || fail "не найден RAUC bundle: $BUNDLE_SRC. Сначала запустите build_rauc_bundle."

case "${TARGET_PLATFORM}" in
    pc-efi)
        SGDISK_SRC="$RAUC_TARGETS_DIR/partition-layout/pc-efi.sgdisk"
        INSTALLER_SRC="$RAUC_TARGETS_DIR/installer/install-to-disk.sh"
        BACKUP_SRC="$RAUC_TARGETS_DIR/installer/backup-restore-home.sh"
        GUI_SRC="$RAUC_TARGETS_DIR/installer/install-gui.sh"
        START_SRC="$RAUC_TARGETS_DIR/installer/START-INSTALLER.sh"
        DESKTOP_SRC="$RAUC_TARGETS_DIR/installer/Inauto Panel Installer.desktop"
        ;;
    *-uboot)
        fail "build-installer-image.sh: U-Boot installer ещё не реализован (Phase 10)."
        ;;
    *)
        fail "Неизвестный TARGET_PLATFORM='${TARGET_PLATFORM}'."
        ;;
esac

# Единственный источник raw-байт для установки — сам signed bundle.
# Installer сначала verify'ит подпись через keyring, затем монтирует
# bundle средствами RAUC и копирует efi.vfat + rootfs.img на целевой
# панели. Никаких отдельных raw-образов в payload'е не кладём — это
# устранило бы криптографическую связь между подписью и тем, что реально
# попадёт на disk.
cp "$BUNDLE_SRC" "$PAYLOAD_DIR/bundle.raucb"

# Keyring — обязателен: без него installer не сможет verify/mount bundle.
KEYRING_SRC="${INSTALLER_KEYRING_SRC:-}"
if [[ -z "$KEYRING_SRC" ]]; then
    if [[ "${RAUC_VERSION_MODE:-release}" == "release" ]]; then
        fail "INSTALLER_KEYRING_SRC обязателен для release-сборки installer payload."
    fi
    KEYRING_SRC="$REPO_ROOT/pki/dev-keyring.pem"
    log "WARNING: INSTALLER_KEYRING_SRC не задан; используется dev-keyring: $KEYRING_SRC"
fi
[[ -f "$KEYRING_SRC" ]] || fail "keyring не найден: $KEYRING_SRC"

log "проверяю bundle выбранным installer keyring: $KEYRING_SRC"
rauc info --keyring="$KEYRING_SRC" "$BUNDLE_SRC" >/dev/null \
    || fail "bundle $BUNDLE_SRC не верифицируется через installer keyring $KEYRING_SRC"

install -m 0644 "$KEYRING_SRC" "$PAYLOAD_DIR/keyring.pem"

# Installer executables (chmod 755 внутри payload).
install -m 0755 "$INSTALLER_SRC" "$PAYLOAD_DIR/install-to-disk.sh"
install -m 0755 "$SGDISK_SRC"    "$PAYLOAD_DIR/pc-efi.sgdisk"
install -m 0755 "$BACKUP_SRC"    "$PAYLOAD_DIR/backup-restore-home.sh"
install -m 0755 "$GUI_SRC"       "$PAYLOAD_DIR/install-gui.sh"
install -m 0755 "$START_SRC"     "$PAYLOAD_DIR/START-INSTALLER.sh"
install -m 0755 "$DESKTOP_SRC"   "$PAYLOAD_DIR/Inauto Panel Installer.desktop"

# Firmware version marker.
printf '%s\n' "$RAUC_BUNDLE_VERSION" > "$PAYLOAD_DIR/firmware-version"
compatible > "$PAYLOAD_DIR/target-compatible"

# README с инструкцией по ручной прошивке (до появления полноценного USB ISO).
cat > "$PAYLOAD_DIR/README.txt" <<'EOF_README'
Inauto panel immutable firmware installer payload.

Назначение:
  Прошить operator-панель (UEFI PC) immutable firmware'ом.

Как использовать:
  1. Загрузите панель с любого Ubuntu/Debian Live USB (UEFI).
  2. Скопируйте этот payload на live-систему и распакуйте:
       mkdir -p /opt/inauto-installer
       tar -I zstd -xf <payload>.tar.zst -C /opt
  3. Запустите мастер установки:
       /opt/inauto-installer/START-INSTALLER.sh

  Если live-система позволяет запускать .desktop файлы, можно открыть:
       /opt/inauto-installer/Inauto Panel Installer.desktop

Что делает мастер:
  - проверяет UEFI mode;
  - проверяет/предлагает установить недостающие live-инструменты;
  - показывает список fixed-дисков >= 32 GiB;
  - просит явное подтверждение перед стиранием диска;
  - сохраняет /home/inauto, если старые данные найдены;
  - показывает прогресс и предлагает reboot после успешной установки.

Управляющие переменные:
  TARGET_DEVICE=/dev/sda     явный целевой диск
  CONTAINER_STORE_SIZE=16G   размер container-store (перекрывает auto-size)
  SKIP_REBOOT=1              не перезагружать после установки
  SKIP_BACKUP=1              полностью пропустить backup/restore /home/inauto
  FORCE_YES=1                не спрашивать подтверждение перед стиранием диска
  DRY_RUN=1                  показать команды, не писать на диск
  BACKUP_DIR=/tmp/...        где хранить tar.zst старого /home/inauto
                             (default /tmp/inauto-backup — tmpfs)

Автоматический backup + restore /home/inauto:
  Installer сам ищет существующее /home/inauto с .inautolock на
  non-removable устройствах до разметки TARGET_DEVICE, архивирует его
  ДО разметки диска и распаковывает в /home/inauto/backup/ ПОСЛЕ
  установки. Skeleton (/home/inauto/{.inautolock,on_start,on_login,
  staff,log}) при этом НЕ перезаписывается.

  Если backup слишком большой для tmpfs — переопределите BACKUP_DIR
  на внешний USB. После reboot backup живёт только в /home/inauto/backup
  (tmpfs исчезает).

Аварийный ручной режим:
  sudo TARGET_DEVICE=/dev/sda /opt/inauto-installer/install-to-disk.sh

  Для unattended-запуска:
  sudo FORCE_YES=1 TARGET_DEVICE=/dev/sda /opt/inauto-installer/install-to-disk.sh
EOF_README

# --- Упаковка -------------------------------------------------------------

ARTIFACT_BASE="inauto-panel-installer-${TARGET_DISTRO}-${TARGET_ARCH}-${TARGET_PLATFORM}-${RAUC_BUNDLE_VERSION}"
ARTIFACT="$OUT_DIR/${ARTIFACT_BASE}.tar.zst"

log "упаковываю payload в $ARTIFACT"
rm -f "$ARTIFACT"
tar -C "$WORK_DIR" -cf - inauto-installer | zstd -T0 -19 -o "$ARTIFACT"

log "считаю sha256"
(cd "$OUT_DIR" && sha256sum "${ARTIFACT_BASE}.tar.zst" > "${ARTIFACT_BASE}.tar.zst.sha256")

log "готово: $ARTIFACT"
