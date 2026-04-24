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
RAUC_COMPATIBLE_VERSION="${RAUC_COMPATIBLE_VERSION:-v1}"
DOCKER_RUN_NETWORK="${DOCKER_RUN_NETWORK:-}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-}"
LIVECD_APT_CACHE_VOLUME="${LIVECD_APT_CACHE_VOLUME:-$(basename "$REPO_ROOT")-apt-cache-${TARGET_DISTRO}}"
LIVECD_KEEP_APT_CACHE="${LIVECD_KEEP_APT_CACHE:-1}"
clean_apt_cache="${CLEAN_APT_CACHE:-0}"
CLEAN_CACHE_ARGS=()

function usage() {
    cat <<'EOF'
Build the complete RAUC factory installer:
  1. panel RAUC bundle + installer payload
  2. separate factory installer live ISO

Usage:
  RAUC_BUNDLE_VERSION=<version> ./scripts/build-rauc-installer.sh [--clean-cache]

Options:
  --clean-cache  Remove the shared APT package cache before phase 1 only.
                 Phase 2 reuses the same warmed cache, and later builds reuse it too.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-cache)
            clean_apt_cache=1
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
echo "=====> shared APT cache volume: $LIVECD_APT_CACHE_VOLUME (clean before phase 1: $clean_apt_cache)"
(
    cd "$REPO_ROOT"
    env \
        "${common_env[@]}" \
        CLEAN_APT_CACHE=0 \
        TARGET_FORMAT=rauc \
        INAUTO_IMAGE_ROLE=panel \
        LIVECD_CHROOT_VOLUME="$target_volume" \
        ./scripts/build-in-docker.sh --clean "${CLEAN_CACHE_ARGS[@]}" -
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
