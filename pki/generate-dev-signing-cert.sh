#!/bin/bash
# Перевыпускает только DEV signing cert под существующим dev-root-ca.
# Используйте это для локальной ротации signing cert без смены keyring на панелях.

set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "$0")"

ORG="${ORG:-Inauto Panels DEV}"
RSA_BITS="${RSA_BITS:-4096}"
VALIDITY_DAYS="${VALIDITY_DAYS:-1825}"

if ! [[ "$VALIDITY_DAYS" =~ ^[0-9]+$ ]] || (( VALIDITY_DAYS <= 0 )); then
    echo "ERROR: VALIDITY_DAYS must be a positive integer, got: $VALIDITY_DAYS" >&2
    exit 1
fi

if [[ ! -f dev-root-ca.key || ! -f dev-root-ca.crt ]]; then
    echo "ERROR: dev-root-ca.key / dev-root-ca.crt не найдены в $(pwd)" >&2
    echo "Сначала запустите ./generate-dev-keys.sh для первичной dev PKI." >&2
    exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -f dev-signing.key ]]; then
    echo "==> Backup предыдущего dev signing cert в dev-signing-${timestamp}.key/crt"
    mv dev-signing.key "dev-signing-${timestamp}.key"
fi
if [[ -f dev-signing.crt ]]; then
    mv dev-signing.crt "dev-signing-${timestamp}.crt"
fi

echo "==> Generating DEV Signing Cert (RSA-$RSA_BITS, ~$((VALIDITY_DAYS / 365)) years)"
openssl req -newkey rsa:$RSA_BITS -nodes \
    -keyout dev-signing.key \
    -out dev-signing.csr \
    -subj "/CN=$ORG Signing/O=$ORG"

EXTFILE="./dev-signing.ext"
printf "keyUsage=critical,digitalSignature\nextendedKeyUsage=emailProtection,codeSigning\n" > "$EXTFILE"

openssl x509 -req -in dev-signing.csr \
    -CA dev-root-ca.crt -CAkey dev-root-ca.key -CAcreateserial \
    -out dev-signing.crt \
    -days "$VALIDITY_DAYS" \
    -extfile "$EXTFILE"

rm -f "$EXTFILE" dev-signing.csr dev-root-ca.srl
chmod 600 dev-signing.key

echo ""
echo "==> Verification"
openssl verify -CAfile dev-root-ca.crt dev-signing.crt

echo ""
echo "========================================================"
echo "DEV signing cert generated:"
echo "  dev-signing.crt  (public)"
echo "  dev-signing.key  (PRIVATE)"
echo ""
echo "Срок действия:"
openssl x509 -in dev-signing.crt -noout -dates
echo ""
echo "SHA-256 fingerprint:"
openssl x509 -in dev-signing.crt -noout -fingerprint -sha256
echo "========================================================"
