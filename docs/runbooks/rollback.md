# Runbook: rollback и manual slot switch

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc`, `TARGET_PLATFORM=pc-efi`.

## Уровни rollback

1. **Автоматический** — EFI BootNext + failed healthcheck вернут к
   предыдущему slot'у на следующий reboot. Это работает "из коробки"
   после успешной установки новой версии, если healthcheck упал.
2. **Блокирующий** — admin снимает плохой bundle со `stable`-канала,
   новые панели перестают его получать.
3. **Manual reslot** — admin принудительно переключает активный slot
   через `rauc status mark-active` на конкретной панели.
4. **Hard rollback** — откат через установку предыдущего bundle
   (с `force_downgrade=true` на сервере).

## Уровень 1: автоматический

Ничего делать не нужно. Описано в `docs/runbooks/qemu-pc-efi-test.md`
шаг 5.5 и `docs/runbooks/watchdog.md`.

Критерий успеха: `cat /etc/inauto/firmware-version` после второго
reboot'а = предыдущая версия, `rauc status` показывает old slot =
booted, good.

## Уровень 2: демоут со stable-канала

Если плохая версия уже promote'нута в `stable` и часть парка её
подхватила:

```
# На update server'е (один SQL-запрос):
sqlite3 /var/lib/.../server.sqlite3 \
  "UPDATE bundles SET channel='candidate' \
   WHERE compatible='inauto-panel-ubuntu-amd64-pc-efi-v1' \
     AND version='<BAD_VERSION>';"
```

Эффект:
- Необновившиеся панели `/api/latest` больше не вернёт BAD_VERSION,
  они останутся на предыдущем good.
- Уже обновившиеся панели, у которых healthcheck упал, откатятся
  автоматически (уровень 1).
- Уже обновившиеся панели, у которых healthcheck прошёл, но проблема
  выявилась позже — см. уровень 3 или 4.

## Уровень 3: manual reslot на конкретной панели

Если панель загрузилась в bad slot (healthcheck прошёл, но потом
обнаружилась регрессия) — явно переключаем обратно:

```bash
# На панели:
sudo -i

rauc status
# Смотрим какой slot booted, какой other.

# Переключаем BootOrder так, чтобы следующий boot пошёл в other slot.
# На EFI backend:
rauc status mark-active other

# Reboot, и следующий boot будет уже из прежнего slot'а
systemctl reboot
```

После reboot'а:

```bash
cat /etc/inauto/firmware-version
# Должна быть версия old slot'а.

rauc status
# Прошлый slot = booted; текущий (то есть бывший "новый") = active или bad.
```

**Замечание:** `rauc status mark-active other` на EFI backend'е
обновляет BootOrder (через `efibootmgr`). Нужны root-права и включённый
UEFI runtime (`/sys/firmware/efi`).

## Уровень 4: hard rollback через force_downgrade

Используется только в крайних случаях: плохая версия прошла в stable,
много панелей уже на ней, rollback через BootNext не работает
(здоровый healthcheck несмотря на регрессию).

### Шаг 1 — Загрузить предыдущую good-версию в `stable`

Если в БД `bundles` уже есть предыдущая good-версия, она всё ещё
доступна. Убедимся что она в `stable`:

```
sqlite3 ... "SELECT version, channel FROM bundles \
             WHERE compatible='inauto-panel-ubuntu-amd64-pc-efi-v1' \
             ORDER BY version DESC LIMIT 5;"
```

### Шаг 2 — Временно патчить сервер

В MVP update server нет готового `force_downgrade=true` переключателя
по bundle'у, есть только поле в ответе `/api/latest`. Надо патчить
backend:

```python
# В app/main.py, в api_latest():
#   ... если bundle.version == KNOWN_ROLLBACK_VERSION:
#       return JSONResponse({..., "force_downgrade": True})
```

Или заменить все stable'ы:

```
# SQL-способ: снять bad, вернуть good в stable
UPDATE bundles SET channel='candidate' WHERE version='<BAD>';
# (good уже в stable, ничего менять не надо)
```

И вручную дать серверу знать, что это downgrade ответ. **MVP-способ:**
временный custom endpoint, подложенный на сервере на время инцидента.

### Шаг 3 — Обновить панели

`panel-check-updates.timer` tick'нет у всех панелей в пределах
часа + RandomizedDelaySec. С `force_downgrade=true` агент установит
старую версию поверх новой.

### Шаг 4 — Убрать force_downgrade

Когда все панели вернулись — откатить server-патч, чтобы следующие
обновления не downgrade'или случайно.

## Осмотр состояния всего парка

```
sqlite3 ... <<'SQL'
SELECT
  serial,
  compatible,
  current_version,
  current_slot,
  last_error,
  last_seen
FROM panels
ORDER BY last_seen DESC;
SQL
```

Полезные вопросы:
- «Какие панели на BAD_VERSION?» — `WHERE current_version='<BAD>'`.
- «Кто давно не отвечал?» — `WHERE last_seen < datetime('now','-1 hour')`.
- «У кого last_error не NULL?» — `WHERE last_error IS NOT NULL`.

## Чего делать нельзя

- **Править GPT вручную после factory-provision'а.** RAUC и
  `panel-check-updates` ожидают partlabels — любое отклонение ломает
  и install, и rollback.
- **Удалять `persist` для "чистого reset'а"** — потеряете SSH host keys,
  NetworkManager, /etc/inauto/* . Лучше reinstall через factory runbook.
- **Использовать `rauc install` на том же slot'е, который booted.** RAUC
  откажет, но если обойти — получите corrupted rootfs текущего slot'а.
  `rauc install` всегда пишет в **other** slot.
