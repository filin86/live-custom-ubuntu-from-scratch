#!/bin/bash
# Hotfix уже установленной панели: чинит права/владельца в /home/inauto.
#
# Когда нужен: панель установлена образом, где вендорский payload приехал без
# битов исполнения. Симптомы — aksusbd.service падает с 203/EXEC, следом по
# Requires= не стартует hasplmd.service (сетевой ключ), а 001-idmvs.sh сыплет
# "Permission denied" на под-скриптах MVS/IDMVS.
#
# Почему хватает одного /home/inauto: rootfs панели immutable, а /opt, /usr/sbin
# и /etc лежат в tmpfs-overlay и пересобираются каждую загрузку скриптами
# on_start/oneshot. Персистентен только раздел inauto-data. Чиним права на нём —
# и после перезагрузки симлинки, MVS и ключ HASP встают заново уже корректно.
#
# Использование (оба файла рядом, на панели, от root):
#   scp normalize-home-perms.sh fix-panel-perms.sh root@<панель>:/tmp/
#   ssh root@<панель> 'bash /tmp/fix-panel-perms.sh'
#   ssh root@<панель> reboot

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/normalize-home-perms.sh"
INAUTO_ROOT="${INAUTO_ROOT:-/home/inauto}"

log()  { echo "[fix-panel-perms] $*"; }
fail() { echo "[fix-panel-perms] ERROR: $*" >&2; exit 1; }

(( EUID == 0 )) || fail "запускать от root."

[[ -f "$NORMALIZE" ]] \
    || fail "рядом нет normalize-home-perms.sh (ожидался $NORMALIZE) — скопируйте оба файла."

# Правка должна пережить reboot. Если /home/inauto не отдельный mountpoint, мы
# внутри tmpfs-overlay: chmod уедет при перезагрузке, а причина останется.
mountpoint -q "$INAUTO_ROOT" \
    || fail "$INAUTO_ROOT не mountpoint: правка не переживёт reboot. Проверьте MountHome.service."

# Показываем aksusbd до/после как самый наглядный маркер: именно он падает с
# 203/EXEC. На панели без hasplm его нет — тогда просто молчим, счётчик
# изменённых файлов всё равно печатает normalize-home-perms.sh.
AKSUSBD="$INAUTO_ROOT/distr/hasplm/usr/sbin/aksusbd_x86_64"

if [[ -e "$AKSUSBD" ]]; then
    log "до правки:  $(ls -l "$AKSUSBD" | awk '{print $1, $3":"$4}')"
fi

bash "$NORMALIZE" "$INAUTO_ROOT"

if [[ -e "$AKSUSBD" ]]; then
    log "после правки: $(ls -l "$AKSUSBD" | awk '{print $1, $3":"$4}')"
fi

cat <<'EOF_NEXT'

[fix-panel-perms] Готово. Дальше — reboot:

    reboot

Перезагрузка нужна, а не просто restart служб: /opt/MVS, /opt/IDMVS и симлинки
в /usr/sbin лежат в tmpfs-overlay и ставятся заново скриптами on_start/oneshot
при старте. После загрузки проверьте:

    systemctl status aksusbd hasplmd
    journalctl -u OnStartOneShot -b
EOF_NEXT