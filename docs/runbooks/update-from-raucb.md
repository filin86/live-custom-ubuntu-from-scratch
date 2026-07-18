# Инструкция: обновление системы из `.raucb`

Применимость: панель уже установлена как неизменяемая RAUC-система, а
инженеру передали только файл `*.raucb`.

Для старой изменяемой ISO-системы этот способ не подходит. Сначала нужна
миграция через заводской установщик.

## Что нужно

- Один файл `*.raucb`.
- Доступ к панели по SSH или локальный терминал.
- Права root или sudo.
- Достаточно свободного места в `/tmp` или `/home/inauto` под RAUC-пакет.

## Быстрый способ: скрипт `panel-update`

В образ включён `/usr/local/bin/panel-update`, который автоматизирует всю
процедуру ниже: проверку контрольной суммы, диагностику текущей системы,
остановку автообновлений, вывод сводки «текущая → новая», запрос
подтверждения, `rauc install` и перезагрузку.

1. Передайте на панель `*.raucb` (и рядом лежащий `*.raucb.sha256`) — см. шаг 1.
2. Запустите:

   ```bash
   sudo panel-update /tmp/inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb
   ```

   Без аргумента скрипт сам найдёт единственный `*.raucb` в `/tmp`,
   `/home/inauto`, `/home/inauto/update` или `/media/*`.

3. Проверьте выведенную сводку и подтвердите установку (`y`). После `rauc install`
   панель перезагрузится в новый слот; текущий останется точкой отката.
4. После возврата панели выполните проверку из шага 7.

Скрипт останавливает `panel-check-updates.timer` на время установки и возвращает
его при отмене или ошибке. Если контрольная сумма не совпала, `rauc info` не смог
прочитать пакет или `rauc install` упал — установка прерывается, система не
трогается.

Пошаговая ручная процедура ниже нужна, только если `panel-update` в образе нет
или требуется ручной контроль над каждым шагом (отладка).

## Миграция со старой EFI-схемы (v1) на GRUB-схему (v2) — без инсталлятора

Прошивка панелей перезаписывает UEFI `BootOrder` на каждом POST, поэтому в
v2-схеме выбор слота выполняет единый GRUB на `efi_A` по `grubenv`
(см. `docs/2026-07-04-grub-boot-selection-design.md`). Панель на старой схеме
(`bootloader=efi` в `/etc/rauc/system.conf`) мигрирует по SSH, заводской
инсталлятор НЕ нужен:

1. Передайте на панель в `/tmp` релизные артефакты и новый скрипт:

   ```bash
   scp inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb{,.sha256} \
       boot.vfat{,.sha256} panel-update.sh ubuntu@<ip_панели>:/tmp/
   ```

2. Запустите новый скрипт (старый `/usr/local/bin/panel-update` образа v1
   миграцию не умеет):

   ```bash
   sudo bash /tmp/panel-update.sh /tmp/inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb
   ```

   Скрипт сам распознаёт старую схему + v2-bundle и выполняет миграцию:
   проверка sha256 → `rauc mount` (проверка подписи) → запись rootfs в
   неактивный слот → запись загрузчика в оба ESP (сначала неактивный) →
   `grubenv` на новый слот → удаление устаревших NVRAM-записей → перезагрузка.

3. После перезагрузки выполните проверку из шага 7: версия новая,
   `rauc-mark-boot-good.service` прошёл, в `/etc/rauc/system.conf` —
   `bootloader=grub`.

**ВНИМАНИЕ:** до установки СЛЕДУЮЩЕГО v2-обновления старый слот незагружаем
(в нём нет `/boot/grub-slot.cfg`) — отката на старую версию после миграции
нет. Не выключайте питание панели во время миграции.

Порядок записи ESP минимизирует риск: сначала неактивный, затем активный;
скрипт валидирует записанный загрузчик до перезагрузки. Остаточный риск —
потеря питания ровно во время записи АКТИВНОГО ESP: расчёт на то, что
прошивка возьмёт `\EFI\BOOT\BOOTX64.EFI` со второго ESP (она стабильно
создаёт записи для обоих). Этот фолбэк на реальном железе отдельно не
проверялся; восстановление на такой случай — заводской установщик с USB
(`docs/runbooks/factory-provisioning.md`).

## 1. Передать RAUC-пакет на панель

С инженерного ноутбука:

```bash
scp inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb \
    ubuntu@<ip_панели>:/tmp/
```

Контрольная сумма `*.raucb.sha256` генерируется рядом с bundle автоматически
(при сборке в `build-bundle.sh`). Передайте её вместе с пакетом:

```bash
scp inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb.sha256 \
    ubuntu@<ip_панели>:/tmp/
```

Дальше в примерах используется переменная `BUNDLE`:

```bash
sudo -i
cd /tmp
BUNDLE="/tmp/inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb"
```

Если есть только USB-носитель, можно оставить путь вида
`/media/ubuntu/<usb>/inauto-panel-...raucb` и записать его в `BUNDLE`.

## 2. Проверить текущую систему

На панели:

```bash
cat /etc/inauto/firmware-version
cat /proc/cmdline | grep -o 'rauc.slot=[^ ]*'
rauc status
systemctl status rauc-mark-boot-good.service --no-pager
```

Перед установкой текущая система должна быть рабочей точкой отката. Если
текущий слот ещё не `good`, сначала разобраться с проверкой работоспособности.

## 3. Проверить RAUC-пакет

```bash
rauc info "$BUNDLE"
```

Проверить:

- `Compatible` совпадает с панелью, например
  `inauto-panel-ubuntu-amd64-pc-efi-v1`;
- версия та, которую нужно поставить;
- подпись принимается локальной доверенной связкой ключей RAUC.

Проверьте контрольную сумму (файл `.sha256` идёт в комплекте с bundle):

```bash
cd /tmp
sha256sum -c inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb.sha256
```

## 4. Остановить автообновления

```bash
systemctl stop panel-check-updates.timer panel-check-updates.service || true
```

Это защищает от параллельного `rauc install` со стороны агента обновлений.

## 5. Проверить grubenv

С v2-схемы выбор слота выполняет GRUB на `efi_A`, UEFI-записи для слотов не
используются (прошивка панелей переписывает BootOrder на каждом POST —
см. `docs/2026-07-04-grub-boot-selection-design.md`). Перед установкой
убедитесь, что раздел загрузчика смонтирован и grubenv читается:

```bash
systemctl status run-inauto-bootenv.mount --no-pager
grub-editenv /run/inauto/bootenv/grubenv list
```

Ожидаемо: `ORDER="system0 system1"` (или наоборот), у загруженного слота
`_OK=1` и `_TRY=0`. Если mount неактивен:

```bash
systemctl start run-inauto-bootenv.mount
```

## 6. Установить RAUC-пакет

```bash
systemctl start rauc.service
rauc install "$BUNDLE"
sync
systemctl reboot
```

`rauc install` пишет только в неактивный слот. Текущий загруженный слот не
перезаписывается и остаётся точкой отката.

## 7. Проверить после перезагрузки

После возврата панели:

```bash
sudo -i

cat /etc/inauto/firmware-version
cat /proc/cmdline | grep -o 'rauc.slot=[^ ]*'
rauc status
systemctl status rauc-mark-boot-good.service --no-pager
journalctl -u rauc-mark-boot-good.service -b --no-pager
```

Ожидаемо:

- версия = `<VERSION>` из RAUC-пакета;
- загруженный слот сменился на противоположный;
- `rauc-mark-boot-good.service` завершился успешно;
- `rauc status` показывает новый слот как `booted`/`good`.

Вернуть таймер автообновлений:

```bash
systemctl start panel-check-updates.timer
```

## 8. Если новая версия не загрузилась или проверка упала

Если новый слот не дошёл до `rauc status mark-good booted`, следующая
перезагрузка должна вернуть панель на предыдущий исправный слот:

```bash
systemctl reboot
```

После отката проверить:

```bash
cat /etc/inauto/firmware-version
rauc status
journalctl -b -1 -u rauc-mark-boot-good.service --no-pager
```

Если панель загрузилась в новую версию, но прикладная регрессия обнаружена уже
после `mark-good`, использовать ручное переключение слота из
`docs/runbooks/rollback.md`.

## Чего делать нельзя

- Не распаковывать `.raucb` руками и не писать `rootfs.img` через `dd`.
- Не запускать два `rauc install` параллельно.
- Не выключать питание во время `rauc install`.
- Не очищать persist-раздел для "чистого обновления" — там ключи SSH,
  NetworkManager и `/etc/inauto/*`.
