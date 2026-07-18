#!/bin/bash

DESKTOP_DIR=$HOME

# Копируем ярлыки на рабочий стол
cp -r /home/inauto/staff/shortcuts/* $DESKTOP_DIR
# Копируем ярлыки в меню
cp -r /home/inauto/staff/shortcuts/* /usr/share/applications
# Для ярлыков на рабочем столе ставим признак доверенного приложения
for f in $DESKTOP_DIR/*.desktop
do
   if ! gio info "$f" | grep metadata::xfce-exe-checksum > /dev/null 2>&1; then
      chmod +x "$f"
      gio set -t string "$f" metadata::xfce-exe-checksum "$(sha256sum "$f" | awk '{print $1}')"
   fi
done

# Отключаем погашение экрана
echo "00 Desktop conf complete"
