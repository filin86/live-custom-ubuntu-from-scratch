# Design: Immutable Panel Firmware с RAUC

Дата: 2026-04-20
Статус: implementation-ready draft v2
Автор: @filin

## Контекст

Текущий проект собирает кастомизированный Ubuntu/Debian Live ISO с XFCE kiosk-режимом, autologin, x11vnc, Docker и systemd-автовосстановлением compose-проектов. Образы устанавливаются на operator-панели (HMI-терминалы). На предприятиях развёрнут парк до 50 панелей.

Проблемы mutable-подхода:
- Drift между панелями в поле.
- Неудачный `apt upgrade` может оставить панель неработоспособной.
- Нет атомарного OS rollback.
- Runtime-логи и временные данные могут переполнять rootfs.
- После compromise rootfs нельзя гарантированно вернуть в чистое состояние без переустановки.

Цель: перейти на immutable rootfs с A/B обновлениями через RAUC, сохранив текущий workflow наладчиков, где site-specific software и конфигурация живут в `/home/inauto`.

## Обязательные решения

| Решение | Значение |
|---|---|
| Update framework | RAUC, min 1.13, pinned version в builder/CI |
| PC boot backend | RAUC `bootloader=efi`, только UEFI PC в MVP |
| Tablet boot backend | RAUC `bootloader=uboot`, после идентификации SoC/платы |
| Legacy BIOS | Out of scope для MVP. BIOS-only панели требуют отдельного legacy path или остаются на старом ISO |
| Boot artifacts | A/B boot slots обновляются вместе с rootfs slots |
| Rootfs | SquashFS, mounted read-only, tmpfs overlay upper |
| Bundle format | RAUC `format=verity`, `bundle-formats=-plain` |
| Runtime dm-verity | Не входит в MVP. См. раздел "Verity scope" |
| Persistent state | Только явно перечисленные bind-mount paths + `/home/inauto` + container storage |
| Docker storage | Отдельный RW-раздел, содержит Docker и containerd data roots |
| Application lifecycle | Qt-app, compose-проекты и site-specific софт живут в `/home/inauto` и обновляются независимо от OS |
| Compatible string | `inauto-panel-<distro>-<arch>-<platform>-v1` |
| Versioning | Explicit `RAUC_BUNDLE_VERSION`, normally from git tag `vYYYY.MM.DD.N`; production bundle version must match `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$` |
| Channels | `candidate`, `stable` |
| Update trigger | systemd timer pull раз в час + ручной запуск |
| Factory provisioning | USB installer, собирается CI из того же bundle |
| Server side | Custom HTTP API + nginx + SQLite |

Допустимые `platform` значения для MVP:
- `pc-efi`: x86_64/amd64 PC-панели с UEFI.
- `<board>-uboot`: конкретная ARM64 tablet board, например `mindeo-bk5v-uboot`, после идентификации SoC и загрузочного стека.

Примеры compatible:
- `inauto-panel-ubuntu-amd64-pc-efi-v1`
- `inauto-panel-debian-amd64-pc-efi-v1`
- `inauto-panel-ubuntu-arm64-mindeo-bk5v-uboot-v1`

## Verity scope

RAUC `format=verity` защищает `.raucb` bundle во время установки и streaming, но не делает установленный rootfs автоматически dm-verity protected при boot.

MVP гарантирует:
- bundle проверяется X.509 подписью RAUC;
- plain bundles запрещены через `bundle-formats=-plain`;
- rootfs после установки монтируется read-only как SquashFS;
- все runtime-записи уходят в tmpfs overlay или в явно разрешённые RW-разделы.

MVP не гарантирует:
- cryptographic verification уже установленного rootfs при каждом boot;
- защиту от атакующего, который получил root и может писать в boot/rootfs partitions offline;
- secure boot chain.

Runtime dm-verity можно добавить отдельной фазой после MVP. Для этого нужно:
- генерировать rootfs image как `squashfs + verity hash tree`;
- хранить root hash/hash offset в boot slot metadata;
- передавать hash в initramfs через EFI/U-Boot cmdline;
- включить Secure Boot/подписанный U-Boot или признать, что verity защищает только от случайной corruption, а не от физического/privileged tampering.

## Threat model

Immutable OS решает OS drift и даёт атомарный OS rollback. Это не делает всю панель "sterile", потому что `/home/inauto` и container storage остаются persistent и trusted.

В MVP считается доверенной зоной:
- `/home/inauto`;
- Docker/containerd storage;
- site hooks `on_start/*` и `on_login/*`;
- persistent NetworkManager/SSH/update config.

Если атакующий получил возможность записывать в `/home/inauto`, он может сохранить persistence через текущие startup hooks. Это осознанная совместимость с workflow наладчиков. Ужесточение возможно отдельной фазой:
- подпись site hooks/app bundles;
- запуск hooks не от root;
- отдельный RAUC-managed `appfs`;
- allowlist compose-проектов;
- AppArmor/SELinux profile.

## Слои системы

```
rootfs_A/rootfs_B (raw partition with SquashFS bytes, RO)
  - systemd, Xorg/XFCE kiosk, LightDM
  - Docker engine + containerd binaries
  - x11vnc, sshd, NetworkManager
  - /etc/inauto stub scripts
  - RAUC client, update agent, healthcheck
  - base sudoers/polkit/pam policies

tmpfs overlay upper (volatile, default 2 GB)
  - runtime writes to /etc, /var/log, /tmp, etc.
  - discarded on reboot

persist (ext4, RW, 1 GB)
  - bind-mounted files/directories that must survive reboot

container-store (ext4, RW)
  - /var/lib/docker
  - /var/lib/containerd

inauto-data (ext4, RW)
  - mounted at /home/inauto
  - Qt app, compose projects, site config, site data, project logs
```

## Partition layout

Use GPT everywhere. Use stable `/dev/disk/by-partlabel/*` paths in initramfs and RAUC config. Do not rely on filesystem labels for A/B slots because labels can duplicate after image writes.

### PC UEFI target (`platform=pc-efi`)

Legacy BIOS is not supported in this target.

For maximum RAUC `efi` compatibility, PC uses two redundant VFAT boot partitions. Each boot partition contains an EFI-stub Linux kernel and initramfs at the same path. RAUC creates or updates UEFI boot entries that point to the matching partition.

MVP boot artifact choice: **EFI-stub kernel + external initrd**, not UKI. `inauto-panel.efi` is just the distro kernel copied/renamed as an EFI application. The kernel command line is supplied through RAUC EFI boot entry loader options (`efi-cmdline`) or equivalent `efibootmgr --unicode` options. UKI may be added later as a separate hardening/simplification phase.

Default layout for a 200 GB disk:

```
/dev/sda1  efi_A          512 MB   FAT32   boot slot A, EFI-stub kernel + initrd
/dev/sda2  efi_B          512 MB   FAT32   boot slot B, EFI-stub kernel + initrd
/dev/sda3  rootfs_A       5 GB     raw     SquashFS bytes
/dev/sda4  rootfs_B       5 GB     raw     SquashFS bytes
/dev/sda5  persist        1 GB     ext4    explicit persistent state
/dev/sda6  container-store variable ext4    Docker + containerd
/dev/sda7  inauto-data    rest     ext4    /home/inauto
```

PC `container-store` sizing:
- disks >= 100 GB: 40 GB default;
- disks 64..99 GB: 16 GB default;
- disks 32..63 GB: 8 GB default;
- disks < 32 GB: unsupported for PC UEFI target unless an explicit product profile overrides layout.

Installer must accept explicit `CONTAINER_STORE_SIZE` and fail if the requested layout cannot fit with at least 8 GB remaining for `inauto-data`.

Partition type for `efi_A`/`efi_B`:
- Preferred: regular FAT partition with explicit UEFI Boot#### entries managed by `efibootmgr`/RAUC.
- Fallback: ESP type GUID if specific firmware refuses to boot from non-ESP FAT partitions. Factory tests must then verify that firmware-created extra boot entries do not override RAUC BootOrder/BootNext.

### Tablet U-Boot target (`platform=<board>-uboot`)

Exact bootloader/vendor partitions depend on SoC and BSP. The layout below is the RAUC-managed part after vendor bootloader requirements are known.

Tablet 32 GB default:

```
mmcblk0p1  bootloader       board-specific   vendor U-Boot/SPL/TF-A area, not RAUC-managed in MVP
mmcblk0p2  uboot-env        4 MB             redundant U-Boot env, or documented fixed offsets
mmcblk0p3  boot_A           256 MB FAT32     kernel + initrd + dtb for slot A
mmcblk0p4  boot_B           256 MB FAT32     kernel + initrd + dtb for slot B
mmcblk0p5  rootfs_A         5 GB raw         SquashFS bytes
mmcblk0p6  rootfs_B         5 GB raw         SquashFS bytes
mmcblk0p7  persist          1 GB ext4        explicit persistent state
mmcblk0p8  container-store  8 GB ext4        Docker + containerd
mmcblk0p9  inauto-data      rest ext4        /home/inauto
```

Tablet 64 GB differs only in `container-store=16 GB`.

If the board stores U-Boot environment at raw eMMC offsets instead of a GPT partition, `uboot-env` is omitted and `/etc/fw_env.config` documents the two redundant offsets.

## Persistent paths

`persist` is mounted early in initramfs at `/persist`. The initramfs then bind-mounts specific entries into `/new-root`.

Required persistent entries:

```
/persist/etc/machine-id                         -> /etc/machine-id
/persist/etc/hostname                           -> /etc/hostname
/persist/etc/ssh                                -> /etc/ssh
/persist/etc/NetworkManager/NetworkManager.conf -> /etc/NetworkManager/NetworkManager.conf
/persist/etc/NetworkManager/system-connections  -> /etc/NetworkManager/system-connections
/persist/etc/inauto/serial.txt                  -> /etc/inauto/serial.txt
/persist/etc/inauto/channel                     -> /etc/inauto/channel
/persist/etc/inauto/update-server               -> /etc/inauto/update-server
/persist/etc/x11vnc.pass                        -> /etc/x11vnc.pass
/persist/var/lib/rauc                           -> /var/lib/rauc
/persist/var/lib/systemd/random-seed            -> /var/lib/systemd/random-seed
```

First boot initialization rules:
- If a persistent file is missing and rootfs contains a default, copy the default from `/lower` into `/persist`, then bind-mount it.
- SSH host keys are generated into `/persist/etc/ssh` by the installer. If missing, first boot generates them before `sshd`.
- `/etc/machine-id` and `/etc/hostname` are bind-mounted in initramfs before `switch_root`, i.e. before `systemd-machine-id-setup` and hostname setup can run.
- NetworkManager connection files are mode `0600` and owned by root.
- `NetworkManager.conf` is persistent because DNS/renderer changes are site-specific in some deployments. Product images may still enforce defaults by provisioning this file during factory install.
- `/var/lib/rauc` must exist before `rauc.service` or any `rauc install`.

Optional persistent journald:
- `INAUTO_JOURNAL_DIR=/home/inauto/log/journal` by default.
- A normal systemd service after `/home/inauto` mount creates the directory and bind-mounts it to `/var/log/journal`.
- If this bind mount fails, journald remains volatile with size caps.

## Container storage

Use one ext4 partition `container-store`, mounted at `/var/lib/inauto/container-store`.

Inside it:

```
/var/lib/inauto/container-store/docker      -> bind to /var/lib/docker
/var/lib/inauto/container-store/containerd  -> bind to /var/lib/containerd
```

`DockerPersistentStorage.service` changes from "create loopback ext4 file under /home" to "mount/check dedicated container-store partition and bind Docker/containerd roots".

Rules:
- Compose project files and business data should live under `/home/inauto`, not only inside Docker named volumes.
- Docker named volumes may persist, but are treated as runtime/container state.
- Docker CLI credentials and per-user `DOCKER_CONFIG` stay under `/home/inauto/staff/docker-config`. This is site/project state, not container runtime state.
- OS rollback does not rollback Docker/containerd storage. Therefore Docker/containerd major upgrades require candidate testing and a healthcheck that verifies `docker info` plus critical compose startup before `mark-good`.
- If `container-store` is unavailable, Docker/containerd must not silently start in ephemeral mode in production. The service fails and prevents `mark-good`.

## `/home/inauto` contract

`inauto-data` is mounted deterministically by initramfs at `/home/inauto` using `PARTLABEL=inauto-data`. The old dynamic `.inautolock` scan remains only as an import/service tool, not as the normal immutable boot path.

Required initial structure:

```
/home/inauto/.inautolock
/home/inauto/on_start/before_login/
/home/inauto/on_start/oneshot/
/home/inauto/on_start/forking/
/home/inauto/on_login/
/home/inauto/staff/
/home/inauto/log/
```

Build-time variables define integration paths:

```
INAUTO_SITE_CONFIG_DIR=/home/inauto/config
INAUTO_AUTOSTART_SCRIPT=/home/inauto/on_login
INAUTO_JOURNAL_DIR=/home/inauto/log/journal
```

The login user remains `AUTOLOGIN_USER` from the current build profile. In the current repository this is `ubuntu`; `/home/inauto` is the persistent data mount and is not automatically the login user's home unless a separate user migration changes that.

## RAUC configuration

### PC UEFI `system.conf`

Generated template path:

```
scripts/profiles/<distro>/rauc/system-efi.conf.template
```

Template:

```ini
[system]
compatible=inauto-panel-@DISTRO@-@ARCH@-pc-efi-v1
bootloader=efi
data-directory=/var/lib/rauc
bundle-formats=-plain
efi-use-bootnext=true
activate-installed=true

[keyring]
path=/etc/rauc/keyring.pem

[slot.efi.0]
device=/dev/disk/by-partlabel/efi_A
type=vfat
bootname=system0
efi-loader=\\EFI\\Linux\\inauto-panel.efi
efi-cmdline=initrd=\\EFI\\Linux\\initrd.img rauc.slot=system0 root=/dev/disk/by-partlabel/rootfs_A rootfstype=squashfs ro quiet

[slot.efi.1]
device=/dev/disk/by-partlabel/efi_B
type=vfat
bootname=system1
efi-loader=\\EFI\\Linux\\inauto-panel.efi
efi-cmdline=initrd=\\EFI\\Linux\\initrd.img rauc.slot=system1 root=/dev/disk/by-partlabel/rootfs_B rootfstype=squashfs ro quiet

[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs_A
type=raw
parent=efi.0

[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs_B
type=raw
parent=efi.1
```

Notes:
- `inauto-panel.efi` is the distro kernel copied/renamed into the VFAT image. The kernel must support EFI stub boot.
- `initrd.img` is slot-local and updated together with the kernel.
- `efi-loader` and `efi-cmdline` are RAUC EFI slot keys documented in upstream RAUC Integration docs. The implementation gate must verify the pinned RAUC version accepts the rendered `system.conf`.
- EFI paths in this document are written with escaped backslashes for INI examples. The implementation gate must verify `efibootmgr -v` produces loader paths that firmware can actually boot; if pinned RAUC expects single backslashes in config, templates must use that exact syntax.
- RAUC's EFI backend can use BootCurrent to detect the booted slot. `rauc.slot` is still passed explicitly for initramfs and diagnostics.
- EFI rollback is one-boot probation via `BootNext`. If healthcheck does not call `mark-good`, next boot returns to previous BootOrder entry.

### Tablet U-Boot `system.conf`

Generated template path:

```
scripts/profiles/<distro>/rauc/system-uboot.conf.template
```

Template:

```ini
[system]
compatible=inauto-panel-@DISTRO@-@ARCH@-@PLATFORM@-v1
bootloader=uboot
data-directory=/var/lib/rauc
bundle-formats=-plain
boot-attempts=3
boot-attempts-primary=3
activate-installed=true

[keyring]
path=/etc/rauc/keyring.pem

[slot.boot.0]
device=/dev/disk/by-partlabel/boot_A
type=vfat
bootname=A

[slot.boot.1]
device=/dev/disk/by-partlabel/boot_B
type=vfat
bootname=B

[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs_A
type=raw
parent=boot.0

[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs_B
type=raw
parent=boot.1
```

U-Boot requirements:
- `fw_printenv` and `fw_setenv` installed in rootfs.
- `/etc/fw_env.config` matches board environment storage.
- U-Boot env is redundant if the board supports it.
- Production U-Boot support requires a real board-tested `boot.cmd`/`boot.scr`, not only a template.
- Boot script uses `BOOT_ORDER`, `BOOT_A_LEFT`, `BOOT_B_LEFT` and decrements attempts before boot.
- Boot script passes `rauc.slot=A|B` and rootfs partition to kernel cmdline.

## Bundle manifest

Bundle workdir contains:

```
manifest.raucm
efi.vfat        # PC UEFI only
boot.vfat       # U-Boot target only
rootfs.img      # SquashFS bytes, installed raw into rootfs slot
```

PC UEFI manifest:

```ini
[update]
compatible=inauto-panel-ubuntu-amd64-pc-efi-v1
version=2026.04.20.1
description=Inauto panel firmware 2026.04.20.1

[bundle]
format=verity

[image.efi]
filename=efi.vfat

[image.rootfs]
filename=rootfs.img
```

U-Boot manifest:

```ini
[update]
compatible=inauto-panel-ubuntu-arm64-mindeo-bk5v-uboot-v1
version=2026.04.20.1
description=Inauto panel tablet firmware 2026.04.20.1

[bundle]
format=verity

[image.boot]
filename=boot.vfat

[image.rootfs]
filename=rootfs.img
```

Build rules:
- `rootfs.img` is copied from `scripts/image/<LIVE_BOOT_DIR>/filesystem.squashfs`.
- `efi.vfat` contains `\EFI\Linux\inauto-panel.efi` and `\EFI\Linux\initrd.img`.
- `boot.vfat` contains board-specific kernel/initrd/dtb paths expected by U-Boot script.
- rootfs contains rendered `/etc/rauc/system.conf`.
- rootfs contains `/etc/inauto/firmware-version` with the bundle version string.
- `RAUC_BUNDLE_VERSION` is mandatory for release builds. CI derives it from the git tag. Production versions must match `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$`; target scripts must reject non-matching production versions. Local dev builds may pass a clearly marked dev version, but dev versions are never published to `candidate` or `stable`.
- The bundle is signed by RAUC with online signing cert.

## Initramfs boot flow

The same rootfs initramfs logic is used for EFI and U-Boot.

Inputs from kernel cmdline:

```
root=/dev/disk/by-partlabel/rootfs_A|rootfs_B
rauc.slot=system0|system1|A|B
```

Algorithm:

```bash
parse /proc/cmdline
resolve ROOT_DEV from root=
wait for ROOT_DEV and required PARTLABEL devices

mount -t squashfs -o ro "$ROOT_DEV" /lower

mount -t tmpfs -o mode=0755,size=${INAUTO_OVERLAY_SIZE:-2G} tmpfs /tmpfs-upper
mkdir -p /tmpfs-upper/upper /tmpfs-upper/work /new-root
mount -t overlay overlay \
  -o lowerdir=/lower,upperdir=/tmpfs-upper/upper,workdir=/tmpfs-upper/work \
  /new-root

mount -t ext4 /dev/disk/by-partlabel/persist /persist
initialize_missing_persist_entries_from_lower
bind_mount_persist_entries

mount -t ext4 /dev/disk/by-partlabel/inauto-data /new-root/home/inauto
mount -t ext4 /dev/disk/by-partlabel/container-store /new-root/var/lib/inauto/container-store
mkdir -p /new-root/var/lib/docker /new-root/var/lib/containerd
mount --bind /new-root/var/lib/inauto/container-store/docker /new-root/var/lib/docker
mount --bind /new-root/var/lib/inauto/container-store/containerd /new-root/var/lib/containerd

exec switch_root /new-root /sbin/init
```

Failure policy:
- Missing rootfs slot: panic/drop to emergency shell in factory/dev, reboot in production after watchdog timeout.
- Missing `persist`, `inauto-data`, or `container-store`: boot continues only to emergency target; healthcheck must fail.
- Corrupt SquashFS: boot fails; RAUC backend rollback handles next boot according to backend semantics.
- EFI cannot recover from a hang unless the system reboots. Production images must configure a watchdog path (hardware watchdog where available, otherwise kernel panic/reboot and systemd watchdog settings) before enabling unattended rollouts.

## Mark boot good

Systemd unit:

```ini
[Unit]
Description=Mark current RAUC slot as good after successful boot
After=multi-user.target network-online.target docker.service lightdm.service MountHome.service
Requires=MountHome.service docker.service lightdm.service

[Service]
Type=oneshot
ExecStartPre=/usr/local/bin/panel-healthcheck.sh
ExecStart=/usr/bin/rauc status mark-good booted
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Healthcheck minimum:

```bash
#!/bin/bash
set -euo pipefail

sleep "${INAUTO_HEALTHCHECK_DELAY:-60}"

systemctl is-active --quiet lightdm
systemctl is-active --quiet docker
systemctl is-active --quiet containerd
systemctl is-active --quiet x11vnc
systemctl is-active --quiet ssh

mountpoint -q /home/inauto
mountpoint -q /var/lib/inauto/container-store
mountpoint -q /var/lib/docker
mountpoint -q /var/lib/containerd

for attempt in {1..10}; do
    docker info >/dev/null && break
    if [[ "$attempt" -eq 10 ]]; then
        exit 1
    fi
    sleep 3
done

if [[ -x /home/inauto/config/healthcheck.sh ]]; then
    /home/inauto/config/healthcheck.sh
fi
```

Backend-specific behavior:
- EFI: updated slot is tried via BootNext. If `mark-good` is not called, subsequent boots return to previous BootOrder primary.
- U-Boot: updated slot gets `BOOT_<slot>_LEFT=3`. Failed boots decrement attempts and then fall back.

### Boot watchdog

EFI `BootNext` gives rollback on the next boot, but does not itself cause a reboot if the new slot hangs before healthcheck. Production rollouts require one of:
- hardware watchdog enabled early enough to reboot a stuck boot;
- systemd watchdog (`RuntimeWatchdogSec`) for userspace hangs plus kernel `panic=<seconds>` for panics;
- site power/controller watchdog.

The QEMU/physical candidate gate must include a forced hang/panic test or explicitly record that early-boot hang recovery is not available on that hardware.

## Update agent

Runtime config is persistent:

```
/etc/inauto/update-server
/etc/inauto/channel
/etc/inauto/serial.txt
```

`panel-check-updates.sh`:

```bash
#!/bin/bash
set -euo pipefail

SERVER="$(cat /etc/inauto/update-server)"
CHANNEL="$(cat /etc/inauto/channel 2>/dev/null || echo stable)"
SERIAL="$(cat /etc/inauto/serial.txt 2>/dev/null || hostname)"

CURRENT="$(cat /etc/inauto/firmware-version)"
COMPATIBLE="$(awk -F= '/^compatible=/ { print $2; exit }' /etc/rauc/system.conf)"

LATEST_JSON="$(curl -fsS \
  -H "X-Panel-Serial: ${SERIAL}" \
  "${SERVER}/api/latest?channel=${CHANNEL}&compatible=${COMPATIBLE}")"

LATEST_VERSION="$(jq -r '.version // empty' <<<"$LATEST_JSON")"
BUNDLE_URL="$(jq -r '.url // empty' <<<"$LATEST_JSON")"
FORCE_DOWNGRADE="$(jq -r '.force_downgrade // false' <<<"$LATEST_JSON")"
VERSION_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$'

if [[ ! "$CURRENT" =~ $VERSION_RE || ! "$LATEST_VERSION" =~ $VERSION_RE ]]; then
    echo "Refusing update with non-production version: current=$CURRENT latest=$LATEST_VERSION" >&2
    exit 0
fi

version_gt() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
}

if [[ -n "$LATEST_VERSION" && -n "$BUNDLE_URL" ]] \
    && { version_gt "$LATEST_VERSION" "$CURRENT" || [[ "$FORCE_DOWNGRADE" == "true" ]]; }; then
    rauc install "$BUNDLE_URL"
    systemctl reboot
fi

BOOTED="$(sed -n 's/.*rauc\.slot=\([^ ]*\).*/\1/p' /proc/cmdline)"
if [[ -n "$BOOTED" ]]; then
    curl -fsS -X POST \
      -H "X-Panel-Serial: ${SERIAL}" \
      -H "Content-Type: application/json" \
      -d "{\"compatible\":\"${COMPATIBLE}\",\"version\":\"${CURRENT}\",\"slot\":\"${BOOTED}\"}" \
      "${SERVER}/api/heartbeat" || true
else
    curl -fsS -X POST \
      -H "X-Panel-Serial: ${SERIAL}" \
      -H "Content-Type: application/json" \
      -d "{\"compatible\":\"${COMPATIBLE}\",\"version\":\"${CURRENT}\",\"last_error\":\"missing rauc.slot\"}" \
      "${SERVER}/api/heartbeat" || true
fi
```

Timer:

```ini
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
```

## Update server

API:

```
POST /api/upload
  auth: Bearer token
  form: file=<bundle>, channel=candidate|stable

GET /api/latest?channel=<channel>&compatible=<compatible>
  returns: {"version":"2026.04.20.1","url":"https://.../bundles/name.raucb","force_downgrade":false}

POST /api/heartbeat
  body: compatible, version, slot, rollback flag if detectable, last_error

GET /bundles/<filename>
  static nginx
```

SQLite tables:

```
bundles(id, filename, compatible, version, channel, sha256, uploaded_at)
panels(serial, compatible, channel, last_seen, current_version, current_slot, last_error)
```

Server must never infer compatibility only from `arch`. It uses exact `compatible`.

Heartbeat validation:
- `serial`, `compatible`, and `version` are required.
- `slot` may be absent only when `last_error` explains why the panel could not detect it.
- Empty `slot` without `last_error` is rejected with HTTP 400.
- `version` for production panels must match `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$`.

## Factory provisioning

USB installer is a separate image:

```
inauto-panel-installer-<distro>-<arch>-<platform>-<version>.img.zst
```

PC UEFI installer steps:
1. Boot installer via UEFI.
2. Detect target disk or require `TARGET_DEVICE`.
3. Refuse automatic install on disks < 32 GB. Smaller disks require an explicit product profile and `TARGET_DEVICE`.
4. Create GPT layout for `pc-efi`.
5. Format `efi_A`, `efi_B`, `persist`, `container-store`, `inauto-data`.
6. Extract `efi.vfat` and `rootfs.img` from the verified `.raucb` using RAUC tooling on the installer.
7. Raw-write `efi.vfat` to both `efi_A` and `efi_B`.
8. Raw-write `rootfs.img` to both `rootfs_A` and `rootfs_B`.
9. Create UEFI boot entries with `efibootmgr`:
   - label `system0`, partition `efi_A`, loader `\EFI\Linux\inauto-panel.efi`;
   - label `system1`, partition `efi_B`, loader `\EFI\Linux\inauto-panel.efi`.
10. Set BootOrder to prefer `system0`.
11. Generate `/persist/etc/machine-id`, SSH host keys, x11vnc password, update-server/channel placeholders.
12. Create `/home/inauto/.inautolock` and required directory skeleton.
13. Reboot.

Tablet installer steps are board-specific and require:
- known SoC;
- bootloader unlock or vendor signing process;
- U-Boot build or binary;
- DTB and kernel boot path;
- `fw_env.config` tested from Linux.

## Site startup integration

Rootfs keeps current integration points:

```
/etc/inauto/exec-files-in-folder.sh
/etc/inauto/restore-docker-compose.sh
/etc/systemd/system/OnStartBeforeLogin.service
/etc/systemd/system/OnStartOneShot.service
/etc/systemd/system/OnStartForking.service
/etc/systemd/system/DockerComposeRestore.service
/etc/xdg/autostart/exec_on_start.desktop
```

Change from current mutable model:
- For RAUC builds, `MountHome.service` no longer scans devices during normal boot. It becomes a check/no-op service that verifies `/home/inauto` is already a mountpoint.
- ISO builds keep the current scanning `MountHome.service`.
- `rauc-mark-boot-good.service` must be generated only for RAUC builds and must require the RAUC check-style `MountHome.service`, not the ISO scanning implementation.
- The old `find-and-mount-home.sh` remains available as a manual import helper for service engineers.
- Startup hooks still run from `/home/inauto`; this is trusted mutable behavior by design.

## CI integration

Pipeline:

```
trigger: tag vYYYY.MM.DD.N
  -> build rootfs with existing build flow
  -> create rootfs.img from filesystem.squashfs
  -> create efi.vfat or boot.vfat
  -> render system.conf template for target
  -> rauc bundle --cert --key --intermediate
  -> publish to update server as candidate
  -> build USB installer containing same bundle
```

CI matrix dimensions:
- distro: `ubuntu`, `debian`
- arch: `amd64`, later `arm64`
- platform: `pc-efi`, later concrete tablet platform

Required builder packages:
- `rauc`
- `squashfs-tools`
- `dosfstools`
- `mtools`
- `efibootmgr` for installer runtime
- `u-boot-tools` for tablet boot scripts
- `jq`, `curl`, `openssl`

Secrets:
- `RAUC_SIGNING_CERT`
- `RAUC_SIGNING_KEY`
- `RAUC_INTERMEDIATE_CERT` optional
- `UPDATE_SERVER_DEPLOY_TOKEN`

Root CA private key is never in CI.

## PKI

Root CA:
- offline;
- 20 years;
- public cert installed as `/etc/rauc/keyring.pem`;
- private key stored in encrypted offline media.

Signing cert:
- signed by root CA;
- valid for 2 years;
- private key stored in CI secret or Vault;
- rotates without reflashing panels.

Revocation:
- MVP: rotate signing cert and stop publishing with compromised key.
- CRL is optional. If enabled, CRL distribution and `check-crl=true` must be tested before production use.

## Test strategy

QEMU PC UEFI gate:
- Build `pc-efi` bundle.
- Boot USB installer in QEMU with OVMF.
- Verify GPT partlabels.
- Verify `efibootmgr -v` contains `system0` and `system1`.
- Boot slot A.
- Run `rauc install` to slot B.
- Reboot and verify booted bundle version/slot.
- Force healthcheck failure and verify next boot returns to previous slot.
- Verify `/home/inauto`, `persist`, `/var/lib/docker`, `/var/lib/containerd` survive update.

Tablet gate:
- Starts only after board identification.
- Verify U-Boot script, redundant env, `fw_printenv/fw_setenv`.
- Verify `BOOT_A_LEFT/BOOT_B_LEFT` behavior.
- Verify kernel, initrd, DTB load from `boot_A/boot_B`.

Production candidate gate:
- Minimum two test panels in `candidate`.
- 24h soak before promoting to `stable`.
- Check update, rollback, VNC, SSH, Docker compose restore, site healthcheck, persistent logs.

## Migration

New panels:
- factory flash with USB installer.

Existing panels:
- recommended: full reflash.
- backup `/home/inauto`;
- flash immutable image;
- restore `/home/inauto`;
- redeploy/verify compose projects;
- expected downtime: about 30 minutes per panel.

In-place repartitioning is out of scope for first production release.

## Out of scope

- Legacy BIOS boot path.
- Runtime dm-verity with Secure Boot.
- TPM-backed measured boot.
- Delta updates/casync.
- hawkBit.
- Automatic canary rollout.
- SELinux/AppArmor enforcing.
- Tablet implementation before exact SoC/BSP/bootloader information is available.

## Implementation phases

1. PC UEFI QEMU MVP: partitioner, EFI slots, rootfs SquashFS, initramfs overlay.
2. RAUC bundle: `efi.vfat + rootfs.img`, signing, install to inactive slot.
3. USB installer for `pc-efi`.
4. Healthcheck and EFI rollback validation.
5. Dedicated container-store migration.
6. Update server and pull agent.
7. Runbooks and migration procedure.
8. Tablet U-Boot port after hardware identification.
