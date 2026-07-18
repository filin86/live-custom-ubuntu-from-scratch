# Changelog

Все значимые изменения в этом проекте документируются здесь.
Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## [Unreleased]

### Added — драйвер Moxa UPort 11x0 (USB-serial, build-time)
- Для редких панелей с адаптерами Moxa UPort 11x0 (in-tree `mxuport` их не биндит). Вендорный `mxu11x0` занесён в репозиторий (`scripts/targets/rauc/drivers/mxu11x0/`, GPLv2) и собирается на этапе сборки образа (в runtime на immutable-панели тулчейна нет): `config.sh::install_moxa_uport_driver()` строит модуль под каждое целевое ядро (`make -C /lib/modules/<kver>/build`), ставит в `/lib/modules/.../kernel/drivers/usb/serial/` + `depmod`. GCC-14 понижается точечно (`-Wno-error=incompatible-pointer-types,empty-body` — драйвер 2023 г.). Автозагрузка по modalias (`MODULE_DEVICE_TABLE`, VID `0x110A`) — на панелях без адаптера не грузится. `build.sh::prechroot` заносит source в chroot (`/root/drivers`). Fail-hard, если модуль не собрался ни под одно ядро.

### Fixed — timezone/NTP на immutable-панели (без timedatectl)
- `timedatectl` на панели даёт `Access denied` (timedated/polkit без сессии/агента в boot-контексте). `005-time.sh` выставляет зону **прямым** `ln -sf /usr/share/zoneinfo/<tz> /etc/localtime`, NTP — `systemctl enable systemd-timesyncd` (оба без DBus). Добавлена чистка CR/пробелов из `staff/timezone` (CRLF-файл не проходил проверку zoneinfo).
- **NTP-сервер параметризован:** новый per-site файл `staff/ntp-server` (рядом с `staff/timezone`), из него `005-time.sh` генерирует `/etc/systemd/timesyncd.conf` (`NTP=` + `FallbackNTP=`). Статический `staff/fs/etc/systemd/timesyncd.conf` удалён.

### Changed — NetworkManager: no-auto-default генерируется скриптом, без autoconnect=false
- `/etc/NetworkManager/conf.d/20-no-auto-default.conf` теперь генерируется в `network_pre/10-config-network.sh` (до старта NM) c одним `[main] no-auto-default=*`. Убран `[connection] autoconnect=false` (мешал автоподъёму реальных соединений → риск «панель без сети»). Статический файл в `staff/fs` удалён.

### Removed — самостоятельный tar.zst-метод установки
- Инсталлятор больше не собирается в `out/*.tar.zst` (метод «распаковать в /opt и запустить» не использовался). `build-installer-image.sh` публикует payload **директорией** `out/inauto-panel-installer-<…>/`, `build.sh::build_rauc_installer_iso` берёт её напрямую (`cp -a` вместо `tar -xf`). Из `.gitlab-ci.yml` убраны `*.tar.zst`/`.sha256` артефакты и неиспользуемый `INSTALLER=` dotenv. Удалён рунбук `install-from-installer-tar-zst.md`, вычищены ссылки в `factory-provisioning`/`release-workflow`/`field-migration`/`qemu-pc-efi-test`/`ci-pki-secrets`. Backup `/home/inauto` (`home-inauto.tar.zst`) не затронут.

### Changed — актуальность пакетов образа (dist-upgrade)
- В chroot добавлен `apt-get -y dist-upgrade` (после `apt-get update`, до установки ядра/драйверов) — база из `debootstrap` подтягивается до последних версий (вкл. `-security`/`-updates`; sources уже содержат их, пинов нет). Раньше базовые пакеты застревали на версиях момента debootstrap.

### Fixed — сборочный ПК: утечка Docker-томов и общий кэш для worktree
- **Утечка диска устранена:** `build-rauc-installer.sh` создавал per-version chroot-тома `livecd-<версия>-target/-installer` (~7 ГБ/сборку) и не удалял — они копились до сотен ГБ. Теперь `trap EXIT` их сносит (одноразовый scratch; `KEEP_BUILD_VOLUMES=1` — оставить для отладки).
- **Общий кэш для worktree:** apt/Trivy-тома переведены на фиксированное имя (`livecd-apt-cache-<distro>`, `livecd-trivy-cache`) вместо `basename REPO_ROOT` → worktree/клоны делят `.deb`- и Trivy-кэш, не качают заново. chroot-том остаётся per-worktree (изоляция).
- `--clean-cache` теперь чистит и Trivy-том (раньше не чистился ничем), и прунит осиротевшие project-тома других worktree (кроме chroot текущей сборки).

### Fixed — автологин панели не срабатывал (падал в greeter)
- **Протухший `.Xauthority` из kiosk-скелета.** `before_login/10-kiosk.sh` копировал `staff/kiosk/.*` в `/home/ubuntu`, затаскивая запечённый `.Xauthority` (X-cookie сборочного хоста) → XFCE-сессия не могла авторизоваться на `:0`, падала с кодом 1, LightDM откатывался к greeter. Файл удалён из скелета; `10-kiosk.sh` переписан на `rsync -a --exclude='.Xauthority' --exclude='.ICEauthority'` — заодно устранён баг `cp -rf .*`, который через `..` затаскивал в `/home/ubuntu` весь родительский `staff/` (включая ssh-ключи).
- **Смена hostname под живой X-сессией.** `50-sethostname.sh` стоял в `oneshot` (после старта LightDM); смена имени инвалидировала X-cookie `:0` — первая автологин-сессия падала, работала только вторая. Перенесён в новую фазу `network_pre` (до NetworkManager и до X), задаёт имя через `/etc/hostname`+`hostname(1)` (не `hostnamectl` — на ранней фазе `DefaultDependencies=no` systemd-hostnamed/DBus может быть не поднят), читает `staff/hostname`, валидирует, на ошибке не роняет фазу.
- `OnStartOneShot.service` объявлен `Before=display-manager.service` — UI ждёт полной пред-настройки; попутно убрана гонка «автостарт приложения раньше установки».

### Added — фаза `on_start/network_pre` (сеть/имя до NetworkManager)
- Новый юнит `OnStartNetworkPre.service` (`config.sh::service_onstartnetworkpre`): `DefaultDependencies=no`, `After=MountHome.service`, `Wants/Before=network-pre.target`, `Before=NetworkManager.service`; раннер выполняет `on_start/network_pre/*.sh`.
- Сетевые скрипты перенесены из `oneshot` в `network_pre`: `10-config-network.sh` кладёт netplan из `staff/netplan/` и делает `netplan generate` **без `apply`** (NM подхватит при старте) — убран churn «сеть поднялась с дефолтом → reconfigure → restart NM», добавлен атомарный своп через staging; `03-fs-reload.sh` — fs-overlay + `daemon-reload`, без `nmcli delete`/`restart NetworkManager`.

### Added — CIFS-automount сетевой папки Windows
- Пакет `cifs-utils` в образ. Новый `oneshot/020-mount-winshare.sh` генерирует systemd `.mount`+`.automount` из `staff/winshare/winshare.conf` (+`credentials`, режим 600): монтирование по первому обращению (переживает выключенный ПК/сетевые сбои), `uid/gid=1000` для записи из-под `ubuntu`. Шаблоны `winshare.conf.example`/`credentials.example`; без реального `winshare.conf` — no-op.

### Changed — провижининг из `staff/`, реструктуризация `on_start`
- **timezone** вынесен в `oneshot/005-time.sh` (читает `staff/timezone`, дефолт `Europe/Moscow`, валидация по `/usr/share/zoneinfo`), туда же переехала NTP-синхронизация. Устранён конфликт: `90` и `100-preconfiguration.sh` задавали **разный** пояс, лексически побеждал `100`.
- Инсталляторы `00-hasplm.sh`/`01-idmvs.sh` перенесены из `forking` (Type=forking для run-and-exit — семантически неверно) в `oneshot`.
- SSH-ключи вынесены в `before_login/05-ssh-keys.sh` (root+ubuntu+svc_redcheck, `install -d -m700 / -m600` под sshd StrictModes); дублирование из `01`/`02` убрано.
- Префиксы `oneshot/*` нормализованы до 3 цифр (`000/001/005/020/090/100`) — лексический `sort` раннера теперь совпадает с численным порядком.

### Fixed — баги site-скриптов `on_start`
- `01-add-redcheck-user.sh`: `sudo -aG sudo` (несуществующая команда) → `usermod -aG sudo`; `.ssh`/`authorized_keys` получают `700`/`600` и владельца (иначе sshd StrictModes игнорирует ключ); идемпотентное создание пользователя.
- `00-rootpass.sh`: `sudo echo | passwd` → `chpasswd`.
- `090-preconfiguration.sh`: получил недостающий `+x` — до этого раннер (`find -executable`) молча его пропускал (NTP/ICMP-воркэраунд не выполнялись); убран избыточный `restart systemd-timesyncd`; ICMP-drop оставлен как raw iptables с `TODO(firewall)` (ufw пока `disable` в `01-idmvs.sh`).
- Все `on_start`-скрипты приведены к `set -euo pipefail`.

### Removed — дубль в payload инсталлятора
- Удалён `home-skel/distr/IDMVS/opt/IDMVS_Install_Temp/` (~99 МБ; `IDMVS.tar.gz` внутри уже распакованного `IDMVS/`, не используется boot-путём установки) — `distr/` ужался 721→623 МБ.

### Changed — документация (docs/ + home-skel/README)
- `docs/2026-04-20-immutable-panel-firmware-design.md`: фаза `network_pre`, юнит `OnStartNetworkPre.service`, порядок фаз `on_start` + гейтинг `Before=display-manager`.
- `docs/runbooks/troubleshooting.md`: новая секция про несрабатывающий автологин (протухший `.Xauthority`, смена hostname); исправлен устаревший путь netplan (`staff/lxqt/netplan` → `staff/netplan`).
- `docs/runbooks/factory-provisioning.md`: per-site `staff/timezone` и `staff/winshare/` + пункты чек-листа. `qemu-pc-efi-test.md`: `network_pre` в перечне фаз.
- `home-skel/README.md`: фаза `network_pre`, per-site `staff/`-параметры, таблица примеров зон, раздел winshare.

### Added — дефолтное наполнение /home/inauto при первой установке (home-skel)
- Новый каталог `scripts/targets/rauc/installer/home-skel/` — файлы, которые заводской инсталлятор засевает в раздел `inauto-data` (`/home/inauto`) при **первой установке** панели. Структура повторяет `/home/inauto` (`on_start/{before_login,network_pre,oneshot,forking}`, `on_login`, `staff`, `config`); пустые каталоги держатся `.gitkeep`, а `README.md`/`.gitkeep` на панель не копируются.
- `build-installer-image.sh` упаковывает `home-skel/` в payload (`inauto-installer/home-skel/`), вырезая служебные `README.md`/`.gitkeep`; если после вычистки не осталось реальных файлов — каталог в payload не включается (installer его просто пропускает).
- `install-to-disk.sh` (секция 7.4) раскатывает `home-skel/` в свежий `inauto-data` **после** создания skeleton'а, но **до** restore backup'а — при миграции восстановленные пользовательские файлы перетирают дефолты (данные пользователя побеждают). Каталог опционален: старый payload без `home-skel` установку не ломает. Файлы копируются `cp -a` (сохранение прав — скрипты `on_start/*`/`on_login` должны быть закоммичены исполняемыми). Засев одноразовый: последующие RAUC-обновления firmware эти файлы не трогают.

### Added — подавление шума загрузки/выключения
- `config.sh::quiet_boot_noise()` (вызывается из `customize_image()`) заносит `snd_hda_intel` в blacklist (`/etc/modprobe.d` + `install ... /bin/true`) — HDA-кодек на панелях не отвечает, из-за чего выключение стабильно тормозило на `azx_get_response timeout` (~3 сек); звук панелям не нужен.
- На RAUC-target (`TARGET_FORMAT=rauc`) `casper-md5check.service` теперь маскируется через `systemctl mask` — это чисто live-ISO проверка контрольных сумм, на immutable-образе она всегда падала и засоряла лог загрузки.

### Changed — переход на GRUB-схему выбора A/B-слота (pc-efi v2, RAUC bootloader=grub)
- **Причина:** прошивка панелей перезаписывает UEFI `BootOrder` на каждом POST (пересортировывает записи `\EFI\BOOT\BOOTX64.EFI` по номеру раздела и демотирует записи с уникальным путём к загрузчику) — после второй перезагрузки система откатывалась на предыдущий слот, а одноразовый `BootNext` прошивка уважает лишь на один боот вперёд. Ранее опробованный обходной путь — скрипт `panel-commit-bootorder.sh`, переставлявший `BootOrder` первым слотом после `rauc-mark-boot-good` — был проверен на реальном железе и **не сработал** (подтверждено тестовой записью `RAUCPROBE`, которую прошивка демотировала так же, как остальные); скрипт удалён из обоих профилей до релиза, в ISO так и не попал. Дизайн итогового решения — `docs/2026-07-04-grub-boot-selection-design.md`.
- GPT-раскладка дисков не меняется; `efi_A` теперь несёт единый GRUB standalone-загрузчик (`\EFI\BOOT\BOOTX64.EFI` + `grub.cfg` + `grubenv`), `efi_B` — его резервную копию. Активный слот выбирается через переменные `grubenv` (`ORDER`, `<slot>_OK`, `<slot>_TRY`) с автоматическим откатом по TRY-счётчику — UEFI `BootOrder`/`BootNext` для выбора слота больше не используются.
- `kernel`/`initrd` и `/boot/grub-slot.cfg` перенесены внутрь squashfs rootfs; RAUC bundle стал rootfs-only (manifest без секции `[image.efi]`), GRUB читает kernel/initrd прямо с rootfs-раздела (xz-сжатый squashfs, проверено `grub-fstest` 2.12).
- Новый `scripts/targets/rauc/build-boot-grub.sh` собирает `boot.vfat` (`grub-mkstandalone` + преднастроенный `grubenv`) — используется и как релизный артефакт, и как payload заводского инсталлятора; новый `scripts/targets/rauc/grub/grub.cfg`.
- Новый mount-юнит `run-inauto-bootenv.mount` монтирует `grubenv` в `/run/inauto/bootenv` + drop-in для `rauc.service`; функция `install_rauc_boot_artifacts()` в `config.sh` устанавливает `/boot`-артефакты.
- `system-efi.conf.template`: `bootloader=grub`, слоты `rootfs.0`/`rootfs.1` с `bootname system0`/`system1`.
- **BREAKING:** `RAUC_COMPATIBLE_VERSION` поднят до `v2` — bundle'ы старой (v1, BootOrder-based) схемы несовместимы с новым GRUB-загрузчиком без миграции.
- Поднята версия конфига до 0.7 (требуется обновить локальный `scripts/config.sh`) — новые переменные GRUB boot-схемы (`build.sh`, `config-installer.sh`).
- `installer/install-to-disk.sh`: `boot.vfat` теперь пишется в оба `efi_A`+`efi_B`; NVRAM-записи слотов больше не создаются (только зачистка устаревших записей от старой схемы). `docker/Builder.Dockerfile`: добавлены `grub-common`, `grub-efi-amd64-bin`.
- `panel-update.sh`: добавлен режим миграции v1→v2 без заводского инсталлятора — `rauc mount` с проверкой подписи → `dd` rootfs в неактивный слот → `dd` `boot.vfat` в оба ESP → запись `grubenv` → зачистка NVRAM → reboot; поиск bundle дополнительно ведётся в `/home/inauto/update`. `rauc-mark-boot-good.service` лишился `ExecStartPost=` (закреплявшего `BootOrder`) и теперь зависит от bootenv-mount.
- Runbooks обновлены: `docs/runbooks/update-from-raucb.md` (раздел миграции, шаг 5 — проверка `grubenv` вместо `efibootmgr`) и `docs/runbooks/rollback.md` (`grub-editenv` вместо `efibootmgr`).

### Added — Драйвер Realtek RTL8125 (2.5 GbE) и кнопка питания
- В `config.sh` функция `install_r8125_driver()` (вызов из `customize_image()`) собирает вендорный драйвер Realtek RTL8125 (2.5GbE) из закреплённых исходников вместо пакета `r8125-dkms` из noble/multiverse: пакетная версия — старая ветка 9.011 (2022), на новых ревизиях чипа битый RX-путь (линк поднимается, но DHCP не отвечает, интерфейс вечно «connecting», плюс лишняя вторая иконка NetworkManager в трее). Скачивается pinned r8125 9.016.01 (мирор awesometic/realtek-r8125-dkms, закреплённые URL + sha256, с проверкой) и собирается через DKMS для каждого целевого ядра по `/lib/modules/*/build` прямо в chroot — на immutable RAUC-панели DKMS в runtime недоступен, пересборка невозможна. Если `r8125.ko` не собрался ни для одного ядра, сборка прерывается с ошибкой. Точечный udev-override (r8169→r8125 только для PCI `10ec:8125`) не изменился.
- В `config.sh` добавлена функция `configure_power_button()` (вызов из `custom_conf()`): записывает системный xfconf-файл `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml` с `logind-handle-power-key=true` и `power-button-action=4` (XFPM_DO_SHUTDOWN). Кнопка питания теперь корректно выключает систему вместо недетерминированного поведения Ubuntu 24.04 по умолчанию; работает и на immutable RAUC-панели с tmpfs-overlay.

### Fixed
- `scripts/build-rauc-release.sh`: исправлен разбор аргументов — позиционный `N` (номер билда за день) и флаг `--clean-cache` теперь разбираются явно; `--clean-cache` пробрасывается в `build-rauc-installer.sh` через массив `clean_cache_args` только при реальной передаче. Добавлены `usage()` и флаги `-h/--help`; неизвестные аргументы отвергаются.

### Added — Immutable panel firmware (RAUC target, phases 0–9)
- Новая цель сборки `TARGET_FORMAT=rauc` для immutable operator-панелей с A/B обновлениями через RAUC. ISO-путь остаётся дефолтом и не меняется.
- `TARGET_PLATFORM=pc-efi` (UEFI PC, MVP); `<board>-uboot` зарезервирован для планшетов после идентификации BSP.
- Новые build-переменные: `TARGET_ARCH`, `RAUC_BUNDLE_VERSION` (обязательна для релизов, production regex `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$`, dev-префикс `dev.*`), `INAUTO_OVERLAY_SIZE`, `INAUTO_SITE_CONFIG_DIR`, `INAUTO_AUTOSTART_SCRIPT`, `INAUTO_JOURNAL_DIR`.
- `scripts/targets/rauc/`: `common.sh` (helpers), `build-bundle.sh`, `build-boot-vfat.sh`, `build-installer-image.sh`, `installer/install-to-disk.sh`, `installer/backup-restore-home.sh` (автоматический backup существующего `/home/inauto` до wipe'а диска с исключением `staff/docker/` + restore прямо в `/home/inauto/` после установки), `partition-layout/pc-efi.sgdisk`, `manifest-{efi,uboot}.raucm.template`.
- RAUC-assets в профилях (`scripts/profiles/{ubuntu,debian}/rauc/`): `system-{efi,uboot}.conf.template`, initramfs hook+script для immutable overlay (`panel-boot`), `scripts/init-persist-paths.sh`, `scripts/panel-healthcheck.sh`, `scripts/panel-check-updates.sh`, systemd units `rauc-mark-boot-good.service` и `panel-check-updates.{service,timer}`.
- Раздельный `DockerPersistentStorage.service` и `MountHome.service` для ISO vs RAUC builds.
- Systemd watchdog default (`RuntimeWatchdogSec=60s`) + kernel `panic=30` в `efi-cmdline`.
- `docker/Builder.Dockerfile`: добавлены `rauc`, `dosfstools`, `mtools`, `gdisk`, `parted`, `kmod`, `initramfs-tools`, `efibootmgr`, `openssl` (и best-effort `u-boot-tools`).
- `server/` — минимальный update server (FastAPI + SQLite + nginx + docker-compose) с `/api/{upload,latest,heartbeat}`, validation production regex на upload, rejection пустого `slot` без `last_error`.
- GitLab CI pipeline `.gitlab-ci.yml` с `parallel: matrix: ubuntu/debian × pc-efi × amd64`, подписью через File-type variables `RAUC_SIGNING_CERT/KEY` из `Project → CI/CD → Variables`, publish в candidate-channel update server на push-tag `vYYYY.MM.DD.N` или ручной запуск с `PUBLISH_CANDIDATE=true`. Требует shell executor с privileged docker и runner tag `rauc-builder`.

### Fixed (post-review)
- **Critical: UEFI entries без kernel cmdline** — `install-to-disk.sh` теперь передаёт полный `--unicode 'initrd=\EFI\Linux\initrd.img rauc.slot=system<N> root=/dev/disk/by-partlabel/rootfs_<X> rootfstype=squashfs ro quiet panic=30'` в `efibootmgr --create`. Без этого EFI-stub kernel не находил initrd/root на factory boot.
- **Critical: `build-in-docker.sh` не пробрасывал RAUC переменные** — добавлены `-e TARGET_FORMAT`, `TARGET_PLATFORM`, `TARGET_ARCH`, `RAUC_BUNDLE_VERSION`, `RAUC_VERSION_MODE`, `RAUC_SIGNING_CERT`, `RAUC_SIGNING_KEY`, `RAUC_INTERMEDIATE_CERT`, `RAUC_KEYRING_PATH`, `INAUTO_*`. Без этого RAUC-target сборки в CI просто не работали.
- **Critical: backup исключал `TARGET_DEVICE`** — `backup-restore-home.sh` больше не пропускает target disk при поиске `.inautolock`. Типичный single-disk reinstall теперь корректно архивирует `/home/inauto` перед wipe'ом. Добавлена недостающая функция `warn()` в `install-to-disk.sh`.
- **High: installer теперь извлекает raw-байты из signed bundle** — `build-installer-image.sh` больше не генерирует отдельные `efi.vfat` и `rootfs.img` в payload; installer при запуске `rauc info --keyring=keyring.pem bundle.raucb` + `rauc extract` и только потом `dd`. Криптографическая связь между подписью bundle'а и реально записываемыми байтами восстановлена.
- **High: GitLab publish matrix glob мог загрузить чужой bundle** — `publish-candidate` использует полное имя `inauto-panel-${TARGET_DISTRO}-${TARGET_ARCH}-${TARGET_PLATFORM}-${RAUC_BUNDLE_VERSION}.raucb` вместо glob'а с одной осью.
- **GitLab File-type variables корректно копируются внутрь `$CI_PROJECT_DIR/.tmp/pki/`** перед передачей в `build-in-docker.sh` — иначе bind-mount `/workspace` не видел секреты.
- **Medium: update server upload cleanup** — при ошибке `rauc info` или INSERT в БД недописанный файл `dest` теперь удаляется через единый try/except. `INAUTO_RAUC_KEYRING` и `INAUTO_PUBLIC_BASE_URL` стали обязательными на `@app.on_event("startup")` — сервер отказывается стартовать без них, больше никаких silent fallback'ов на optional keyring или relative `/bundles/` URL.
- **Low: heartbeat agent function ordering** — избыточный pre-reboot heartbeat удалён (после reboot'а стандартный timer-tick пришлёт новую версию), `build_heartbeat_body` поднят выше install-блока, чтобы bash не попадал в call-before-declaration.

### Fixed (second review pass)
- **Critical: backup fail → destructive install остановлен** — `install-to-disk.sh` больше не продолжает установку, если backup существующего `/home/inauto` завершился с ошибкой (полный `BACKUP_DIR`, tar/zstd fail, повреждённая ФС). Fail-by-default с подсказкой либо задать `BACKUP_DIR` на внешний носитель, либо передать явный `ALLOW_NO_BACKUP=1` для осознанного skip'а.
- **High: heredoc в `--shell` → `build_installer_image` stage** — installer payload теперь собирается обычным stage'ем в `build.sh::CMD` (`build_rauc_bundle` → `build_installer_image`), без `./scripts/build-in-docker.sh --shell <<EOSH`, который в non-TTY GitLab runner'е не получал stdin. `.gitlab-ci.yml` упрощён до одного `./scripts/build-in-docker.sh -`.
- **Medium: backup пропускал removable-check** — `find_home_inauto_device` теперь читает `/sys/block/<name>/removable`. USB-stick и SD-карты с major 8 (неразличимые через `lsblk -e 7,11`) больше не попадают в кандидаты — случайный backup Ubuntu Live USB с подложенным `.inautolock` невозможен.
- **Low: устаревшие комментарии синхронизированы с кодом** — header `build-installer-image.sh` и блок описания в `backup-restore-home.sh` приведены в соответствие с реальным поведением (bundle-extract, TARGET_DEVICE не исключается, removable-check).

### Fixed (third review pass)
- **Critical: rootfs и installer получали dev keyring в production** — добавлена обязательная File-type переменная `RAUC_KEYRING` в GitLab CI. Release-mode pipeline теперь копирует её в `$CI_PROJECT_DIR/.tmp/pki/keyring.pem` и экспортит `RAUC_KEYRING_PATH` (для `build.sh::prechroot` → `/etc/rauc/keyring.pem` в rootfs) и `INSTALLER_KEYRING_SRC` (для `build-installer-image.sh` → `keyring.pem` в tar.zst). Без `RAUC_KEYRING` release-сборка прерывается — иначе prod-signed bundle отвергался бы `rauc extract` на factory installer'e и `rauc install` на установленной системе. Fallback-ветка (dev) явно использует `pki/dev-keyring.pem`. `build-in-docker.sh` пробрасывает `INSTALLER_KEYRING_SRC` в контейнер.
- **Medium: отсутствующий backup helper → fail-by-default** — `install-to-disk.sh` теперь блокирует destructive install и при отсутствии `backup-restore-home.sh` (corrupted payload), не только при runtime error helper'а. Override `ALLOW_NO_BACKUP=1` работает единообразно для обеих ситуаций.
- **Low: комментарии в install-to-disk.sh и backup-restore-home.sh** приведены в соответствие с removable-check и не-исключением TARGET_DEVICE.

### Fixed (fourth review pass)
- **High: private signing key мог пережить failed build** — весь build-flow в `.gitlab-ci.yml` слит в один bash-блок с `trap 'rm -rf .tmp/pki' EXIT` сразу после `mkdir .tmp/pki`. При любом exit (success, `set -e` fail, SIGTERM от timeout) приватный key удаляется до того, как shell-runner перейдёт к следующему job'у. Дополнительно `after_script: rm -rf .tmp/pki || true` — defence-in-depth на случай kill'а до EXIT-trap'а.
- **Low: оставшийся устаревший комментарий** — в `backup-restore-home.sh` env-блок `TARGET_DEVICE` пояснял «исключается из поиска», хотя реализация обратная. Теперь явно указано, что переменная только логируется.
- Полный runbook-пакет: `docs/runbooks/{factory-provisioning,field-migration,troubleshooting,rollback,qemu-pc-efi-test,release-workflow,watchdog,docker-container-store,ci-pki-secrets}.md`.
- Spec и plan: `docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md`, `docs/superpowers/plans/2026-04-20-immutable-panel-firmware.md`.

### Added — Debian support (pre-RAUC)
- Поддержка сборки Debian-варианта live-ISO (`TARGET_DISTRO=debian`, дефолт `trixie`).
- Архитектура профилей: distro-specific логика изолирована в `scripts/profiles/<name>/`.
- Поддерживаемые Debian-релизы: `trixie` (stable), `forky` (testing), `sid` (unstable).
- Параметризация `docker/Builder.Dockerfile` через `ARG BASE_IMAGE` — отдельные builder-образы под Ubuntu и Debian.

### Changed
- Поднята `CONFIG_FILE_VERSION` до `0.6`. Требуется обновить локальный `scripts/config.sh` (новые переменные RAUC target'а).
- `scripts/build.sh::check_config()` валидирует `TARGET_FORMAT` (iso/rauc) и `TARGET_PLATFORM` (pc-efi / `<board>-uboot` warning).
- `CMD`-массив build pipeline'а расширен stage'ом `build_rauc_bundle`; `build_iso` делает early-exit после `mksquashfs` при `TARGET_FORMAT=rauc`.
- `invoke_chroot_stage()` helper в `build.sh` пробрасывает `TARGET_*`/`RAUC_*`/`INAUTO_*` переменные во все `chr_*` этапы — чтобы `chroot_build.sh`/`config.sh` видели их.
- `docker/container-entrypoint.sh::chown_outputs` теперь покрывает `<repo>/out/` и `*.raucb` наравне с `*.iso`.
- Имя named volume для chroot теперь per-distro: `<repo>-chroot-<distro>`.
- `config.sh::install_docker_engine` использует `DOCKER_APT_DISTRO` из профиля вместо хардкода `/linux/ubuntu`.
- RAUC installer backup теперь исключает `staff/docker/`, а restore накатывает архив прямо в `/home/inauto/` поверх нового `inauto-data` skeleton'а.

### Removed
- Поддержка Ubuntu релизов младше `noble` (24.04 LTS) — логика `lupin-casper` удалена.

### Build
- `docker/Builder.Dockerfile` ставит Trivy через официальный apt-репозиторий Aqua.
- В builder включены keyring-пакеты обоих дистрибутивов (`ubuntu-keyring`, `debian-archive-keyring`) и `gettext-base` для envsubst.
