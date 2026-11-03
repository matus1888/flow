#!/usr/bin/env bash
# Удаление установки opncdjob (обёртка над ./opncdjob uninstall).
#   ./uninstall.sh            удалить установку, оставить каталог репозитория
#   ./uninstall.sh --purge    удалить и каталог репозитория
set -euo pipefail

DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
exec "$DIR/opncdjob" uninstall "$@"
