# Runbook: миграция существующей mutable-панели на immutable firmware

Дата: 2026-04-20
Применимость: панели, ранее прошитые старым ISO (mutable Ubuntu + casper).

## Scope

Перевод панели с mutable ISO на immutable RAUC firmware. In-place
repartitioning **не поддерживается** в первом production-релизе: диск
полностью переразмечается. Поэтому процедура = backup + reflash + restore.

**Downtime на панель:** ~30 минут (зависит от объёма `/home/inauto`).

**Автоматический путь (по умолчанию):** installer сам ищет существующее
`/home/inauto` с маркером `.inautolock` на non-removable устройствах,
архивирует его до разметки диска и распаковывает в `/home/inauto/backup/`
после установки. Ручной rsync на ноутбук инженера — fallback для
случаев, когда автомат не подходит (очень большой `/home/inauto`,
особая топология дисков, debug).

## Предпосылки

- Панель работает под старым ISO (mutable).
- Accessible: SSH/локальный терминал, sudo-права (или физический доступ).
- В `/home/inauto` лежат рабочие compose-проекты, Qt-app, site config.
- Сетевой доступ до backup-хранилища (rsync/SSH target или USB).

## Этапы

### Этап 1 — Подготовка

На сборочном host'е (не на панели):
- Собран installer payload нужной версии.
- Подготовлен Ubuntu Live USB + вторая USB с payload + `.sha256`.
- Проверено в QEMU (`docs/runbooks/qemu-pc-efi-test.md`), что bundle boot'ится.

На панели:
- Убедиться что Docker compose-проекты помечены labels'ами
  `com.docker.compose.*` (иначе `DockerComposeRestore.service` их не
  восстановит).
- Сделать `docker compose pull` для всех проектов — чтобы после миграции
  не зависеть от внешних registries.

### Этап 2 — Подготовка (до boot'а installer'а)

На работающей mutable-панели:

```bash
# Зафиксировать состояние compose (пригодится для audit после миграции):
sudo docker ps -a > /home/inauto/log/migration-docker-ps.txt
sudo docker images > /home/inauto/log/migration-docker-images.txt

# Остановить compose-проекты, чтобы не было активных writes в /home/inauto:
for proj in $(docker compose ls -q); do
    docker compose -p "$proj" stop || true
done

sync
```

Убедитесь, что у `/home/inauto/.inautolock` правильный маркер —
installer его использует для автодетекта.

### Этап 3 — Reflash через factory-provisioning runbook (с автоматическим backup'ом)

См. `docs/runbooks/factory-provisioning.md`. Installer сам делает backup
и restore при миграции:

1. Boot с Ubuntu Live USB (mutable-система останавливается, `/home/inauto`
   больше не пишется — мы теперь в live-сессии).
2. Распаковать installer payload.
3. Если `/home/inauto` большой (> ~30% RAM):
   ```
   export BACKUP_DIR=/media/<second-usb>/inauto-backup
   ```
   Иначе — default `/tmp/inauto-backup` (tmpfs, живёт в RAM live-session).
4. Запустить `install-to-disk.sh` с `TARGET_DEVICE=/dev/<внутренний_диск>`.
   Скрипт покажет выбранный диск и продолжит только после ввода `yes`.

Installer выполнит (в строгом порядке):
- **Backup** — `backup-restore-home.sh backup` сканирует
  non-removable блок-устройства на `.inautolock` (исключая
  TARGET_DEVICE и USB), архивирует находку в `$BACKUP_DIR/home-inauto.tar.zst`
  + `.sha256`.
- GPT разметка, dd raw-образов, UEFI entries, persist/inauto-data
  skeletons — всё как для новой панели.
- **Restore** — `backup-restore-home.sh restore /home/inauto/backup` —
  распаковывает archive в подкаталог `backup/`, skeleton сохраняется
  нетронутым.
- Reboot.

### Этап 4 — Перенос данных из `/home/inauto/backup` в active layout

После reboot'а на immutable firmware:

```bash
ssh ubuntu@<ip_панели>
sudo -i

ls /home/inauto/backup/
# Ожидаем структуру старой панели: on_start/, on_login/, staff/, log/ и т.п.

du -sh /home/inauto/backup/
# Сравнить с backup-tarball'ом или с `du` исходной панели до миграции.
```

Перенос решает наладчик (installer не делает mixing автоматически,
чтобы не затереть изменения skeleton'а от новой версии rootfs):

```bash
# Типичный сценарий — compose-проекты и site config переезжают целиком:
rsync -aHAX /home/inauto/backup/staff/         /home/inauto/staff/
rsync -aHAX /home/inauto/backup/on_start/      /home/inauto/on_start/
rsync -aHAX /home/inauto/backup/on_login/      /home/inauto/on_login/

# Если на старой панели был config/ site-specific каталог:
[[ -d /home/inauto/backup/config ]] && \
    rsync -aHAX /home/inauto/backup/config/ /home/inauto/config/

# После переноса можно удалить backup (или оставить как audit trail):
# rm -rf /home/inauto/backup
```

**Важно про permissions:** installer восстанавливает xattrs/ACL через
`tar --xattrs-include='*'`, но UIDs внутри tarball'а отражают старую
панель. Если user id'ы различаются (очень редко — autologin user =
`ubuntu` с uid 1000 в обеих версиях), нужно `chown -R ubuntu:ubuntu
/home/inauto/staff /home/inauto/on_login /home/inauto/on_start`.

### Этап 4.1 — Fallback: ручной rsync (если автомат не подошёл)

Если `/home/inauto` слишком большой и `BACKUP_DIR` на второй USB тоже
не помещает (редкий кейс — десятки ГБ compose-образов в rootfs панели),
используется ручной rsync на ноутбук инженера ДО запуска installer'а:

```bash
# На панели:
rsync -aHAXv --progress /home/inauto/ \
    engineer@laptop:/backup/panels/<serial>/home-inauto/

ssh engineer@laptop 'du -sh /backup/panels/<serial>/home-inauto/'
# Сверить с local `du -sh /home/inauto/`.
```

Затем запустить installer **без** backup-шага:

```bash
SKIP_BACKUP=1 /opt/inauto-installer/install-to-disk.sh
# Installer всё равно попросит подтвердить стирание выбранного диска вводом `yes`.
```

После reboot'а restore'ить данные rsync'ом обратно:

```bash
rsync -aHAXv --progress \
    engineer@laptop:/backup/panels/<serial>/home-inauto/ \
    /home/inauto/
```

### Этап 5 — Восстановление compose-проектов

`DockerComposeRestore.service` запускается при boot'е и для всех
compose-проектов с labels делает `docker compose up -d`. Но на свежем
rootfs образы не загружены (container-store пустой). Поэтому:

```bash
# Либо reboot — сервис сам поднимет:
systemctl reboot

# Либо руками, не дожидаясь reboot'а:
for compose_dir in $(find /home/inauto -name docker-compose.yml -o -name compose.yaml); do
    cd "$(dirname "$compose_dir")"
    docker compose up -d
done
```

Образы скачаются в `container-store` и после первого reboot'а будут
автовосстанавливаться.

### Этап 6 — Смена канала и serial

```bash
echo "stable" > /etc/inauto/channel
echo "panel-<site>-<n>" > /etc/inauto/serial.txt
# update-server уже был в backup'е /persist — но /persist в новой rootfs
# по умолчанию пустой. Заполняем вручную:
echo "https://panels.example.com" > /etc/inauto/update-server

systemctl restart panel-check-updates.timer
```

### Этап 7 — Acceptance

Прогон checklist из `factory-provisioning.md` раздел "Acceptance".
Дополнительно:

- [ ] Все compose-проекты из миграции работают (`docker compose ls`).
- [ ] Объём `/home/inauto` соответствует backup'у (`du -sh` сравнение).
- [ ] На update-сервере появился heartbeat с правильным `serial`.
- [ ] 24 часа soak'а на панели до признания миграции успешной.

## Rollback к старому ISO

Если после миграции панель не работает и срочно нужно вернуть старый
ISO — обратный путь:

1. Boot с Ubuntu Live USB.
2. Restored `/home/inauto` уже есть в backup'е — можно использовать его.
3. Прошить старую ISO-версию (прежние команды `./scripts/build.sh -`
   и `dd` образа).
4. Restore `/home/inauto` через rsync.

## Чего делать нельзя

- **In-place переразметить диск без backup'а.** Риск потерять compose-данные.
- **Скопировать `/persist` со старой панели на новую immutable-панель.**
  Старый `/persist` не существует на mutable ISO — это раздел появляется
  только после install'а immutable firmware. Не путать с `/home/inauto`.
- **Оставить панель на dev-канале в production.** `/etc/inauto/channel`
  должен быть `stable` после миграции.
- **Skip 24h soak.** Даже если всё визуально работает — прогнать сутки
  на панели под реальной нагрузкой перед подтверждением.
