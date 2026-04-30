# Инструкция: выпуск версии для панелей

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc` + RAUC-сервер обновлений (`server/`).

## Обзор каналов

Два канала в SQLite-таблице `bundles.channel`:

- `candidate` — только тестовые панели (`/etc/inauto/channel=candidate`).
- `stable` — весь парк (`/etc/inauto/channel=stable`).

Панели читают канал из `/etc/inauto/channel`; сам файл persistent и
проецируется из persist-раздела через initramfs. Перевод конкретной панели в
`candidate` делается записью файла — без пересборки образа системы.

## Шаг 1. Сборка и подпись

1. Выпускается git-тег `vYYYY.MM.DD.N` в репозитории.
2. GitLab CI (`.gitlab-ci.yml`) запускает конвейер на отправку тега:
   - `validate-version` проверяет regex;
   - `build-bundle` (matrix ubuntu/debian) вызывает
     `./scripts/build-in-docker.sh -` с подписью через файловые переменные
     `RAUC_SIGNING_CERT` / `RAUC_SIGNING_KEY`;
   - `publish-candidate` загружает артефакт на сервер обновлений.
3. Ключ подписи хранится в переменной GitLab CI/CD `RAUC_SIGNING_KEY`
   (тип File, Protected), **не root CA** (root CA хранится вне сети).
4. Артефакт: `out/inauto-panel-<distro>-amd64-pc-efi-<version>.raucb` +
   `.sha256` + `.tar.zst`-архив установщика.

## Шаг 2. Загрузка в candidate

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

## Шаг 3. Раскатка на панели candidate

Минимум — две физические панели в режиме `candidate`:

```
# На каждой тестовой панели:
echo candidate > /etc/inauto/channel
systemctl restart panel-check-updates.timer
systemctl start panel-check-updates.service
```

`panel-check-updates.timer` запускает `.service` через `OnBootSec=5min` и
далее `OnUnitActiveSec=1h` + `RandomizedDelaySec=5min`. Ручной старт
`.service` выше нужен, чтобы не ждать следующего срабатывания таймера. Агент
сам установит RAUC-пакет с более новой версией (`sort -V`).

Ожидаемо после обновления:
- `rauc status` показывает загруженный противоположный слот;
- `panel-healthcheck.sh` проходит, `rauc-mark-boot-good.service` active;
- отметка о связи уходит: `current_version = <VERSION>`, `slot=system[0|1]`.

## Шаг 4. 24-часовая проверка

Оставляем обе панели `candidate` работать минимум 24 часа. Проверки:

| Что | Где посмотреть |
|---|---|
| Компоненты стека active | `systemctl status lightdm docker containerd x11vnc ssh` |
| Docker compose проекты поднимаются | `docker compose ls`, логи проектов |
| Нет kernel panic / watchdog reset | `dmesg` / `journalctl -k` |
| отметка о связи регулярно уходит | таблица `panels.last_seen` |
| объектная проверка работоспособности не падает | `journalctl -u rauc-mark-boot-good.service` |

Если что-то из перечисленного не проходит — сборка бракуется, см. шаг 6.

## Шаг 5. Перевод candidate → stable

Вариант A (SQL, простой):

```
sqlite3 /var/lib/docker/volumes/server_update-data/_data/server.sqlite3 \
    "UPDATE bundles SET channel='stable'
     WHERE compatible='inauto-panel-ubuntu-amd64-pc-efi-v1'
       AND version='${VERSION}';"
```

Вариант B (загрузка второй раз в `stable`): не рекомендуется. Сервер
отклоняет повтор того же имени файла, а загрузка под другим именем создаст
вторую запись для того же RAUC-пакета и усложнит разбор истории.

После перевода весь парк на следующем срабатывании таймера (в пределах 1 часа
+ случайная задержка) начнёт подтягивать версию.

## Шаг 6. Откат / блокировка плохой версии

Если после перевода обнаружена регрессия:

1. **Мгновенно: снять с stable.**
   ```
   sqlite3 ... "UPDATE bundles SET channel='candidate' WHERE version='${BAD_VERSION}';"
   ```
   Панели, ещё не обновившиеся, `/api/latest` больше не предложит `BAD_VERSION`
   (в `stable` остаётся предыдущий исправный RAUC-пакет).

2. **Панели, которые уже обновились и сломались:** RAUC EFI BootNext + упавшая
   проверка работоспособности должны вернуть их на предыдущий слот автоматически
   (см. `docs/runbooks/qemu-pc-efi-test.md`, шаг 5.5 и `watchdog.md`).

3. **Панели, обновившиеся успешно в плохую версию (регрессия не критична):**
   выкатить исправленную версию `VERSION.N+1` в stable. Так как панели используют
   `sort -V`, они ставят новое.

4. **Понижение версии в исключительном случае:** сервер может вернуть
   `"force_downgrade": true` в `/api/latest`, и агент установит старую
   версию поверх новой (без отката через RAUC). Эта правка ответа сервера
   требует ручного вмешательства (добавить поле в ответ). Использовать только
   как крайний вариант.

## Шаг 7. След аудита

На сервере:

```
sqlite3 ... "SELECT filename, version, channel, uploaded_at FROM bundles
             ORDER BY uploaded_at DESC LIMIT 20;"
```

Отметки о связи панелей:

```
sqlite3 ... "SELECT serial, current_version, current_slot, last_error, last_seen
             FROM panels ORDER BY last_seen DESC;"
```

Для эксплуатации — подключить внешний сборщик логов (Grafana Loki / удалённый
journald) и регулярно копировать sqlite в снимок S3.

## Ручные сценарии без сервера обновлений

- Если передали только `*.raucb` для уже установленной RAUC-панели:
  `docs/runbooks/update-from-raucb.md`.
- Если передали архив установщика `*.tar.zst` и нужно установить или
  переустановить панель через загрузочную флешку Ubuntu/Debian:
  `docs/runbooks/install-from-installer-tar-zst.md`.

## Контрольный список перед переводом в stable

- [ ] RAUC-пакет подписан промышленным сертификатом подписи (не dev).
- [ ] Версия в git-теге соответствует `RAUC_BUNDLE_VERSION` в артефакте.
- [ ] Загрузка в `candidate` прошла без ошибок.
- [ ] Минимум две физические панели `candidate` 24 часа без регрессий.
- [ ] `rauc-mark-boot-good.service` active на всех тестовых панелях.
- [ ] `panel-check-updates` отправляет отметку о связи с правильными `slot` и
      `current_version`.
- [ ] Проверка watchdog (`docs/runbooks/watchdog.md`) пройдена хотя бы один раз
      на этой серии сборок.
- [ ] Журнал изменений / примечания к выпуску обновлены.

Только после всех галочек — выполнять шаг 5.
