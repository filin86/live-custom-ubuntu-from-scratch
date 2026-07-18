#!/bin/bash
# Задаём пароль root. Скрипт выполняется от root (systemd oneshot), sudo не нужен.
# chpasswd надёжнее, чем 'passwd' из пайпа.
set -euo pipefail

echo "root:VeryStrongPassword36CharactersLength" | chpasswd

echo "root password set"