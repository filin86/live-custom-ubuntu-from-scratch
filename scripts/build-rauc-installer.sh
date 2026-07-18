#!/bin/bash
# Full two-phase RAUC factory build:
#   1. build the immutable panel bundle + payload from the panel rootfs
#   2. build a separate live installer ISO rootfs and embed that payload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_DISTRO="${TARGET_DISTRO:-ubuntu}"
INSTALLER_PROFILE="${INSTALLER_PROFILE:-ubuntu-installer}"
TARGET_PLATFORM="${TARGET_PLATFORM:-pc-efi}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
RAUC_VERSION_MODE="${RAUC_VERSION_MODE:-release}"
RAUC_PINNED_VERSION="${RAUC_PINNED_VERSION:-1.15.2}"
# v2 = GRUB-схема выбора слота (см. docs/2026-07-04-grub-boot-selection-design.md);
# держать в синхроне с дефолтом в scripts/config.sh.
RAUC_COMPATIBLE_VERSION="${RAUC_COMPATIBLE_VERSION:-v2}"
DOCKER_RUN_NETWORK="${DOCKER_RUN_NETWORK:-}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-}"
# Фиксированное имя (livecd-*, не по basename REPO_ROOT) — общий .deb-кэш для всех
# worktree/клонов проекта, чтобы не качать пакеты заново в каждом worktree.
LIVECD_APT_CACHE_VOLUME="${LIVECD_APT_CACHE_VOLUME:-livecd-apt-cache-${TARGET_DISTRO}}"
LIVECD_KEEP_APT_CACHE="${LIVECD_KEEP_APT_CACHE:-1}"
clean_apt_cache="${CLEAN_APT_CACHE:-0}"
rebuild_builder="${REBUILD_BUILDER:-0}"
CLEAN_CACHE_ARGS=()
REBUILD_BUILDER_ARGS=()

function usage() {
    cat <<'EOF'
Build the complete RAUC factory installer:
  1. panel RAUC bundle + installer payload
  2. separate factory installer live ISO

Usage:
  RAUC_BUNDLE_VERSION=<version> ./scripts/build-rauc-installer.sh [--clean-cache] [--rebuild-builder]

Options:
  --clean-cache      Remove cache volumes (APT + Trivy) and prune stale project
                     build volumes (chroot/trivy/apt of other repos/worktrees;
                     current chroot kept) before phase 1.
                     Phase 2 reuses the same warmed cache, and later builds reuse it too.
  --rebuild-builder  Rebuild the builder Docker image before phase 1 (needed after
                     docker/Builder.Dockerfile changes). Phase 2 reuses the rebuilt image.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-cache)
            clean_apt_cache=1
            shift
            ;;
        --rebuild-builder)
            rebuild_builder=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            >&2 echo "ERROR: unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

case "$clean_apt_cache" in
    1|true|yes)
        clean_apt_cache=1
        CLEAN_CACHE_ARGS=(--clean-cache)
        ;;
    0|false|no|"")
        clean_apt_cache=0
        CLEAN_CACHE_ARGS=()
        ;;
    *)
        >&2 echo "ERROR: CLEAN_APT_CACHE must be one of: 0, 1, true, false, yes, no"
        exit 1
        ;;
esac

case "$rebuild_builder" in
    1|true|yes)
        rebuild_builder=1
        # Пересборка только перед phase 1: обе фазы используют один builder-образ
        # (livecd-builder-${TARGET_DISTRO}:local), phase 2 берёт уже свежий.
        REBUILD_BUILDER_ARGS=(--rebuild-builder)
        ;;
    0|false|no|"")
        rebuild_builder=0
        REBUILD_BUILDER_ARGS=()
        ;;
    *)
        >&2 echo "ERROR: REBUILD_BUILDER must be one of: 0, 1, true, false, yes, no"
        exit 1
        ;;
esac

if [[ -z "$LIVECD_APT_CACHE_VOLUME" || "$LIVECD_APT_CACHE_VOLUME" == "none" ]]; then
    >&2 echo "ERROR: build-rauc-installer.sh requires a shared LIVECD_APT_CACHE_VOLUME."
    >&2 echo "       Use a named Docker volume so phase 2 and repeated builds reuse downloaded packages."
    exit 1
fi

if [[ -z "${RAUC_BUNDLE_VERSION:-}" ]]; then
    >&2 echo "ERROR: RAUC_BUNDLE_VERSION is required."
    >&2 echo "Example: RAUC_BUNDLE_VERSION=dev.2026.04.21.1 RAUC_VERSION_MODE=dev-ok $0 --clean-cache"
    exit 1
fi

if [[ ! "$INSTALLER_PROFILE" =~ ^[A-Za-z0-9._-]+$ ]]; then
    >&2 echo "ERROR: INSTALLER_PROFILE contains unsupported characters: '$INSTALLER_PROFILE'"
    exit 1
fi

build_id="${TARGET_DISTRO}-${TARGET_ARCH}-${TARGET_PLATFORM}-${RAUC_BUNDLE_VERSION}"
target_volume="${LIVECD_TARGET_CHROOT_VOLUME:-livecd-${build_id}-target}"
installer_volume="${LIVECD_INSTALLER_CHROOT_VOLUME:-livecd-${build_id}-${INSTALLER_PROFILE}-installer}"

# Per-version chroot-тома фаз — одноразовый scratch: имя содержит версию (никогда
# не переиспользуется, фазы идут с --clean), артефакты уже в out/. Удаляем на
# выходе, иначе на КАЖДУЮ сборку копится ~7 ГБ (это и был источник переполнения
# диска сборочного ПК). KEEP_BUILD_VOLUMES=1 — оставить (отладка);
# DOCKER_USE_SUDO=1 — если docker вызывается через sudo.
DOCKER_BIN="${DOCKER_BIN:-docker}"
_docker_cli=("$DOCKER_BIN")
[[ "${DOCKER_USE_SUDO:-auto}" == "1" ]] && _docker_cli=(sudo "$DOCKER_BIN")
cleanup_build_volumes() {
    [[ "${KEEP_BUILD_VOLUMES:-0}" == "1" ]] && return 0
    local vol
    for vol in "$target_volume" "$installer_volume"; do
        if "${_docker_cli[@]}" volume inspect "$vol" >/dev/null 2>&1; then
            "${_docker_cli[@]}" volume rm -f "$vol" >/dev/null 2>&1 \
                && echo "=====> removed per-version build volume: $vol" \
                || echo "WARNING: не удалось удалить том $vol (занят?)" >&2
        fi
    done
}
trap cleanup_build_volumes EXIT

common_env=(
    "TARGET_DISTRO=$TARGET_DISTRO"
    "TARGET_PLATFORM=$TARGET_PLATFORM"
    "TARGET_ARCH=$TARGET_ARCH"
    "RAUC_COMPATIBLE_VERSION=$RAUC_COMPATIBLE_VERSION"
    "RAUC_BUNDLE_VERSION=$RAUC_BUNDLE_VERSION"
    "RAUC_VERSION_MODE=$RAUC_VERSION_MODE"
    "RAUC_PINNED_VERSION=$RAUC_PINNED_VERSION"
    "LIVECD_APT_CACHE_VOLUME=$LIVECD_APT_CACHE_VOLUME"
    "LIVECD_KEEP_APT_CACHE=$LIVECD_KEEP_APT_CACHE"
)

if [[ -n "$DOCKER_RUN_NETWORK" ]]; then
    common_env+=("DOCKER_RUN_NETWORK=$DOCKER_RUN_NETWORK")
fi
if [[ -n "$DOCKER_BUILD_NETWORK" ]]; then
    common_env+=("DOCKER_BUILD_NETWORK=$DOCKER_BUILD_NETWORK")
fi

echo "=====> phase 1/2: build panel RAUC bundle + installer payload"
echo "=====> shared APT cache volume: $LIVECD_APT_CACHE_VOLUME (clean before phase 1: $clean_apt_cache, rebuild builder: $rebuild_builder)"
(
    cd "$REPO_ROOT"
    env \
        "${common_env[@]}" \
        CLEAN_APT_CACHE=0 \
        TARGET_FORMAT=rauc \
        INAUTO_IMAGE_ROLE=panel \
        LIVECD_CHROOT_VOLUME="$target_volume" \
        ./scripts/build-in-docker.sh --clean "${CLEAN_CACHE_ARGS[@]}" "${REBUILD_BUILDER_ARGS[@]}" -
)

echo "=====> phase 2/2: build separate factory installer ISO"
(
    cd "$REPO_ROOT"
    env \
        "${common_env[@]}" \
        CLEAN_APT_CACHE=0 \
        TARGET_FORMAT=iso \
        INAUTO_IMAGE_ROLE=factory-installer \
        TARGET_PROFILE="$INSTALLER_PROFILE" \
        TARGET_NAME=inauto-factory-installer-live \
        LIVECD_CHROOT_VOLUME="$installer_volume" \
        ./scripts/build-in-docker.sh --clean -
)

echo "=====> done"
echo "Installer ISO:"
echo "  $REPO_ROOT/out/inauto-panel-installer-${TARGET_DISTRO}-${TARGET_ARCH}-${TARGET_PLATFORM}-${RAUC_BUNDLE_VERSION}.iso"
