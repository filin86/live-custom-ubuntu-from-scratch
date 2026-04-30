# Инструкция: установка системы из `.tar.zst`-архива установщика

Применимость: есть файл
`inauto-panel-installer-<distro>-<arch>-pc-efi-<version>.tar.zst`, но нет
готового загрузочного ISO-образа установщика.

Важно: `.tar.zst` — это архив установщика для заводской установки. Он
запускается из загрузочной флешки Ubuntu/Debian, полностью переразмечает
целевой диск и ставит систему заново. Это не `rauc install` поверх текущей
системы. Для рабочей панели обязательно сохраните `/home/inauto`.

## Что нужно

- Загрузочная флешка Ubuntu/Debian, запущенная в режиме UEFI.
- Файл `inauto-panel-installer-*.tar.zst`.
- Файл `inauto-panel-installer-*.tar.zst.sha256`, если передали.
- Отдельная USB-флешка или сетевое хранилище для резервной копии
  `/home/inauto`, если панель уже была в эксплуатации.
- Имя панели, канал обновлений (`stable` или `candidate`) и URL сервера
  обновлений.

## 1. Загрузиться с флешки Ubuntu/Debian

1. Вставить загрузочную флешку Ubuntu/Debian.
2. В меню загрузки UEFI выбрать USB-запись с пометкой `UEFI`.
3. Дождаться рабочего стола временной системы.
4. Подключить носитель, на котором лежит `inauto-panel-installer-*.tar.zst`.

Проверить, что система действительно загружена в UEFI:

```bash
test -d /sys/firmware/efi && echo UEFI
```

Если вывода `UEFI` нет, перезагрузитесь и выберите USB-запись с пометкой
`UEFI`.

## 2. Проверить архив установщика

Перейти в каталог с архивом установщика:

```bash
cd /media/ubuntu/<usb-or-disk>
ls -lh inauto-panel-installer-*.tar.zst*
```

Если рядом есть `.sha256`:

```bash
sha256sum -c inauto-panel-installer-*.tar.zst.sha256
```

## 3. Распаковать архив установщика

```bash
sudo mkdir -p /opt
sudo tar -I zstd -xf inauto-panel-installer-*.tar.zst -C /opt
ls -l /opt/inauto-installer/
```

Ожидаемо внутри есть:

- `START-INSTALLER.sh`;
- `install-gui.sh`;
- `install-to-disk.sh`;
- `bundle.raucb`;
- `keyring.pem`;
- `backup-restore-home.sh`.

## 4. Запустить GUI-мастер

```bash
sudo /opt/inauto-installer/START-INSTALLER.sh
```

Мастер выполнит те же шаги, что ISO-инсталлятор:

1. Проверит режим UEFI и недостающие инструменты.
2. Покажет внутренние диски `>= 32 GiB`.
3. Спросит имя панели.
4. Спросит канал обновлений (`stable` или `candidate`).
5. Спросит сервер обновлений.
6. Предложит сохранить старый `/home/inauto`.
7. Попросит ввести `ERASE` перед стиранием диска.
8. Запишет образ системы и предложит перезагрузку.

Подробная операторская инструкция по окнам мастера:
`docs/runbooks/operator-iso-installer.md`.

## 5. Резервная копия `/home/inauto`

Для панели, которая уже работала в эксплуатации, в мастере выберите сохранение
резервной копии.

Рекомендуемый вариант:

- подключить отдельную USB-флешку;
- создать на ней папку `inauto-backup`;
- выбрать эту папку в мастере.

Не выбирайте саму загрузочную флешку или каталог с архивом установщика как
место для резервной копии, если они смонтированы только для чтения.

По умолчанию мастер предлагает `/tmp/inauto-backup`. Это временная папка в
памяти: подходит только для небольшого `/home/inauto` и исчезнет после
перезагрузки.

## 6. Если графический мастер недоступен

Можно запустить установщик напрямую. Пример:

```bash
sudo TARGET_DEVICE=/dev/sda \
    PANEL_HOSTNAME=panel-warehouse-01 \
    UPDATE_CHANNEL=stable \
    UPDATE_SERVER=http://172.16.88.80:9001 \
    BACKUP_DIR=/media/ubuntu/BACKUP/inauto-backup \
    /opt/inauto-installer/install-to-disk.sh
```

Скрипт покажет выбранный диск и продолжит только после ввода `yes`.

Для новой или тестовой панели без резервной копии:

```bash
sudo TARGET_DEVICE=/dev/sda \
    PANEL_HOSTNAME=test-panel-01 \
    UPDATE_CHANNEL=candidate \
    UPDATE_SERVER=http://172.16.88.80:9001 \
    SKIP_BACKUP=1 \
    /opt/inauto-installer/install-to-disk.sh
```

## 7. Первая загрузка после установки

После успешной установки:

1. Согласиться на перезагрузку.
2. Вытащить загрузочную флешку Ubuntu/Debian.
3. Вытащить носитель с архивом установщика, если он больше не нужен.
4. Оставить флешку с резервной копией подключённой только если нужно забрать
   архив позже.

Панель должна загрузиться с внутреннего диска.

## 8. Проверка после загрузки

На панели:

```bash
sudo -i

cat /etc/inauto/firmware-version
cat /home/inauto/staff/hostname
cat /etc/inauto/{channel,update-server,serial.txt}
rauc status
systemctl status rauc-mark-boot-good.service --no-pager
docker info >/dev/null && echo "docker ok"
```

Ожидаемо:

- версия соответствует архиву установщика;
- имя панели, канал обновлений и сервер обновлений совпадают с введёнными;
- `rauc status` показывает загруженный слот `system0`;
- `rauc-mark-boot-good.service` завершился успешно;
- если была резервная копия, данные восстановлены в `/home/inauto`.

Отправить отметку о связи вручную, не дожидаясь таймера:

```bash
systemctl restart panel-check-updates.timer
systemctl start panel-check-updates.service
```

## Чего делать нельзя

- Не запускать `.tar.zst` на уже работающей панели без загрузочной флешки:
  это архив установщика, а не пакет обновления.
- Не продолжать установку рабочей панели без резервной копии `/home/inauto`.
- Не выбирать внешний USB как целевой диск.
- Не выключать питание во время записи.
