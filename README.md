[![GitHub stars](https://img.shields.io/github/stars/mvallim/live-custom-ubuntu-from-scratch?style=social)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/mvallim/live-custom-ubuntu-from-scratch?style=social)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/network/members)
[![GitHub watchers](https://img.shields.io/github/watchers/mvallim/live-custom-ubuntu-from-scratch?style=social)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/watchers)

# Как создать собственный Ubuntu Live-образ с нуля

[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/graphs/commit-activity)
[![Project Status](https://img.shields.io/badge/status-active-success.svg)](https://github.com/mvallim/live-custom-ubuntu-from-scratch)
[![GitHub last commit](https://img.shields.io/github/last-commit/mvallim/live-custom-ubuntu-from-scratch)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/commits/master)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

[![Ubuntu 18.04 Bionic](https://img.shields.io/badge/Ubuntu-18.04%20Bionic-E95420?logo=ubuntu&logoColor=white)](https://releases.ubuntu.com/18.04/)
[![Ubuntu 20.04 Focal](https://img.shields.io/badge/Ubuntu-20.04%20Focal-E95420?logo=ubuntu&logoColor=white)](https://releases.ubuntu.com/20.04/)
[![Ubuntu 22.04 Jammy](https://img.shields.io/badge/Ubuntu-22.04%20Jammy-E95420?logo=ubuntu&logoColor=white)](https://releases.ubuntu.com/22.04/)
[![Ubuntu 24.04 Noble](https://img.shields.io/badge/Ubuntu-24.04%20Noble-E95420?logo=ubuntu&logoColor=white)](https://releases.ubuntu.com/24.04/)

[![GitHub issues](https://img.shields.io/github/issues/mvallim/live-custom-ubuntu-from-scratch)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/issues)
[![GitHub pull requests](https://img.shields.io/github/issues-pr/mvallim/live-custom-ubuntu-from-scratch)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/pulls)
[![Contributors](https://img.shields.io/github/contributors/mvallim/live-custom-ubuntu-from-scratch)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/graphs/contributors)
[![GitHub release](https://img.shields.io/github/release/mvallim/live-custom-ubuntu-from-scratch)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/releases)

<p align="center">
   <img src="images/live-boot.png">
</p>

Этот проект показывает, как собрать полностью кастомизированную версию Ubuntu Linux с нуля. Он охватывает создание live ISO-образа с заранее установленными пакетами, конфигурациями и пользовательскими скриптами под ваши задачи. Шаги проводят вас через подготовку окружения, настройку `chroot`, установку ПО, изменение ядра и финальную генерацию ISO. Такой подход подходит тем, кому нужен полный контроль над собственной сборкой Linux как для личного, так и для профессионального использования.

## Требования

* Уверенное владение shell-командами и скриптами Linux.
* Достаточный объем диска и памяти для сборки ISO.

## Общая схема
1. **Подготовить окружение**: установить необходимые зависимости.
2. **Создать базовую систему**: использовать `debootstrap` для минимальной Ubuntu.
3. **Настроить пакеты**: добавить или удалить ПО, настроить ядро.
4. **Сгенерировать ISO**: упаковать систему в загрузочный образ.

## Авторы

* **Marcos Vallim** - *Основатель, автор, разработка, тестирование, документация* - [mvallim](https://github.com/mvallim)
* **Ken Gilmer** -  *Коммитер, разработка, тестирование, документация* - [kgilmer](https://github.com/kgilmer)

Список всех участников проекта доступен в файле [CONTRIBUTORS.txt](CONTRIBUTORS.txt).

## Как использовать этот туториал

* (Рекомендуется) пройти шаги ниже по порядку, чтобы понять процесс сборки Ubuntu ISO.
* Запустить `./scripts/build-in-docker.sh -`, чтобы собирать образ внутри Docker builder-окружения с меньшей зависимостью от хоста.
* Запустить скрипт `build.sh` в каталоге `scripts` после клонирования репозитория локально.
* Сделать fork репозитория и запустить GitHub Action `build`. Он сгенерирует ISO в вашем GitHub-аккаунте.

[![build-bionic](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-bionic.yml/badge.svg)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-bionic.yml)
[![build-focal](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-focal.yml/badge.svg)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-focal.yml)
[![build-jammy](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-jammy.yml/badge.svg)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-jammy.yml)
[![build-noble](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-noble.yml/badge.svg)](https://github.com/mvallim/live-custom-ubuntu-from-scratch/actions/workflows/build-noble.yml)

## Сборка в контейнере (рекомендуется для переносимой сборки)

В репозитории есть Docker wrapper `./scripts/build-in-docker.sh`. Он упаковывает зависимости хостовой части, запускает существующий pipeline `build.sh` внутри привилегированного контейнера и хранит тяжелый кэш `chroot` в именованном Docker volume вместо обычной файловой системы хоста.

Это предпочтительный путь, если вы хотите сделать сборку менее зависимой от версии ОС хоста или запускать ее из Docker Desktop / WSL2 / с arm64-хостов, где доступна эмуляция контейнеров `amd64`.

Требования:

* Docker с включенными Linux-контейнерами
* Возможность запускать привилегированные контейнеры (`docker run --privileged`)
* Достаточно дискового пространства под Docker volume, используемый для `scripts/chroot`

Запустить полный pipeline:

```shell
./scripts/build-in-docker.sh -
```

Запустить только часть этапов:

```shell
./scripts/build-in-docker.sh debootstrap - build_iso
```

Полезные переменные окружения:

* `BUILDER_PLATFORM` — по умолчанию `linux/amd64`. Сохраняйте это значение, чтобы собирать текущий `amd64` ISO с `x86_64`, `arm64` или Windows-хостов, если Docker поддерживает эмуляцию `amd64`.
* `DOCKER_USE_SUDO` — по умолчанию `auto`. Wrapper сначала пробует обычный доступ к Docker и при ошибке доступа к `docker.sock` автоматически переключается на `sudo docker`.
* `REBUILD_BUILDER=1` — принудительно пересобирает Docker builder-образ.
* `LIVECD_CHROOT_VOLUME` — переопределяет имя Docker volume, используемого для `scripts/chroot`.
* `TRIVY_CACHE_VOLUME` — переопределяет имя Docker volume, используемого для базы данных Trivy.

Артефакты, которые появляются после контейнерной сборки:

* `scripts/*.iso`
* `scripts/image/md5sum.txt`
* `scripts/reports/`

> [!IMPORTANT]
> Builder-окружение теперь переносимо между разными хост-платформами, но схема загрузки ISO в этом репозитории пока все еще жестко завязана на `amd64/x86_64`. Для полноценной сборки non-amd64 ISO понадобятся дополнительные изменения в загрузчиках и пакетах внутри build-скриптов.

### Сборка Debian-варианта

Проект поддерживает два дистрибутива: Ubuntu (по умолчанию) и Debian. Переключение — через `TARGET_DISTRO` в `scripts/config.sh` либо переменной окружения:

```shell
# Однократно
TARGET_DISTRO=debian ./scripts/build-in-docker.sh -

# Через config.sh
echo 'export TARGET_DISTRO="debian"' >> scripts/config.sh
./scripts/build-in-docker.sh -
```

Поддерживаемые релизы:

* **Ubuntu:** `noble` (24.04 LTS, по умолчанию), `questing` (25.10), `26.04` (после релиза 2026-04-23).
* **Debian:** `trixie` (13, по умолчанию), `forky` (14, testing), `sid` (unstable).

Под каждый дистрибутив собирается свой builder-образ (`livecd-builder-ubuntu:local` / `livecd-builder-debian:local`) и отдельный chroot-volume (`<repo>-chroot-<distro>`). Первая сборка под новый дистрибутив длиннее (пересборка builder-а + debootstrap с нуля).

## Термины

* `build system` - компьютерная среда, в которой запускаются скрипты сборки, генерирующие ISO.
* `live system` - среда, работающая из live ОС, созданной `build system`. Ее также можно называть `chroot environment`.
* `target system` - среда, в которой работает установленная система после завершения установки из `live system`.

## Предварительные требования для нативного режима на хосте (GNU/Linux Ubuntu)

Этот раздел относится к сценарию, когда вы запускаете `./scripts/build.sh` напрямую на хосте, а не используете `./scripts/build-in-docker.sh`.

> [!IMPORTANT]
> Очень важно помнить, что версия собираемой системы зависит от версии, установленной на хостовой машине.
>
> Пример:
> Если вы собираете версию `bionic` с нуля, то на хостовой машине должна быть установлена `bionic` или более новая версия.
>
> | Сборка   | Хост        |
> |:--------:|:-----------:|
> | `bionic` | `>= bionic` |
> | `focal`  | `>= focal`  |
> | `jammy`  | `>= jammy`  |
> | `noble`  | `>= noble`  |

Установите пакеты, которые нужны нашим скриптам в `build system`.

```shell
sudo apt-get install \
   debootstrap \
   squashfs-tools \
   xorriso
```

```shell
mkdir $HOME/live-ubuntu-from-scratch
```

## Bootstrap и настройка Ubuntu

`debootstrap` — это программа для генерации образов ОС. Мы устанавливаем ее в `build system`, чтобы начать создание ISO.

* Выполните bootstrap

  ```shell
  sudo debootstrap \
     --arch=amd64 \
     --variant=minbase \
     noble \
     $HOME/live-ubuntu-from-scratch/chroot \
     http://us.archive.ubuntu.com/ubuntu/
  ```
  
  > **debootstrap** используется для создания базовой Debian-системы с нуля, без необходимости иметь заранее установленный **dpkg** или **apt**. Он скачивает `.deb`-пакеты с зеркала и аккуратно распаковывает их в каталог, в который затем можно войти через **chroot**.

* Настройте внешние точки монтирования
  
  ```shell
  sudo mount --bind /dev $HOME/live-ubuntu-from-scratch/chroot/dev
  
  sudo mount --bind /run $HOME/live-ubuntu-from-scratch/chroot/run
  ```

  Поскольку дальше мы будем обновлять систему и устанавливать пакеты (в том числе `grub`), эти точки монтирования необходимы внутри `chroot`-окружения, чтобы установка завершалась без ошибок.

## Определение `chroot`-окружения

*В Unix-подобных операционных системах `chroot` — это операция, меняющая видимый корень файловой системы для текущего процесса и его потомков. Программа, запущенная в таком окружении, не может обращаться к файлам за пределами указанного дерева каталогов. Термин `chroot` может означать как системный вызов, так и обертку над ним. Модифицированная среда называется `chroot jail`.*

> Источник: <https://en.wikipedia.org/wiki/Chroot>

Начиная с этого момента, мы настраиваем `live system`.

1. **Войти в `chroot`-окружение**

   ```shell
   sudo chroot $HOME/live-ubuntu-from-scratch/chroot
   ```

2. **Настроить точки монтирования, домашний каталог и locale**

   ```shell
   mount none -t proc /proc

   mount none -t sysfs /sys

   mount none -t devpts /dev/pts

   export HOME=/root

   export LC_ALL=C
   ```

   Эти точки монтирования нужны внутри `chroot`-окружения, чтобы установка и настройка пакетов завершались без ошибок.

3. **Задать собственное имя хоста**

   ```shell
   echo "ubuntu-fs-live" > /etc/hostname
   ```

4. **Настроить `apt sources.list`**

   ```shell
   cat <<EOF > /etc/apt/sources.list
   deb http://us.archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse
   deb-src http://us.archive.ubuntu.com/ubuntu/ noble main restricted universe multiverse

   deb http://us.archive.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse
   deb-src http://us.archive.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse

   deb http://us.archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
   deb-src http://us.archive.ubuntu.com/ubuntu/ noble-updates main restricted universe multiverse
   EOF
   ```

5. **Обновить индексы пакетов**

   ```shell
   apt-get update
   ```

6. **Установить `systemd`**

   ```shell
   apt-get install -y libterm-readline-gnu-perl systemd-sysv
   ```

   > **systemd** — это системный и сервисный менеджер для Linux. Он обеспечивает агрессивную параллелизацию, использует socket- и D-Bus-активацию для запуска сервисов, умеет запускать демоны по требованию, отслеживает процессы через control groups, управляет точками монтирования и автомонтирования и реализует развитую транзакционную логику зависимостей.

7. **Настроить `machine-id` и diversion**

   ```shell
   dbus-uuidgen > /etc/machine-id

   ln -fs /etc/machine-id /var/lib/dbus/machine-id
   ```

   > Файл `/etc/machine-id` содержит уникальный идентификатор локальной системы, который задается во время установки или загрузки. Это одна строка из 32 шестнадцатеричных символов в нижнем регистре, соответствующая 16-байтовому/128-битному значению. Этот идентификатор не должен состоять из нулей.

   ```shell
   dpkg-divert --local --rename --add /sbin/initctl

   ln -s /bin/true /sbin/initctl
   ```

   > **dpkg-divert** — утилита, которая используется для создания и обновления списка diversion-правил.

8. **Обновить пакеты**

   ```shell
   apt-get -y upgrade
   ```

9. **Установить пакеты, необходимые для Live System**

   ```shell
   apt-get install -y \
      sudo \
      ubuntu-standard \
      casper \
      discover \
      laptop-detect \
      os-prober \
      network-manager \
      net-tools \
      wireless-tools \
      wpagui \
      locales \
      grub-common \
      grub-gfxpayload-lists \
      grub-pc \
      grub-pc-bin \
      grub2-common \
      grub-efi-amd64-signed \
      shim-signed \
      mtools \
      binutils
   ```

   ```shell
   apt-get install -y --no-install-recommends linux-generic
   ```

10. **Графический установщик**

    ```shell
    apt-get install -y \
       ubiquity \
       ubiquity-casper \
       ubiquity-frontend-gtk \
       ubiquity-slideshow-ubuntu \
       ubiquity-ubuntu-artwork
    ```

    Следующие шаги появятся автоматически как результат установки пакетов на предыдущем этапе — ничего дополнительно вводить или запускать не потребуется.

    1. Настройка клавиатуры

       <p align="center">
       <img src="images/keyboard-configure-01.png">
       </p>

       <p align="center">
       <img src="images/keyboard-configure-02.png">
       </p>

    2. Настройка консоли

       <p align="center">
       <img src="images/console-configure-01.png">
       </p>

11. **Установить оконное окружение**

    ```shell
    apt-get install -y \
       plymouth-themes \
       ubuntu-gnome-desktop \
       ubuntu-gnome-wallpapers
    ```

12. **Установить полезные приложения**

    ```shell
    apt-get install -y \
       clamav-daemon \
       terminator \
       apt-transport-https \
       curl \
       vim \
       nano \
       less
    ```

13. **Установить Visual Studio Code (необязательно)**

    1. Скачать и установить ключ

       ```shell
       curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg

       install -o root -g root -m 644 microsoft.gpg /etc/apt/trusted.gpg.d/

       echo "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list

       rm microsoft.gpg
       ```

    2. Затем обновить кэш пакетов и установить пакет

       ```shell
       apt-get update

       apt-get install -y code
       ```

14. **Установить Google Chrome (необязательно)**

    1. Скачать и установить ключ

       ```shell
       wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo apt-key add -

       echo "deb http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
       ```

    2. Затем обновить кэш пакетов и установить пакет

       ```shell
       apt-get update

       apt-get install google-chrome-stable
       ```

15. **Установить Java JDK 8 (необязательно)**

    ```shell
    apt-get install -y \
        openjdk-8-jdk \
        openjdk-8-jre
    ```

16. **Удалить ненужные приложения (необязательно)**

    ```shell
    apt-get purge -y \
       transmission-gtk \
       transmission-common \
       gnome-mahjongg \
       gnome-mines \
       gnome-sudoku \
       aisleriot \
       hitori
    ```

17. **Удалить неиспользуемые пакеты**

    ```shell
    apt-get autoremove -y
    ```

18. **Перенастроить пакеты**

    1. Сгенерировать locale

       ```shell
       dpkg-reconfigure locales
       ```

       1. *Выбрать locales*
          <p align="center">
          <img src="images/locales-select.png">
          </p>

       2. *Выбрать locale по умолчанию*
          <p align="center">
          <img src="images/locales-default.png">
          </p>

    2. Настроить `network-manager`

       1. Создать конфигурационный файл

          ```shell
          cat <<EOF > /etc/NetworkManager/NetworkManager.conf
          [main]
          rc-manager=none
          plugins=ifupdown,keyfile
          dns=systemd-resolved

          [ifupdown]
          managed=false
          EOF
          ```

       2. Перенастроить `network-manager`

          ```shell
          dpkg-reconfigure network-manager
          ```

## Создание каталога образа и наполнение его файлами

Теперь, после настройки `live system`, мы возвращаемся в наше `build environment` и продолжаем создавать файлы, необходимые для генерации ISO.

1. Создать каталоги

   ```shell
   mkdir -p /image/{casper,isolinux,install}
   ```

2. Скопировать образы ядра

   ```shell
   cp /boot/vmlinuz-**-**-generic /image/casper/vmlinuz

   cp /boot/initrd.img-**-**-generic /image/casper/initrd
   ```

3. Скопировать бинарник `memtest86+` (BIOS и UEFI)

   ```shell
    wget --progress=dot https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip -O /image/install/memtest86.zip
    unzip -p /image/install/memtest86.zip memtest64.bin > /image/install/memtest86+.bin
    unzip -p /image/install/memtest86.zip memtest64.efi > /image/install/memtest86+.efi
    rm -f /image/install/memtest86.zip
   ```

### Настройка меню GRUB

   1. Создать файл-маркер для поиска корня в grub

      ```shell
      touch /image/ubuntu
      ```

   2. Создать `image/isolinux/grub.cfg`

      ```shell
      cat <<EOF > /image/isolinux/grub.cfg

      search --set=root --file /ubuntu

      insmod all_video

      set default="0"
      set timeout=30

      menuentry "Try Ubuntu FS without installing" {
         linux /casper/vmlinuz boot=casper nopersistent toram quiet splash ---
         initrd /casper/initrd
      }

      menuentry "Install Ubuntu FS" {
         linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
         initrd /casper/initrd
      }

      menuentry "Check disc for defects" {
         linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
         initrd /casper/initrd
      }

      grub_platform
      if [ "\$grub_platform" = "efi" ]; then
      menuentry 'UEFI Firmware Settings' {
         fwsetup
      }

      menuentry "Test memory Memtest86+ (UEFI)" {
         linux /install/memtest86+.efi
      }
      else
      menuentry "Test memory Memtest86+ (BIOS)" {
         linux16 /install/memtest86+.bin
      }
      fi
      EOF
      ```

### Создание manifest

Далее мы создаем файл `filesystem.manifest`, в котором указывается каждый пакет и его версия, установленные в `live system`. Затем создается файл `filesystem.manifest-desktop`, определяющий, какие пакеты должны остаться в `target system`. После завершения работы установщика Ubiquity из системы будут удалены пакеты, перечисленные в `filesystem.manifest`, но отсутствующие в `filesystem.manifest-desktop`.

1. Сгенерировать manifest

   ```shell
   dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee /image/casper/filesystem.manifest

   cp -v /image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop

   sed -i '/ubiquity/d' /image/casper/filesystem.manifest-desktop

   sed -i '/casper/d' /image/casper/filesystem.manifest-desktop

   sed -i '/discover/d' /image/casper/filesystem.manifest-desktop

   sed -i '/laptop-detect/d' /image/casper/filesystem.manifest-desktop

   sed -i '/os-prober/d' /image/casper/filesystem.manifest-desktop
   ```

### Создание `README.diskdefines`

Файл **README**, часто встречающийся на установочных Linux LiveCD, например на установочном диске Ubuntu, обычно называется `README.diskdefines` и может использоваться во время установки.

1. Создать файл `/image/README.diskdefines`

   ```shell
   cat <<EOF > /image/README.diskdefines
   #define DISKNAME  Ubuntu from scratch
   #define TYPE  binary
   #define TYPEbinary  1
   #define ARCH  amd64
   #define ARCHamd64  1
   #define DISKNUM  1
   #define DISKNUM1  1
   #define TOTALNUM  0
   #define TOTALNUM0  1
   EOF
   ```

### Сборка файлов образа

1. Перейти в каталог образа

   ```shell
   cd /image
   ```

2. Скопировать EFI-загрузчики

   ```shell
   cp /usr/lib/shim/shimx64.efi.signed.previous isolinux/bootx64.efi
   cp /usr/lib/shim/mmx64.efi isolinux/mmx64.efi
   cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed isolinux/grubx64.efi
   ```

3. Создать FAT16 UEFI boot disk image с EFI-загрузчиками

   ```shell
   (
      cd isolinux && \
      dd if=/dev/zero of=efiboot.img bs=1M count=10 && \
      mkfs.vfat -F 16 efiboot.img && \
      LC_CTYPE=C mmd -i efiboot.img efi efi/ubuntu efi/boot && \
      LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/bootx64.efi && \
      LC_CTYPE=C mcopy -i efiboot.img ./mmx64.efi ::efi/boot/mmx64.efi && \
      LC_CTYPE=C mcopy -i efiboot.img ./grubx64.efi ::efi/boot/grubx64.efi && \
      LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg ::efi/ubuntu/grub.cfg
   )
   ```

4. Создать BIOS-образ `grub`

   ```shell
   grub-mkstandalone \
      --format=i386-pc \
      --output=isolinux/core.img \
      --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
      --modules="linux16 linux normal iso9660 biosdisk search" \
      --locales="" \
      --fonts="" \
      "boot/grub/grub.cfg=isolinux/grub.cfg"
   ```

5. Собрать загрузочный `Grub cdboot.img`

   ```shell
   cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img
   ```

6. Сгенерировать `md5sum.txt`

   ```shell
   /bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'isolinux' > md5sum.txt)"
   ```

### Очистка `chroot`-окружения

   1. Если вы устанавливали программное обеспечение, обязательно выполните

      ```shell
      truncate -s 0 /etc/machine-id
      ```

   2. Удалите diversion

      ```shell
      rm /sbin/initctl

      dpkg-divert --rename --remove /sbin/initctl
      ```

   3. Выполните очистку

      ```shell
      apt-get clean

      rm -rf /tmp/* ~/.bash_history

      umount /proc

      umount /sys

      umount /dev/pts

      export HISTSIZE=0

      exit
      ```

## Отвязать точки монтирования

```shell
sudo umount $HOME/live-ubuntu-from-scratch/chroot/dev

sudo umount $HOME/live-ubuntu-from-scratch/chroot/run
```

## Сжать `chroot`

После того как в **chrooted**-окружении все установлено и предварительно настроено, нужно сгенерировать образ результатов этих действий, выполняя следующие шаги уже в `build environment`.

1. Перейти в каталог сборки

   ```shell
   cd $HOME/live-ubuntu-from-scratch
   ```

2. Переместить артефакты образа

   ```shell
   sudo mv chroot/image .
   ```

3. Создать `squashfs`

   ```shell
   sudo mksquashfs chroot image/casper/filesystem.squashfs \
      -noappend -no-duplicates -no-recovery \
      -wildcards \
      -comp xz -b 1M -Xdict-size 100% \
      -e "var/cache/apt/archives/*" \
      -e "root/*" \
      -e "root/.*" \
      -e "tmp/*" \
      -e "tmp/.*" \
      -e "swapfile"
   ```

   > **Squashfs** — это сильно сжатая read-only файловая система для Linux. Она использует `zlib` для сжатия файлов, inode'ов и каталогов. Inode'ы в такой системе очень малы, а все блоки упаковываются так, чтобы минимизировать накладные расходы. Поддерживаются размеры блока больше 4K, вплоть до 64K.
   > **Squashfs** предназначена для общего использования в read-only системах, для архивирования (например, в случаях, где мог бы использоваться `.tar.gz`) и для ограниченных по памяти или блочным устройствам систем (например, **embedded systems**), где важны низкие накладные расходы.

4. Записать `filesystem.size`

   ```shell
   printf $(sudo du -sx --block-size=1 chroot | cut -f1) | sudo tee image/casper/filesystem.size
   ```

## Создание ISO-образа LiveCD (BIOS + UEFI + Secure Boot)

1. Перейти в каталог сборки

   ```shell
   cd $HOME/live-ubuntu-from-scratch/image
   ```

2. Создать ISO из каталога образа через командную строку

   ```shell
   sudo xorriso \
      -as mkisofs \
      -iso-level 3 \
      -full-iso9660-filenames \
      -J -J -joliet-long \
      -volid "Ubuntu from scratch" \
      -output "../ubuntu-from-scratch.iso" \
      -eltorito-boot isolinux/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog boot.catalog \
        --grub2-boot-info \
        --grub2-mbr ../chroot/usr/lib/grub/i386-pc/boot_hybrid.img \
        -partition_offset 16 \
        --mbr-force-bootable \
      -eltorito-alt-boot \
        -no-emul-boot \
        -e isolinux/efiboot.img \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b isolinux/efiboot.img \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -m "isolinux/efiboot.img" \
        -m "isolinux/bios.img" \
        -e '--interval:appended_partition_2:::' \
      -exclude isolinux \
      -graft-points \
         "/EFI/boot/bootx64.efi=isolinux/bootx64.efi" \
         "/EFI/boot/mmx64.efi=isolinux/mmx64.efi" \
         "/EFI/boot/grubx64.efi=isolinux/grubx64.efi" \
         "/EFI/ubuntu/grub.cfg=isolinux/grub.cfg" \
         "/isolinux/bios.img=isolinux/bios.img" \
         "/isolinux/efiboot.img=isolinux/efiboot.img" \
         "."
   ```

## Альтернативный способ: если предыдущий не сработал, создать Hybrid ISO

1. Создать загрузочное меню ISOLINUX (`syslinux`)

   ```shell
   cat <<EOF> isolinux/isolinux.cfg
   UI vesamenu.c32

   MENU TITLE Boot Menu
   DEFAULT linux
   TIMEOUT 600
   MENU RESOLUTION 640 480
   MENU COLOR border       30;44   #40ffffff #a0000000 std
   MENU COLOR title        1;36;44 #9033ccff #a0000000 std
   MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
   MENU COLOR unsel        37;44   #50ffffff #a0000000 std
   MENU COLOR help         37;40   #c0ffffff #a0000000 std
   MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
   MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
   MENU COLOR msg07        37;40   #90ffffff #a0000000 std
   MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

   LABEL linux
    MENU LABEL Try Ubuntu FS
    MENU DEFAULT
    KERNEL /casper/vmlinuz
    APPEND initrd=/casper/initrd boot=casper

   LABEL linux
    MENU LABEL Try Ubuntu FS (nomodeset)
    MENU DEFAULT
    KERNEL /casper/vmlinuz
    APPEND initrd=/casper/initrd boot=casper nomodeset
   EOF
   ```

2. Добавить BIOS-модули `syslinux`

   ```shell
   apt install -y syslinux-common && \
   cp /usr/lib/ISOLINUX/isolinux.bin image/isolinux/ && \
   cp /usr/lib/syslinux/modules/bios/* image/isolinux/
   ```

3. Перейти в каталог сборки

   ```shell
   cd $HOME/live-ubuntu-from-scratch/image
   ```

4. Создать ISO из каталога образа

   ```shell
   sudo xorriso \
      -as mkisofs \
      -iso-level 3 \
      -full-iso9660-filenames \
      -J -J -joliet-long \
      -volid "Ubuntu from scratch" \
      -output "../ubuntu-from-scratch.iso" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot \
        isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog isolinux/isolinux.cat \
    -eltorito-alt-boot \
        -e /EFI/boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
    -append_partition 2 0xef EFI/boot/efiboot.img \
      "$HOME/live-ubuntu-from-scratch/image"
   ```

## Создание загрузочного USB-образа

Это можно сделать просто и быстро с помощью `dd`.

```shell
sudo dd if=ubuntu-from-scratch.iso of=<device> status=progress oflag=sync bs=4M
```

## Итог

На этом процесс создания live Ubuntu installer с нуля завершен. Полученный ISO можно проверить в виртуальной машине, например в `VirtualBox`, либо записать на носитель и загрузить на обычном ПК.

## Вклад в проект

Подробности о правилах взаимодействия и процессе отправки pull request смотрите в [CONTRIBUTING.md](CONTRIBUTING.md).

## Версионирование

Для версионирования используется [GitHub](https://github.com/mvallim/live-custom-ubuntu-from-scratch). Список доступных версий можно посмотреть по [тегам этого репозитория](https://github.com/mvallim/live-custom-ubuntu-from-scratch/tags).

## Лицензия

Проект распространяется по лицензии GNU GENERAL PUBLIC LICENSE. Подробности смотрите в файле [LICENSE](LICENSE).
