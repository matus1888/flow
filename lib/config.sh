# shellcheck shell=bash
# Подписка: загрузка Clash-конфига, правка, валидация и обновление.

subscription_url() { [[ -f "$SUB_FILE" ]] && cat "$SUB_FILE"; }

save_subscription_url() {
    local url="$1"
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    (umask 077 && printf '%s' "$url" >"$SUB_FILE")
    chmod 600 "$SUB_FILE"
}

mihomo_test_config_file() {
    local file="$1"
    [[ -x "$BIN" ]] || return 1
    "$BIN" -t -d "$CONFIG_DIR" -f "$file" >/dev/null 2>&1
}

refresh_sub_meta() {
    local line key value
    [[ -f "$SUB_HEADERS" && -f "$CONF" ]] || return 0
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        [[ -n "$key" ]] || continue
        eval "value=$value"
        state_set "$key" "$value"
    done < <(python3 "$HELPERS" sub-info "$SUB_HEADERS" "$CONF" 2>/dev/null || true)
    state_set LAST_UPDATE "$(date -Iseconds)"
}

fetch_and_patch() {
    local url="$1" raw candidate
    raw="$(mktemp)"
    candidate="$CONFIG_DIR/config.yaml.new"

    step "скачиваю подписку"
    if [[ "$url" == file://* || "$url" == /* ]]; then
        local src="${url#file://}"
        if [[ ! -f "$src" ]]; then
            err "локальный файл подписки не найден: $src"
            rm -f "$raw"
            return 1
        fi
        cp -f "$src" "$raw"
        if [[ -f "$src.headers" ]]; then
            cp -f "$src.headers" "$SUB_HEADERS"
        else
            : >"$SUB_HEADERS"
        fi
        step "использую локальный файл: $src"
    elif ! curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 60 \
        -A 'clash.meta' -D "$SUB_HEADERS" -o "$raw" "$url"; then
        rm -f "$raw"
        err "не удалось скачать подписку (проверь ссылку и доступность x.llill.tech)"
        return 1
    fi
    chmod 600 "$SUB_HEADERS" 2>/dev/null || true

    if ! grep -qE '^(proxies|mixed-port):' "$raw" 2>/dev/null; then
        rm -f "$raw"
        err "ответ не похож на Clash-конфиг — возможно, ссылка устарела"
        return 1
    fi

    if ! python3 "$HELPERS" patch-config \
        "$raw" "$candidate" "$PROXY_PORT" "$SOCKS_PORT" "$CONTROLLER_PORT" \
        "$(state_get CONTROLLER_SECRET)"; then
        rm -f "$raw"
        err "не удалось подготовить конфиг"
        return 1
    fi
    rm -f "$raw"
    chmod 600 "$candidate" 2>/dev/null || true

    if ! mihomo_test_config_file "$candidate"; then
        err "mihomo отверг сгенерированный конфиг:"
        "$BIN" -t -d "$CONFIG_DIR" -f "$candidate" 2>&1 | tail -n 5 >&2 || true
        rm -f "$candidate"
        return 1
    fi

    [[ -f "$CONF" ]] && cp -f "$CONF" "$CONF.prev" 2>/dev/null || true
    mv -f "$candidate" "$CONF"
    chmod 600 "$CONF" 2>/dev/null || true

    refresh_sub_meta
    ok "конфиг готов: $(state_get SUB_NODES) узлов, $(state_get SUB_GROUPS) групп"
}

update_config() {
    local url
    url="$(subscription_url)"
    [[ -n "$url" ]] || {
        err "не задана ссылка подписки"
        return 1
    }

    fetch_and_patch "$url" || return 1

    if mihomo_ready; then
        if mihomo_reload; then
            mihomo_select_global >/dev/null 2>&1 || true
            ok "прокси перечитал конфиг без перезапуска"
        else
            warn "горячая перезагрузка не удалась — перезапускаю прокси"
            mihomo_restart || return 1
        fi
    fi
}

verify_proxy() {
    local ip direct attempts=6
    while ((attempts > 0)); do
        ip="$(proxy_ip)"
        [[ -n "$ip" ]] && break
        sleep 1
        attempts=$((attempts - 1))
    done
    if [[ -z "$ip" ]]; then
        warn "прокси не отвечает на $(proxy_url)"
        return 1
    fi

    direct="$(direct_ip)"
    if [[ -n "$direct" && "$direct" == "$ip" ]]; then
        warn "трафик идёт напрямую: IP $ip совпадает с прямым — узел не применился"
        return 1
    fi

    ok "внешний IP через VPN: $ip"
    if [[ -n "$direct" ]]; then
        ok "напрямую (без прокси): $direct — остальной трафик идёт как обычно"
    fi
}

describe_subscription() {
    local nodes expire download total updated title
    nodes="$(state_get SUB_NODES)"
    expire="$(state_get SUB_EXPIRE)"
    download="$(state_get SUB_DOWNLOAD)"
    total="$(state_get SUB_TOTAL)"
    updated="$(state_get LAST_UPDATE)"
    title="$(state_get SUB_TITLE)"

    printf '%s' "${title:-подписка}"
    [[ -n "$nodes" ]] && printf ', узлов: %s' "$nodes"
    if [[ -n "$expire" && "$expire" != "0" ]]; then
        printf ', до %s' "$(human_date "$expire")"
    fi
    if [[ -n "$download" && "$download" != "0" ]]; then
        if [[ -n "$total" && "$total" != "0" ]]; then
            printf ', трафик %s из %s' "$(human_bytes "$download")" "$(human_bytes "$total")"
        else
            printf ', трафик %s' "$(human_bytes "$download")"
        fi
    fi
    [[ -n "$updated" ]] && printf ', обновлено %s' "${updated/T/ }"
}
