#!/bin/sh
# telemt / telemt-panel — единое меню (nfqws-menu repo)
# Компоненты: installer_telemt_v3.sh, install_telemt-panel.sh (тот же репозиторий)

set -e
set -o pipefail 2>/dev/null || true

RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
CYAN=$(printf '\033[0;36m')
YELLOW=$(printf '\033[1;33m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

REPO_RAW="${TELEMT_REPO_RAW:-https://raw.githubusercontent.com/rndnaame/nfqws-menu/main}"
TELEMT_CORE_URL="${REPO_RAW}/installer_telemt_v3.sh"
TELEMT_PANEL_URL="${REPO_RAW}/install_telemt-panel.sh"
TELEMT_SYSTEMCTL_URL="${TELEMT_SYSTEMCTL_URL:-https://raw.githubusercontent.com/anch665/keendev/main/systemctl.sh}"
TELEMT_JOURNALCTL_URL="${TELEMT_JOURNALCTL_URL:-https://raw.githubusercontent.com/anch665/keendev/main/journalctl.sh}"

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[!]${NC} $*"; }
ask()   { printf '%s' "$*"; }

is_telemt_installed() {
    [ -x /opt/usr/bin/telemt ] || [ -x /opt/etc/init.d/S99telemt ] || \
        [ -d /opt/etc/telemt ] || [ -x /opt/sbin/telemt-panel ] || \
        [ -x /opt/etc/init.d/S99telemt-panel ] || [ -d /opt/etc/telemt-panel ]
}

_download() {
    _url="$1"
    _out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_out" "$_url"
    else
        error "Нужны curl или wget"
        return 1
    fi
}

run_component() {
    _url="$1"
    _label="$2"
    _tmp="/tmp/telemt_comp_$$.sh"
    info "Источник: $_url"
    if ! _download "$_url" "$_tmp"; then
        error "Не удалось скачать $_label"
        rm -f "$_tmp"
        return 1
    fi
    chmod +x "$_tmp" 2>/dev/null || true
    # интерактив: предпочитаем /dev/tty
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        sh "$_tmp" < /dev/tty > /dev/tty 2>&1 || _rc=$?
    else
        sh "$_tmp" || _rc=$?
    fi
    _rc=${_rc:-0}
    rm -f "$_tmp"
    return "$_rc"
}

install_telemt_core() {
    echo
    info "Установка telemt"
    run_component "$TELEMT_CORE_URL" "installer_telemt_v3.sh" || true
    info "Установщик telemt завершил работу."
}

install_telemt_panel() {
    echo
    info "Установка telemt-panel"
    run_component "$TELEMT_PANEL_URL" "install_telemt-panel.sh" || true
    info "Установщик telemt-panel завершил работу."
}

install_telemt_systemd_emu() {
    echo
    info "Эмуляция systemD (systemctl / journalctl) для панели и логов"
    info "systemctl:  $TELEMT_SYSTEMCTL_URL"
    info "journalctl: $TELEMT_JOURNALCTL_URL"
    echo
    mkdir -p /opt/usr/bin
    if ! _download "$TELEMT_SYSTEMCTL_URL" /opt/usr/bin/systemctl; then
        error "Не удалось скачать systemctl"
        return 1
    fi
    if ! _download "$TELEMT_JOURNALCTL_URL" /opt/usr/bin/journalctl; then
        error "Не удалось скачать journalctl"
        return 1
    fi
    chmod +x /opt/usr/bin/systemctl /opt/usr/bin/journalctl
    if [ -x /opt/etc/init.d/S99telemt-panel ]; then
        /opt/etc/init.d/S99telemt-panel restart 2>/dev/null || true
        info "S99telemt-panel перезапущен."
    else
        warn "S99telemt-panel не найден — перезапуск пропущен."
    fi
    info "Эмуляция systemD установлена: /opt/usr/bin/systemctl, /opt/usr/bin/journalctl"
}

remove_telemt() {
    echo
    info "Удаление telemt / telemt-panel..."
    /opt/etc/init.d/S99telemt-panel stop 2>/dev/null || true
    /opt/etc/init.d/S99telemt stop 2>/dev/null || true
    rm -f /opt/etc/init.d/S99telemt
    rm -f /opt/etc/init.d/S99telemt-panel
    rm -f /opt/usr/bin/telemt
    rm -f /opt/sbin/telemt-panel
    rm -rf /opt/etc/telemt
    rm -rf /opt/etc/telemt-panel
    rm -rf /opt/tmp/telemt_dl
    rm -rf /opt/tmp/telemt-panel-install
    rm -rf /tmp/telemt_dl /tmp/telemt-panel-dl
    rm -f /tmp/log/telemt.log
    rm -f /tmp/cache/beobachten.txt
    # systemctl/journalctl эмуляцию не трогаем — может использоваться иначе
    info "telemt / telemt-panel удалены."
}

confirm_yes() {
    ask "$1 [y/N]: "
    if [ -r /dev/tty ]; then
        read _c < /dev/tty || _c=""
    else
        read _c || _c=""
    fi
    case "$_c" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

read_choice() {
    if [ -r /dev/tty ]; then
        read _ch < /dev/tty || _ch=""
    else
        read _ch || _ch=""
    fi
    printf '%s' "$_ch"
}

show_banner() {
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}           telemt / telemt-panel${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}Telemt — быстрый, безопасный и функциональный сервер на Rust:${NC}"
    printf '%s\n' "${DIM}полностью реализует официальный алгоритм Telegram-прокси${NC}"
    printf '%s\n' "${DIM}и добавляет множество улучшений.${NC}"
    echo
    printf '%s\n' "${DIM}panel upstream: https://github.com/amirotin/telemt_panel${NC}"
    printf '%s\n' "${DIM}(Entware / Keenetic; aarch64, x86_64, mipsel, mips)${NC}"
    echo
    if is_telemt_installed; then
        _tm_st=""
        { [ -x /opt/usr/bin/telemt ] || [ -x /opt/etc/init.d/S99telemt ]; } && _tm_st="${_tm_st}telemt "
        { [ -x /opt/sbin/telemt-panel ] || [ -x /opt/etc/init.d/S99telemt-panel ]; } && _tm_st="${_tm_st}telemt-panel "
        [ -x /opt/usr/bin/systemctl ] && _tm_st="${_tm_st}systemctl "
        info "Обнаружено: ${_tm_st:-частично}"
        echo
    fi
    echo "  1. Установка telemt"
    echo "  2. Установка telemt-panel"
    echo "  3. Эмуляция systemD"
    echo "  4. Удаление"
    echo "  0. Назад"
    echo
}

# --- main menu loop ---
while true; do
    show_banner
    ask "Выбор: "
    tchoice=$(read_choice)
    case "$tchoice" in
        1) install_telemt_core || true ;;
        2) install_telemt_panel || true ;;
        3) install_telemt_systemd_emu || true ;;
        4)
            if confirm_yes "Удалить telemt и telemt-panel?"; then
                remove_telemt || true
            else
                info "Отменено."
            fi
            ;;
        0|"")
            exit 0
            ;;
        *)
            warn "Неверный пункт"
            ;;
    esac
    echo
    ask "Нажмите Enter для возврата в меню..."
    read_choice >/dev/null
done
