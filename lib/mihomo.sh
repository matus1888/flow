# shellcheck shell=bash
# Управление бинарником и процессом mihomo (systemd --user либо nohup).

mihomo_version() {
    [[ -x "$BIN" ]] || return 0
    "$BIN" -v 2>/dev/null | sed -n 's/.*\(v[0-9][0-9.]*\).*/\1/p' | head -n 1
}

mihomo_test_config() {
    [[ -x "$BIN" ]] || return 1
    "$BIN" -t -d "$CONFIG_DIR" -f "$CONF" >/dev/null 2>&1
}

mihomo_install_binary() {
    local arch tmp vendored url
    arch="$(detect_arch)" || die "неподдерживаемая архитектура: $(uname -m)"

    mkdir -p "$LIB_DIR"
    chmod 700 "$LIB_DIR" 2>/dev/null || true

    if [[ -n "${OPNCDJOB_VENDOR:-}" ]]; then
        [[ -f "$OPNCDJOB_VENDOR" ]] || die "OPNCDJOB_VENDOR=$OPNCDJOB_VENDOR не найден"
        install -m 0755 "$OPNCDJOB_VENDOR" "$BIN"
        ok "mihomo взят из OPNCDJOB_VENDOR ($(mihomo_version))"
        return 0
    fi

    vendored="$REPO_DIR/vendor/mihomo-linux-$arch"
    if [[ -x "$vendored" ]]; then
        install -m 0755 "$vendored" "$BIN"
        ok "mihomo взят из vendor/ ($(mihomo_version))"
        return 0
    fi

    url="https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${arch}-compatible-v${MIHOMO_VERSION}.gz"
    if [[ "$arch" != "amd64" ]]; then
        url="https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${arch}-v${MIHOMO_VERSION}.gz"
    fi
    step "скачиваю mihomo v${MIHOMO_VERSION} ($arch)"
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    if ! curl -fL --progress-bar --retry 3 --retry-delay 1 --connect-timeout 15 --max-time 300 -o "$tmp/mihomo.gz" "$url"; then
        err "не удалось скачать $url"
        err "если GitHub недоступен — скачай бинарник вручную и положи в $REPO_DIR/vendor/mihomo-linux-$arch"
        return 1
    fi

    gzip -dc "$tmp/mihomo.gz" >"$tmp/mihomo"
    chmod +x "$tmp/mihomo"
    if ! "$tmp/mihomo" -v >/dev/null 2>&1; then
        err "скачанный бинарник не запускается"
        return 1
    fi

    install -m 0755 "$tmp/mihomo" "$BIN"
    ok "mihomo установлен: $(mihomo_version) → $BIN"
}

controller_request() {
    local method="$1" path="$2" body="${3:-}" secret
    secret="$(state_get CONTROLLER_SECRET)"
    if [[ -n "$body" ]]; then
        curl -fsS --max-time 5 -X "$method" \
            -H "Authorization: Bearer $secret" \
            -H 'Content-Type: application/json' \
            -d "$body" "http://127.0.0.1:$CONTROLLER_PORT$path"
    else
        curl -fsS --max-time 5 -X "$method" \
            -H "Authorization: Bearer $secret" \
            "http://127.0.0.1:$CONTROLLER_PORT$path"
    fi
}

mihomo_ready() { controller_request GET /version >/dev/null 2>&1; }

# В режиме global mihomo по умолчанию выбирает DIRECT, поэтому явно
# переключаем GLOBAL на первую группу из подписки (обычно «Автовыбор»).
mihomo_select_global() {
    local group payload
    group="$(python3 "$HELPERS" first-group "$CONF" 2>/dev/null || true)"
    if [[ -z "$group" ]]; then
        warn "в конфиге не найдено групп прокси"
        return 1
    fi
    payload="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}))' "$group")"
    if ! controller_request PUT /proxies/GLOBAL "$payload" >/dev/null; then
        warn "не удалось выбрать группу «$group» в GLOBAL"
        return 1
    fi
    state_set GLOBAL_GROUP "$group"
}

mihomo_pid() {
    local pid
    pid="$(state_get PID)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"
        return 0
    fi
    if [[ -f "$PID_FILE" ]]; then
        pid="$(cat "$PID_FILE")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    if use_systemd && systemctl --user is-active --quiet "$PROXY_UNIT.service" 2>/dev/null; then
        pid="$(systemctl --user show -p MainPID --value "$PROXY_UNIT.service" 2>/dev/null || true)"
        [[ -n "$pid" && "$pid" != "0" ]] && printf '%s' "$pid"
    fi
}

write_proxy_unit() {
    mkdir -p "$SYSTEMD_DIR"
    cat >"$SYSTEMD_DIR/$PROXY_UNIT.service" <<EOF
[Unit]
Description=opncdjob: mihomo proxy for opencode
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -d $CONFIG_DIR -f $CONF
Restart=on-failure
RestartSec=3
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=default.target
EOF
}

write_timer_units() {
    mkdir -p "$SYSTEMD_DIR"
    cat >"$SYSTEMD_DIR/$UPDATE_UNIT.service" <<EOF
[Unit]
Description=opncdjob: refresh subscription config
After=network-online.target

[Service]
Type=oneshot
ExecStart=$REPO_DIR/opncdjob update --quiet
EOF

    cat >"$SYSTEMD_DIR/$UPDATE_UNIT.timer" <<EOF
[Unit]
Description=opncdjob: hourly subscription refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=${UPDATE_INTERVAL_MINUTES}min
Persistent=true
Unit=$UPDATE_UNIT.service

[Install]
WantedBy=timers.target
EOF
}

mihomo_start() {
    local mode

    if mihomo_ready; then
        mihomo_select_global >/dev/null 2>&1 || true
        ok "прокси уже работает ($(proxy_url))"
        return 0
    fi

    [[ -x "$BIN" ]] || {
        err "mihomo не установлен"
        return 1
    }
    [[ -f "$CONF" ]] || {
        err "нет конфига $CONF"
        return 1
    }

    if port_busy "$PROXY_PORT" && [[ -z "$(mihomo_pid)" ]]; then
        err "порт $PROXY_PORT уже занят другим процессом"
        return 1
    fi

    if use_systemd; then
        mode="systemd"
        write_proxy_unit
        systemctl --user daemon-reload
        systemctl --user enable "$PROXY_UNIT.service" >/dev/null 2>&1 || true
        if ! systemctl --user restart "$PROXY_UNIT.service"; then
            err "не удалось запустить $PROXY_UNIT.service"
            return 1
        fi
    else
        mode="nohup"
        mkdir -p "$STATE_DIR"
        nohup "$BIN" -d "$CONFIG_DIR" -f "$CONF" >>"$LOG_FILE" 2>&1 &
        printf '%s\n' "$!" >"$PID_FILE"
        state_set PID "$!"
    fi

    state_set PROXY_MODE "$mode"

    local attempts=60
    while ((attempts > 0)); do
        if mihomo_ready; then
            mihomo_select_global || warn "не удалось выбрать VPN-группу — проверь «opncdjob status»"
            ok "прокси запущен ($(proxy_url), режим: $mode)"
            return 0
        fi
        sleep 0.25
        attempts=$((attempts - 1))
    done

    err "прокси не ответил за 15 с — смотри лог: $LOG_FILE"
    tail -n 20 "$LOG_FILE" >&2 2>/dev/null || true
    return 1
}

mihomo_stop() {
    local pid stopped=0

    if use_systemd && [[ -f "$SYSTEMD_DIR/$PROXY_UNIT.service" ]]; then
        systemctl --user disable --now "$PROXY_UNIT.service" >/dev/null 2>&1 && stopped=1
    fi

    pid="$(mihomo_pid || true)"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        stopped=1
    fi

    rm -f "$PID_FILE"
    state_drop PID

    if mihomo_ready; then
        err "прокси всё ещё отвечает на $(proxy_url)"
        return 1
    fi

    [[ "$stopped" == "1" ]] && ok "прокси остановлен"
    return 0
}

mihomo_reload() {
    mihomo_ready || return 1
    controller_request PUT "/configs?force=true" "{\"path\":\"$CONF\"}" >/dev/null
}

mihomo_restart() {
    if use_systemd && [[ -f "$SYSTEMD_DIR/$PROXY_UNIT.service" ]]; then
        systemctl --user restart "$PROXY_UNIT.service"
    else
        local pid
        pid="$(mihomo_pid || true)"
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        sleep 0.5
        mihomo_start >/dev/null
    fi
}

enable_update_timer() {
    use_systemd || {
        warn "systemd недоступен — автообновление не настроено"
        return 1
    }
    write_timer_units
    systemctl --user daemon-reload
    systemctl --user enable --now "$UPDATE_UNIT.timer" >/dev/null 2>&1 || {
        err "не удалось включить $UPDATE_UNIT.timer"
        return 1
    }
    ok "автообновление подписки: каждые ${UPDATE_INTERVAL_MINUTES} мин"
}

disable_update_timer() {
    use_systemd || return 0
    systemctl --user disable --now "$UPDATE_UNIT.timer" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/$UPDATE_UNIT.timer" "$SYSTEMD_DIR/$UPDATE_UNIT.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
}

timer_enabled() {
    use_systemd || return 1
    systemctl --user is-enabled --quiet "$UPDATE_UNIT.timer" 2>/dev/null
}
