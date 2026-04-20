#!/bin/bash
# Генерирует PROD Signing Cert (подписан Root CA). Запускается на air-gap машине,
# где уже лежит prod-root-ca.key. Каждые ~2 года.
#
# Output:
#   prod-signing.key  — передаётся в CI через secure channel (CI secrets)
#   prod-signing.crt  — публичный, вместе с key в CI

set -euo pipefail

# Git Bash / MSYS на Windows конвертит /CN=... — отключаем.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "$0")"

ORG="${ORG:-Inauto Panels}"
RSA_BITS="${RSA_BITS:-4096}"
VALIDITY_DAYS="${VALIDITY_DAYS:-730}"  # 2 года

# Наличие root CA
if [[ ! -f prod-root-ca.key || ! -f prod-root-ca.crt ]]; then
    echo "ERROR: prod-root-ca.key / prod-root-ca.crt не найдены в $(pwd)"
    echo "Сначала запустите generate-prod-root-ca.sh, либо восстановите Root CA"
    echo "с защищённого USB-носителя в эту директорию."
    exit 1
fi

echo "=========================================="
echo "PROD Signing Cert generation"
echo "=========================================="
echo "Org:      $ORG"
echo "RSA bits: $RSA_BITS"
echo "Validity: $VALIDITY_DAYS days (~$((VALIDITY_DAYS / 365)) years)"
echo ""
echo "Это ротация signing cert."
echo "Продолжить? (yes/no)"
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# Safety: сеть должна быть off
if ip route get 1.1.1.1 >/dev/null 2>&1; then
    echo "ERROR: машина в сети. Отключите и повторите."
    exit 1
fi

# Backup предыдущий signing cert если был
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ -f prod-signing.key ]]; then
    echo "==> Backup предыдущего signing cert в prod-signing-${TIMESTAMP}.key/crt"
    mv prod-signing.key "prod-signing-${TIMESTAMP}.key"
    mv prod-signing.crt "prod-signing-${TIMESTAMP}.crt"
fi

echo "==> Generating new signing key"
openssl req -newkey rsa:$RSA_BITS -nodes \
    -keyout prod-signing.key \
    -out prod-signing.csr \
    -subj "/CN=$ORG Signing $TIMESTAMP/O=$ORG/C=RU"

chmod 600 prod-signing.key

echo "==> Signing by Root CA"
EXTFILE="./prod-signing.ext"
printf "keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nbasicConstraints=CA:false\n" > "$EXTFILE"

openssl x509 -req -in prod-signing.csr \
    -CA prod-root-ca.crt -CAkey prod-root-ca.key -CAcreateserial \
    -out prod-signing.crt \
    -days $VALIDITY_DAYS \
    -extfile "$EXTFILE"

rm -f "$EXTFILE" prod-signing.csr prod-root-ca.srl

echo ""
echo "==> Verification"
openssl verify -CAfile prod-root-ca.crt prod-signing.crt

echo ""
echo "========================================================"
echo "PROD Signing Cert generated:"
echo "  prod-signing.crt  — PUBLIC"
echo "  prod-signing.key  — PRIVATE (передаётся в CI)"
echo ""
echo "Срок действия:"
openssl x509 -in prod-signing.crt -noout -enddate
echo ""
echo "SHA-256 fingerprint (для аудита):"
openssl x509 -in prod-signing.crt -noout -fingerprint -sha256
echo ""
echo "NEXT STEPS:"
echo "  1. Закопировать prod-signing.key + prod-signing.crt"
echo "     на изолированный USB."
echo "  2. Перенести в CI через secure channel (не в git)."
echo "  3. Загрузить в CI secrets как RAUC_SIGNING_KEY и RAUC_SIGNING_CERT."
echo "  4. После переноса — shred файлов с air-gap машины:"
echo "       shred -u prod-signing.key  # если скопировано с сохранностью"
echo "  5. prod-root-ca.key — УБРАТЬ обратно на защищённый USB после"
echo "     завершения операции ротации."
echo "========================================================"
