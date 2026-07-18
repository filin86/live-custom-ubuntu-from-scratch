#!/bin/bash
# Настраивает systemd-automount сетевой папки Windows (SMB/CIFS) из site-конфига.
# Автомаунт = монтирование "по обращению": шара поднимается при первом write
# приложения, переживает выключенный в момент загрузки Windows-ПК и сетевые сбои.
#
# Пока /home/inauto/staff/winshare/winshare.conf нет (есть только .example) —
# скрипт ничего не делает. Это нормальное состояние до настройки на площадке.
#
# Ошибки конфига НЕ роняют фазу oneshot (иначе не отработает 100-preconfiguration):
# при проблеме — предупреждение и exit 0.
set -euo pipefail

readonly CONF=/home/inauto/staff/winshare/winshare.conf
readonly CRED=/home/inauto/staff/winshare/credentials

if [[ ! -r "$CONF" ]]; then
    echo "winshare: $CONF отсутствует — автомаунт не настраиваю"
    exit 0
fi

# shellcheck source=/dev/null
. "$CONF"

if [[ -z "${SERVER:-}" || -z "${SHARE:-}" || -z "${MOUNTPOINT:-}" ]]; then
    echo "winshare: в $CONF не заданы SERVER/SHARE/MOUNTPOINT — пропускаю" >&2
    exit 0
fi

smb_version="${SMB_VERSION:-3.0}"
guest="${GUEST:-0}"

# uid/gid=1000 (ubuntu) — чтобы приложение могло писать в смонтированную папку
# (CIFS иначе монтируется от root). Опции монтирования, специфичные для cifs.
opts="uid=1000,gid=1000,file_mode=0664,dir_mode=0775,vers=${smb_version},iocharset=utf8"
if [[ "$guest" == "1" ]]; then
    opts="guest,${opts}"
elif [[ -r "$CRED" ]]; then
    chmod 600 "$CRED" 2>/dev/null || true   # пароль не должен быть world-readable
    opts="credentials=${CRED},${opts}"
else
    echo "winshare: нет ни GUEST=1, ни читаемого $CRED — пропускаю" >&2
    exit 0
fi

# Имена unit'ов обязаны соответствовать пути монтирования (systemd-escape).
mount_unit="$(systemd-escape -p --suffix=mount "$MOUNTPOINT")"
automount_unit="${mount_unit%.mount}.automount"

mkdir -p "$MOUNTPOINT"

# Юниты кладём в /run (tmpfs) — генерируются заново из persistent-конфига каждую
# загрузку, в образ (squashfs) не попадают.
cat > "/run/systemd/system/${mount_unit}" <<EOF
[Unit]
Description=CIFS mount //${SERVER}/${SHARE}
After=network-online.target
Wants=network-online.target

[Mount]
What=//${SERVER}/${SHARE}
Where=${MOUNTPOINT}
Type=cifs
Options=${opts}
TimeoutSec=30
EOF

cat > "/run/systemd/system/${automount_unit}" <<EOF
[Unit]
Description=Automount CIFS //${SERVER}/${SHARE}

[Automount]
Where=${MOUNTPOINT}
TimeoutIdleSec=120

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start "$automount_unit" || echo "WARN: не удалось запустить $automount_unit" >&2

echo "winshare: автомаунт настроен //${SERVER}/${SHARE} -> ${MOUNTPOINT}"