#!/bin/bash
# Генерирует dev PKI для локального тестирования RAUC bundle signing.
# НЕ использовать в продакшене — используйте generate-prod-*.sh.
#
# Output:
#   dev-root-ca.key / dev-root-ca.crt  — dev root CA (10 лет)
#   dev-signing.key / dev-signing.crt  — dev signing cert (1 год, подписан dev-root-ca)
#   dev-keyring.pem                     — root CA в формате keyring для RAUC

set -euo pipefail

# Git Bash / MSYS на Windows конвертит subject paths вида /CN=... в C:/...
# Отключаем это поведение только для openssl-команд с -subj.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "$0")"

ORG="${ORG:-Inauto Panels DEV}"
RSA_BITS="${RSA_BITS:-4096}"

if [[ -f dev-root-ca.key || -f dev-signing.key ]]; then
    echo "WARNING: dev keys already exist in $(pwd)"
    echo "To regenerate, remove them first: rm -f dev-*.key dev-*.crt dev-keyring.pem"
    exit 1
fi

echo "==> Generating DEV Root CA (RSA-$RSA_BITS, 10 years)"
openssl req -x509 -newkey rsa:$RSA_BITS -nodes \
    -keyout dev-root-ca.key \
    -out dev-root-ca.crt \
    -days 3650 \
    -subj "/CN=$ORG Root CA/O=$ORG"

chmod 600 dev-root-ca.key

echo "==> Generating DEV Signing Cert (RSA-$RSA_BITS, 1 year)"
openssl req -newkey rsa:$RSA_BITS -nodes \
    -keyout dev-signing.key \
    -out dev-signing.csr \
    -subj "/CN=$ORG Signing/O=$ORG"

EXTFILE="./dev-signing.ext"
printf "keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n" > "$EXTFILE"

openssl x509 -req -in dev-signing.csr \
    -CA dev-root-ca.crt -CAkey dev-root-ca.key -CAcreateserial \
    -out dev-signing.crt \
    -days 365 \
    -extfile "$EXTFILE"

rm -f "$EXTFILE" dev-signing.csr dev-root-ca.srl
chmod 600 dev-signing.key

echo "==> Creating keyring (copy of root CA) for RAUC"
cp dev-root-ca.crt dev-keyring.pem

echo ""
echo "========================================================"
echo "DEV PKI generated in $(pwd):"
echo "  dev-root-ca.crt   (public, used as keyring на панели)"
echo "  dev-root-ca.key   (PRIVATE, do NOT distribute)"
echo "  dev-signing.crt   (public)"
echo "  dev-signing.key   (PRIVATE, mounted in CI/builder)"
echo "  dev-keyring.pem   (same as dev-root-ca.crt, для /etc/rauc/keyring.pem)"
echo ""
echo "Validity:"
openssl x509 -in dev-root-ca.crt -noout -enddate | sed 's/^/  root CA: /'
openssl x509 -in dev-signing.crt -noout -enddate | sed 's/^/  signing: /'
echo ""
echo "Verification:"
openssl verify -CAfile dev-root-ca.crt dev-signing.crt
echo "========================================================"
