# RAUC PKI

Двухуровневая PKI для подписи RAUC bundle'ов:

```
Root CA (offline, долгоживущий 20 лет)
  └─ Signing Cert (онлайн в CI, срок 3-5 лет, default 5 лет)
       └─ подписывает *.raucb bundle'ы
```

На панели в `/etc/rauc/keyring.pem` лежит только **Root CA** сертификат. RAUC проверяет цепочку подписи bundle'ов против него.

---

## Два режима: dev и prod

### Dev-режим (для локальных тестов)

Dev keys генерируются **одной командой**, хранятся в той же директории, используются для QEMU/локального тестирования. **Не use'ить для продакшена.**

```bash
./pki/generate-dev-keys.sh
```

Что создаётся:
- `dev-root-ca.key` / `dev-root-ca.crt` — dev root CA, 10 лет.
- `dev-signing.key` / `dev-signing.crt` — dev signing cert, 5 лет по умолчанию.
- `dev-keyring.pem` — копия root CA, которая пишется в rootfs при сборке dev-bundle.

Если dev root CA уже разложен по тестовым панелям и нужно только продлить
срок подписи без смены keyring на панелях, используйте:

```bash
./pki/generate-dev-signing-cert.sh
```

Этот скрипт перевыпускает только `dev-signing.crt` / `dev-signing.key` под
тем же `dev-root-ca.crt`, поэтому уже прошитые dev-образы продолжают доверять
новым bundle'ам.

Все файлы в `.gitignore`.

### Prod-режим (для production PKI)

**Root CA** генерируется **один раз**, на **air-gap машине** (никогда не в сети, никогда не в CI). Private key root CA физически извлекается из air-gap только для подписи intermediate/signing certs (или для revocation).

**Signing cert** генерируется на 3-5 лет (по умолчанию 5 лет), подписывается root CA, выдаётся в CI через secrets.

---

## Prod workflow

### Шаг 1 — Генерация Root CA (одноразово, раз в 20 лет)

На air-gap машине (live-USB с Linux, отключённый сетевой кабель):

```bash
./pki/generate-prod-root-ca.sh
```

На выходе:
- `prod-root-ca.key` — **СЕКРЕТ**. Записать на зашифрованный USB-носитель, хранить физически в сейфе. **НИКОГДА не подключать к сетевой машине.**
- `prod-root-ca.crt` — публичный. Копируется на online машины, попадает в rootfs панелей как `/etc/rauc/keyring.pem`.

Рекомендация: сделать **два экземпляра** зашифрованных USB с root-ca.key (на двух разных носителях, в разных физических локациях) — для защиты от утери.

### Шаг 2 — Генерация Signing Cert (3-5 лет)

На air-gap машине, имея доступ к `prod-root-ca.key`:

```bash
./pki/generate-prod-signing-cert.sh
```

По умолчанию скрипт выдаёт сертификат на 5 лет. Для более короткой
production-политики можно задать срок в допустимом диапазоне 3-5 лет:

```bash
VALIDITY_DAYS=1095 ./pki/generate-prod-signing-cert.sh
```

Вход: `prod-root-ca.key`, `prod-root-ca.crt`.

На выходе:
- `prod-signing.key` — приватный ключ signing cert. Передаётся в CI через secure-канал (в CI secrets).
- `prod-signing.crt` — публичный сертификат signing. Аналогично.

После передачи в CI — локальные файлы `prod-signing.key` / `prod-signing.crt` рекомендуется удалить с air-gap машины (чтобы минимизировать area of attack).

### Шаг 3 — Установка в CI

В `Project → Settings → CI/CD → Variables` (GitLab) создаются:

| Secret | Содержимое | Откуда |
|---|---|---|
| `RAUC_SIGNING_CERT` | PEM содержимое `prod-signing.crt` | из шага 2 |
| `RAUC_SIGNING_KEY` | PEM содержимое `prod-signing.key` | из шага 2 |
| `RAUC_INTERMEDIATE_CERT` | (опционально) если используется промежуточный | — |
| `RAUC_KEYRING` | PEM содержимое `prod-keyring.pem` (= `prod-root-ca.crt`) | из шага 1 (public часть) |
| `UPDATE_SERVER_DEPLOY_TOKEN` | Bearer-token для `POST /api/upload` | `INAUTO_UPLOAD_TOKEN` на сервере |

Подробнее про CI secrets — `docs/runbooks/ci-pki-secrets.md`.

CI при сборке bundle'ов использует эти secrets через `rauc bundle --cert --key --intermediate`.

### Шаг 4 — Установка Root CA в rootfs

При сборке rootfs в chroot_build.sh:

```bash
install -D -m 0644 /root/profile/rauc/keyring.pem /etc/rauc/keyring.pem
```

`keyring.pem` — это `prod-root-ca.crt` (переименованный). Попадает в squashfs, байт-идентичен на всех панелях.

Production signing cert должен содержать `extendedKeyUsage=emailProtection,codeSigning`.
RAUC проверяет bundle как CMS/S/MIME (`smimesign` purpose), поэтому cert только с
`codeSigning` будет отвергаться с ошибкой `unsuitable certificate purpose`.

---

## Rotation

### Ротация signing cert (до истечения production signing cert)

1. На air-gap — запустить `generate-prod-signing-cert.sh` повторно.
2. Обновить CI secrets (`RAUC_SIGNING_CERT`, `RAUC_SIGNING_KEY`).
3. Следующая сборка bundle'а использует новый signing cert.
4. Панели принимают bundle'ы (проверяют цепочку через тот же root CA).

**Перепрошивка панелей НЕ требуется.**

### Ротация root CA (раз в 20 лет)

Серьёзная операция. Требует:
1. Генерации нового root CA на air-gap.
2. Deployment нового `keyring.pem` в rootfs (через новую версию rootfs).
3. Все bundle'ы должны быть подписаны через новый signing cert (подписанный новым root CA) к моменту, когда панели получат новый keyring.
4. Переходный период: `keyring.pem` может содержать **оба** root CA — тогда bundle'ы обоих поколений валидны.

---

## Revocation

Если скомпрометирован **signing cert**:
1. Немедленно ротировать (новый signing cert от того же root CA).
2. Обновить CI secrets.
3. Старый signing cert становится неиспользуемым в CI — атакующему нужна и приватная часть, и доступ к update-серверу.
4. Опционально: включить CRL (`check-crl=true` в `system.conf`) и distribute CRL через update-сервер.

Если скомпрометирован **root CA private key**:
1. КАТАСТРОФА. Все панели перепрошиваются с новым keyring.pem.
2. Это худший сценарий — почему root CA key хранится air-gap.

---

## Команды инспекции

```bash
# Просмотр root CA
openssl x509 -in prod-root-ca.crt -text -noout | head -30

# Просмотр signing cert
openssl x509 -in prod-signing.crt -text -noout | head -30

# Проверка цепочки
openssl verify -CAfile prod-root-ca.crt prod-signing.crt

# Сроки
openssl x509 -in prod-root-ca.crt -noout -enddate
openssl x509 -in prod-signing.crt -noout -enddate
```
