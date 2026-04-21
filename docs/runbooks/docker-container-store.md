# Runbook: container-store на RAUC-панелях

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc`, `TARGET_PLATFORM=pc-efi` (MVP).

## Что это

На панелях с immutable firmware Docker и containerd больше не пишут в
overlay'ный rootfs и не используют loopback-файл внутри `/home/inauto`.
Вместо этого выделен отдельный GPT-раздел `container-store`:

- устройство: `/dev/disk/by-partlabel/container-store` (ext4);
- точка монтирования: `/var/lib/inauto/container-store`;
- bind-mount'ы делаются initramfs-скриптом (`scripts/local-bottom/panel-boot`):
  - `container-store/docker` → `/var/lib/docker`
  - `container-store/containerd` → `/var/lib/containerd`;
- валидация — `DockerPersistentStorage.service` (`setup-docker-storage.sh` в RAUC-варианте).

`DOCKER_CONFIG` по-прежнему живёт в `/home/inauto/staff/docker-config/<user>`:
это site/project state, не container runtime state. Это политика MVP и
менять её отдельной фазой без явной необходимости не нужно.

## Что НЕ защищается OS rollback'ом

RAUC-rollback атомарно переключает только `rootfs_A` ↔ `rootfs_B` и
соответствующую boot-группу (`efi_A` ↔ `efi_B`). Остальное не откатывается:

- `container-store` (Docker images/containers/volumes, containerd metadata);
- `persist` (machine-id, host keys, update-server config и т.п.);
- `inauto-data` (`/home/inauto`: compose проекты, Qt-app, логи и данные наладчика).

Практические следствия:

1. **Docker/containerd major upgrades требуют candidate-testing.**
   Если версия daemon'а в новом bundle несовместима с метаданными/графом
   слоёв, уже лежащими в `container-store`, нельзя «просто откатить» OS.
   На rollback старый daemon может не стартовать поверх мигрированного
   хранилища.

   Процедура перед публикацией такой сборки в `stable`:
   - выкатить bundle в `candidate`;
   - прогнать 24-часовой soak на тестовых панелях;
   - убедиться, что `docker info`, `docker ps`, `docker compose up -d`
     отрабатывают штатно;
   - только после этого promote в `stable`.

2. **Бизнес-данные — bind'ами из `/home/inauto`, не только Docker volumes.**
   Рекомендация: размещать compose-файлы, `.env`, и сохраняемые данные
   (БД, артефакты, загружаемые пользователем файлы) под `/home/inauto/...`
   и монтировать их в контейнеры через `volumes: - /home/inauto/...:...`.
   Тогда при уничтожении container-store данные остаются в `inauto-data`.

3. **Docker named volumes — runtime-состояние.**
   Их можно использовать, но относиться как к кеш'у: при miscatch'е OS/daemon
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
   installer'ом, некорректный partlabel, повреждённый ext4. См.
   `docs/runbooks/troubleshooting.md` (будет добавлен).

### «Нужно вручную вычистить Docker-слои, не пересобирая OS»

Удалять содержимое `container-store` — безопасно (в отличие от overlayfs в
mutable Ubuntu). Процедура:
```
systemctl stop docker.service containerd.service
rm -rf /var/lib/inauto/container-store/docker/*
rm -rf /var/lib/inauto/container-store/containerd/*
systemctl start containerd.service docker.service
```
После этого compose-проекты потребуется перезапустить
(`DockerComposeRestore.service` должен их поднять при `docker compose` labels).

## Что делать, если Docker metadata несовместим после OS rollback

Сценарий: мы откатились с версии N+1 (новый daemon) на N (старый daemon),
а `container-store` содержит метаданные новой версии.

Варианты по убыванию предпочтительности:

1. **Выкатить новый bundle в `candidate`, поднять обратно, проверить и
   promote.** Если новый bundle не сломан в целом, а упал по другой
   причине — просто поднять его обратно.
2. **Попробовать запустить daemon старой версии** и посмотреть, умеет ли
   он работать с новыми метаданными (обычно Docker умеет только
   читать свои же или более старые).
3. **Очистить `container-store` и восстановить compose-проекты.**
   Данные бизнеса должны лежать под `/home/inauto`, compose-проекты
   поднимутся из `DockerComposeRestore.service`.

«Никогда не трогать container-store при rollback» не годится, потому что
без данных OS rollback всё равно не откатит daemon state.

## Ссылки

- Spec: `docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md`
- Plan: `docs/superpowers/plans/2026-04-20-immutable-panel-firmware.md`
- Реализация: `scripts/config.sh::make_docker_storage_script_rauc`,
  `scripts/profiles/<distro>/rauc/initramfs-scripts/panel-boot`.
