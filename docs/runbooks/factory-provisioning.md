# Инструкция: заводская подготовка новой панели

Дата: 2026-04-21
Применимость: первичная установка панели оператора (UEFI PC) неизменяемой
RAUC-системой.

## Требования

- Новая или прошедшая полную очистку панель с UEFI; legacy BIOS не поддерживается.
- Внутренний накопитель >= 32 GiB: SATA/NVMe/eMMC.
- Основной вариант: загрузочный ISO-образ установщика
  `out/inauto-panel-installer-<distro>-<arch>-pc-efi-<version>.iso`.
- Запасной вариант: архив установщика
  `out/inauto-panel-installer-<distro>-<arch>-pc-efi-<version>.tar.zst`
  + загрузочная флешка Ubuntu/Debian.
- Клавиатура и монитор для первичной настройки загрузки UEFI.

## Подготовка USB

До прихода на объект:

1. Собрать RAUC-образ и отдельный ISO-образ заводского установщика:
   ```bash
   RAUC_BUNDLE_VERSION=<version> ./scripts/build-rauc-installer.sh
   ```
   Если нужно пересобрать с чистым APT-кэшем пакетов:
   ```bash
   RAUC_BUNDLE_VERSION=<version> ./scripts/build-rauc-installer.sh --clean-cache
   ```
2. Проверить контрольную сумму:
   ```bash
   cd out
   sha256sum -c inauto-panel-installer-*.iso.sha256
   ```
3. Записать ISO-образ установщика на USB: Rufus/balenaEtcher, GPT, режим UEFI.

## Установка

Для оператора без инженерных деталей используйте
`docs/runbooks/operator-iso-installer.md`.

### 1. Загрузка

1. Воткнуть USB, включить панель.
2. В меню загрузки UEFI выбрать USB-запись с пометкой `UEFI`.
3. Дождаться загрузки временной системы.

### 2. Мастер

Мастер установки должен открыться автоматически. На рабочем столе также есть
ярлык `Inauto Panel Installer`. Если мастер не открылся:

```bash
/cdrom/inauto-installer/START-INSTALLER.sh
```

На Debian live путь может быть:

```bash
/run/live/medium/inauto-installer/START-INSTALLER.sh
```

Мастер:

- проверяет режим UEFI;
- показывает список внутренних дисков `>= 32 GiB`;
- спрашивает имя панели;
- даёт выбор канала обновлений (`stable` или `candidate`) и спрашивает адрес
  сервера обновлений;
- в начале спрашивает, нужна ли резервная копия старого `/home/inauto`;
- если резервная копия нужна, предлагает место для архива;
- пишет имя панели в `/home/inauto/staff/hostname`;
- генерирует серийный номер автоматически как `<hostname>-<uuid>`;
- просит ввести `ERASE` перед стиранием диска;
- показывает прогресс установки;
- предлагает перезагрузку после успешной установки.

### 3. Первая загрузка

После перезагрузки вытащить USB с установщиком.

Панель должна сама загрузиться с внутреннего диска. UEFI BootOrder должен быть
`system0, system1`. Если панель снова приходит в установщик, USB не вытащен
или прошивка UEFI вмешалась со своей загрузочной записью.

Ожидаемо при первой загрузке:

- LightDM с автоматическим входом пользователя `ubuntu`;
- `/home/inauto` смонтирован из `inauto-data`;
- `/etc/inauto/firmware-version` соответствует установленной версии;
- SSH и x11vnc доступны.

### 4. Сервер обновлений

```bash
ssh ubuntu@<ip_панели>
sudo -i

cat /home/inauto/staff/hostname
cat /etc/inauto/{update-server,channel,serial.txt}

systemctl restart panel-check-updates.timer
systemctl start panel-check-updates.service
systemctl list-timers panel-check-updates.timer
```

Ожидаемо:

- `/home/inauto/staff/hostname` = введённое в мастере имя панели;
- `/etc/inauto/channel` = выбранный канал обновлений;
- `/etc/inauto/update-server` = введённый URL сервера;
- `/etc/inauto/serial.txt` = `<hostname>-<uuid>`.

Через 5-10 минут в таблице `panels` на сервере обновлений должна появиться
отметка о связи от нового серийного номера.

## Запасной вариант: загрузочная флешка + архив установщика

Использовать только если загрузочный ISO-образ установщика недоступен.
Подробная инструкция: `docs/runbooks/install-from-installer-tar-zst.md`.

1. Загрузить панель с флешки Ubuntu/Debian в режиме UEFI.
2. Скопировать `inauto-panel-installer-*.tar.zst` во временную систему.
3. Распаковать:
   ```bash
   sudo mkdir -p /opt
   sudo tar -I zstd -xf inauto-panel-installer-*.tar.zst -C /opt
   ```
4. Запустить мастер:
   ```bash
   /opt/inauto-installer/START-INSTALLER.sh
   ```

Если временная система не содержит нужных пакетов (`rauc`, `gdisk`, `jq`, `zstd`,
`efibootmgr` и т.п.), мастер предложит установить их через `apt`.

## Проверочный список

- [ ] `efibootmgr -v` показывает `system0` и `system1`, BootOrder = `system0,system1`.
- [ ] `rauc status` показывает загруженный слот = `system0`, состояние слота = `good`.
- [ ] `/home/inauto/.inautolock` существует; skeleton директорий создан.
- [ ] `/etc/inauto/firmware-version` = ожидаемая `<VERSION>`.
- [ ] `/home/inauto/staff/hostname` = ожидаемое имя панели.
- [ ] `/etc/inauto/serial.txt` имеет вид `<hostname>-<uuid>`.
- [ ] `docker info` работает.
- [ ] `systemctl is-active lightdm docker containerd x11vnc ssh` все `active`.
- [ ] Отметка о связи появилась в `panels.last_seen` на сервере обновлений.
- [ ] Сброс overlay подтверждён: создать `/etc/marker`, перезагрузиться,
      убедиться что он исчез.

Если все пункты зелёные, панель сдана в эксплуатацию.
