# shellcheck shell=bash
# Переключение исходящего прокси в OpenCode (background service).

oc_cmd() { command -v opencode 2>/dev/null || true; }

oc_available() { [[ -n "$(oc_cmd)" ]]; }

oc_env_json() {
    local bin
    bin="$(oc_cmd)"
    if [[ -z "$bin" ]]; then
        printf '{}'
        return 0
    fi
    "$bin" service get env 2>/dev/null || printf '{}'
}

oc_env_value() {
    oc_env_json | python3 "$HELPERS" json-get "$1" 2>/dev/null || true
}

oc_supports_service_env() {
    local bin
    bin="$(oc_cmd)"
    [[ -n "$bin" ]] || return 1
    "$bin" service get env >/dev/null 2>&1
}

oc_proxy_enabled() { [[ -f "$OPENCODE_MARKER" ]]; }

oc_enable() {
    local bin
    bin="$(oc_cmd)"

    if [[ -z "$bin" ]]; then
        warn "opencode не найден в PATH — прокси для него не настроен"
        return 0
    fi

    if ! oc_supports_service_env; then
        warn "эта версия opencode не умеет «service set env» — используй: opncdjob run opencode"
        return 1
    fi

    if ! oc_proxy_enabled; then
        mkdir -p "$STATE_DIR"
        oc_env_json >"$OPENCODE_BACKUP"
        chmod 600 "$OPENCODE_BACKUP" 2>/dev/null || true
    fi

    step "включаю прокси для opencode"
    "$bin" service set env HTTP_PROXY "$(proxy_url)" >/dev/null 2>&1 || true
    "$bin" service set env HTTPS_PROXY "$(proxy_url)" >/dev/null 2>&1 || true
    "$bin" service set env NO_PROXY 'localhost,127.0.0.1,::1' >/dev/null 2>&1 || true
    : >"$OPENCODE_MARKER"
    state_set OPENCODE_PROXY 1

    "$bin" service start >/dev/null 2>&1 || warn "не удалось перезапустить сервис opencode"
    ok "opencode: HTTPS_PROXY=$(proxy_url)"
}

oc_disable() {
    local bin key value
    bin="$(oc_cmd)"
    state_set OPENCODE_PROXY 0

    if [[ -z "$bin" ]]; then
        rm -f "$OPENCODE_MARKER"
        return 0
    fi

    if ! oc_proxy_enabled; then
        return 0
    fi

    step "возвращаю opencode к прямому подключению"
    for key in HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY; do
        "$bin" service unset env "$key" >/dev/null 2>&1 || true
    done

    if [[ -f "$OPENCODE_BACKUP" ]]; then
        while IFS=$'\t' read -r key value; do
            case "$key" in
                HTTP_PROXY | HTTPS_PROXY | NO_PROXY | ALL_PROXY) ;;
                *) continue ;;
            esac
            [[ -n "$value" ]] || continue
            "$bin" service set env "$key" "$value" >/dev/null 2>&1 || true
        done < <(python3 "$HELPERS" json-entries "$OPENCODE_BACKUP" 2>/dev/null || true)
    fi

    "$bin" service start >/dev/null 2>&1 || true
    rm -f "$OPENCODE_MARKER"
    ok "opencode: прямой доступ"
}

oc_health() {
    local bin
    bin="$(oc_cmd)"
    [[ -n "$bin" ]] || return 1
    have timeout || return 1
    timeout 20 "$bin" api get /api/info >/dev/null 2>&1
}

oc_status_text() {
    if ! oc_available; then
        printf 'не найден в PATH'
        return
    fi
    if oc_proxy_enabled; then
        printf 'включён (HTTPS_PROXY=%s)' "$(proxy_url)"
    else
        printf 'выключен (напрямую)'
    fi
}
