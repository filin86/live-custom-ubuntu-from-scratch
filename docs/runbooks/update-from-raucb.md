# Инструкция: ручное обновление системы из `.raucb`

Применимость: панель уже установлена как неизменяемая RAUC-система, а
инженеру передали только файл `*.raucb`.

Для старой изменяемой ISO-системы этот способ не подходит. Сначала нужна
миграция через заводской установщик.

## Что нужно

- Один файл `*.raucb`.
- Доступ к панели по SSH или локальный терминал.
- Права root или sudo.
- Достаточно свободного места в `/tmp` или `/home/inauto` под RAUC-пакет.

## 1. Передать RAUC-пакет на панель

С инженерного ноутбука:

```bash
scp inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb \
    ubuntu@<ip_панели>:/tmp/
```

Если рядом дали контрольную сумму:

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

Если рядом дали `.sha256`:

```bash
cd /tmp
sha256sum -c inauto-panel-ubuntu-amd64-pc-efi-<VERSION>.raucb.sha256
```

## 4. Остановить автообновления

```bash
systemctl stop panel-check-updates.timer panel-check-updates.service || true
```

Это защищает от параллельного `rauc install` со стороны агента обновлений.

## 5. Установить RAUC-пакет

```bash
systemctl start rauc.service
rauc install "$BUNDLE"
sync
systemctl reboot
```

`rauc install` пишет только в неактивный слот. Текущий загруженный слот не
перезаписывается и остаётся точкой отката.

## 6. Проверить после перезагрузки

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

## 7. Если новая версия не загрузилась или проверка упала

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
