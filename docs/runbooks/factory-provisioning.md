# Runbook: factory provisioning новой панели

Дата: 2026-04-20
Применимость: первичная прошивка operator-панели (UEFI PC) immutable firmware'ом.

## Требования

- Новая или прошедшая полную очистку панель с UEFI (legacy BIOS не поддерживается).
- Внутренний накопитель ≥ 32 GiB (SATA/NVMe/eMMC — любой).
- Installer payload: `out/inauto-panel-installer-<distro>-<arch>-pc-efi-<version>.tar.zst`.
- Ubuntu 24.04 Live USB (общедоступный, любой mirror).
- Клавиатура + монитор (для первичной настройки UEFI boot).

## Подготовка installer USB

До прихода на shop floor:

1. Собрать installer payload (CI делает это автоматически при tag):
   ```
   TARGET_FORMAT=rauc TARGET_PLATFORM=pc-efi ./scripts/build-in-docker.sh -
   ```
2. Скачать Ubuntu 24.04 Live ISO.
3. Записать Ubuntu Live на USB (Rufus/balenaEtcher, GPT, UEFI mode).
4. На второй USB (или в `/home/ubuntu` на том же) положить tar.zst payload
   и его `.sha256`.

## На панели: шаги установки

### Шаг 1. Boot с Ubuntu Live USB

1. Воткнуть USB, включить панель.
2. Зайти в UEFI (обычно `Del`/`F2`/`F12`), выбрать boot с USB.
3. В меню GRUB — «Try Ubuntu».

### Шаг 2. Развернуть payload

В терминале Ubuntu Live:

```bash
sudo -i

# Проверить что мы UEFI:
ls /sys/firmware/efi && echo "UEFI ok" || { echo "BIOS — abort"; exit 1; }

# Скопировать payload с второго USB (или из сети).
cp /media/ubuntu/<USB>/inauto-panel-installer-*.tar.zst /tmp/
sha256sum -c /media/ubuntu/<USB>/inauto-panel-installer-*.tar.zst.sha256

# Распаковать в /opt
mkdir -p /opt
tar -I zstd -xf /tmp/inauto-panel-installer-*.tar.zst -C /opt
```

### Шаг 3. Выбрать target disk

```bash
lsblk -d -o NAME,SIZE,RM,MODEL
```

`RM=0` — non-removable (внутренний SSD). Обычно это `/dev/sda` или
`/dev/nvme0n1`. USB-флешки видны с `RM=1` — их ни в коем случае не брать.

### Шаг 4. Запустить installer

```bash
TARGET_DEVICE=/dev/<диск> /opt/inauto-installer/install-to-disk.sh
```

Если только один non-removable диск ≥ 32 GiB — `TARGET_DEVICE` можно не
указывать, installer выберет автоматически.

**Dry-run** (проверка без записи):

```bash
TARGET_DEVICE=/dev/<диск> DRY_RUN=1 /opt/inauto-installer/install-to-disk.sh
```

### Шаг 5. Ожидаемая последовательность действий installer'а

Installer выводит `[installer] ...` строки. Ключевые этапы:

```
[installer] target disk: /dev/<диск> (<bytes>)
[installer] firmware version: <VERSION>
[installer] создаю GPT разметку (/opt/inauto-installer/pc-efi.sgdisk)
[pc-efi.sgdisk] Layout: efi_A=512M ... container-store=NG inauto-data=NG
[pc-efi.sgdisk] Форматируем EFI-разделы как FAT32
[pc-efi.sgdisk] Форматируем ext4-разделы (persist, container-store, inauto-data)
[installer] заливаю efi_A/efi_B из efi.vfat
[installer] заливаю rootfs_A/rootfs_B из rootfs.img
[installer] регистрирую UEFI boot entries (efi_A=X, efi_B=Y)
[installer] устанавливаю BootOrder=XXXX,YYYY
[installer] установка завершена; перезагружаюсь через 10 секунд
```

### Шаг 6. Первая загрузка

После reboot вытащить Ubuntu Live USB.

Панель должна сама загрузиться с внутреннего диска (UEFI запомнил
BootOrder = `system0, system1`). Если панель снова приходит в GRUB
Ubuntu Live — USB не вытащен, либо BIOS вмешался со своим boot entry
(см. troubleshooting.md).

Ожидаемо при первом boot'е:
- ~15–20 секунд до LightDM (auto-login user `ubuntu`).
- XFCE с открытым compose-проектом (если на панель настроен он в `/home/inauto`).
- SSH и x11vnc работают; пароли из `/persist/etc/x11vnc.pass`.

### Шаг 7. Настройка update-сервера

```bash
ssh ubuntu@<ip_панели>
sudo -i

# Записать персистентные параметры.
echo "https://panels.example.com"  > /etc/inauto/update-server
echo "stable"                       > /etc/inauto/channel
echo "panel-<site>-<n>"             > /etc/inauto/serial.txt

systemctl restart panel-check-updates.timer
systemctl list-timers panel-check-updates.timer  # следующий tick ожидаем в пределах ~5 минут
```

Через 5–10 минут в `panels` таблице на update-server'е должен появиться
heartbeat от нового serial.

## Acceptance checklist

- [ ] `efibootmgr -v` показывает `system0` и `system1`, BootOrder = system0,system1.
- [ ] `rauc status` показывает booted slot = `system0`, slot state = good.
- [ ] `/home/inauto/.inautolock` существует; skeleton директорий создан.
- [ ] `/etc/inauto/firmware-version` = ожидаемая `<VERSION>`.
- [ ] `docker info` работает; `systemctl is-active lightdm docker containerd x11vnc ssh` все active.
- [ ] Heartbeat появился в `panels.last_seen` на update-сервере.
- [ ] Overlay reset подтверждён: создать `/etc/marker`, reboot, убедиться что он исчез.

Если все пункты зелёные — панель сдана в эксплуатацию.
