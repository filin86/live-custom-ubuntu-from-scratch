#!/bin/bash
# Установка/подъём SDK камеры IDMVS+MVS (Hikrobot) на текущую загрузку.
# Выполняется от root (systemd oneshot). Установка не роняет остальные скрипты
# фазы (100-preconfiguration с hasplmd) — сбой логируется, но не прерывает boot.
set -euo pipefail

# TODO(security): firewall отключается полностью, т.к. неизвестны порты камеры.
# GigE Vision: контроль по UDP 3956, стриминг — динамические UDP-порты. Правильно
# сузить до интерфейса/подсети камеры (ufw allow in on <iface> / from <subnet>),
# когда будут известны сетевые параметры камеры. Пока — осознанный security debt.
ufw disable || echo "WARN: 'ufw disable' завершился с ошибкой" >&2

if /home/inauto/distr/install_idmvs.sh; then
    echo "IDMVS/MVS install: OK"
else
    echo "ERROR: install_idmvs.sh завершился с ошибкой" >&2
fi