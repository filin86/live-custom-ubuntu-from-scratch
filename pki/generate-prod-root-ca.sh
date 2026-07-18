#!/bin/bash
# Генерирует PROD Root CA для RAUC. Запускается ОДНОКРАТНО на air-gap машине.
#
# КРИТИЧНО:
#   - Запускать ТОЛЬКО на машине без сетевого подключения.
#   - После успешной генерации:
#       1. prod-root-ca.crt — скопировать на online машину (публичный).
#       2. prod-root-ca.key — записать на зашифрованный USB и убрать в сейф.
#          Сделать ДВЕ копии на разных USB в разных физических локациях.
#          НИКОГДА не подключать к сетевой машине.
#
# Для signing cert использовать generate-prod-signing-cert.sh (тоже на air-gap).

set -euo pipefail

# Git Bash / MSYS на Windows конвертит /CN=... — отключаем.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

cd "$(dirname "$0")"

ORG="${ORG:-Inauto Panels}"
RSA_BITS="${RSA_BITS:-4096}"
VALIDITY_DAYS="${VALIDITY_DAYS:-7300}"  # 20 лет

# Safety check: предупредить что это PROD операция
echo "=========================================="
echo "PROD Root CA generation"
echo "=========================================="
echo "Org:      $ORG"
echo "RSA bits: $RSA_BITS"
echo "Validity: $VALIDITY_DAYS days (~$((VALIDITY_DAYS / 365)) years)"
echo ""
echo "Проверьте что машина в air-gap (без сети)."
echo "Продолжить? (yes/no)"
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# Safety check: сеть должна быть off
if ip route get 1.1.1.1 >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Router reachable via 1.1.1.1 — this machine appears to have network access."
    echo "Отключите сеть и повторите."
    exit 1
fi

if [[ -f prod-root-ca.key ]]; then
    echo "ERROR: prod-root-ca.key already exists. Regeneration — особая операция."
    echo "Если точно хотите — удалите вручную: rm -i prod-root-ca.key prod-root-ca.crt"
    exit 1
fi

echo "==> Generating Root CA (RSA-$RSA_BITS, $VALIDITY_DAYS days)"
openssl req -x509 -newkey rsa:$RSA_BITS -nodes \
    -keyout prod-root-ca.key \
    -out prod-root-ca.crt \
    -days $VALIDITY_DAYS \
    -subj "/CN=$ORG Root CA/O=$ORG/C=RU" \
    -addext "basicConstraints=critical,CA:true,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

chmod 600 prod-root-ca.key

echo ""
echo "========================================================"
echo "PROD Root CA generated:"
echo "  prod-root-ca.crt  — PUBLIC (можно копировать на online)"
echo "  prod-root-ca.key  — PRIVATE (только на зашифрованный USB!)"
echo ""
echo "NEXT STEPS:"
echo "  1. Скопировать prod-root-ca.crt на online машину —"
echo "     он попадёт в rootfs панелей как /etc/rauc/keyring.pem."
echo "  2. Записать prod-root-ca.key на два зашифрованных USB,"
echo "     положить в сейф в разных физических локациях."
echo "  3. Запустить generate-prod-signing-cert.sh (тоже на air-gap)"
echo "     для генерации первого signing cert."
echo "  4. После завершения работы — shred -u этих файлов из директории"
echo "     если они скопированы на USB:"
echo "       shred -u prod-root-ca.key"
echo "========================================================"
echo ""
echo "Validity:"
openssl x509 -in prod-root-ca.crt -noout -enddate

echo ""
echo "SHA-256 fingerprint (запишите себе — для отчётности и при ротации):"
openssl x509 -in prod-root-ca.crt -noout -fingerprint -sha256
