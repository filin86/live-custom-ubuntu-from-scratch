#!/bin/bash
# Install pinned RAUC from upstream release sources.
#
# Ubuntu 24.04 ships RAUC 1.11.x, while the panel firmware spec requires a
# newer pinned RAUC. This helper is used by the Docker builder, the RAUC target rootfs,
# and the factory installer ISO so all stages use the same RAUC CLI/runtime.

set -euo pipefail

RAUC_PINNED_VERSION="${RAUC_PINNED_VERSION:-1.15.2}"
RAUC_INSTALL_PREFIX="${RAUC_INSTALL_PREFIX:-/usr}"
default_source_url="https://github.com/rauc/rauc/releases/download/v${RAUC_PINNED_VERSION}/rauc-${RAUC_PINNED_VERSION}.tar.xz"
default_source_sha256=""

case "$RAUC_PINNED_VERSION" in
    1.15.2)
        default_source_sha256="127a24cde208c65b837ae978c695a00730f1094ee8b6c7d48cf58ef846eae340"
        ;;
    1.13)
        default_source_sha256="1ddb218a5d713c8dbd6e04d5501d96629f1c8e2521576fbd9e7751edb7da113e"
        ;;
esac

RAUC_SOURCE_URL="${RAUC_SOURCE_URL:-$default_source_url}"
RAUC_SOURCE_SHA256="${RAUC_SOURCE_SHA256:-$default_source_sha256}"

log() {
    echo "[rauc-source] $*"
}

installed_rauc_version() {
    command -v rauc >/dev/null 2>&1 || return 1
    rauc --version 2>/dev/null | awk 'NR == 1 { print $NF }'
}

if [[ "$(installed_rauc_version || true)" == "$RAUC_PINNED_VERSION" ]]; then
    log "RAUC $RAUC_PINNED_VERSION already installed: $(command -v rauc)"
    exit 0
fi

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

log "installing build dependencies"
apt-get update
base_deps=(
    ca-certificates \
    curl \
    xz-utils
)
build_deps=(
    build-essential \
    cmake \
    meson \
    ninja-build \
    pkg-config \
    libcurl4-openssl-dev \
    libdbus-1-dev \
    libglib2.0-dev \
    libnl-genl-3-dev \
    libssl-dev \
    libjson-glib-dev \
    libfdisk-dev \
    libsystemd-dev
)
apt-get install -y --no-install-recommends \
    "${base_deps[@]}" \
    "${build_deps[@]}"

work_dir="$(mktemp -d -t rauc-src-XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

log "downloading RAUC $RAUC_PINNED_VERSION"
if [[ -z "$RAUC_SOURCE_SHA256" ]]; then
    echo "[rauc-source] ERROR: RAUC_SOURCE_SHA256 must be set for RAUC $RAUC_PINNED_VERSION" >&2
    exit 1
fi
curl -fsSL "$RAUC_SOURCE_URL" -o "$work_dir/rauc.tar.xz"
printf '%s  %s\n' "$RAUC_SOURCE_SHA256" "$work_dir/rauc.tar.xz" | sha256sum -c -
tar -C "$work_dir" -xf "$work_dir/rauc.tar.xz"

src_dir="$work_dir/rauc-${RAUC_PINNED_VERSION}"
[[ -d "$src_dir" ]] || {
    echo "[rauc-source] ERROR: extracted source directory not found: $src_dir" >&2
    exit 1
}

log "building RAUC $RAUC_PINNED_VERSION"
meson setup "$src_dir/build" "$src_dir" \
    --prefix="$RAUC_INSTALL_PREFIX" \
    --buildtype=release \
    -Dnetwork=false \
    -Dstreaming=false \
    -Djson=enabled \
    -Dgpt=enabled \
    -Dtests=false \
    -Dfuzzing=false \
    -Dhtmldocs=false
meson compile -C "$src_dir/build"
meson install -C "$src_dir/build"

ldconfig
hash -r

actual="$(installed_rauc_version || true)"
if [[ "$actual" != "$RAUC_PINNED_VERSION" ]]; then
    echo "[rauc-source] ERROR: expected RAUC $RAUC_PINNED_VERSION, got '${actual:-<missing>}'" >&2
    exit 1
fi

if [[ "${RAUC_KEEP_BUILD_DEPS:-0}" != "1" ]]; then
    log "removing RAUC build dependencies"
    apt-get purge -y "${build_deps[@]}"
    apt-get autoremove -y
fi

log "installed RAUC $actual at $(command -v rauc)"
