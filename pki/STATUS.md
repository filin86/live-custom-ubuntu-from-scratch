# PKI: текущее состояние и переход к production

Обновлено: 2026-04-24

## Текущее состояние — Dev PKI

Для локальной разработки и QEMU-тестов в директории `pki/` сгенерированы dev-ключи:

| Файл | Роль | Валидность |
|---|---|---|
| `dev-root-ca.crt` | Публичный корневой CA. Попадёт в rootfs как `/etc/rauc/keyring.pem` на панелях (при dev-сборке). | до 2036-04-18 (10 лет) |
| `dev-root-ca.key` | **Приватный** ключ Root CA. Только локально, не распространять. | — |
| `dev-signing.crt` | Публичный signing-cert, подписан Root CA. Для dev-сборок `.raucb`. | до 2031-04-23 (5 лет) |
| `dev-signing.key` | **Приватный** signing-key. Монтируется в builder/CI при сборке bundle'ов. | — |
| `dev-keyring.pem` | Копия Root CA для RAUC — укладывается в rootfs. | — |

Подпись корректно проверяется:
```bash
openssl verify -CAfile dev-root-ca.crt dev-signing.crt
# → dev-signing.crt: OK
```

Все приватные ключи/сертификаты внесены в `.gitignore` — в git не попадут.

Для сохранения совместимости с уже прошитыми dev-образами dev root CA не
ротировался: перевыпущен только `dev-signing.crt` под тем же `dev-root-ca.crt`.
Для этого добавлен отдельный helper `./pki/generate-dev-signing-cert.sh`.

### Использование dev-ключей

При сборке RAUC-bundle локально (см. `scripts/targets/rauc/build-bundle.sh` из implementation plan):
```bash
SIGNING_CERT=./pki/dev-signing.crt \
SIGNING_KEY=./pki/dev-signing.key \
    ./scripts/targets/rauc/build-bundle.sh
```

При сборке rootfs — `dev-keyring.pem` копируется в образ как `/etc/rauc/keyring.pem` (делается на фазе implementation, Task 14 плана).

**Dev-ключи НЕЛЬЗЯ использовать для боевых панелей.** Они предназначены только для разработки и QEMU-тестов. На производстве любая панель должна иметь `/etc/rauc/keyring.pem` с **production** Root CA.

---

## Переход к Production PKI

### Шаг 1 — Подготовка air-gap машины

1. Взять любой Linux live-USB (Ubuntu, Debian, Tails, etc.).
2. Загрузить машину с live-USB в offline-режиме.
3. **Физически отключить сетевой кабель.**
4. **Выключить Wi-Fi и Bluetooth.**
5. Можно проверить отсутствие сети: `ip route get 1.1.1.1` должна ошибиться — скрипт `generate-prod-root-ca.sh` это сам проверяет и отказывается работать в сети.

### Шаг 2 — Перенос скриптов на air-gap

Скопировать на air-gap машину (через USB-флешку) содержимое директории `pki/`:
- `README.md` (полная документация)
- `STATUS.md` (этот файл)
- `generate-prod-root-ca.sh`
- `generate-prod-signing-cert.sh`

Dev-ключи переносить **не нужно** — они нерелевантны для prod-PKI.

### Шаг 3 — Генерация Root CA

На air-gap машине:

```bash
cd pki/
./generate-prod-root-ca.sh
```

Скрипт:
1. Проверяет отсутствие сети (router via 1.1.1.1).
2. Запрашивает подтверждение.
3. Генерирует RSA-4096 ключ, X.509-сертификат на 20 лет.
4. Выводит SHA-256 fingerprint сертификата (**записать его** для отчётности и проверок при ротации).

На выходе:
- `prod-root-ca.crt` — публичный сертификат.
- `prod-root-ca.key` — приватный ключ (**главный секрет**).

### Шаг 4 — Генерация первого Signing Cert

Сразу на той же air-gap машине (`prod-root-ca.key` ещё доступен):

```bash
./generate-prod-signing-cert.sh
```

Скрипт:
1. Проверяет наличие Root CA.
2. Проверяет отсутствие сети.
3. Запрашивает подтверждение.
4. Генерирует RSA-4096 signing key, подписывает через Root CA, срок 5 лет по умолчанию (допустимый production-диапазон 3-5 лет).
5. Выводит SHA-256 fingerprint signing-cert'а.

На выходе:
- `prod-signing.crt` — публичный.
- `prod-signing.key` — приватный.

Примечание: production signing cert должен иметь
`extendedKeyUsage=emailProtection,codeSigning`. Для RAUC это важно, потому что
bundle signature проверяется через OpenSSL `smimesign`; cert только с
`codeSigning` не пройдёт verify (`unsuitable certificate purpose`).

### Шаг 5 — Безопасный перенос артефактов

**`prod-root-ca.crt`** (публичный):
- Скопировать на online-машину через USB.
- Положить в `scripts/profiles/<distro>/rauc/keyring.pem` (переименование) — на фазе implementation это попадёт в rootfs всех панелей.
- Можно коммитить в git (это **публичный** сертификат).

**`prod-root-ca.key`** (КРИТИЧНО — приватный ключ Root CA):
- Записать на **два разных зашифрованных USB** (LUKS / VeraCrypt / Kingston IronKey).
- Положить **в разных физических локациях** (напр., основной офис и резервный / сейф дома).
- **НИКОГДА** не подключать к машине с сетью.
- После копирования на USB — `shred -u prod-root-ca.key` с air-gap диска.

**`prod-signing.crt` + `prod-signing.key`** (оба приватно, для CI):
- Перенести на online-машину через USB.
- Загрузить в CI secrets как `RAUC_SIGNING_CERT` и `RAUC_SIGNING_KEY` (секреты в GitHub Actions / GitLab CI).
- После загрузки в CI — `shred -u` локальных копий.

### Шаг 6 — Проверка

После копирования `prod-root-ca.crt` на online-машину:

```bash
# Проверить срок действия
openssl x509 -in prod-root-ca.crt -noout -enddate

# SHA-256 fingerprint должен совпадать с тем, что выдал generate-prod-root-ca.sh
openssl x509 -in prod-root-ca.crt -noout -fingerprint -sha256
```

На CI — первая тестовая сборка должна подписаться через prod signing-cert и проверяться prod root CA:

```bash
openssl verify -CAfile prod-root-ca.crt prod-signing.crt
# → должно быть: prod-signing.crt: OK
```

---

## Ротация

### Signing cert — до истечения production signing cert

1. Снова подготовить air-gap машину (см. шаг 1).
2. Восстановить `prod-root-ca.key` и `prod-root-ca.crt` с одного из зашифрованных USB на air-gap.
3. Запустить `./generate-prod-signing-cert.sh` — скрипт сохранит старые ключи с timestamp-suffix'ом и создаст новые.
4. Перенести новые `prod-signing.crt` и `prod-signing.key` в CI.
5. Убрать `prod-root-ca.key` обратно на USB (shred локальную копию).

**Перепрошивка панелей НЕ требуется** — keyring.pem (Root CA) тот же, цепочка подписи валидна.

### Root CA — раз в 20 лет

Серьёзная операция:
1. Новый `generate-prod-root-ca.sh` с увеличенным counter-ом в CN (чтобы отличать поколения).
2. Подписать новый signing-cert от нового Root CA.
3. Новый keyring.pem в rootfs может содержать **оба** Root CA — bundle'ы обоих поколений валидны (переходный период).
4. После того, как все панели обновились до rootfs с новым keyring'ом — старый Root CA можно выкинуть.

## Revocation

### Compromise signing cert

1. Ротировать — новый signing-cert от того же Root CA.
2. Удалить старые ключи из CI secrets.
3. Атакующему нужно иметь и приватный ключ, и доступ к update-серверу для разрушительного действия.
4. Опционально: включить CRL — `check-crl=true` в `/etc/rauc/system.conf` + опубликовать CRL через update-сервер.

### Compromise Root CA private key

**Худший сценарий.** План действий:
1. Немедленная генерация нового Root CA.
2. Сборка новой версии rootfs с новым keyring.pem.
3. Перепрошивка всех панелей (или push через RAUC, если старый ключ ещё не скомпрометирован для атакующего полностью).
4. Именно это почему Root CA private key хранится air-gap и дублируется на разных USB.

---

## Команды для быстрой инспекции

```bash
# Просмотр сертификата
openssl x509 -in prod-root-ca.crt -text -noout | head -30

# Срок действия
openssl x509 -in <file>.crt -noout -enddate

# Fingerprint
openssl x509 -in <file>.crt -noout -fingerprint -sha256

# Проверка цепочки подписи
openssl verify -CAfile prod-root-ca.crt prod-signing.crt

# Просмотр RAUC system.conf подписи (на панели после prod-rollout)
rauc info --keyring=/etc/rauc/keyring.pem /path/to/bundle.raucb
```
