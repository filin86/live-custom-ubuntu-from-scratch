#!/bin/bash
# Собирает и подписывает RAUC bundle (.raucb) для TARGET_FORMAT=rauc.
#
# Требования (должны быть выполнены предыдущими stage'ами build.sh):
#   - scripts/image/<LIVE_BOOT_DIR>/<LIVE_SQUASHFS_NAME>  (build_iso до xorriso или build_rauc_bundle prep);
#   - scripts/image/<LIVE_BOOT_DIR>/<LIVE_KERNEL_NAME>    (chr_build_image);
#   - scripts/image/<LIVE_BOOT_DIR>/<LIVE_INITRD_NAME>    (chr_build_image);
#   - RAUC_BUNDLE_VERSION (от CI/пользователя; production regex валидируется);
#   - RAUC_SIGNING_CERT/RAUC_SIGNING_KEY for release builds.
#     dev-ok builds may fall back to pki/dev-signing.*.
#
# Результат:
#   out/<artifact_name>  (по умолчанию rel. к REPO_ROOT/out).

set -euo pipefail

# shellcheck source=scripts/targets/rauc/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_repo_config
load_distro_profile
require_rauc_vars
validate_rauc_version "${RAUC_VERSION_MODE:-release}"

for tool in rauc openssl; do
    command -v "$tool" >/dev/null 2>&1 || fail "не найден инструмент '$tool'."
done

OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
WORK_DIR="$(mktemp -d -t rauc-bundle-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"

SQUASHFS_SRC="$(live_squashfs_path)"
[[ -f "$SQUASHFS_SRC" ]] || fail "не найден rootfs squashfs: $SQUASHFS_SRC (нужен build_iso до xorriso или отдельный prepare_rootfs_image)."

COMPAT="$(compatible)"
ARTIFACT="$OUT_DIR/$(artifact_name)"

log "подготовка bundle workdir: $WORK_DIR"
cp "$SQUASHFS_SRC" "$WORK_DIR/rootfs.img"

case "${TARGET_PLATFORM}" in
    pc-efi)
        # Bundle = только rootfs.img: kernel/initrd + grub-slot.cfg лежат внутри
        # squashfs (/boot), их читает единый GRUB с раздела efi_A (boot.vfat
        # собирается build-boot-grub.sh и ставится заводским инсталлятором).
        manifest_tmpl="$RAUC_TARGETS_DIR/manifest-efi.raucm.template"
        ;;
    *-uboot)
        fail "build-bundle.sh: U-Boot bundle ещё не реализован (Phase 10)."
        ;;
    *)
        fail "Неизвестный TARGET_PLATFORM='${TARGET_PLATFORM}'."
        ;;
esac

[[ -f "$manifest_tmpl" ]] || fail "manifest template не найден: $manifest_tmpl"

# Build-id — информативные метаданные сборки (поле Build в `rauc info`), НЕ версия.
# По умолчанию git describe; при недоступности git — падаем на версию bundle.
# CI может переопределить через RAUC_BUILD_ID (например, номер pipeline).
RAUC_BUILD_ID="${RAUC_BUILD_ID:-$(git -C "$REPO_ROOT" describe --always --dirty --tags 2>/dev/null || true)}"
[[ -n "$RAUC_BUILD_ID" ]] || RAUC_BUILD_ID="$RAUC_BUNDLE_VERSION"

log "рендерю manifest.raucm (build=$RAUC_BUILD_ID)"
sed \
    -e "s|@COMPATIBLE@|$COMPAT|g" \
    -e "s|@RAUC_BUNDLE_VERSION@|$RAUC_BUNDLE_VERSION|g" \
    -e "s|@RAUC_BUILD_ID@|$RAUC_BUILD_ID|g" \
    "$manifest_tmpl" > "$WORK_DIR/manifest.raucm"

SIGN_CERT="${RAUC_SIGNING_CERT:-}"
SIGN_KEY="${RAUC_SIGNING_KEY:-}"
INTERMEDIATE="${RAUC_INTERMEDIATE_CERT:-}"
if [[ -z "$SIGN_CERT" || -z "$SIGN_KEY" ]]; then
    if [[ "${RAUC_VERSION_MODE:-release}" == "release" ]]; then
        fail "RAUC_SIGNING_CERT и RAUC_SIGNING_KEY обязательны для release-сборки."
    fi
    SIGN_CERT="$REPO_ROOT/pki/dev-signing.crt"
    SIGN_KEY="$REPO_ROOT/pki/dev-signing.key"
    log "WARNING: RAUC_SIGNING_CERT/KEY не заданы; используется dev signing cert: $SIGN_CERT"
fi

[[ -f "$SIGN_CERT" ]] || fail "signing cert не найден: $SIGN_CERT"
[[ -f "$SIGN_KEY" ]]  || fail "signing key не найден: $SIGN_KEY"

if [[ "${RAUC_VERSION_MODE:-release}" == "release" ]]; then
    min_days="${RAUC_SIGNING_CERT_MIN_DAYS:-1095}"
    [[ "$min_days" =~ ^[0-9]+$ ]] || fail "RAUC_SIGNING_CERT_MIN_DAYS должен быть числом дней."
    if ! openssl x509 -in "$SIGN_CERT" -checkend "$((min_days * 86400))" -noout >/dev/null; then
        fail "production signing cert истекает раньше чем через $min_days дней: $SIGN_CERT"
    fi
fi

rauc_args=(bundle "--cert=$SIGN_CERT" "--key=$SIGN_KEY")
if [[ -n "$INTERMEDIATE" ]]; then
    [[ -f "$INTERMEDIATE" ]] || fail "intermediate cert не найден: $INTERMEDIATE"
    rauc_args+=("--intermediate=$INTERMEDIATE")
fi
rauc_args+=("$WORK_DIR" "$ARTIFACT")

log "подписываю bundle: $ARTIFACT (signing cert: $SIGN_CERT)"
rm -f "$ARTIFACT"
rauc "${rauc_args[@]}"

log "готово: $ARTIFACT"

# Контрольная сумма рядом с bundle. Пишем basename (а не полный путь), чтобы
# `sha256sum -c <bundle>.sha256` работал из каталога с bundle — как в
# docs/runbooks/update-from-raucb.md и в панельном скрипте panel-update.
log "генерирую SHA256 контрольную сумму"
(
    cd "$OUT_DIR"
    sha256sum "$(basename "$ARTIFACT")" > "$(basename "$ARTIFACT").sha256"
)
log "готово: $ARTIFACT.sha256"

# boot.vfat — образ загрузочного раздела (единый GRUB + grubenv). Релизный
# артефакт: нужен заводскому инсталлятору и миграции v1->v2 через panel-update
# (dd в efi_A/efi_B). Собирается детерминированно, версии не имеет.
if [[ "${TARGET_PLATFORM}" == "pc-efi" ]]; then
    log "собираю boot.vfat (GRUB standalone)"
    "$RAUC_TARGETS_DIR/build-boot-grub.sh" "$OUT_DIR"
    (
        cd "$OUT_DIR"
        sha256sum boot.vfat > boot.vfat.sha256
    )
    log "готово: $OUT_DIR/boot.vfat (+ .sha256)"
fi

rauc info --keyring="$REPO_ROOT/pki/dev-keyring.pem" "$ARTIFACT" || \
    log "WARNING: не удалось verify bundle локальным dev-keyring'ом (возможно подписан prod-ключом)"
