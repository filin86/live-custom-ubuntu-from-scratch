# Inauto update server

Минимальный backend для доставки RAUC bundle'ов панелям.

## Что внутри

- **FastAPI** (`app/main.py`): API `/api/{upload,latest,heartbeat}`, health `/healthz`.
- **SQLite** (`app/db.py`): `bundles` и `panels`, единственный volume `update-data`.
- **nginx**: раздаёт `/bundles/*` статически, остальное проксирует на FastAPI.
- **rauc CLI** в api-контейнере — чтобы читать manifest (`compatible`, `version`) из
  подписанного bundle при `POST /api/upload`.

## Запуск (dev)

Положите prod/dev keyring в `server/keyring/keyring.pem` (этот путь читается
контейнером). Для локального теста:

```
cp ../pki/dev-keyring.pem server/keyring/keyring.pem
```

Создайте `.env` (не коммитится):

```
INAUTO_UPLOAD_TOKEN=replace-with-strong-random
INAUTO_PUBLIC_BASE_URL=http://panels.example.local:9001
INAUTO_LISTEN_PORT=9001
```

Старт:

```
cd server
docker compose up -d --build
```

## API

### `POST /api/upload`

```
curl -fsS -H "Authorization: Bearer $INAUTO_UPLOAD_TOKEN" \
    -F "file=@../out/inauto-panel-ubuntu-amd64-pc-efi-2026.04.20.1.raucb" \
    -F "channel=candidate" \
    http://localhost:9001/api/upload
```

По умолчанию `nginx` на сервере принимает upload'ы до `4G`, чего хватает для
текущих `.raucb` bundle'ов. После изменения `server/nginx.conf` перезапустите
`nginx` контейнер:

```bash
cd server
docker compose restart nginx
```

`rauc info` распаковывает manifest, сервер проверяет `version` против
`^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$` и `compatible` против
`inauto-panel-<distro>-<arch>-<platform>-v<n>`. Дубли по
`(compatible, version, channel)` отклоняются `409`.

### `GET /api/latest?channel=<c>&compatible=<compat>`

Ответ либо `{}` (ничего нет), либо `{"version": "...", "url": "...", "force_downgrade": false}`.
URL — полный, если `INAUTO_PUBLIC_BASE_URL` задан; иначе относительный `/bundles/...`.

### `POST /api/heartbeat`

```
{ "compatible": "inauto-panel-ubuntu-amd64-pc-efi-v1",
  "version": "2026.04.20.1",
  "serial": "panel-03",
  "slot": "system0",
  "last_error": null }
```

Пустой `slot` без `last_error` → 400 (spec: "Empty `slot` without `last_error`
is rejected").

## Promote candidate → stable

SQL-способ (до появления /api/promote):

```
sqlite3 /var/lib/docker/volumes/server_update-data/_data/server.sqlite3 \
    "UPDATE bundles SET channel='stable' WHERE filename='<bundle.raucb>';"
```

Перед promote убедитесь, что прошёл 24h soak (см. `docs/runbooks/release-workflow.md`).

## Безопасность

- Private signing key сервер НЕ хранит — только public keyring для `rauc info`.
- `INAUTO_UPLOAD_TOKEN` — единственный секрет на сервере; хранится вне git
  (`.env` или Vault). Ротируется независимо от PKI.
- Root CA private key остаётся offline (`docs/runbooks/ci-pki-secrets.md`).
