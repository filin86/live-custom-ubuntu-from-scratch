#!/bin/bash
# Права пользователя ubuntu (его SSH-ключ ставит 05-ssh-keys.sh).
# Выполняется от root (systemd oneshot), sudo не нужен.
set -euo pipefail

# ubuntu в группу dialout (доступ к сканерам/COM-портам).
usermod -aG dialout ubuntu

# Лишаем ubuntu sudo: пользователь без пароля не должен иметь sudo (намеренно).
# '|| true' — идемпотентность: при повторной загрузке ubuntu уже не в группе
# sudo, и gpasswd -d вернёт ошибку, которую здесь безопасно проигнорировать.
gpasswd -d ubuntu sudo || true
# Убираем sudoers.d-файл, созданный на этапе сборки (NOPASSWD для ubuntu).
rm -rf /etc/sudoers.d/*

echo "User rights changed"