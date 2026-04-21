# Runbook: watchdog и BootNext rollback

Дата: 2026-04-20
Применимость: `TARGET_FORMAT=rauc`, `TARGET_PLATFORM=pc-efi`.

## Почему это вообще нужно

RAUC EFI backend использует `BootNext` как «probation»:

1. `rauc install <bundle>` → прописывает `BootNext=<inactive_slot>`.
2. Следующий boot пытается загрузить inactive slot.
3. Если в inactive slot'е `rauc status mark-good booted` не вызвался —
   UEFI спецификация говорит, что `BootNext` одноразовый и затирается при
   следующем boot, значит firmware вернётся на `BootOrder`.
4. Следовательно прежний slot будет активен после второго reboot'а.

**Это работает только если панель реально перезагружается.** Если новый
kernel зависает в ранней фазе (panic до init, dead-lock в driver'е,
замёрзший X сервер без нашего healthcheck'а) — BootNext остаётся съеденным
UEFI, но system так и висит. `rauc mark-good` не вызовется никогда, но и
rollback тоже: панель просто мёртвая до ручной перезагрузки.

Поэтому rollout новых firmware требует **отдельной политики watchdog'а**.

## Что включено в MVP

### 1. Kernel panic → автоматический reboot

`scripts/profiles/<distro>/rauc/system-efi.conf.template` содержит в
`efi-cmdline` параметр `panic=30`:

```
panic=30
```

Это kernel cmdline, приказывающее ядру перезагрузиться через 30 секунд
после panic. Т.е. если новый kernel падает kernel-panic'ом — мы автоматом
получаем второй reboot, BootNext потрачен, и firmware вернёт BootOrder.

### 2. Systemd userspace watchdog

`configure_rauc_target` устанавливает `/etc/systemd/system.conf.d/10-inauto-watchdog.conf`:

```ini
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=5min
KExecWatchdogSec=10min
```

`RuntimeWatchdogSec=60s` означает: если в системе есть `/dev/watchdog`
(hardware watchdog от чипсета или виртуальный от QEMU i6300esb), systemd
пингует его каждые 30 секунд. Если systemd сам висит или kernel'ный
scheduler его не будит — watchdog-hardware перезагружает панель.

`RebootWatchdogSec=5min` задаёт, сколько systemd ждёт корректный shutdown
до принудительного reboot'а.

### 3. Healthcheck + mark-good

См. `rauc-mark-boot-good.service` — `panel-healthcheck.sh` проверяет
lightdm/docker/containerd/x11vnc/ssh + mountpoints + `docker info` с
retry-loop + опциональный `/home/inauto/config/healthcheck.sh`. Ошибка
healthcheck'а блокирует `rauc mark-good booted`, что в паре с BootNext
даёт rollback.

## Что НЕ покрыто MVP

- **Bootloader hang до kernel start.** Если UEFI не смог загрузить `system1`
  из-за повреждённого `efi.vfat`, но и не упал сразу — панель висит в UEFI.
  Здесь спасает только вторая прошивка или сервисный выезд.
- **Hardware без /dev/watchdog.** Если на конкретной материнке нет
  поддерживаемого watchdog-устройства, systemd молча игнорирует
  `RuntimeWatchdogSec`. Перед production-rollout'ом проверяйте
  `journalctl -b | grep -i watchdog` — systemd должен отчитаться о
  `Using hardware watchdog`.
- **Hang в kernel scheduler без panic.** `panic=30` работает только если
  kernel осознаёт, что произошла panic. Soft-lockup без panic — в идеале
  ловится hardware watchdog'ом, но это зависит от железа и модулей.

## Как проверить watchdog в QEMU

Q35 machine поддерживает `-watchdog i6300esb`:

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -m 4G \
    -cpu host \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/tmp/panel-OVMF_VARS.fd \
    -drive file=/tmp/panel.qcow2,if=virtio,format=qcow2 \
    -watchdog i6300esb -watchdog-action reset \
    -net nic -net user -net user,hostfwd=tcp::2222-:22 \
    -vga virtio -display gtk
```

Проверки внутри панели:

```bash
journalctl -b --no-pager | grep -i 'watchdog' | head -20
# Ожидаем "Using hardware watchdog 'iTCO_wdt' at ..." или i6300esb,
# и "systemd[1]: Watchdog running with a hardware timeout of 1min."

ls -l /dev/watchdog*   # должен быть /dev/watchdog и /dev/watchdog0
```

## Forced hang / panic gate

Перед тем как отдать сборку в candidate-channel на реальные панели,
нужно сделать хотя бы один прогон forced-hang в QEMU:

### Kernel panic

Спровоцировать panic:

```bash
echo c > /proc/sysrq-trigger
# Kernel крашится, panic=30 -> reboot через 30 секунд.
```

Ожидаемо: панель перезагружается, через ~30s появляется UEFI-boot,
следующий boot выбран по BootOrder (если BootNext был потрачен до краша).

### Userspace hang

Имитировать зависание init (опасно в production, только в QEMU):

```bash
# Как root — блокируем сигналы и уходим в бесконечный цикл.
# Systemd перестанет пинговать watchdog, hardware watchdog перезагрузит.
systemd-run --scope --property=Delegate=yes bash -c 'trap "" TERM; while :; do :; done'
```

Ожидаемо: через ~1–2 минуты hardware watchdog вызывает reset.

### Record-сценарий для gate'а

Сохранить в отчёт:

- `journalctl -b | grep -i watchdog` (до и после теста);
- `dmesg | tail -50` (после reboot из panic);
- `rauc status` до/после (slot rollback ожидается если mark-good не успел).

## Как отключить (для отладки)

**Не отключать в production.** Для dev-сборки:

```bash
# В панели:
mkdir -p /etc/systemd/system.conf.d
echo -e "[Manager]\nRuntimeWatchdogSec=off" > /etc/systemd/system.conf.d/99-disable-watchdog.conf
systemctl daemon-reexec
```

Kernel panic=30 снимается только через новый bundle с изменённым
`efi-cmdline` в `system.conf.template`. Namenlich прикладывать runtime
override нельзя — kernel cmdline читается UEFI при загрузке.

## Ссылки

- Spec: `docs/superpowers/specs/2026-04-20-immutable-panel-firmware-design.md` раздел "Boot watchdog".
- QEMU тест: `docs/runbooks/qemu-pc-efi-test.md` шаг 5.5.
- Healthcheck и mark-good: `scripts/profiles/<distro>/rauc/scripts/panel-healthcheck.sh`,
  `scripts/profiles/<distro>/rauc/systemd-units/rauc-mark-boot-good.service`.
