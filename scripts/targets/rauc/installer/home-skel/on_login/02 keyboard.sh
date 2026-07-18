#!/bin/bash

# Меняем режим ввода, чтобы не падало с ошибкой
gsettings set org.onboard.keyboard input-event-source 'GTK'

# увеличение прозрачности при простое
gsettings set org.onboard.window enable-inactive-transparency "true" 

# всегда на переднем плане
#gsettings set org.onboard.window force-to-top "true" 

# прозрачность при простое
gsettings set org.onboard.window inactive-transparency "60.0" 

# общая прозрачность
gsettings set org.onboard.window transparency "20.0" 

# прозрачный фон
gsettings set org.onboard.window transparent-background "true" 

# отключить заголовок окна (где кнопки закрыть, свернуть, etc.)
#gsettings set org.onboard.window window-decoration "false" 

# показывать иконку панели уведомлений
gsettings set org.onboard show-status-icon "false" 

# Показывать плавающий значок 
gsettings set org.onboard.icon-palette in-use "true"

# Позиция и размер плавающего значка. Позиции под типовой экран 1024*768 15"
gsettings set org.onboard.icon-palette.landscape width "40"
gsettings set org.onboard.icon-palette.landscape height "40"
gsettings set org.onboard.icon-palette.landscape x "312"
gsettings set org.onboard.icon-palette.landscape y "305"

#Default koords 882 705

# Раскладка по умолчанию и так компакт
gsettings set org.onboard layout "/usr/share/onboard/layouts/Compact.onboard"

# запускать скрытой
gsettings set org.onboard start-minimized "true" 

# Запускаем экранную клавиатуру
onboard &

echo "02 onboard conf complete"
