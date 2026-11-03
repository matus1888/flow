# shellcheck shell=bash
# Общие функции, пути и утилиты opncdjob.
# Подключается из opncdjob; не предназначен для прямого запуска.

set -euo pipefail

OPNCDJOB_VERSION="${OPNCDJOB_VERSION:-1.0.0}"

CONFIG_DIR="${OPNCDJOB_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opncdjob}"
STATE_DIR="${OPNCDJOB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/opncdjob}"
LIB_DIR="${OPNCDJOB_LIB_DIR:-${XDG_DATA_HOME:-$HOME/.local/lib}/opncdjob}"
SYSTEMD_DIR="${OPNCDJOB_SYSTEMD_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"

BIN="$LIB_DIR/mihomo"
CONF="$CONFIG_DIR/config.yaml"
SUB_FILE="$CONFIG_DIR/subscription.url"
SUB_HEADERS="$CONFIG_DIR/subscription.headers"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="$STATE_DIR/mihomo.log"
PID_FILE="$STATE_DIR/mihomo.pid"
OPENCODE_MARKER="$STATE_DIR/opencode-proxy.enabled"
OPENCODE_BACKUP="$STATE_DIR/opencode-env.backup.json"

PROXY_PORT="${OPNCDJOB_PORT:-7890}"
SOCKS_PORT="${OPNCDJOB_SOCKS_PORT:-7891}"
CONTROLLER_PORT="${OPNCDJOB_CONTROLLER_PORT:-9090}"
MIHOMO_VERSION="${OPNCDJOB_MIHOMO_VERSION:-1.19.33}"
UPDATE_INTERVAL_MINUTES="${OPNCDJOB_UPDATE_INTERVAL:-60}"

UPDATE_UNIT="opncdjob-update"
PROXY_UNIT="opncdjob-proxy"

QUIET="${QUIET:-0}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

say() { [[ "$QUIET" == "1" ]] || printf '%s\n' "$*"; }
step() { [[ "$QUIET" == "1" ]] || printf '%s▸%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { [[ "$QUIET" == "1" ]] || printf '%s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
    err "$*"
    exit 1
}
hr() { [[ "$QUIET" == "1" ]] || printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────${C_RESET}"; }

have() { command -v "$1" >/dev/null 2>&1; }

state_get() {
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^$1=//p" "$STATE_FILE" | head -n 1
}

state_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    touch "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    tmp="$(mktemp)"
    if [[ -s "$STATE_FILE" ]]; then
        grep -v "^${key}=" "$STATE_FILE" >"$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_drop() {
    local key="$1" tmp
    [[ -f "$STATE_FILE" ]] || return 0
    tmp="$(mktemp)"
    grep -v "^${key}=" "$STATE_FILE" >"$tmp" || true
    mv "$tmp" "$STATE_FILE"
}

is_installed() { [[ -x "$BIN" && -f "$CONF" ]]; }

proxy_url() { printf 'http://127.0.0.1:%s' "$PROXY_PORT"; }

proxy_ip() { curl -fsS --max-time 6 -x "$(proxy_url)" https://api.ipify.org 2>/dev/null || true; }

direct_ip() { curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true; }

port_busy() {
    local port="$1"
    have ss || return 1
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) printf 'amd64' ;;
        aarch64 | arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

gen_secret() {
    if have openssl; then
        openssl rand -hex 16
    else
        python3 -c 'import secrets; print(secrets.token_hex(16))'
    fi
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KB MB GB TB PB", unit, " ");
        i = 1;
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%.0f %s" : "%.2f %s"), b, unit[i]
    }'
}

human_date() {
    [[ -n "${1:-}" && "$1" != "0" ]] && date -d "@$1" '+%d.%m.%Y' 2>/dev/null || printf '—'
}

mask_url() {
    local url="$1"
    if [[ ${#url} -le 18 ]]; then
        printf '***'
    else
        printf '%s…%s' "${url:0:8}" "${url: -4}"
    fi
}

ask_value() {
    local prompt="$1" default="${2:-}" answer=""
    if [[ ! -t 0 ]]; then
        printf '%s' "$default"
        return 0
    fi
    printf '%s' "$prompt" >&2
    IFS= read -r answer || answer=""
    printf '%s' "${answer:-$default}"
}

ask_secret() {
    local prompt="$1" answer=""
    if [[ ! -t 0 ]]; then
        printf ''
        return 0
    fi
    printf '%s' "$prompt" >&2
    IFS= read -rs answer || answer=""
    printf '\n' >&2
    printf '%s' "$answer"
}

confirm() {
    local prompt="$1" default="${2:-n}" answer=""
    [[ "${OPNCDJOB_YES:-0}" == "1" ]] && return 0
    [[ -t 0 ]] || return 1
    if [[ "$default" == "y" ]]; then
        printf '%s [Y/n]: ' "$prompt" >&2
    else
        printf '%s [y/N]: ' "$prompt" >&2
    fi
    IFS= read -r answer || answer=""
    answer="${answer:-$default}"
    case "${answer,,}" in
        y | yes | д | да) return 0 ;;
        *) return 1 ;;
    esac
}

pause_enter() {
    [[ -t 0 ]] || return 0
    printf '\n%sEnter — продолжить%s' "$C_DIM" "$C_RESET" >&2
    IFS= read -r _ || true
}

detect_environment() {
    IS_WSL=0
    if grep -qi microsoft /proc/version 2>/dev/null; then
        IS_WSL=1
    fi

    OS_ID="unknown"
    OS_PRETTY="$(uname -s)"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        OS_ID="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
        # shellcheck disable=SC1091
        OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$OS_ID}")"
    fi

    ARCH="$(detect_arch 2>/dev/null || printf 'unknown')"
}

use_systemd() {
    [[ "${OPNCDJOB_NO_SYSTEMD:-0}" == "1" ]] && return 1
    have systemctl || return 1
    systemctl --user show-environment >/dev/null 2>&1
}

systemd_available() { use_systemd; }

require_ubuntu() {
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        warn "целевая ОС — Ubuntu; обнаружено: $OS_PRETTY. Продолжаю, но без гарантий."
    fi
}

require_command() {
    local cmd="$1" hint="${2:-}"
    if ! have "$cmd"; then
        err "не найдена команда «$cmd»${hint:+ — $hint}"
        return 1
    fi
}
