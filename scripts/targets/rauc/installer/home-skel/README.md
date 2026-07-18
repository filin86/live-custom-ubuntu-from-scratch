# home-skel — дефолтное наполнение /home/inauto

Всё, что лежит в этом каталоге (кроме самого `README.md` и файлов-маркеров
`.gitkeep`), при **первой установке** панели заводским инсталлятором
раскатывается в раздел `inauto-data`, который монтируется в `/home/inauto`.

## Как это работает

1. `build-installer-image.sh` упаковывает содержимое `home-skel/` в payload
   инсталлятора (`inauto-installer/home-skel/`), вырезая `README.md` и
   `.gitkeep` — на панель они не попадают.
2. `install-to-disk.sh` при установке засевает эти файлы в свежий раздел
   `inauto-data` **после** создания скелета каталогов, но **до** восстановления
   backup'а старого `/home/inauto`.

## Приоритеты

- **Чистая установка** (фабрично-новая панель): в `/home/inauto` оказываются
  файлы из `home-skel/`.
- **Миграция** (инсталлятор нашёл и восстанавливает старый `/home/inauto`):
  восстановленные пользовательские файлы **перетирают** дефолты — данные
  пользователя всегда побеждают.

## Важно

- **Исполняемый бит.** Файлы копируются с сохранением прав (`cp -a`), а tar/zstd
  их не теряет. Скрипт в `on_start/oneshot/`, `on_start/forking/`,
  `on_start/before_login/` или `on_login/` запустится, только если он закоммичен
  **исполняемым** (`chmod +x` + `git update-index --chmod=+x`).
- **Только при первой установке.** Засев происходит один раз — при заводской
  установке. Последующие RAUC-обновления firmware эти файлы не трогают и не
  переприменяют. Изменение дефолтов в новой прошивке не «долетит» до уже
  установленных панелей.
- **Владелец.** Файлы кладутся как `root:root` (инсталлятор работает от root,
  как и создание скелета). Site-хуки `on_start/*` исполняются systemd от root.

## Куда что класть

Структура повторяет `/home/inauto` (см. скелет в `install-to-disk.sh`):

| Путь                       | Назначение                                        |
|----------------------------|---------------------------------------------------|
| `on_start/before_login/`   | скрипты до логина (systemd, до сети и LightDM)     |
| `on_start/network_pre/`    | до старта NetworkManager (hostname, netplan, fs)  |
| `on_start/oneshot/`        | one-shot скрипты при старте (после подъёма сети)   |
| `on_start/forking/`        | долгоживущие (forking) скрипты при старте          |
| `on_login/`                | скрипты при логине оператора                        |
| `staff/`                   | служебные файлы панели                              |
| `config/`                  | site-конфиги (например, `config/healthcheck.sh`)   |

Пустые каталоги-заглушки помечены `.gitkeep`, чтобы структура жила в git;
на панель `.gitkeep` не копируется.

## Per-site параметры в `staff/`

Значения, свои для каждой площадки, вынесены в файлы `staff/` (одно значение —
одна строка), скрипты `on_start/` их читают:

| Файл              | Что задаёт                          | Читает                       |
|-------------------|-------------------------------------|------------------------------|
| `staff/hostname`  | имя панели                          | `network_pre/50-sethostname.sh` |
| `staff/timezone`  | часовой пояс (напр. `Europe/Moscow`)| `oneshot/005-time.sh`        |
| `staff/ntp-server`| адрес(а) NTP-сервера                | `oneshot/005-time.sh`        |

`staff/timezone` содержит одно имя зоны из `/usr/share/zoneinfo` (по умолчанию
`Europe/Moscow`); некорректное/пустое значение скрипт игнорирует, не роняя boot.

`staff/ntp-server` содержит адрес NTP-сервера (первая строка; несколько серверов —
через пробел). Из него `005-time.sh` генерирует `/etc/systemd/timesyncd.conf`
(`NTP=…` + `FallbackNTP=ntp.ubuntu.com pool.ntp.org`); при пустом/отсутствующем
файле остаётся дефолтный конфиг. Зона и NTP выставляются **без `timedatectl`**
(на immutable-панели он даёт `Access denied` через timedated/polkit): зона —
прямым symlink'ом `/etc/localtime`, служба — `systemctl … systemd-timesyncd`.

Примеры имён зон:

| Город              | Значение `staff/timezone` | Смещение |
|--------------------|---------------------------|----------|
| Санкт-Петербург    | `Europe/Moscow`           | UTC+3    |
| Тула               | `Europe/Moscow`           | UTC+3    |
| Екатеринбург       | `Asia/Yekaterinburg`      | UTC+5    |
| Новосибирск        | `Asia/Novosibirsk`        | UTC+7    |
| Кемерово           | `Asia/Novokuznetsk`       | UTC+7    |
| Красноярск         | `Asia/Krasnoyarsk`        | UTC+7    |
| Владивосток        | `Asia/Vladivostok`        | UTC+10   |
| Камчатка           | `Asia/Kamchatka`          | UTC+12   |

Санкт-Петербург и Тула отдельной зоны не имеют — используют московскую
(`Europe/Moscow`). У Кемерова IANA-зона называется по Новокузнецку
(`Asia/Novokuznetsk`).

## Сетевая папка Windows (SMB/CIFS)

Приложению нужна расшаренная папка Windows как локальный путь — реализовано
через **systemd-automount** (монтирование по первому обращению; переживает
выключенный в момент загрузки ПК и сетевые сбои).

Компоненты:

- пакет `cifs-utils` — уже в образе (`config.sh`);
- `on_start/oneshot/020-mount-winshare.sh` — генерит systemd-automount из конфига;
- `staff/winshare/winshare.conf.example` — шаблон параметров шары;
- `staff/winshare/credentials.example` — шаблон логина/пароля.

**Активация на площадке** (в `/home/inauto/staff/winshare/`):

```bash
cp winshare.conf.example winshare.conf     # заполнить SERVER/SHARE/MOUNTPOINT
cp credentials.example  credentials        # логин/пароль (если не GUEST=1)
chmod 600 credentials
reboot                                     # или: systemctl start <mnt>.automount
```

Пока `winshare.conf` нет (только `.example`) — монтирование не активируется, это
штатное состояние. Файлы `*.example` на панель попадают, но эффекта не дают.
Приложение должно писать в `MOUNTPOINT` (по умолчанию `/mnt/winshare`); файлы
создаются от пользователя `ubuntu` (`uid/gid=1000`).