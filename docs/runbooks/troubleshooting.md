# Runbook: troubleshooting immutable panel firmware

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc`, `TARGET_PLATFORM=pc-efi`.

## 1. Панель не загружается в установленный system0

### Симптомы
- После reboot'а из installer'а панель приходит в UEFI Setup / GRUB Ubuntu Live.
- Или "No bootable device".

### Диагностика

Если есть доступ в UEFI Setup:

1. Проверить Boot order в UEFI — должны быть `system0`, `system1`.
2. Secure Boot: у нас dev-firmware не подписан, Secure Boot должен быть
   **отключён** в UEFI Setup.
3. UEFI может добавлять свои "Windows Boot Manager" и т.п. перед нашими
   entries. Приоритет BootOrder надо настроить вручную.

С Ubuntu Live USB:

```bash
efibootmgr -v
# Ожидаем:
#   BootOrder: XXXX,YYYY,...
#   BootXXXX* system0  HD(1,GPT,...,)/File(\EFI\Linux\inauto-panel.efi)
#   BootYYYY* system1  HD(2,GPT,...,)/File(\EFI\Linux\inauto-panel.efi)
```

Если entries отсутствуют — installer не отработал шаг `efibootmgr --create`.

### Что делать

1. Удалить чужие boot entries, мешающие RAUC BootOrder:
   ```
   efibootmgr --bootnum <XXXX> --delete-bootnum
   ```
2. Пересоздать system0/system1 вручную:
   ```
   efibootmgr --create --disk /dev/<диск> --part <efi_A_part_num> \
       --label system0 --loader '\EFI\Linux\inauto-panel.efi'
   ```
   Партиционный номер находится через `lsblk | grep efi_A` и `readlink`.
3. Проверить что `\EFI\Linux\inauto-panel.efi` физически есть в `efi_A`:
   ```
   mount /dev/disk/by-partlabel/efi_A /mnt
   ls /mnt/EFI/Linux/    # ожидаем inauto-panel.efi + initrd.img
   ```
4. Установить BootOrder: `efibootmgr --bootorder <XXXX>,<YYYY>`.

## 2. initramfs падает в emergency shell

### Симптомы
- После UEFI видны kernel messages, потом `cannot mount root ...`
  или emergency shell.

### Диагностика

В emergency shell:

```
ls /dev/disk/by-partlabel/
```

Ожидаем: `efi_A`, `efi_B`, `rootfs_A`, `rootfs_B`, `persist`,
`container-store`, `inauto-data`.

Если какого-то нет:
- Проверить что `rootfs_A` / `rootfs_B` не пустые:
  `blkid /dev/disk/by-partlabel/rootfs_A` — ожидаем `TYPE="squashfs"`.
- Проверить PARTLABEL'ы через `sgdisk -p /dev/<диск>`.

Если все разделы есть, но `panel-boot` init-скрипт падает — проверить
dmesg на ошибки overlay/squashfs.

### Что делать

- Если raw-slot пустой (сбой dd в installer'е) — перезапустить installer
  с того же USB payload.
- Если partlabels не совпадают — переразметить (`pc-efi.sgdisk`) и заново
  прошить.
- Если мы попали в emergency shell и можно продолжить:
  ```
  mount -t squashfs -o ro /dev/disk/by-partlabel/rootfs_A /mnt
  ls /mnt/sbin/panel-init-persist-paths   # должен быть
  ```

## 3. `rauc-mark-boot-good.service` failed

### Симптомы
- Панель загрузилась, UI работает, но после 1–2 минут слоту не выставлен `good`.
- `rauc status` показывает slot state как `bad` или `booted`.
- Следующий reboot возвращает к предыдущему slot'у (если это был новый install).

### Диагностика

```bash
journalctl -u rauc-mark-boot-good.service -b
systemctl status rauc-mark-boot-good.service
```

Обычно вывод содержит `[panel-healthcheck] FAIL: <что-то>`.

Частые причины:

| FAIL | Что это значит |
|---|---|
| `lightdm не active` | graphics.target не поднялся — возможно Xorg/driver проблемы |
| `docker не active` | DockerPersistentStorage failed (см. docker-container-store.md) |
| `/home/inauto не mountpoint` | inauto-data раздел не смонтирован initramfs'ом |
| `/var/lib/docker не mountpoint` | container-store bind не сработал |
| `docker info не отвечает после 10 попыток` | docker daemon крашится или висит |
| site healthcheck non-zero | `/home/inauto/config/healthcheck.sh` вернул ошибку |

### Что делать

1. Починить первопричину (обычно docker или mount'ы).
2. Запустить mark-good вручную после фикса:
   ```
   systemctl restart rauc-mark-boot-good.service
   ```
3. Если это был новый install и healthcheck чинить нечем — сразу reboot
   для вернуть предыдущий slot.

## 4. Панель «зависает» в ранней фазе boot'а

### Симптомы
- Чёрный экран, UEFI-лого долго, ничего не происходит.

### Поведение watchdog

Если kernel вышел в panic — через `panic=30` будет auto-reboot. BootNext
(если новый slot) потратится; следующий boot придёт по BootOrder (старый slot).

Если userspace висит и hardware watchdog включён — через
`RuntimeWatchdogSec=60s` принудительный reset.

Если нет ни panic, ни watchdog — **панель мёртвая до ручного reboot**.

### Что делать

1. Hard reset (reset-кнопка / reinsert power).
2. После reboot'а — `rauc status`, посмотреть какой slot активен.
3. Если вернулись на старый slot — проанализировать что в новой rootfs
   сломано. dmesg из failed boot'а не сохраняется; нужен debug USB и
   mount новой rootfs для инспекции.

Подробно — `docs/runbooks/watchdog.md`.

## 5. Heartbeat не уходит на update-server

### Симптомы
- `panel-check-updates.service` active, но `panels.last_seen` на сервере
  не обновляется.

### Диагностика

```bash
journalctl -u panel-check-updates.service -b --no-pager | tail -50
```

Частые проблемы:
- `update-server отсутствует` → `/etc/inauto/update-server` пустой.
- `curl: (6) Could not resolve host` → DNS/сеть проблемы.
- `HTTP 401` → `UPDATE_SERVER_DEPLOY_TOKEN` не совпадает? (панель не
  аутентифицируется, но heartbeat не требует token'а — это проблема
  конфигурации сервера).
- `HTTP 400 "slot обязателен"` → на панели cmdline пропал `rauc.slot=`
  (не должно быть — это означает неправильный bundle).

### Что делать

1. Проверить сетевую связь до сервера:
   ```
   curl -v https://panels.example.com/healthz
   ```
2. Проверить персистентные файлы:
   ```
   cat /etc/inauto/{update-server,channel,serial.txt,firmware-version}
   grep '^compatible=' /etc/rauc/system.conf
   ```
3. Руками запустить agent:
   ```
   /usr/local/bin/panel-check-updates.sh
   ```

## 6. Docker compose проекты не восстанавливаются

См. `docs/runbooks/docker-container-store.md`. Коротко:

- Проверить что labels `com.docker.compose.*` живы в контейнерах:
  `docker ps -a --filter label=com.docker.compose.project`.
- Проверить что compose-файлы по путям из labels существуют.
- `DockerComposeRestore.service` — oneshot; запустить вручную:
  `systemctl start DockerComposeRestore.service` и посмотреть journal.

## 7. Runtime edits в `/etc` не сбрасываются после reboot

### Симптомы
- Правки `/etc/nginx/...` выжили перезагрузку (не ожидалось).

### Вероятные причины

- Панель прошита ISO-target'ом, не RAUC. Проверить
  `cat /etc/inauto/firmware-version` и `findmnt /`.
- `/etc/nginx` попал в persist allowlist (маловероятно — списка мало,
  не должно быть `nginx`).
- Панель не сделала reboot, а только `systemctl daemon-reexec` (overlay
  не сбрасывается без kernel reboot'а).

## 8. Overlay переполнился

### Симптомы
- `No space left on device` при попытке писать в `/tmp`, `/var/log`, `/etc`.

### Причина

tmpfs overlay upper имеет размер `INAUTO_OVERLAY_SIZE=2G` по умолчанию.
Всё, что пишется runtime'ом в rootfs, складывается сюда. Утечки логов
или temp-файлов переполняют overlay.

### Что делать

1. Найти виновника:
   ```
   du -sx /run/panel/tmpfs/upper/* 2>/dev/null | sort -h | tail
   ```
2. Сразу освободить место: удалить из overlay (или reboot — tmpfs
   исчезает).
3. Долгосрочно: переадресовать большие логи в persistent journal
   (`INAUTO_JOURNAL_DIR=/home/inauto/log/journal`) или в `/home/inauto`.

## Диагностический snapshot

Перед открытием тикета — собрать:

```bash
sudo -i
{
  echo "== firmware =="; cat /etc/inauto/firmware-version
  echo "== rauc =="; rauc status
  echo "== cmdline =="; cat /proc/cmdline
  echo "== mounts =="; findmnt --real
  echo "== efibootmgr =="; efibootmgr -v
  echo "== services =="; systemctl list-units --failed
  echo "== dmesg tail =="; dmesg | tail -50
  echo "== healthcheck ==";  journalctl -u rauc-mark-boot-good.service -b --no-pager | tail -50
  echo "== update-agent ==";  journalctl -u panel-check-updates.service -b --no-pager | tail -50
  echo "== docker =="; docker info 2>&1 | head -30
} > /tmp/panel-snapshot.txt

cat /tmp/panel-snapshot.txt  # и отправить в тикет
```
