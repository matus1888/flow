#!/usr/bin/env bash
# Интерактивная установка opncdjob (обёртка над ./opncdjob install).
set -euo pipefail

DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
exec "$DIR/opncdjob" install "$@"
