# Runbook: factory provisioning новой панели

Дата: 2026-04-21
Применимость: первичная прошивка operator-панели (UEFI PC) immutable firmware'ом.

## Требования

- Новая или прошедшая полную очистку панель с UEFI; legacy BIOS не поддерживается.
- Внутренний накопитель >= 32 GiB: SATA/NVMe/eMMC.
- Preferred: bootable installer ISO
  `out/inauto-panel-installer-<distro>-<arch>-pc-efi-<version>.iso`.
- Fallback: installer payload
  `out/inauto-panel-installer-<distro>-<arch>-pc-efi-<version>.tar.zst`
  + Ubuntu/Debian Live USB.
- Клавиатура + монитор для первичной настройки UEFI boot.

## Подготовка USB

До прихода на объект:

1. Собрать RAUC target и отдельный factory-installer ISO:
   ```bash
   RAUC_BUNDLE_VERSION=<version> ./scripts/build-rauc-installer.sh
   ```
   Если нужно пересобрать с чистым APT-кэшем пакетов:
   ```bash
   RAUC_BUNDLE_VERSION=<version> ./scripts/build-rauc-installer.sh --clean-cache
   ```
2. Проверить checksum:
   ```bash
   cd out
   sha256sum -c inauto-panel-installer-*.iso.sha256
   ```
3. Записать installer ISO на USB: Rufus/balenaEtcher, GPT, UEFI mode.

## Установка

### 1. Boot

1. Воткнуть USB, включить панель.
2. В UEFI boot menu выбрать USB entry с пометкой `UEFI`.
3. Дождаться загрузки live-системы.

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

- проверяет UEFI mode;
- показывает список внутренних дисков `>= 32 GiB`;
- в начале спрашивает, нужен ли backup старого `/home/inauto`;
- если backup нужен, предлагает место для архива;
- просит ввести `ERASE` перед стиранием диска;
- показывает прогресс установки;
- предлагает reboot после успешной установки.

### 3. Первый Boot

После reboot вытащить installer USB.

Панель должна сама загрузиться с внутреннего диска. UEFI BootOrder должен быть
`system0, system1`. Если панель снова приходит в installer USB, USB не вытащен
или firmware вмешался со своим boot entry.

Ожидаемо при первом boot:

- LightDM с auto-login user `ubuntu`;
- `/home/inauto` смонтирован из `inauto-data`;
- `/etc/inauto/firmware-version` соответствует установленной версии;
- SSH и x11vnc доступны.

### 4. Update Server

```bash
ssh ubuntu@<ip_панели>
sudo -i

echo "https://panels.example.com" > /etc/inauto/update-server
echo "stable"                    > /etc/inauto/channel
echo "panel-<site>-<n>"          > /etc/inauto/serial.txt

systemctl restart panel-check-updates.timer
systemctl list-timers panel-check-updates.timer
```

Через 5-10 минут в `panels` таблице на update-server'е должен появиться
heartbeat от нового serial.

## Fallback: Live USB + Payload

Использовать только если bootable installer ISO недоступен.

1. Загрузить панель с Ubuntu/Debian Live USB в UEFI mode.
2. Скопировать `inauto-panel-installer-*.tar.zst` на live-систему.
3. Распаковать:
   ```bash
   sudo mkdir -p /opt
   sudo tar -I zstd -xf inauto-panel-installer-*.tar.zst -C /opt
   ```
4. Запустить мастер:
   ```bash
   /opt/inauto-installer/START-INSTALLER.sh
   ```

Если live-система не содержит нужных пакетов (`rauc`, `gdisk`, `jq`, `zstd`,
`efibootmgr` и т.п.), мастер предложит установить их через `apt`.

## Acceptance Checklist

- [ ] `efibootmgr -v` показывает `system0` и `system1`, BootOrder = `system0,system1`.
- [ ] `rauc status` показывает booted slot = `system0`, slot state = `good`.
- [ ] `/home/inauto/.inautolock` существует; skeleton директорий создан.
- [ ] `/etc/inauto/firmware-version` = ожидаемая `<VERSION>`.
- [ ] `docker info` работает.
- [ ] `systemctl is-active lightdm docker containerd x11vnc ssh` все `active`.
- [ ] Heartbeat появился в `panels.last_seen` на update-server'е.
- [ ] Overlay reset подтверждён: создать `/etc/marker`, reboot, убедиться что он исчез.

Если все пункты зелёные, панель сдана в эксплуатацию.
