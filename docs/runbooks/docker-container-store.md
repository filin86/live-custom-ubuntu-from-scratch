# Инструкция: container-store на RAUC-панелях

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc`, `TARGET_PLATFORM=pc-efi` (MVP).

## Что это

На панелях с неизменяемой RAUC-системой Docker и containerd больше не пишут в
overlay-rootfs и не используют loopback-файл внутри `/home/inauto`.
Вместо этого выделен отдельный GPT-раздел `container-store`:

- устройство: `/dev/disk/by-partlabel/container-store` (ext4);
- точка монтирования: `/var/lib/inauto/container-store`;
- bind-mount'ы делаются initramfs-скриптом (`scripts/local-bottom/panel-boot`):
  - `container-store/docker` → `/var/lib/docker`
  - `container-store/containerd` → `/var/lib/containerd`;
- валидация — `DockerPersistentStorage.service` (`setup-docker-storage.sh` в RAUC-варианте).

`DOCKER_CONFIG` по-прежнему живёт в `/home/inauto/staff/docker-config/<user>`:
это состояние объекта и проекта, а не runtime-состояние контейнеров. Это
политика MVP, менять её отдельной фазой без явной необходимости не нужно.

## Что НЕ защищается откатом системы

RAUC-rollback атомарно переключает только `rootfs_A` ↔ `rootfs_B` и
соответствующую boot-группу (`efi_A` ↔ `efi_B`). Остальное не откатывается:

- `container-store` (образы, контейнеры, тома Docker, метаданные containerd);
- `persist` (machine-id, host keys, настройки сервера обновлений и т.п.);
- `inauto-data` (`/home/inauto`: compose-проекты, Qt-приложение, логи и данные наладчика).

Практические следствия:

1. **Крупные обновления Docker/containerd требуют проверки в `candidate`.**
   Если версия daemon в новом RAUC-пакете несовместима с метаданными/графом
   слоёв, уже лежащими в `container-store`, нельзя «просто откатить» систему.
   При откате старый daemon может не стартовать поверх мигрированного
   хранилища.

   Процедура перед публикацией такой сборки в `stable`:
   - выкатить RAUC-пакет в `candidate`;
   - прогнать 24-часовую проверку на тестовых панелях;
   - убедиться, что `docker info`, `docker ps`, `docker compose up -d`
     отрабатывают штатно;
   - только после этого перевести в `stable`.

2. **Данные объекта — bind-монтированиями из `/home/inauto`, не только томами Docker.**
   Рекомендация: размещать compose-файлы, `.env`, и сохраняемые данные
   (БД, артефакты, загружаемые пользователем файлы) под `/home/inauto/...`
   и монтировать их в контейнеры через `volumes: - /home/inauto/...:...`.
   Тогда при уничтожении container-store данные остаются в `inauto-data`.

3. **Именованные тома Docker — runtime-состояние.**
   Их можно использовать, но относиться как к кешу: при несовместимости системы/daemon
   их может потребоваться пересоздавать.

## Диагностика

### «Docker не стартует после обновления»

1. Проверить что раздел существует:
   ```
   ls -l /dev/disk/by-partlabel/container-store
   ```
2. Проверить, что всё смонтировано:
   ```
   mountpoint -q /var/lib/inauto/container-store && echo ok
   mountpoint -q /var/lib/docker && echo ok
   mountpoint -q /var/lib/containerd && echo ok
   ```
3. Логи сервиса:
   ```
   journalctl -u DockerPersistentStorage.service -b
   journalctl -u docker.service -b
   ```
4. Если `DockerPersistentStorage.service` упал с «не является bind-mount»,
   `initramfs`-этап не смог подмонтировать. Причины: раздел не создан
   установщиком, некорректный partlabel, повреждённый ext4. См.
   `docs/runbooks/troubleshooting.md`.

### «Нужно вручную вычистить Docker-слои, не пересобирая систему»

Удалять содержимое `container-store` — безопасно (в отличие от overlayfs в
изменяемой Ubuntu). Процедура:
```
systemctl stop docker.service containerd.service
rm -rf /var/lib/inauto/container-store/docker/*
rm -rf /var/lib/inauto/container-store/containerd/*
systemctl start containerd.service docker.service
```
После этого compose-проекты потребуется перезапустить
(`DockerComposeRestore.service` должен их поднять при `docker compose` labels).

## Что делать, если метаданные Docker несовместимы после отката системы

Сценарий: мы откатились с версии N+1 (новый daemon) на N (старый daemon),
а `container-store` содержит метаданные новой версии.

Варианты по убыванию предпочтительности:

1. **Выкатить новый RAUC-пакет в `candidate`, поднять обратно, проверить и
   перевести в `stable`.** Если новый RAUC-пакет не сломан в целом, а упал по другой
   причине — просто поднять его обратно.
2. **Попробовать запустить daemon старой версии** и посмотреть, умеет ли
   он работать с новыми метаданными (обычно Docker умеет только
   читать свои же или более старые).
3. **Очистить `container-store` и восстановить compose-проекты.**
   Данные бизнеса должны лежать под `/home/inauto`, compose-проекты
   поднимутся из `DockerComposeRestore.service`.

«Никогда не трогать container-store при откате» не годится, потому что
без этих данных откат системы всё равно не откатит состояние daemon.

## Ссылки

- Design: `docs/2026-04-20-immutable-panel-firmware-design.md`
- Реализация: `scripts/config.sh::make_docker_storage_script_rauc`,
  `scripts/profiles/<distro>/rauc/initramfs-scripts/panel-boot`.
