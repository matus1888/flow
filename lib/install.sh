# shellcheck shell=bash
# Установка, включение/выключение, обновление и удаление.

banner() {
    [[ "$QUIET" == "1" ]] && return 0
    printf '%s\n' "${C_BOLD}opncdjob${C_RESET} ${C_DIM}v$OPNCDJOB_VERSION${C_RESET} — VPN только для opencode"
    printf '%s\n' "${C_DIM}локальный прокси mihomo (Rocket VPN) в этом окружении; хост не меняется${C_RESET}"
    hr
}

check_dependencies() {
    local missing=0 cmd
    for cmd in curl python3 gzip install; do
        if ! have "$cmd"; then
            err "не найдена команда «$cmd»"
            missing=1
        fi
    done
    if [[ "$missing" == "1" ]]; then
        die "установи зависимости: sudo apt install -y curl python3 gzip coreutils"
    fi
}

resolve_subscription() {
    local url="" existing=""

    if [[ -n "${OPNCDJOB_SUB_URL:-}" ]]; then
        step "использую ссылку из OPNCDJOB_SUB_URL"
        url="$OPNCDJOB_SUB_URL"
    else
        existing="$(subscription_url)"
        if [[ -n "$existing" ]]; then
            if confirm "Оставить прежнюю подписку $(mask_url "$existing")?" y; then
                url="$existing"
            else
                url="$(ask_secret 'Ссылка подписки Rocket VPN: ')"
            fi
        else
            url="$(ask_secret 'Ссылка подписки Rocket VPN: ')"
        fi
    fi

    [[ -n "$url" ]] || die "ссылка подписки не задана"
    save_subscription_url "$url"
}

fetch_subscription_with_retry() {
    local attempt=1 url
    while ! fetch_and_patch "$(subscription_url)"; do
        attempt=$((attempt + 1))
        if ((attempt > 3)); then
            die "не удалось получить конфиг подписки"
        fi
        warn "попытка $attempt из 3"
        url="$(ask_secret 'Ссылка подписки Rocket VPN: ')"
        [[ -n "$url" ]] || die "ссылка подписки не задана"
        save_subscription_url "$url"
    done
}

cmd_install() {
    banner
    require_ubuntu
    check_dependencies
    resolve_subscription

    if [[ ! -x "$BIN" ]]; then
        mihomo_install_binary || die "не удалось установить mihomo"
    else
        ok "mihomo уже установлен: $(mihomo_version) → $BIN"
    fi

    if [[ -z "$(state_get CONTROLLER_SECRET)" ]]; then
        state_set CONTROLLER_SECRET "$(gen_secret)"
    fi
    state_set VERSION "$OPNCDJOB_VERSION"

    fetch_subscription_with_retry
    mihomo_start || die "не удалось запустить прокси"

    local proxy_ok=0
    if verify_proxy; then
        proxy_ok=1
    else
        warn "прокси не подтвердил работу — смотри лог: $LOG_FILE"
    fi

    if oc_available; then
        if [[ "$proxy_ok" == "1" ]]; then
            if confirm "Включить прокси для opencode?" y; then
                oc_enable || warn "не удалось включить прокси для opencode"
            fi
        else
            warn "opencode оставлен напрямую; включить позже: opncdjob enable"
            if confirm "Всё равно включить прокси для opencode?" n; then
                oc_enable || warn "не удалось включить прокси для opencode"
            fi
        fi
    else
        warn "opencode не найден в PATH — прокси для него не настроен"
    fi

    if use_systemd; then
        if confirm "Обновлять конфиг подписки каждые ${UPDATE_INTERVAL_MINUTES} мин (systemd --user)?" y; then
            enable_update_timer || true
        fi
    fi

    print_summary
}

print_summary() {
    [[ "$QUIET" == "1" ]] && return 0
    hr
    ok "готово"
    printf '  %-16s %s\n' "конфиг:" "$CONFIG_DIR"
    printf '  %-16s %s\n' "бинарник:" "$BIN"
    printf '  %-16s %s\n' "прокси:" "$(proxy_url)"
    printf '  %-16s %s\n' "статус вкл/выкл:" "$REPO_DIR/opncdjob"
    printf '  %-16s %s\n' "разово для команды:" "opncdjob run <команда>"
    printf '  %-16s %s\n' "удалить:" "$REPO_DIR/uninstall.sh"
    hr
}

cmd_enable() {
    if ! is_installed; then
        err "не установлено — запусти $REPO_DIR/install.sh"
        return 1
    fi
    mihomo_start || return 1

    if verify_proxy; then
        if oc_available; then
            oc_enable || return 1
        else
            warn "opencode не найден в PATH — прокси доступен только локально"
        fi
        return 0
    fi

    if confirm "VPN не подтвердил работу — всё равно включить прокси для opencode?" n; then
        oc_enable || return 1
        return 0
    fi
    return 1
}

cmd_disable() {
    oc_disable || true
    if mihomo_ready; then
        ok "прокси оставлен запущенным ($(proxy_url)); чтобы остановить: opncdjob stop"
    fi
}

cmd_stop_all() {
    oc_disable || true
    mihomo_stop || true
}

cmd_update() {
    if ! is_installed; then
        err "не установлено — запусти $REPO_DIR/install.sh"
        return 1
    fi
    update_config || return 1
    mihomo_ready && verify_proxy || true
}

cmd_change_subscription() {
    local url
    url="$(ask_secret 'Новая ссылка подписки Rocket VPN: ')"
    [[ -n "$url" ]] || {
        err "ссылка не задана"
        return 1
    }
    save_subscription_url "$url"
    update_config || return 1
    verify_proxy || true
}

cmd_logs() {
    local lines="${1:-60}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n "$lines" "$LOG_FILE"
    else
        warn "лог пока пуст: $LOG_FILE"
    fi
    if use_systemd; then
        printf '\n%s\n' "${C_DIM}systemd --user status:${C_RESET}" >&2
        systemctl --user status --no-pager "$PROXY_UNIT.service" 2>/dev/null | head -n 15 || true
    fi
}

cmd_env() {
    printf 'export HTTP_PROXY=%s\n' "$(proxy_url)"
    printf 'export HTTPS_PROXY=%s\n' "$(proxy_url)"
    printf 'export NO_PROXY=%s\n' 'localhost,127.0.0.1,::1'
}

cmd_run() {
    [[ $# -gt 0 ]] || die "usage: opncdjob run <команда…>"
    if ! mihomo_ready; then
        is_installed || die "не установлено — запусти $REPO_DIR/install.sh"
        mihomo_start >/dev/null || die "не удалось запустить прокси"
    fi
    HTTP_PROXY="$(proxy_url)" HTTPS_PROXY="$(proxy_url)" NO_PROXY='localhost,127.0.0.1,::1' "$@"
}

remove_dir_if_ours() {
    local dir="$1" name="$2"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    if [[ "$(basename "$dir")" != "$name" ]]; then
        warn "пропускаю удаление $dir (не похоже на каталог $name)"
        return 0
    fi
    rm -rf "$dir"
}

cmd_uninstall() {
    local purge=0 arg
    for arg in "$@"; do
        case "$arg" in
            --purge) purge=1 ;;
            --yes | -y) OPNCDJOB_YES=1 ;;
        esac
    done

    banner

    if ! is_installed && [[ ! -d "$CONFIG_DIR" ]]; then
        warn "установка не найдена — удалять нечего"
        [[ "$purge" == "1" ]] && schedule_repo_removal
        return 0
    fi

    if ! confirm "Удалить установку opncdjob (прокси, конфиг, юниты, настройки opencode)?" n; then
        say "отменено"
        return 0
    fi

    oc_disable || true
    disable_update_timer || true
    mihomo_stop || true

    rm -f "$SYSTEMD_DIR/$PROXY_UNIT.service" \
        "$SYSTEMD_DIR/$UPDATE_UNIT.service" \
        "$SYSTEMD_DIR/$UPDATE_UNIT.timer" 2>/dev/null || true
    use_systemd && systemctl --user daemon-reload >/dev/null 2>&1 || true

    remove_dir_if_ours "$CONFIG_DIR" "opncdjob"
    remove_dir_if_ours "$STATE_DIR" "opncdjob"
    remove_dir_if_ours "$LIB_DIR" "opncdjob"

    ok "установка удалена"

    if [[ "$purge" == "1" ]]; then
        schedule_repo_removal
    elif [[ "$QUIET" != "1" ]]; then
        printf '  %s\n' "${C_DIM}каталог репозитория оставлен: $REPO_DIR${C_RESET}"
    fi
}

schedule_repo_removal() {
    step "удаляю каталог $REPO_DIR"
    (
        cd /
        setsid bash -c "sleep 1; rm -rf '$REPO_DIR'" >/dev/null 2>&1 &
    ) || true
    exit 0
}
