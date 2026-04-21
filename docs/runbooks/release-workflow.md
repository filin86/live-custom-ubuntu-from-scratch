# Runbook: release workflow для panel firmware

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc` + RAUC update server (`server/`).

## Обзор каналов

Два канала в SQLite-таблице `bundles.channel`:

- `candidate` — только тестовые панели (`/etc/inauto/channel=candidate`).
- `stable` — весь парк (`/etc/inauto/channel=stable`).

Панели читают канал из `/persist/etc/inauto/channel`. Перевод конкретной
панели в `candidate` делается записью файла — без пересборки firmware.

## Шаг 1. Сборка и подпись

1. Выпускается git tag `vYYYY.MM.DD.N` в repo.
2. GitLab CI (`.gitlab-ci.yml`) триггерит pipeline на push-tag:
   - `validate-version` проверяет regex;
   - `build-bundle` (matrix ubuntu/debian) вызывает
     `./scripts/build-in-docker.sh -` с подписью через File-type variables
     `RAUC_SIGNING_CERT` / `RAUC_SIGNING_KEY`;
   - `publish-candidate` upload'ит в update-server.
3. Signing key хранится в GitLab CI/CD Variable `RAUC_SIGNING_KEY`
   (File type, Protected), **не root CA** (root CA живёт offline).
4. Артефакт: `out/inauto-panel-<distro>-amd64-pc-efi-<version>.raucb` +
   `.sha256` + installer tar.zst.

## Шаг 2. Upload в candidate

```
curl -fsS -H "Authorization: Bearer ${INAUTO_UPLOAD_TOKEN}" \
    -F "file=@out/inauto-panel-ubuntu-amd64-pc-efi-${VERSION}.raucb" \
    -F "channel=candidate" \
    ${UPDATE_SERVER_URL}/api/upload
```

Сервер:
- запускает `rauc info` с prod-keyring (подпись чужим ключом → 400);
- валидирует `version` regex'ом `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$`;
- валидирует `compatible`;
- отказ при дубле `(compatible, version, channel)`.

## Шаг 3. Раскатка на candidate-панели

Минимум — две физические панели в режиме `candidate`:

```
# На каждой тестовой панели:
echo candidate > /etc/inauto/channel
systemctl restart panel-check-updates.timer
```

`panel-check-updates.timer` запускает `.service` через `OnBootSec=5min` и
далее `OnUnitActiveSec=1h`; агент сам установит bundle (sort -V newer).

Ожидаемо после обновления:
- `rauc status` показывает booted = противоположный slot;
- `panel-healthcheck.sh` проходит, `rauc-mark-boot-good.service` active;
- heartbeat уходит: `current_version = <VERSION>`, `slot=system[0|1]`.

## Шаг 4. 24-часовой soak

Оставляем обе candidate-панели работать минимум 24 часа. Проверки:

| Что | Где посмотреть |
|---|---|
| Компоненты стека active | `systemctl status lightdm docker containerd x11vnc ssh` |
| Docker compose проекты поднимаются | `docker compose ls`, логи проектов |
| Нет kernel panic / watchdog reset | `dmesg` / `journalctl -k` |
| heartbeat регулярно уходит | таблица `panels.last_seen` |
| site healthcheck не падает | `journalctl -u rauc-mark-boot-good.service` |

Если что-то из перечисленного failing — сборка бракуется, см. шаг 6.

## Шаг 5. Promote candidate → stable

Вариант A (SQL, простой):

```
sqlite3 /var/lib/docker/volumes/server_update-data/_data/server.sqlite3 \
    "UPDATE bundles SET channel='stable'
     WHERE compatible='inauto-panel-ubuntu-amd64-pc-efi-v1'
       AND version='${VERSION}';"
```

Вариант B (upload второй раз в `stable`): не рекомендуется, создаёт две
записи для одного файла и усложняет ретроспективу.

После promote весь парк на следующем timer-tick (в пределах 1h + jitter)
начнёт подтягивать версию.

## Шаг 6. Rollback / блокировка плохой версии

Если после promote обнаружена регрессия:

1. **Мгновенно: снять с stable.**
   ```
   sqlite3 ... "UPDATE bundles SET channel='candidate' WHERE version='${BAD_VERSION}';"
   ```
   Панели, ещё не обновившиеся, `/api/latest` больше не предложит `BAD_VERSION`
   (в `stable` остаётся предыдущий good-bundle).

2. **Панели, которые уже обновились и сломались:** RAUC EFI BootNext + failing
   healthcheck должны вернуть их на предыдущий slot автоматически
   (см. `docs/runbooks/qemu-pc-efi-test.md`, шаг 5.5 и `watchdog.md`).

3. **Панели, обновившиеся успешно в плохую версию (regression не critical):**
   выкатить fix-версию `VERSION.N+1` в stable. Так как панели используют
   `sort -V`, они ставят новое.

4. **Downgrade в exceptional случае:** сервер может вернуть
   `"force_downgrade": true` в `/api/latest`, и агент установит старую
   версию поверх новой (без отката через RAUC rollback). Этот rewrite
   MVP-сервера требует ручного хака (добавить поле в ответ). Использовать
   как ultima ratio.

## Шаг 7. Audit trail

На сервере:

```
sqlite3 ... "SELECT filename, version, channel, uploaded_at FROM bundles
             ORDER BY uploaded_at DESC LIMIT 20;"
```

Heartbeat панелей:

```
sqlite3 ... "SELECT serial, current_version, current_slot, last_error, last_seen
             FROM panels ORDER BY last_seen DESC;"
```

Для production — подключить внешний log collector (Grafana Loki / journald
remote) и регулярно копировать sqlite → S3 snapshot.

## Контрольный список перед promote

- [ ] Bundle подписан production signing cert (не dev).
- [ ] Version в git tag соответствует `RAUC_BUNDLE_VERSION` в artifact.
- [ ] Upload в `candidate` прошёл без ошибок.
- [ ] Минимум две физические candidate-панели 24h без регрессий.
- [ ] `rauc-mark-boot-good.service` active на всех тестовых панелях.
- [ ] `panel-check-updates` heartbeat содержит правильный `slot` и
      `current_version`.
- [ ] Watchdog gate (`docs/runbooks/watchdog.md`) пройден хотя бы один раз
      на этой серии builds.
- [ ] Changelog / release notes обновлены.

Только после всех галочек — выполнять шаг 5.
