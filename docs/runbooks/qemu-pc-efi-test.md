# Инструкция: проверка PC EFI в QEMU

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc`, `TARGET_PLATFORM=pc-efi`.

Цель — быстрый acceptance-цикл для immutable firmware до физических панелей.
Запускается локально или в CI.

## Pre-requisites

Хост:
- `qemu-system-x86_64` с поддержкой `-machine q35` и `-bios`/`-drive if=pflash`;
- OVMF (UEFI firmware for QEMU). Ubuntu: `sudo apt install ovmf`.
  Файлы: `/usr/share/OVMF/OVMF_CODE.fd`, `/usr/share/OVMF/OVMF_VARS.fd`.
- Сборочное окружение: `./scripts/build-in-docker.sh --rebuild-builder --shell` один раз,
  чтобы удостовериться, что builder содержит pinned RAUC (`RAUC_PINNED_VERSION`,
  по умолчанию 1.15.2),
  `mtools`, `dosfstools`, `gdisk`, `efibootmgr`.

Payload:
- `out/inauto-panel-ubuntu-amd64-pc-efi-<version>.raucb`
- `out/inauto-panel-installer-ubuntu-amd64-pc-efi-<version>.tar.zst`
- `out/inauto-panel-installer-ubuntu-amd64-pc-efi-<version>.iso`

Соберите их:

```bash
TARGET_PLATFORM=pc-efi TARGET_ARCH=amd64 \
    RAUC_BUNDLE_VERSION="dev.$(date -u +%Y.%m.%d).1" \
    RAUC_VERSION_MODE=dev-ok \
    ./scripts/build-rauc-installer.sh
```

(Переменную `RAUC_VERSION_MODE=dev-ok` используем только в локальной сборке;
production-bundle'ы подписываются CI из git-тега vYYYY.MM.DD.N.)

## Шаг 1. Пустой виртуальный диск

```bash
qemu-img create -f qcow2 /tmp/panel.qcow2 64G
```

32 GiB достаточно для full layout, но 64 оставляет запас для stress-сценариев.

## Шаг 2. Запустить installer ISO

Короткая версия:
1. Запустить `out/inauto-panel-installer-*.iso` в QEMU с OVMF и пустым qcow2.
2. В live-сессии запустить desktop-мастер `Inauto Panel Installer` или
   `/cdrom/inauto-installer/START-INSTALLER.sh`.
3. Для CI/unattended-сценариев можно запустить runtime script напрямую:
   - `TARGET_DEVICE=/dev/vda` (или что увидит `lsblk`);
   - `SKIP_REBOOT=1`, чтобы контролировать reboot самим;
   - `FORCE_YES=1`, чтобы пропустить подтверждение стирания тестового диска;
   - `PANEL_HOSTNAME`, `UPDATE_CHANNEL`, `UPDATE_SERVER`, чтобы не было prompt'ов.

   ```bash
   sudo TARGET_DEVICE=/dev/vda SKIP_REBOOT=1 FORCE_YES=1 \
       PANEL_HOSTNAME=qemu-panel UPDATE_CHANNEL=candidate \
       UPDATE_SERVER=http://10.0.2.2:9001 \
       /cdrom/inauto-installer/install-to-disk.sh
   ```

Пример QEMU команды для installer-сессии:

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -m 4G \
    -cpu host \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/tmp/panel-OVMF_VARS.fd \
    -drive file=out/inauto-panel-installer-ubuntu-amd64-pc-efi-<version>.iso,media=cdrom \
    -drive file=/tmp/panel.qcow2,if=virtio,format=qcow2 \
    -net nic -net user \
    -vga virtio -display gtk
```

Где `/tmp/panel-OVMF_VARS.fd` — свежая копия `OVMF_VARS.fd` (чтобы не ломать host state).

## Шаг 3. Acceptance-проверки после install

После успешного `install-to-disk.sh` (ещё в live-сессии, до reboot):

### Partlabels + layout

```bash
sgdisk -p /dev/vda
# Ожидаем именно:
#  efi_A (512 MiB, EF00)
#  efi_B (512 MiB, EF00)
#  rootfs_A (5 GiB, 8300)
#  rootfs_B (5 GiB, 8300)
#  persist (1 GiB, 8300)
#  container-store (variable, 8300)
#  inauto-data (rest, 8300)

ls -l /dev/disk/by-partlabel/
# efi_A, efi_B, rootfs_A, rootfs_B, persist, container-store, inauto-data
```

### UEFI boot entries

```bash
efibootmgr -v
# Ожидаем два entry:
#   Boot00XX* system0  ... \EFI\BOOT\BOOTX64.EFI ... rauc.slot=system0 root=PARTLABEL=rootfs_A ...
#   Boot00XX* system1  ... \EFI\BOOT\BOOTX64.EFI ... rauc.slot=system1 root=PARTLABEL=rootfs_B ...
# BootOrder должен начинаться с system0.
```

### efi.vfat содержимое

```bash
mkdir -p /mnt/efi_A && mount /dev/disk/by-partlabel/efi_A /mnt/efi_A
ls -l /mnt/efi_A/EFI/BOOT/
# BOOTX64.EFI
ls -l /mnt/efi_A/EFI/Linux/
# compatibility copy inauto-panel.efi + initrd.img
umount /mnt/efi_A
```

### persist skeleton

```bash
mkdir -p /mnt/persist && mount /dev/disk/by-partlabel/persist /mnt/persist
ls -l /mnt/persist/etc/ /mnt/persist/etc/ssh/ /mnt/persist/etc/inauto/
# machine-id, hostname, ssh host keys (rsa/ecdsa/ed25519), serial.txt, channel, update-server
umount /mnt/persist
```

### inauto-data skeleton

```bash
mkdir -p /mnt/inauto && mount /dev/disk/by-partlabel/inauto-data /mnt/inauto
ls -l /mnt/inauto/
# .inautolock + on_start/{before_login,oneshot,forking}/ + on_login/ + staff/ + log/
umount /mnt/inauto
```

## Шаг 4. Первый boot в installed систему

Выключите live-ISO (`qemu-system -boot order=c` без cdrom) и загрузитесь с qcow2:

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -m 4G \
    -cpu host \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/tmp/panel-OVMF_VARS.fd \
    -drive file=/tmp/panel.qcow2,if=virtio,format=qcow2 \
    -net nic -net user,hostfwd=tcp::2222-:22 \
    -vga virtio -display gtk
```

Ожидаемое:
- UEFI выбирает `system0` (BootOrder[0]).
- kernel EFI-stub грузится, initramfs выполняет `scripts/local-bottom/panel-boot`.
- systemd стартует в overlay-rootfs.
- `/home/inauto` смонтирован из `inauto-data`.
- Docker и containerd поднимаются поверх `container-store`.

### Проверки внутри системы

```bash
findmnt /                 # overlayfs, lower=/run/panel/lower, upper=/run/panel/tmpfs/upper
findmnt /home/inauto      # /dev/vda7 (inauto-data)
findmnt /var/lib/docker   # bind from /var/lib/inauto/container-store/docker
findmnt /var/lib/containerd

cat /etc/inauto/firmware-version    # dev.<date>.1 (или prod-версия)
cat /etc/rauc/system.conf | head -3 # compatible=inauto-panel-ubuntu-amd64-pc-efi-v1

systemctl is-active MountHome DockerPersistentStorage docker containerd x11vnc ssh lightdm

docker info | head
```

### Overlay reset

Проверяем что runtime-правки в `/etc` исчезают после reboot:

```bash
echo marker > /etc/overlay-reset-marker
sync
systemctl reboot
```

После reboot:

```bash
[ ! -f /etc/overlay-reset-marker ] && echo "overlay reset ok"
```

### persist выживает

```bash
# До reboot
cat /etc/machine-id > /home/inauto/log/mid.before
ssh-keyscan -t rsa localhost > /home/inauto/log/hostkey.before

systemctl reboot

# После reboot
diff /home/inauto/log/mid.before /etc/machine-id          # equal
diff /home/inauto/log/hostkey.before <(ssh-keyscan -t rsa localhost)  # equal
```

## Шаг 5. `rauc install` + rollback gate

### 5.1. Зафиксировать исходное состояние

```bash
mkdir -p /home/inauto/log/qemu-gate
rauc status                              # booted slot и slot-статусы
efibootmgr -v > /home/inauto/log/qemu-gate/bootmgr.before
cat /etc/inauto/firmware-version > /home/inauto/log/qemu-gate/fw.before
rauc status mark-good booted             # убеждаемся, что текущий slot — good
```

### 5.2. Собрать bundle N+1 на host

```bash
# В хостовом clone репозитория:
RAUC_BUNDLE_VERSION="dev.$(date -u +%Y.%m.%d).$((RANDOM))" \
    RAUC_VERSION_MODE=dev-ok \
    TARGET_FORMAT=rauc TARGET_PLATFORM=pc-efi TARGET_ARCH=amd64 \
    ./scripts/build-in-docker.sh chr_build_image - build_rauc_bundle

ls -la out/*.raucb
```

Скопировать bundle внутрь QEMU (scp через hostfwd или общий virtfs).

### 5.3. Установить bundle в inactive slot

```bash
# Внутри панели:
rauc install /tmp/inauto-panel-ubuntu-amd64-pc-efi-dev.<N+1>.raucb

efibootmgr -v > /home/inauto/log/qemu-gate/bootmgr.after.install
diff /home/inauto/log/qemu-gate/bootmgr.before /home/inauto/log/qemu-gate/bootmgr.after.install
# Ожидаем появление BootNext, указывающего на system1 (если booted system0).
```

`rauc install` на EFI backend:
- пишет efi.vfat и rootfs.img в inactive slot (например system1);
- ставит `BootNext=<inactive>` через efibootmgr;
- НЕ меняет BootOrder — это произойдёт только после `mark-good`.

### 5.4. Reboot и проверка, что активен новый slot

```bash
systemctl reboot
```

После reboot:

```bash
cat /proc/cmdline | grep -o 'rauc.slot=[^ ]*'
# Ожидаем system1 (или другой — который был inactive до install)

rauc status
# Booted slot должен быть новый.

cat /etc/inauto/firmware-version
# Соответствует N+1.

# Проверяем, что healthcheck отработает и mark-good выставится:
systemctl status rauc-mark-boot-good.service
# После успешного healthcheck'а — active (exited).

rauc status | grep -i 'good\|bad\|active'
# Новый slot должен перейти в состояние "good".
```

### 5.5. Rollback-тест: forced healthcheck failure

Задача — убедиться, что EFI BootNext probation возвращает к предыдущему slot'у,
если `rauc mark-good booted` не выставлен.

Сначала ставим новую версию N+2 (та же процедура 5.2–5.3), но на этот раз
ломаем healthcheck, чтобы он не прошёл в новом slot'е.

Самый простой способ поломать healthcheck — спрятать docker CLI от будущего
overlay'а, чтобы `docker info` упал в скрипте panel-healthcheck.sh. Но overlay
reset'ит правки, так что проще изменить сам panel-healthcheck.sh через
override в site config (`/home/inauto/config/healthcheck.sh` — site hook
обязателен, его ненулевой exit валит общий healthcheck):

```bash
# В панели, перед install новой версии:
install -D -m 0755 /dev/stdin /home/inauto/config/healthcheck.sh <<'EOF'
#!/bin/bash
echo "[site-healthcheck] intentional fail (rollback test)" >&2
exit 1
EOF
```

Теперь install bundle и reboot:

```bash
rauc install /tmp/inauto-panel-ubuntu-amd64-pc-efi-dev.<N+2>.raucb
efibootmgr -v > /home/inauto/log/qemu-gate/bootmgr.after.install2
systemctl reboot
```

После reboot:

```bash
# BootNext сработал один раз, новый slot запущен.
cat /proc/cmdline | grep -o 'rauc.slot=[^ ]*'
# Ожидаем inactive (например снова system1).

# Healthcheck упадёт из-за /home/inauto/config/healthcheck.sh.
systemctl is-failed rauc-mark-boot-good.service
# Должен быть failed; mark-good НЕ вызван.

# Ещё один reboot — EFI вернёт BootOrder на прежний system0.
systemctl reboot
```

После второго reboot:

```bash
cat /proc/cmdline | grep -o 'rauc.slot=[^ ]*'
# Ожидаем system0 (исходный slot).

cat /etc/inauto/firmware-version
# Соответствует N+1 (или N, если rollback-тест шёл прямо от исходного).

efibootmgr -v > /home/inauto/log/qemu-gate/bootmgr.after.rollback
diff /home/inauto/log/qemu-gate/bootmgr.after.install2 /home/inauto/log/qemu-gate/bootmgr.after.rollback
# BootNext должен уже быть потрачен; BootOrder неизменён.
```

Уберите healthcheck-saboteur:

```bash
rm /home/inauto/config/healthcheck.sh
```

### 5.6. Capture artefacts

Для runbook'а положите в отчёт:

- `/home/inauto/log/qemu-gate/bootmgr.before`,
  `/home/inauto/log/qemu-gate/bootmgr.after.install`,
  `/home/inauto/log/qemu-gate/bootmgr.after.install2`,
  `/home/inauto/log/qemu-gate/bootmgr.after.rollback`
- `rauc status` до и после каждого reboot'а
- `journalctl -u rauc-mark-boot-good.service` (успех и failure)
- `cat /etc/inauto/firmware-version` в каждой точке

Этот набор — минимальный обязательный для candidate-gate'а перед promotion в stable.

## Шаг 6. Forced hang / panic test (watchdog gate)

Перед передачей в физический candidate-gate — проверяем, что kernel panic
и userspace hang восстанавливаются через watchdog. Запуск QEMU с
hardware watchdog:

```bash
qemu-system-x86_64 \
    ... \
    -watchdog i6300esb -watchdog-action reset
```

Внутри панели:

```bash
journalctl -b --no-pager | grep -i 'watchdog'
# Ожидаем запись о hardware watchdog и systemd timeout 1min.

ls -l /dev/watchdog0   # block device должен существовать
```

Провокация kernel panic:

```bash
echo c > /proc/sysrq-trigger
```

Ожидаемо: reboot через ~30s (`panic=30` в efi-cmdline).

Детали и userspace hang сценарий — `docs/runbooks/watchdog.md`.

## Что считать пройденным gate'ом

- GPT partlabels и UEFI entries `system0`/`system1` есть после `install-to-disk.sh`.
- Первый boot в `system0` приводит к rabotающей системе с immutable rootfs и overlay.
- `/home/inauto`, `persist`, `/var/lib/docker`, `/var/lib/containerd` выживают перезагрузку.
- Runtime правки в `/etc` сбрасываются после reboot.
- `rauc install` версии N+1 переводит boot в другой slot; healthcheck pass → mark-good; failure → BootOrder rollback.

Все пять пунктов обязательны до promote в `stable` и до физического panel-gate'а.
