# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## О проекте

Репозиторий собирает собственный кастомизированный Ubuntu Live ISO «с нуля» (форк `mvallim/live-custom-ubuntu-from-scratch`, актуальная целевая версия — Ubuntu 24.04 Noble). Внутри образа по умолчанию преднастроены: админский пользователь с автологином, VNC (`x11vnc`) с паролем, предустановленный Docker + systemd-юнит для восстановления compose-проектов при старте системы.

**Технологический стек проекта — Bash + Docker + Ubuntu tooling** (`debootstrap`, `squashfs-tools`, `xorriso`, `grub`, `casper`, `systemd`). Python-инструментарий из пользовательского глобального CLAUDE.md (`uv`, `ruff`, `pyright`, `pytest`) **к этому репозиторию не применяется** — здесь нет Python-кода. Глобальные принципы (Clean Architecture, DDD, TDD) тоже неприменимы по той же причине.

## Частые команды

### Сборка в контейнере (основной и рекомендуемый способ)

```bash
# Полный цикл сборки ISO
./scripts/build-in-docker.sh -

# Сборка с нуля (очищает scripts/chroot, scripts/image, chroot volume)
CLEAN_BUILD=1 ./scripts/build-in-docker.sh -
# или
./scripts/build-in-docker.sh --clean -

# Пересобрать builder-образ перед запуском
REBUILD_BUILDER=1 ./scripts/build-in-docker.sh -
# или
./scripts/build-in-docker.sh --rebuild-builder -

# Открыть интерактивный shell внутри builder-контейнера (для отладки)
./scripts/build-in-docker.sh --shell

# Запустить только отдельные этапы (см. список ниже)
./scripts/build-in-docker.sh debootstrap - build_iso
./scripts/build-in-docker.sh chr_install_pkg - chr_build_image
```

Для сборки на Windows/macOS/arm64-хостах оставляйте `BUILDER_PLATFORM=linux/amd64` (по умолчанию). Ключ `-` в `build.sh` означает «запустить все этапы от предыдущего до следующего аргумента включительно».

**ВАЖНО:** прошлый коммит в истории (`b83a406`) специально отмечает, что для надёжной сборки образа нужно запускать сборку именно через эту команду (а не `build.sh` напрямую на хосте).

### Прямой запуск на хосте (Ubuntu)

```bash
# Полный цикл (требует sudo на хосте, пакеты debootstrap/squashfs-tools/xorriso/binutils/zstd/jq)
./scripts/build.sh -

# Отдельный этап или диапазон этапов
./scripts/build.sh debootstrap
./scripts/build.sh debootstrap - build_iso
```

### Управляющие переменные окружения (`build-in-docker.sh`)

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `DOCKER_BIN` | CLI docker | `docker` |
| `DOCKER_USE_SUDO` | `auto` / `0` / `1` — пробрасывать docker через sudo | `auto` |
| `BUILDER_IMAGE` | тег builder-образа | `livecd-builder:local` |
| `BUILDER_PLATFORM` | платформа контейнера | `linux/amd64` |
| `DOCKERFILE_PATH` | путь к Dockerfile builder-а | `docker/Builder.Dockerfile` |
| `LIVECD_CHROOT_VOLUME` | named volume для `scripts/chroot` | `<repo>-chroot` |
| `TRIVY_CACHE_VOLUME` | named volume кеша Trivy | `<repo>-trivy-cache` |
| `DOCKER_BUILD_NETWORK` / `DOCKER_RUN_NETWORK` | сетевой режим (например, `host`) | пусто |
| `HOST_CA_BUNDLE` | CA-bundle хоста, копируется в builder | `/etc/ssl/certs/ca-certificates.crt` |
| `CHOWN_OUTPUTS` | `0` — не менять владельца reports/ISO на хостового юзера | `1` |
| `HOST_UID` / `HOST_GID` | владелец артефактов на выходе | UID/GID текущего юзера |

## Архитектура сборки

### Двухуровневая оркестрация

Сборка разделена на **две исполнительные среды**, каждая со своим скриптом:

1. **Хостовый оркестратор** — `scripts/build.sh`. Запускается на хосте (или в privileged builder-контейнере). Готовит `chroot/`, монтирует в него `/dev` и `/run`, копирует внутрь артефакты, вызывает chroot-фазу, собирает финальный ISO через `xorriso`.
2. **Внутри-chroot скрипт** — `scripts/chroot_build.sh`. `build.sh` кладёт его в `chroot/root/chroot_build.sh` и прогоняет через `chroot chroot /root/chroot_build.sh <stage>`. Именно этот скрипт выполняет всю кастомизацию Ubuntu внутри подготовленного корня.

Порядок этапов (переменная `CMD` в `build.sh`):

```
setup_host -> debootstrap -> prechroot
  -> chr_setup_host -> chr_install_pkg -> chr_customize_image
  -> chr_custom_conf -> chr_postpkginst -> scan_vulnerabilities
  -> chr_build_image -> chr_finish_up -> postchroot -> build_iso
```

Этапы с префиксом `chr_` выполняются **внутри chroot** через `chroot_build.sh`, остальные — на хосте/в builder-контейнере. `scan_vulnerabilities` запускает Trivy в самом chroot-а и пишет отчёты в `scripts/reports/`.

### Builder-контейнер

`docker/Builder.Dockerfile` описывает привилегированный билдер-образ, в котором установлены все хост-зависимости (`debootstrap`, `squashfs-tools`, `xorriso`, `binutils`, `zstd`, `jq`, Trivy). `docker/container-entrypoint.sh` при старте контейнера опционально «усыновляет» артефакты (`image/`, `reports/`, `*.iso`) на `HOST_UID:HOST_GID` через `chown`, чтобы файлы с хоста было удобно читать и коммитить.

`build-in-docker.sh` монтирует:
- репозиторий в `/workspace` (read-write);
- named volume `<repo>-chroot` в `/workspace/scripts/chroot` (чтобы не упереться в overlayfs внутри контейнера — debootstrap требует реальную ФС);
- named volume `<repo>-trivy-cache` в `/var/lib/trivy` (для кеша БД уязвимостей).

Контейнер запускается с `--privileged` — это нужно для bind-mounts `/dev` и `/run` в chroot.

### Конфигурация: `config.sh` перекрывает `default_config.sh`

`build.sh::load_config()` загружает `scripts/config.sh`, если файл существует; иначе падает на `scripts/default_config.sh`. **Версия конфига проверяется** (`CONFIG_FILE_VERSION`, сейчас `"0.6"`) — при подъёме обязательно обновлять и локальный `config.sh`.

Ключевые переменные конфигурации (определены в `default_config.sh`):
- `TARGET_UBUNTU_VERSION` (например, `noble`), `TARGET_UBUNTU_MIRROR`, `TARGET_NAME`;
- параметры админского пользователя и VNC-пароля;
- список устанавливаемых пакетов и хуки кастомизации.

При модификации сборки **правьте `config.sh` (override)**, а не `default_config.sh`, если нужна локальная настройка, которая не должна попасть всем потребителям дефолтов.

### Цели сборки: `TARGET_FORMAT`

С версии конфига `0.6` сборка параметризуется новой переменной `TARGET_FORMAT`:

- `TARGET_FORMAT=iso` (по умолчанию) — классический Live ISO, текущий workflow без изменений.
- `TARGET_FORMAT=rauc` — immutable firmware для operator-панелей через RAUC (A/B обновления, SquashFS rootfs, tmpfs overlay). Детали в `docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md`, план реализации в `docs/superpowers/plans/2026-04-20-immutable-panel-firmware.md`.

Сопутствующие переменные при `TARGET_FORMAT=rauc`:

- `TARGET_PLATFORM` (`pc-efi` для UEFI PC в MVP; `<board>-uboot` для планшетов после идентификации SoC/BSP);
- `TARGET_ARCH` (информационно; для MVP — `amd64`);
- `RAUC_BUNDLE_VERSION` — обязательный явный вход для релизных сборок (из git tag `vYYYY.MM.DD.N`); production-версии валидируются regex `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$`. Дефолт не задаётся намеренно — silent wall-clock versioning запрещён;
- `INAUTO_OVERLAY_SIZE` (размер tmpfs overlay upper, по умолчанию `2G`);
- `INAUTO_SITE_CONFIG_DIR`, `INAUTO_AUTOSTART_SCRIPT`, `INAUTO_JOURNAL_DIR` — site-интеграционные пути внутри `/home/inauto`.

`build.sh::check_config()` валидирует значения `TARGET_FORMAT` и `TARGET_PLATFORM` при старте.

### Профили дистрибутивов

Distro-specific логика изолирована в `scripts/profiles/<name>/` (`ubuntu/` и `debian/`). Каждый профиль содержит: `profile.env`, `sources.list.template`, `live-packages.list`, `hooks.sh` (4 функции: `profile_install_live_stack`, `profile_kernel_install`, `profile_write_image_marker`, `profile_write_boot_configs`), `iso-layout/{grub,isolinux}.cfg.template`. Общий код (`build.sh`, `chroot_build.sh`) distro-agnostic: читает профиль и дёргает хуки.

Переключатель — `TARGET_DISTRO=ubuntu|debian` в `scripts/config.sh` или окружении. Под каждый дистрибутив собирается отдельный builder-образ `livecd-builder-${TARGET_DISTRO}:local` из одного `docker/Builder.Dockerfile` (`ARG BASE_IMAGE`).

### Артефакты и выходные файлы

- `scripts/chroot/` — полноценная корневая ФС будущего ISO (живёт в named volume при контейнерной сборке);
- `scripts/image/` — исходники ISO (casper, grub, isolinux, squashfs);
- `scripts/reports/` — отчёты Trivy;
- `scripts/*.iso` — готовый образ.

## Что модифицируется в собранном образе

В `chroot_build.sh` настраиваются (ключевые блоки):
- **LightDM + автологин** — юзер логинится автоматически, UI запускается сразу;
- **`x11vnc`** — systemd-юнит `x11vnc.service`, пароль хранится в `/etc/x11vnc.pass`, работает поверх дисплея `:0` LightDM'а;
- **Docker + compose-восстановление** — в образ ставится Docker; при старте системы отдельный systemd-сервис через helper-скрипт находит compose-проекты (по label `com.docker.compose.project`) и делает `docker compose up -d` для каждого, если все указанные compose-файлы доступны;
- **NetworkManager** с renderer'ом `ifupdown`/`keyfile`, `dns=systemd-resolved`;
- **SSH** — включён по конфигу;
- **CA-bundle хоста** — копируется в `chroot/usr/local/share/ca-certificates/inauto-host-ca.crt` и регистрируется через `update-ca-certificates` (нужно в корпсетях с self-signed прокси).

## CI

В `.github/workflows/` лежат воркфлоу `build-bionic.yml`, `build-focal.yml`, `build-jammy.yml`, `build-noble.yml` — собирают ISO под соответствующие релизы Ubuntu. Основная рабочая ветка для noble — та, что в локальной сборке.

## Правила при изменении кода

1. **Идиомы bash.** Все скрипты написаны с `set -euo pipefail` (либо эквивалентом) и кавычат переменные — сохраняйте это. Проверяйте `shellcheck`, если он доступен.
2. **Не ломайте идемпотентность.** Каждый этап `build.sh` должен переживать повторный запуск. Например, в `enable_vnc()` пароль пишется, только если файла ещё нет.
3. **Этапы `chr_*` запускаются внутри chroot** — в них недоступны хостовые пути и нельзя полагаться на хостовые переменные окружения, кроме тех, что проброшены через `/usr/bin/env`.
4. **Секреты.** Пароли (админ, VNC) берутся из `config.sh`/`default_config.sh`. Не хардкодьте новые пароли в местах, где их нельзя перекрыть локальным `config.sh`.
5. **Комментарии и сообщения.** Логи/комментарии — на русском (как в остальном проекте автора); имена переменных и функций — на английском snake_case.
6. **Версия конфига.** Если меняете поля в `default_config.sh` — поднимайте `CONFIG_FILE_VERSION` и обновляйте проверку в `build.sh::check_config()`.