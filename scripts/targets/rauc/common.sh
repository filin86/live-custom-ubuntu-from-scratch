#!/bin/bash
# Общие helpers для сборки immutable firmware через RAUC.
#
# Подключается source'ом из build-bundle.sh, build-boot-vfat.sh,
# build-installer-image.sh и из основной build-оркестрации, когда
# TARGET_FORMAT=rauc.

set -euo pipefail

RAUC_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$RAUC_COMMON_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"

RAUC_TARGETS_DIR="$SCRIPTS_ROOT/targets/rauc"
RAUC_PROFILES_DIR="$SCRIPTS_ROOT/profiles"

export RAUC_COMMON_DIR SCRIPTS_ROOT REPO_ROOT RAUC_TARGETS_DIR RAUC_PROFILES_DIR

log() {
    echo "[rauc-target] $*"
}

fail() {
    echo "[rauc-target] ERROR: $*" >&2
    exit 1
}

# Загружает основные build-переменные репозитория.
load_repo_config() {
    if [[ ! -f "$SCRIPTS_ROOT/config.sh" ]]; then
        fail "Не найден scripts/config.sh."
    fi
    # shellcheck source=/dev/null
    . "$SCRIPTS_ROOT/config.sh"
}

# Загружает distro-profile (ubuntu/debian) с переменными LIVE_BOOT_DIR и т.п.
load_distro_profile() {
    local distro="${TARGET_DISTRO:-}"
    [[ -n "$distro" ]] || fail "TARGET_DISTRO не задан (ожидается ubuntu или debian)."

    local profile_file="$RAUC_PROFILES_DIR/$distro/profile.env"
    [[ -f "$profile_file" ]] || fail "Не найден профиль дистрибутива: $profile_file"

    # shellcheck source=/dev/null
    . "$profile_file"
}

# Проверяет обязательные для RAUC-target переменные.
require_rauc_vars() {
    [[ -n "${TARGET_DISTRO:-}" ]]   || fail "TARGET_DISTRO не задан."
    [[ -n "${TARGET_ARCH:-}" ]]     || fail "TARGET_ARCH не задан."
    [[ -n "${TARGET_PLATFORM:-}" ]] || fail "TARGET_PLATFORM не задан."
}

# Возвращает compatible-строку для текущего target'а.
# Формат: inauto-panel-<distro>-<arch>-<platform>-<RAUC_COMPATIBLE_VERSION>.
compatible() {
    require_rauc_vars
    local compatible_version="${RAUC_COMPATIBLE_VERSION:-v1}"
    [[ "$compatible_version" =~ ^v[0-9]+$ ]] \
        || fail "RAUC_COMPATIBLE_VERSION должен иметь формат v<N>, получено '$compatible_version'"
    printf 'inauto-panel-%s-%s-%s-%s\n' \
        "$TARGET_DISTRO" "$TARGET_ARCH" "$TARGET_PLATFORM" "$compatible_version"
}

# Возвращает имя RAUC bundle-артефакта для текущего target'а и версии.
artifact_name() {
    require_rauc_vars
    local version="${RAUC_BUNDLE_VERSION:-}"
    [[ -n "$version" ]] || fail "RAUC_BUNDLE_VERSION не задан."
    printf 'inauto-panel-%s-%s-%s-%s.raucb\n' \
        "$TARGET_DISTRO" "$TARGET_ARCH" "$TARGET_PLATFORM" "$version"
}

# Regex для production-версии bundle'а.
RAUC_PROD_VERSION_REGEX='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$'
# Dev-префикс разрешает локальные сборки без git-тега.
RAUC_DEV_VERSION_REGEX='^dev\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$'

# Валидирует RAUC_BUNDLE_VERSION.
# Аргумент "release" (по умолчанию) запрещает dev-версии;
# аргумент "dev-ok" разрешает dev.* для локальных сборок.
validate_rauc_version() {
    local mode="${1:-release}"
    local version="${RAUC_BUNDLE_VERSION:-}"

    if [[ -z "$version" ]]; then
        fail "RAUC_BUNDLE_VERSION не задан. Release: git tag vYYYY.MM.DD.N -> YYYY.MM.DD.N. Dev: dev.YYYY.MM.DD.N."
    fi

    if [[ "$version" =~ $RAUC_PROD_VERSION_REGEX ]]; then
        return 0
    fi

    if [[ "$mode" == "dev-ok" && "$version" =~ $RAUC_DEV_VERSION_REGEX ]]; then
        log "WARNING: используется dev-версия '$version'. Никогда не публиковать в candidate/stable."
        return 0
    fi

    fail "Недопустимое RAUC_BUNDLE_VERSION='$version'. Production: YYYY.MM.DD.N. Dev: dev.YYYY.MM.DD.N."
}

# Путь к собранному live-squashfs для текущего distro-профиля.
live_squashfs_path() {
    : "${LIVE_BOOT_DIR:?LIVE_BOOT_DIR не задан; вызовите load_distro_profile.}"
    : "${LIVE_SQUASHFS_NAME:?LIVE_SQUASHFS_NAME не задан; вызовите load_distro_profile.}"
    printf '%s\n' "$SCRIPTS_ROOT/image/$LIVE_BOOT_DIR/$LIVE_SQUASHFS_NAME"
}

# Путь к собранному kernel-образу (vmlinuz и т.п.).
live_kernel_path() {
    : "${LIVE_BOOT_DIR:?LIVE_BOOT_DIR не задан; вызовите load_distro_profile.}"
    : "${LIVE_KERNEL_NAME:?LIVE_KERNEL_NAME не задан.}"
    printf '%s\n' "$SCRIPTS_ROOT/image/$LIVE_BOOT_DIR/$LIVE_KERNEL_NAME"
}

# Путь к собранному initrd.
live_initrd_path() {
    : "${LIVE_BOOT_DIR:?LIVE_BOOT_DIR не задан; вызовите load_distro_profile.}"
    : "${LIVE_INITRD_NAME:?LIVE_INITRD_NAME не задан.}"
    printf '%s\n' "$SCRIPTS_ROOT/image/$LIVE_BOOT_DIR/$LIVE_INITRD_NAME"
}
