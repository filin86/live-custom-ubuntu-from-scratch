# Tablet U-Boot integration guide

Дата: 2026-04-20
Статус: **skeleton; production support требует отдельной фазы после
идентификации конкретной платы.**

## Почему отдельный гайд

PC UEFI target (Phase 0–9) использует RAUC EFI backend, где BootNext/BootOrder
полностью покрывают A/B probation. На планшетах с U-Boot:

- нет стандартного эквивалента BootNext;
- bootcount / BOOT_*_LEFT логика должна быть в самом boot.scr (или в
  U-Boot patched-code);
- SPL/U-Boot/DTB/kernel paths сильно vendor-specific;
- fw_env.config (где U-Boot env хранится) отличается от платы к плате.

Без vendor BSP мы можем подготовить только template. Этот документ
фиксирует, что нужно получить от vendor'а, чтобы закрыть tablet target.

## Что нужно от vendor'а (checklist)

### Hardware + SoC

- [ ] Модель платы / SoC (Rockchip/Allwinner/NXP/Qualcomm/MediaTek/...).
- [ ] Секретность bootloader'а: подписан ли U-Boot vendor-ключом, возможна
      ли замена на custom U-Boot, либо нужна только вендорская версия.
- [ ] Bootloader unlock procedure (если есть Secure Boot).

### Boot chain layout

- [ ] Где физически лежат SPL + U-Boot на eMMC / NAND / raw offsets.
- [ ] GPT layout обязательных vendor-разделов (bootloader, uboot-env, ...).
      Наши A/B partitions (`boot_A`, `boot_B`, `rootfs_A`, `rootfs_B`,
      `persist`, `container-store`, `inauto-data`) встают ПОСЛЕ vendor-разделов
      — см. спек, раздел «Tablet U-Boot target».
- [ ] Устройство/offset для U-Boot env (GPT partition `uboot-env` или raw
      MMC offsets). Две redundant копии обязательны.

### Kernel + DTB

- [ ] Kernel image format: `Image` / `zImage` / `vmlinuz-…` / `uImage`.
- [ ] DTB: имя файла и загрузочный адрес (`${fdt_addr_r}`).
- [ ] initrd: нужен ли `uInitrd` (mkimage wrapping) или обычный cpio/gzip.
- [ ] Bootargs cmdline совместимость: принимает ли kernel стандартные
      `root=/dev/disk/by-partlabel/...`, или нужно `root=PARTLABEL=...`,
      или root=/dev/mmcblk0pN.

### fw_env

- [ ] `/etc/fw_env.config` для `fw_printenv` / `fw_setenv` — нужно
      протестировать из запущенного Linux (не из U-Boot) что redundant
      offsets корректны, иначе RAUC не сможет переключать BOOT_*_LEFT.

### Boot script

- [ ] Формат boot script'а: `boot.scr` (mkimage) или прямое исполнение
      `boot.cmd`. Наш template в `scripts/profiles/<distro>/rauc/boot/uboot/boot.cmd.template`
      использует синтаксис `boot.cmd`, нужна команда `mkimage -A arm[64]
      -O linux -T script -C none -d boot.cmd boot.scr` в build-bundle.
- [ ] Команда загрузки: `booti` (arm64 + Image) / `bootz` (armv7 + zImage)
      / `bootm` (uImage).

## RAUC system.conf differences

Template уже в `scripts/profiles/<distro>/rauc/system-uboot.conf.template`:

```ini
[system]
compatible=inauto-panel-@DISTRO@-@ARCH@-@PLATFORM@-v1
bootloader=uboot
bundle-formats=-plain
boot-attempts=3
boot-attempts-primary=3
activate-installed=true

[slot.boot.0]     device=/dev/disk/by-partlabel/boot_A  type=vfat  bootname=A
[slot.boot.1]     device=/dev/disk/by-partlabel/boot_B  type=vfat  bootname=B
[slot.rootfs.0]   device=/dev/disk/by-partlabel/rootfs_A type=raw   parent=boot.0
[slot.rootfs.1]   device=/dev/disk/by-partlabel/rootfs_B type=raw   parent=boot.1
```

RAUC U-Boot backend использует `fw_setenv` для BOOT_ORDER/BOOT_A_LEFT/
BOOT_B_LEFT. Поэтому:
- `rauc` в rootfs запускается от root;
- `fw_env.config` в rootfs указывает на работающие env offsets;
- unit test: `fw_printenv BOOT_ORDER` должен возвращать строку из U-Boot.

## Production readiness

`boot.cmd.template` — СКЕЛЕТ. Не считается готовым для production без:

- [ ] Board-specific подстановок `@BOARD@`, `@KERNEL_NAME@`, `@INITRD_NAME@`,
      `@DTB_PATH@`.
- [ ] Корректного `load` command (mmc/ubi/nand) с правильными partition
      indices.
- [ ] Verified booti/bootz/bootm для данной arch + kernel format.
- [ ] Тестирования минимум 10 циклов reboot + 5 циклов rauc install с
      forced healthcheck failure → rollback.

Tablet CI target появляется только после прохождения test-plan'а на
реальной плате. До этого `.github/workflows/build-rauc-bundle.yml` не
содержит uboot в matrix (сейчас только `pc-efi`).

## Test plan (шаблон для board bring-up)

1. Прошить installer на панель через vendor-specific процедуру.
2. Проверить что `rauc status` работает, booted slot идентифицирован.
3. `fw_printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT` — корректные значения.
4. `rauc mark-good booted` → `fw_printenv BOOT_<slot>_LEFT` = 3.
5. `rauc install <bundle N+1>` → `fw_printenv BOOT_ORDER` должен
   измениться на `<new_slot> <old_slot>`.
6. Reboot → загрузка в новый slot, healthcheck проходит, mark-good.
7. Собрать bundle N+2 с injected failure → reboot → boot_attempts
   декрементируется до 0 → rollback на prev slot.
8. Тест прерывания питания во время `rauc install` → панель должна
   загружаться в прежний slot (не в half-written новый).

Пока test plan не пройден — в production tablet target не выпускается.

## Ссылки

- Spec: `docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md`,
  раздел «Tablet U-Boot `system.conf`».
- Template boot script: `scripts/profiles/{ubuntu,debian}/rauc/boot/uboot/boot.cmd.template`.
- RAUC upstream U-Boot integration: https://rauc.readthedocs.io/en/latest/integration.html#u-boot
