#!/bin/bash
# Обёртка над build-rauc-installer.sh для релизных prod-сборок:
# собирает RAUC_BUNDLE_VERSION из сегодняшней даты и порядкового номера
# сборки за день (1 по умолчанию), затем подставляет фиксированные
# prod-пути PKI и запускает двухфазную сборку.
#
# Использование:
#   ./scripts/build-rauc-release.sh [N] [доп. флаги build-rauc-installer.sh...]
#
# Пример:
#   ./scripts/build-rauc-release.sh                 # -> RAUC_BUNDLE_VERSION=YYYY.MM.DD.1
#   ./scripts/build-rauc-release.sh 3               # -> RAUC_BUNDLE_VERSION=YYYY.MM.DD.3
#   ./scripts/build-rauc-release.sh 2 --clean-cache # -> N=2, + сброс APT-кеша

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

build_number="${1:-1}"
# Если первый аргумент — флаг (не число), считаем N=1 и ничего не сдвигаем
if [[ "$build_number" =~ ^[0-9]+$ ]]; then
    # shift может упасть, когда аргументов не передали вообще (set -e + set -u)
    shift || true
else
    build_number=1
fi

bundle_version="$(date +%Y.%m.%d).${build_number}"

echo "RAUC_BUNDLE_VERSION=${bundle_version}" >&2

for pki_file in \
    "$REPO_ROOT/pki/prod-signing.crt" \
    "$REPO_ROOT/pki/prod-signing.key" \
    "$REPO_ROOT/pki/prod-keyring.pem"
do
    if [[ ! -f "$pki_file" ]]; then
        echo "ERROR: production PKI file not found: $pki_file" >&2
        exit 1
    fi
done

# prod-override: эти переменные принудительно перекрывают любые значения
# из config.sh/окружения и фиксируют prod-пути PKI внутри builder-контейнера.
RAUC_BUNDLE_VERSION="$bundle_version" \
RAUC_VERSION_MODE=release \
TARGET_DISTRO=ubuntu \
TARGET_PLATFORM=pc-efi \
TARGET_ARCH=amd64 \
RAUC_SIGNING_CERT=/workspace/pki/prod-signing.crt \
RAUC_SIGNING_KEY=/workspace/pki/prod-signing.key \
RAUC_KEYRING_PATH=/workspace/pki/prod-keyring.pem \
INSTALLER_KEYRING_SRC=/workspace/pki/prod-keyring.pem \
exec "$SCRIPT_DIR/build-rauc-installer.sh" "$@"
