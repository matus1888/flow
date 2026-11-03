# shellcheck shell=bash
# Статус и интерактивное меню.

print_status() {
    local system_line pid ver ip sub oc proxy_line

    system_line="$OS_PRETTY"
    [[ "$IS_WSL" == "1" ]] && system_line+=", WSL"
    if use_systemd; then
        system_line+=", systemd --user"
    else
        system_line+=", без systemd (nohup)"
    fi

    printf '\n%sopncdjob%s %s— VPN только для opencode%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %-12s %s\n' "Система:" "$system_line"

    if ! is_installed; then
        printf '  %-12s %s\n' "Установка:" "${C_YELLOW}не установлена${C_RESET}"
        printf '  %-12s %s\n' "Подсказка:" "$REPO_DIR/install.sh"
        return 0
    fi

    printf '  %-12s %s\n' "Установка:" "$CONFIG_DIR"

    ver="$(mihomo_version)"
    if mihomo_ready; then
        pid="$(mihomo_pid)"
        printf '  %-12s %s\n' "mihomo:" "${C_GREEN}работает${C_RESET} ${ver:+$ver, }pid ${pid:-?}, режим: $(state_get PROXY_MODE)"
    elif [[ -n "$ver" ]]; then
        printf '  %-12s %s\n' "mihomo:" "${C_YELLOW}остановлен${C_RESET} $ver"
    else
        printf '  %-12s %s\n' "mihomo:" "${C_RED}не установлен${C_RESET}"
    fi

    if mihomo_ready; then
        ip="$(proxy_ip)"
        if [[ -n "$ip" ]]; then
            local direct
            direct="$(direct_ip)"
            if [[ -n "$direct" && "$direct" == "$ip" ]]; then
                proxy_line="${C_YELLOW}IP как напрямую ($ip) — узел не применился${C_RESET}"
            else
                proxy_line="${C_GREEN}OK${C_RESET} $(proxy_url), внешний IP $ip"
            fi
        else
            proxy_line="${C_YELLOW}отвечает, но IP не получен${C_RESET}"
        fi
    else
        proxy_line="${C_DIM}не запущен${C_RESET}"
    fi
    printf '  %-12s %s\n' "прокси:" "$proxy_line"

    oc="$(oc_status_text)"
    if oc_proxy_enabled; then
        printf '  %-12s %s\n' "opencode:" "${C_GREEN}${oc}${C_RESET}"
    else
        printf '  %-12s %s\n' "opencode:" "$oc"
    fi

    sub="$(describe_subscription)"
    if [[ -n "$sub" ]]; then
        printf '  %-12s %s\n' "подписка:" "$sub"
    else
        printf '  %-12s %s\n' "подписка:" "${C_DIM}нет данных${C_RESET}"
    fi
}

menu_items() {
    cat <<'MENU'
  1) Включить: прокси + opencode
  2) Выключить opencode (прямое подключение, прокси оставить)
  3) Выключить всё (остановить прокси)
  4) Обновить конфиг подписки
  5) Сменить ссылку подписки
  6) Показать лог
  7) Переустановить / починить
  8) Удалить установку
  0) Выход
MENU
}

interactive_menu() {
    local choice

    if [[ ! -t 0 || ! -t 1 ]]; then
        print_status
        return 0
    fi

    while true; do
        print_status

        if is_installed; then
            printf '\n%s\n' "$(menu_items)"
        else
            printf '\n  1) Установить\n  0) Выход\n'
        fi

        printf 'Выбор: '
        IFS= read -r choice || return 0

        if is_installed; then
            case "$choice" in
                0 | q | Q) return 0 ;;
                1) cmd_enable || true ;;
                2) cmd_disable || true ;;
                3) cmd_stop_all || true ;;
                4) cmd_update || true ;;
                5) cmd_change_subscription || true ;;
                6) cmd_logs || true ;;
                7) cmd_install || true ;;
                8)
                    cmd_uninstall || true
                    [[ -d "$CONFIG_DIR" ]] || return 0
                    ;;
                *) warn "неизвестный пункт: $choice" ;;
            esac
        else
            case "$choice" in
                0 | q | Q) return 0 ;;
                1) cmd_install || true ;;
                *) warn "неизвестный пункт: $choice" ;;
            esac
        fi

        pause_enter
    done
}
