#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_USE_SUDO="${DOCKER_USE_SUDO:-auto}"
# Read TARGET_DISTRO from config or caller environment (before container starts).
TARGET_DISTRO_FROM_CONFIG=$(
    set +u
    source "$REPO_ROOT/scripts/default_config.sh" 2>/dev/null || true
    [[ -f "$REPO_ROOT/scripts/config.sh" ]] && source "$REPO_ROOT/scripts/config.sh" 2>/dev/null || true
    echo "${TARGET_DISTRO:-ubuntu}"
)
TARGET_DISTRO="${TARGET_DISTRO:-$TARGET_DISTRO_FROM_CONFIG}"

case "$TARGET_DISTRO" in
    ubuntu) BASE_IMAGE_DEFAULT="ubuntu:24.04" ;;
    debian) BASE_IMAGE_DEFAULT="debian:trixie" ;;
    *) >&2 echo "ERROR: unknown TARGET_DISTRO='$TARGET_DISTRO'"; exit 1 ;;
esac

BASE_IMAGE="${BASE_IMAGE:-$BASE_IMAGE_DEFAULT}"
BUILDER_IMAGE="${BUILDER_IMAGE:-livecd-builder-${TARGET_DISTRO}:local}"
BUILDER_PLATFORM="${BUILDER_PLATFORM:-linux/amd64}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-$REPO_ROOT/docker/Builder.Dockerfile}"
REBUILD_BUILDER="${REBUILD_BUILDER:-0}"
CLEAN_BUILD="${CLEAN_BUILD:-0}"
CHOWN_OUTPUTS="${CHOWN_OUTPUTS:-1}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
REPO_NAME="$(basename "$REPO_ROOT")"
LIVECD_CHROOT_VOLUME="${LIVECD_CHROOT_VOLUME:-${REPO_NAME}-chroot-${TARGET_DISTRO}}"
TRIVY_CACHE_VOLUME="${TRIVY_CACHE_VOLUME:-${REPO_NAME}-trivy-cache}"
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
  ./scripts/build-in-docker.sh [--rebuild-builder] [--shell] [--] [build.sh args...]

Examples:
  ./scripts/build-in-docker.sh -
  ./scripts/build-in-docker.sh --clean debootstrap - build_iso
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
  LIVECD_CHROOT_VOLUME  Named volume used for scripts/chroot
  TRIVY_CACHE_VOLUME    Named volume used for the Trivy database
  DOCKER_BUILD_NETWORK  Optional network mode for 'docker build' (for example: host)
  DOCKER_RUN_NETWORK    Optional network mode for 'docker run' (for example: host)
  HOST_CA_BUNDLE       Optional CA bundle path copied into builder image
  CHOWN_OUTPUTS         Set to 0 to keep container-owned reports/ISO artifacts
  BASE_IMAGE            Override base image for the builder (default depends on TARGET_DISTRO)
  TARGET_DISTRO         ubuntu | debian — overrides config, selects builder image and chroot volume
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
        --shell)
            OPEN_SHELL=1
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
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

BUILD_NETWORK_ARGS=()
RUN_NETWORK_ARGS=()
BUILD_SECRET_ARGS=()

if [[ -n "$DOCKER_BUILD_NETWORK" ]]; then
    BUILD_NETWORK_ARGS=(--network "$DOCKER_BUILD_NETWORK")
fi

if [[ -n "$DOCKER_RUN_NETWORK" ]]; then
    RUN_NETWORK_ARGS=(--network "$DOCKER_RUN_NETWORK")
fi

if [[ -r "$HOST_CA_BUNDLE" ]]; then
    BUILD_SECRET_ARGS=(--secret "id=host_ca_bundle,src=$HOST_CA_BUNDLE")
fi

if [[ "$REBUILD_BUILDER" == "1" ]] || ! "${DOCKER_CMD[@]}" image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    "${DOCKER_CMD[@]}" build \
        --pull \
        --platform "$BUILDER_PLATFORM" \
        "${BUILD_NETWORK_ARGS[@]}" \
        "${BUILD_SECRET_ARGS[@]}" \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
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
    -e TRIVY_CACHE_DIR=/var/lib/trivy \
    -v "$REPO_ROOT:/workspace" \
    -v "$LIVECD_CHROOT_VOLUME:/workspace/scripts/chroot" \
    -v "$TRIVY_CACHE_VOLUME:/var/lib/trivy" \
    -w /workspace \
    "$BUILDER_IMAGE" \
    "$@"
