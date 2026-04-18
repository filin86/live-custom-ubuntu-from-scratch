# Changelog

Все значимые изменения в этом проекте документируются здесь.
Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## [Unreleased]

### Added
- Поддержка сборки Debian-варианта live-ISO (`TARGET_DISTRO=debian`, дефолт `trixie`).
- Архитектура профилей: distro-specific логика изолирована в `scripts/profiles/<name>/`.
- Поддерживаемые Debian-релизы: `trixie` (stable), `forky` (testing), `sid` (unstable).
- Параметризация `docker/Builder.Dockerfile` через `ARG BASE_IMAGE` — отдельные builder-образы под Ubuntu и Debian.

### Changed
- Поднята `CONFIG_FILE_VERSION` до `0.5`. Требуется обновить локальный `scripts/config.sh`.
- Имя named volume для chroot теперь per-distro: `<repo>-chroot-<distro>`.
- `config.sh::install_docker_engine` использует `DOCKER_APT_DISTRO` из профиля вместо хардкода `/linux/ubuntu`.

### Removed
- Поддержка Ubuntu релизов младше `noble` (24.04 LTS) — логика `lupin-casper` удалена.

### Build
- `docker/Builder.Dockerfile` ставит Trivy через официальный apt-репозиторий Aqua.
- В builder включены keyring-пакеты обоих дистрибутивов (`ubuntu-keyring`, `debian-archive-keyring`) и `gettext-base` для envsubst.
