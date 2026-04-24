#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_USE_SUDO="${DOCKER_USE_SUDO:-auto}"
# Read TARGET_DISTRO from config or caller environment (before container starts).
TARGET_DISTRO_FROM_CONFIG=$(
    set +u
    [[ -f "$REPO_ROOT/scripts/config.sh" ]] && source "$REPO_ROOT/scripts/config.sh" 2>/dev/null || true
    echo "${TARGET_DISTRO:-ubuntu}"
)
TARGET_DISTRO="${TARGET_DISTRO:-$TARGET_DISTRO_FROM_CONFIG}"
TARGET_PROFILE_FROM_CONFIG=$(
    set +u
    TARGET_DISTRO="${TARGET_DISTRO:-ubuntu}"
    [[ -f "$REPO_ROOT/scripts/config.sh" ]] && source "$REPO_ROOT/scripts/config.sh" 2>/dev/null || true
    echo "${TARGET_PROFILE:-${TARGET_DISTRO:-ubuntu}}"
)
TARGET_PROFILE="${TARGET_PROFILE:-$TARGET_PROFILE_FROM_CONFIG}"

if [[ ! "$TARGET_PROFILE" =~ ^[A-Za-z0-9._-]+$ ]]; then
    >&2 echo "ERROR: TARGET_PROFILE contains unsupported characters: '$TARGET_PROFILE'"
    exit 1
fi

case "$TARGET_DISTRO" in
    ubuntu) BASE_IMAGE_DEFAULT="ubuntu:24.04" ;;
    debian) BASE_IMAGE_DEFAULT="debian:trixie" ;;
    *) >&2 echo "ERROR: unknown TARGET_DISTRO='$TARGET_DISTRO'"; exit 1 ;;
esac

BASE_IMAGE="${BASE_IMAGE:-$BASE_IMAGE_DEFAULT}"
RAUC_PINNED_VERSION="${RAUC_PINNED_VERSION:-1.15.2}"
BUILDER_IMAGE="${BUILDER_IMAGE:-livecd-builder-${TARGET_DISTRO}-rauc${RAUC_PINNED_VERSION}:local}"
BUILDER_PLATFORM="${BUILDER_PLATFORM:-linux/amd64}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-$REPO_ROOT/docker/Builder.Dockerfile}"
REBUILD_BUILDER="${REBUILD_BUILDER:-0}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
CLEAN_APT_CACHE="${CLEAN_APT_CACHE:-0}"
CHOWN_OUTPUTS="${CHOWN_OUTPUTS:-1}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
REPO_NAME="$(basename "$REPO_ROOT")"
LIVECD_CHROOT_VOLUME="${LIVECD_CHROOT_VOLUME:-${REPO_NAME}-chroot-${TARGET_PROFILE}}"
TRIVY_CACHE_VOLUME="${TRIVY_CACHE_VOLUME:-${REPO_NAME}-trivy-cache}"
LIVECD_APT_CACHE_VOLUME="${LIVECD_APT_CACHE_VOLUME:-${REPO_NAME}-apt-cache-${TARGET_DISTRO}}"
LIVECD_KEEP_APT_CACHE="${LIVECD_KEEP_APT_CACHE:-1}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-}"
DOCKER_RUN_NETWORK="${DOCKER_RUN_NETWORK:-}"
HOST_CA_BUNDLE="${HOST_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
DOCKER_CMD=()

function require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        >&2 echo "ERROR: required command not found: $cmd"
        exit 1
    fi
}

function require_sudo() {
    if ! command -v sudo >/dev/null 2>&1; then
        >&2 echo "ERROR: sudo is required to access Docker from this user."
        exit 1
    fi
}

function docker_access_error() {
    local output="$1"
    [[ "$output" == *"permission denied"* && "$output" == *"docker"* ]]
}

function init_docker_cmd() {
    local probe_output

    require_command "$DOCKER_BIN"

    case "$DOCKER_USE_SUDO" in
        1|true|yes)
            require_sudo
            DOCKER_CMD=(sudo "$DOCKER_BIN")
            return 0
            ;;
        0|false|no)
            DOCKER_CMD=("$DOCKER_BIN")
            return 0
            ;;
        auto)
            ;;
        *)
            >&2 echo "ERROR: DOCKER_USE_SUDO must be one of: auto, 0, 1"
            exit 1
            ;;
    esac

    if probe_output=$("$DOCKER_BIN" version >/dev/null 2>&1); then
        DOCKER_CMD=("$DOCKER_BIN")
        return 0
    fi

    probe_output=$("$DOCKER_BIN" version 2>&1 >/dev/null || true)
    if docker_access_error "$probe_output"; then
        require_sudo
        echo "Docker daemon requires elevated access for this user. Re-running Docker commands through sudo."
        DOCKER_CMD=(sudo "$DOCKER_BIN")
        return 0
    fi

    >&2 echo "ERROR: unable to access Docker using '$DOCKER_BIN'."
    if [[ -n "$probe_output" ]]; then
        >&2 printf '%s\n' "$probe_output"
    fi
    exit 1
}

function usage() {
    cat <<'EOF'
Build the live ISO inside a privileged Docker builder container.

Usage:
  ./scripts/build-in-docker.sh [--rebuild-builder] [--clean-cache] [--shell] [--] [build.sh args...]

Examples:
  ./scripts/build-in-docker.sh -
  ./scripts/build-in-docker.sh --clean debootstrap - build_iso
  ./scripts/build-in-docker.sh --clean --clean-cache -
  ./scripts/build-in-docker.sh debootstrap - build_iso
  BUILDER_PLATFORM=linux/amd64 ./scripts/build-in-docker.sh -

Environment overrides:
  DOCKER_BIN            docker CLI binary to use
  DOCKER_USE_SUDO       auto, 0, or 1; default auto
  BUILDER_IMAGE         Docker image tag for the builder
  BUILDER_PLATFORM      Builder container platform, default linux/amd64
  DOCKERFILE_PATH       Path to docker/Builder.Dockerfile
  REBUILD_BUILDER       Set to 1 to force a builder image rebuild
  CLEAN_BUILD           Set to 1 to remove scripts/chroot, scripts/image, and the chroot volume before building
  CLEAN_APT_CACHE       Set to 1 to remove the APT cache volume before building
  LIVECD_CHROOT_VOLUME  Named volume used for scripts/chroot
  LIVECD_APT_CACHE_VOLUME
                        Named volume used for cached .deb packages. Set to 'none' to disable.
  LIVECD_KEEP_APT_CACHE Keep downloaded .deb packages after chroot package install; default 1
  TRIVY_CACHE_VOLUME    Named volume used for the Trivy database
  DOCKER_BUILD_NETWORK  Optional network mode for 'docker build' (for example: host)
  DOCKER_RUN_NETWORK    Optional network mode for 'docker run' (for example: host)
  HOST_CA_BUNDLE       Optional CA bundle path copied into builder image
  CHOWN_OUTPUTS         Set to 0 to keep container-owned reports/ISO artifacts
  BASE_IMAGE            Override base image for the builder (default depends on TARGET_DISTRO)
  TARGET_DISTRO         ubuntu | debian — target OS and builder base image
  TARGET_PROFILE        Build profile directory under scripts/profiles; default follows TARGET_DISTRO
  TARGET_NAME           Live ISO volume/hostname name for ISO-role builds
  INAUTO_IMAGE_ROLE     panel | factory-installer — factory-installer builds a separate RAUC provisioning live ISO
  RAUC_PINNED_VERSION   RAUC version built from upstream source; default 1.15.2
EOF
}

function clean_build_state() {
    local chroot_path
    local image_path

    chroot_path="$REPO_ROOT/scripts/chroot"
    image_path="$REPO_ROOT/scripts/image"

    echo "Cleaning previous build state..."

    rm -rf "$image_path" "$chroot_path"
    mkdir -p "$chroot_path"

    if "${DOCKER_CMD[@]}" volume inspect "$LIVECD_CHROOT_VOLUME" >/dev/null 2>&1; then
        "${DOCKER_CMD[@]}" volume rm -f "$LIVECD_CHROOT_VOLUME" >/dev/null
    fi
}

function clean_apt_cache_state() {
    if [[ -z "$LIVECD_APT_CACHE_VOLUME" || "$LIVECD_APT_CACHE_VOLUME" == "none" ]]; then
        echo "APT cache volume is disabled; nothing to clean."
        return 0
    fi

    echo "Cleaning APT cache volume: $LIVECD_APT_CACHE_VOLUME"
    if "${DOCKER_CMD[@]}" volume inspect "$LIVECD_APT_CACHE_VOLUME" >/dev/null 2>&1; then
        "${DOCKER_CMD[@]}" volume rm -f "$LIVECD_APT_CACHE_VOLUME" >/dev/null
    else
        echo "APT cache volume does not exist yet: $LIVECD_APT_CACHE_VOLUME"
    fi
}

OPEN_SHELL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --rebuild-builder)
            REBUILD_BUILDER=1
            shift
            ;;
        --clean)
            CLEAN_BUILD=1
            shift
            ;;
        --clean-cache)
            CLEAN_APT_CACHE=1
            shift
            ;;
        --shell)
            OPEN_SHELL=1
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            if [[ "$1" == --* ]]; then
                >&2 echo "ERROR: unknown option: $1"
                usage >&2
                exit 1
            fi
            break
            ;;
    esac
done

if [[ ! -f "$DOCKERFILE_PATH" ]]; then
    >&2 echo "ERROR: builder Dockerfile not found at $DOCKERFILE_PATH"
    exit 1
fi

init_docker_cmd

if [[ "$CLEAN_BUILD" == "1" ]]; then
    clean_build_state
fi

if [[ "$CLEAN_APT_CACHE" == "1" ]]; then
    clean_apt_cache_state
fi

BUILD_NETWORK_ARGS=()
RUN_NETWORK_ARGS=()
BUILD_SECRET_ARGS=()
APT_CACHE_VOLUME_ARGS=()
APT_CACHE_DIR_IN_CONTAINER=""

if [[ -n "$DOCKER_BUILD_NETWORK" ]]; then
    BUILD_NETWORK_ARGS=(--network "$DOCKER_BUILD_NETWORK")
fi

if [[ -n "$DOCKER_RUN_NETWORK" ]]; then
    RUN_NETWORK_ARGS=(--network "$DOCKER_RUN_NETWORK")
fi

if [[ -r "$HOST_CA_BUNDLE" ]]; then
    BUILD_SECRET_ARGS=(--secret "id=host_ca_bundle,src=$HOST_CA_BUNDLE")
fi

if [[ -n "$LIVECD_APT_CACHE_VOLUME" && "$LIVECD_APT_CACHE_VOLUME" != "none" ]]; then
    APT_CACHE_DIR_IN_CONTAINER="/var/cache/livecd-apt/archives"
    APT_CACHE_VOLUME_ARGS=(-v "$LIVECD_APT_CACHE_VOLUME:$APT_CACHE_DIR_IN_CONTAINER")
fi

if [[ "$REBUILD_BUILDER" == "1" ]] || ! "${DOCKER_CMD[@]}" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    "${DOCKER_CMD[@]}" build \
        --pull \
        --platform "$BUILDER_PLATFORM" \
        "${BUILD_NETWORK_ARGS[@]}" \
        "${BUILD_SECRET_ARGS[@]}" \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg RAUC_PINNED_VERSION="$RAUC_PINNED_VERSION" \
        -t "$BUILDER_IMAGE" \
        -f "$DOCKERFILE_PATH" \
        "$REPO_ROOT"
fi

DOCKER_TTY=()
if [[ -t 0 && -t 1 ]]; then
    DOCKER_TTY=(-it)
fi

if [[ "$OPEN_SHELL" == "1" ]]; then
    set -- /bin/bash
elif [[ $# -eq 0 ]]; then
    set -- ./scripts/build.sh -
else
    set -- ./scripts/build.sh "$@"
fi

"${DOCKER_CMD[@]}" run --rm \
    "${DOCKER_TTY[@]}" \
    --platform "$BUILDER_PLATFORM" \
    "${RUN_NETWORK_ARGS[@]}" \
    --privileged \
    --tmpfs /run \
    --tmpfs /tmp \
    -e ALLOW_ROOT=1 \
    -e HOST_UID="$HOST_UID" \
    -e HOST_GID="$HOST_GID" \
    -e CHOWN_OUTPUTS="$CHOWN_OUTPUTS" \
    -e TARGET_DISTRO="$TARGET_DISTRO" \
    -e TARGET_PROFILE="$TARGET_PROFILE" \
    -e TARGET_NAME="${TARGET_NAME:-}" \
    -e TARGET_FORMAT="${TARGET_FORMAT:-iso}" \
    -e INAUTO_IMAGE_ROLE="${INAUTO_IMAGE_ROLE:-panel}" \
    -e TARGET_PLATFORM="${TARGET_PLATFORM:-}" \
    -e TARGET_ARCH="${TARGET_ARCH:-}" \
    -e RAUC_BUNDLE_VERSION="${RAUC_BUNDLE_VERSION:-}" \
    -e RAUC_PINNED_VERSION="$RAUC_PINNED_VERSION" \
    -e RAUC_COMPATIBLE_VERSION="${RAUC_COMPATIBLE_VERSION:-v1}" \
    -e RAUC_VERSION_MODE="${RAUC_VERSION_MODE:-release}" \
    -e RAUC_SIGNING_CERT="${RAUC_SIGNING_CERT:-}" \
    -e RAUC_SIGNING_KEY="${RAUC_SIGNING_KEY:-}" \
    -e RAUC_INTERMEDIATE_CERT="${RAUC_INTERMEDIATE_CERT:-}" \
    -e RAUC_KEYRING_PATH="${RAUC_KEYRING_PATH:-}" \
    -e INSTALLER_KEYRING_SRC="${INSTALLER_KEYRING_SRC:-}" \
    -e INAUTO_OVERLAY_SIZE="${INAUTO_OVERLAY_SIZE:-2G}" \
    -e INAUTO_SITE_CONFIG_DIR="${INAUTO_SITE_CONFIG_DIR:-/home/inauto/config}" \
    -e INAUTO_AUTOSTART_SCRIPT="${INAUTO_AUTOSTART_SCRIPT:-/home/inauto/on_login}" \
    -e INAUTO_JOURNAL_DIR="${INAUTO_JOURNAL_DIR:-/home/inauto/log/journal}" \
    -e LIVECD_APT_CACHE_DIR="$APT_CACHE_DIR_IN_CONTAINER" \
    -e LIVECD_KEEP_APT_CACHE="$LIVECD_KEEP_APT_CACHE" \
    -e TRIVY_CACHE_DIR=/var/lib/trivy \
    -v "$REPO_ROOT:/workspace" \
    -v "$LIVECD_CHROOT_VOLUME:/workspace/scripts/chroot" \
    "${APT_CACHE_VOLUME_ARGS[@]}" \
    -v "$TRIVY_CACHE_VOLUME:/var/lib/trivy" \
    -w /workspace \
    "$BUILDER_IMAGE" \
    "$@"
