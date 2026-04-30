# Скрипты сборки

## build.sh

```console
Этот скрипт собирает загрузочный ISO-образ Ubuntu

Поддерживаемые команды : setup_host debootstrap prechroot chr_setup_host chr_install_pkg chr_customize_image chr_custom_conf chr_postpkginst scan_vulnerabilities chr_build_image chr_finish_up postchroot build_iso

Синтаксис: ./build.sh [start_cmd] [-] [end_cmd]
  выполнить команды от start_cmd до end_cmd
  если start_cmd не указан, выполнение начнется с первой команды
  если end_cmd не указан, выполнение завершится на последней команде
  можно указать одну команду, чтобы выполнить только ее
  символ '-' как единственный аргумент запускает все команды
```

`build.sh` — это точка входа для нативной сборки на хосте. Он предполагает, что все зависимости уже установлены на хостовой системе, и по умолчанию должен запускаться от обычного пользователя с доступным `sudo`.

## build-in-docker.sh

```console
Этот wrapper запускает тот же pipeline сборки ISO внутри привилегированного Docker builder-контейнера.

Использование: ./build-in-docker.sh [--rebuild-builder] [--shell] [--] [аргументы build.sh...]
```

Основные возможности:

- использует существующие этапы `build.sh`
- включает `debootstrap`, `xorriso`, `mksquashfs`, `jq` и `trivy` прямо в builder-образ
- для RAUC-target дополнительно ставит `rauc`, `dosfstools`, `mtools`, `gdisk`, `parted`, `kmod`, `initramfs-tools`, `efibootmgr`, `openssl` (и опционально `u-boot-tools` для планшетных сборок)
- по умолчанию хранит тяжелое дерево `scripts/chroot` в именованном Docker volume
- возвращает итоговые ISO-артефакты и отчеты обратно в workspace репозитория

Типовые примеры:

```console
./build-in-docker.sh -
./build-in-docker.sh --clean debootstrap - build_iso
./build-in-docker.sh debootstrap - build_iso
BUILDER_PLATFORM=linux/amd64 ./build-in-docker.sh -
```

Важные переменные окружения:

- `BUILDER_PLATFORM` по умолчанию: `linux/amd64`
- `DOCKER_USE_SUDO` по умолчанию: `auto`
- `REBUILD_BUILDER` по умолчанию: `0`
- `CLEAN_BUILD` по умолчанию: `0`; удаляет `scripts/chroot`, `scripts/image` и volume для `scripts/chroot` перед сборкой
- `LIVECD_CHROOT_VOLUME` по умолчанию: `<repo-name>-chroot`
- `TRIVY_CACHE_VOLUME` по умолчанию: `<repo-name>-trivy-cache`
- `DOCKER_BUILD_NETWORK` опционально: network mode для `docker build`, например `host`
- `DOCKER_RUN_NETWORK` опционально: network mode для `docker run`, например `host`
- `CHOWN_OUTPUTS` по умолчанию: `1`

При `DOCKER_USE_SUDO=auto` wrapper сначала пробует обычный доступ к Docker, а если получает ошибку доступа к `docker.sock`, автоматически перезапускает Docker-команды через `sudo`.

Платформа builder'а `linux/amd64` по умолчанию позволяет собирать текущий `amd64` ISO и на non-amd64 Docker-хостах, если доступна эмуляция `amd64`-контейнеров. Сам builder переносим между разными хост-платформами, но итоговый ISO в этом репозитории пока проверен только для загрузки на `amd64/x86_64`.

## Как настраивать сборку

Основной конфиг сборки — `scripts/config.sh`. Файл обязателен: `build.sh` завершается с ошибкой, если он отсутствует. `default_config.sh` удалён — при необходимости создайте `config.sh` вручную или скопируйте из любого существующего окружения.

## Профиль среды XFCE (для `config.sh` этого репозитория)

Файл `config.sh` в этом репозитории настроен под ограниченную киоск-среду XFCE со следующими обязательными возможностями:
- доступ по SSH (по ключам)
- доступ по VNC (служба `x11vnc`)
- запуск пользовательских хуков со специального постоянного раздела, помеченного файлом `.inautolock`

### Структура постоянного раздела

Корень смонтированного постоянного раздела: `/home/inauto`.

Ожидаемая структура:

```text
/home/inauto/
  .inautolock
  docker/
    docker-data.ext4
  docker-config/
    root/
    ubuntu/
  on_start/
    before_login/
    oneshot/
    forking/
  on_login/
  # Историческое имя каталога сохранено для совместимости со старыми payload
  staff/lxqt/
    netplan/*.yaml
    etc/
    usr/
    opt/
    home/inauto/
    xdg/
    autostart/
    systemd/
    certs/system-ca/
    secrets/x11vnc.pass
```

### Постоянное хранилище Docker и containerd

- Docker и `containerd` больше не пишут напрямую в live-rootfs: при старте live-системы создается и монтируется файл `/home/inauto/docker/docker-data.ext4`.
- Этот `ext4`-store bind-mount'ится в стандартные каталоги `/var/lib/docker` и `/var/lib/containerd`, поэтому образы, контейнеры, слои и volume'ы переживают перезагрузку.
- Логины `docker login` сохраняются в `/home/inauto/docker-config/<user>`, поэтому после reboot не нужно заново аутентифицироваться, если использовался интерактивный shell соответствующего пользователя.
- Если постоянный раздел недоступен, Docker и `containerd` запускаются в эпhemeral-режиме на live-rootfs.

### Автовосстановление Compose

- После старта Docker live-система ищет уже существующие compose-контейнеры по labels `com.docker.compose.*` и выполняет для найденных проектов `docker compose up -d`.
- Чтобы это работало предсказуемо, compose-файлы, `.env` и bind-mounted данные должны лежать на постоянном разделе, обычно внутри `/home/inauto`.
- Для новых проектов достаточно один раз выполнить обычный `docker compose up -d`; после следующей перезагрузки этот проект будет восстановлен автоматически.

## Как обновлять конфигурацию

Файл конфигурации версионируется через переменную `CONFIG_FILE_VERSION` (сейчас `"0.6"`). При добавлении или изменении переменных версия поднимается вручную, а `build.sh::check_config()` обновляется соответственно — иначе сборка не запустится.

## Immutable firmware target (RAUC)

С версии конфигурации `0.6` добавлена альтернативная цель сборки — immutable firmware для operator-панелей через RAUC. ISO-путь (`TARGET_FORMAT=iso`) остаётся дефолтным и не меняется.

Новый путь активируется переменной окружения:

```console
TARGET_FORMAT=rauc TARGET_PLATFORM=pc-efi ./build-in-docker.sh -
```

После фаз 0–4 включительно доступна полная сборка `.raucb` bundle'а: `build_iso` останавливается после `mksquashfs` при `TARGET_FORMAT=rauc`, затем отдельный stage `build_rauc_bundle` собирает `efi.vfat` (kernel + initrd) и подписывает bundle ключами из `RAUC_SIGNING_CERT`/`RAUC_SIGNING_KEY` (по умолчанию dev-ключи из `pki/`). Готовый артефакт лежит в `out/inauto-panel-<distro>-<arch>-pc-efi-<version>.raucb`.

Ключевые RAUC-переменные (см. `config.sh`):

- `TARGET_PLATFORM=pc-efi` — UEFI PC (MVP); `<board>-uboot` — планшет.
- `TARGET_ARCH=amd64` — информационно.
- `RAUC_BUNDLE_VERSION` — обязательный явный вход для релизных сборок; production-версии валидируются regex `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$`.
- `INAUTO_OVERLAY_SIZE=2G` — размер tmpfs overlay upper для immutable rootfs.
- `INAUTO_SITE_CONFIG_DIR`, `INAUTO_AUTOSTART_SCRIPT`, `INAUTO_JOURNAL_DIR` — пути внутри `/home/inauto`.

## Этап отчета об уязвимостях

Этап `scan_vulnerabilities` сканирует подготовленный `chroot/` как rootfs и записывает артефакты в `scripts/reports/<target>-<timestamp>/`.

Требования:
- `trivy` должен быть установлен на хосте при использовании `./build.sh`
- при использовании `./build-in-docker.sh` Trivy уже входит в builder-образ
- `jq` устанавливается этапом `./build.sh setup_host`

Создаваемые файлы:
- `metadata.txt` — параметры сканирования и версия Trivy
- `os-release` — метаданные целевой ОС из `chroot`
- `packages.tsv` — инвентарь установленных пакетов
- `trivy-rootfs.json` — полный машиночитаемый отчет об уязвимостях
- `trivy-rootfs.txt` — человекочитаемая таблица уязвимостей
- `vulnerabilities.tsv` — строки package/version/CVE/fixed-version для последующего анализа
- `affected-packages.txt` — уникальные имена пакетов, в которых найдены проблемы
- `summary.txt` — краткая сводка по уровням критичности

Примеры:

```console
./build.sh chr_postpkginst - scan_vulnerabilities
./build.sh scan_vulnerabilities
```

Необязательные переменные окружения:
- `VULN_SCAN_SEVERITIES` по умолчанию: `UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL`
- `VULN_SCAN_TIMEOUT` по умолчанию: `15m`
- `VULN_REPORT_DIR` по умолчанию: `scripts/reports/<target>-<timestamp>`

Если в корне репозитория или в `scripts/` существует файл `.trivyignore`, он будет использован автоматически.
