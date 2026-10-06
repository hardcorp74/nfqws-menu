#!/bin/sh

set -e
set -o pipefail

echo "=== telemt-panel installer for Entware (nfqws-menu) ==="

# ANSI
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BOLD=$(printf '\033[1m')
NC=$(printf '\033[0m')

PANEL_DIR="/opt/etc/telemt-panel"
PANEL_CONFIG="$PANEL_DIR/config.toml"
VERSION_FILE="$PANEL_DIR/.version"
BIN_PATH="/opt/sbin/telemt-panel"
INIT_SCRIPT="/opt/etc/init.d/S99telemt-panel"
TELEMT_CONFIG="/opt/etc/telemt/config.toml"
TMPDIR="/tmp/telemt-panel-dl"
GITHUB_REPO="amirotin/telemt_panel"

# --- Arch (как installer_telemt_v3 / nfqws-menu) ---
_arch_normalize() {
    case "$1" in
        aarch64*|arm64*)             echo "aarch64" ;;
        mipsel*|mipselsf*|mips64el*) echo "mipsel" ;;
        mips*|mipssf*)               echo "mips" ;;
        x86_64*|amd64*|x64*)         echo "x86_64" ;;
        *)                           echo "" ;;
    esac
}

_arch_pick_best() {
    awk '
        $1 == "arch" && $2 != "" && $2 != "all" {
            p = $3 + 0
            n = $2
            bonus = 0
            if (n ~ /^mipsel/ || n ~ /^mipselsf/ || n ~ /^mips64el/) bonus = 2
            else if (n ~ /^aarch64/ || n ~ /^arm64/) bonus = 2
            score = p * 10 + bonus
            if (score > best) { best = score; name = n }
        }
        END { if (name != "") print name }
    '
}

_arch_from_opkg() {
    opkg print-architecture 2>/dev/null | _arch_pick_best
}

_arch_from_opkg_conf() {
    conf="${1:-/opt/etc/opkg.conf}"
    [ -f "$conf" ] || return 0
    name=$(grep -E '^[[:space:]]*arch[[:space:]]+' "$conf" 2>/dev/null | _arch_pick_best) || true
    if [ -n "$name" ]; then
        printf '%s\n' "$name"
        return 0
    fi
    from_url=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            src/gz*|src\ *)
                case "$line" in
                    *mipselsf*|*mips64el*|*mipsel*) from_url="mipsel"; break ;;
                    *mipssf*|*mips*)                from_url="mips"; break ;;
                    *aarch64*|*arm64*)              from_url="aarch64"; break ;;
                    *x86_64*|*amd64*)               from_url="x86_64"; break ;;
                esac
                ;;
        esac
    done < "$conf"
    [ -n "$from_url" ] && printf '%s\n' "$from_url"
}

detect_arch() {
    ARCH=""
    ARCH_RAW=""
    ARCH_SOURCE=""
    ARCH_RAW=$(_arch_from_opkg) || true
    ARCH=$(_arch_normalize "$ARCH_RAW")
    [ -n "$ARCH" ] && ARCH_SOURCE="opkg"
    if [ -z "$ARCH" ]; then
        ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf) || true
        ARCH=$(_arch_normalize "$ARCH_RAW")
        [ -n "$ARCH" ] && ARCH_SOURCE="conf"
    fi
    if [ -z "$ARCH" ]; then
        um=$(uname -m 2>/dev/null || true)
        case "$um" in
            mips|mipsel|mips64|mips64el|"") ;;
            *)
                cand=$(_arch_normalize "$um")
                if [ -n "$cand" ]; then
                    ARCH="$cand"
                    ARCH_RAW="$um"
                    ARCH_SOURCE="uname"
                fi
                ;;
        esac
    fi
}

detect_arch

PANEL_SOURCE="github"
PANEL_IPK_BASE=""
PANEL_IPK_ARCH=""
PANEL_ARCHIVE=""

case "$ARCH" in
    aarch64)
        PANEL_SOURCE="github"
        PANEL_ARCHIVE="telemt-panel-aarch64-linux-gnu.tar.gz"
        ;;
    x86_64)
        PANEL_SOURCE="github"
        PANEL_ARCHIVE="telemt-panel-x86_64-linux-gnu.tar.gz"
        ;;
    mipsel)
        PANEL_SOURCE="ipk"
        PANEL_IPK_BASE="https://test.entware.net/mipssf-k3.4/4test/le"
        PANEL_IPK_ARCH="mipsel-3.4"
        ;;
    mips)
        PANEL_SOURCE="ipk"
        PANEL_IPK_BASE="https://test.entware.net/mipssf-k3.4/4test/be"
        PANEL_IPK_ARCH="mips-3.4"
        ;;
    *)
        echo "ERROR: Unsupported architecture: '${ARCH:-?}' (raw=${ARCH_RAW:-?}, src=${ARCH_SOURCE:-none})"
        exit 1
        ;;
esac

if [ "$PANEL_SOURCE" = "ipk" ]; then
    echo "Architecture: $ARCH → ipk $PANEL_IPK_BASE (detect: ${ARCH_SOURCE:-?})"
else
    echo "Architecture: $ARCH → $PANEL_ARCHIVE (detect: ${ARCH_SOURCE:-?})"
fi

# --- Helpers ---
_http_get() {
    if command -v wget >/dev/null 2>&1; then
        wget -qO- "$1" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" 2>/dev/null
    fi
}

_http_download() {
    _url="$1"
    _out="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$_out" "$_url"
    else
        curl -fL -o "$_out" "$_url"
    fi
}

ensure_deps() {
    _force="${1:-0}"
    _need=0
    command -v openssl >/dev/null 2>&1 || _need=1
    command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || _need=1
    if [ "$_force" = "1" ] || [ "$_need" -eq 1 ]; then
        echo "Установка/проверка зависимостей..."
        opkg update 2>/dev/null || true
        opkg install openssl-util 2>/dev/null || true
        opkg install wget-ssl 2>/dev/null || opkg install wget 2>/dev/null || true
    fi
}


# Свободное место на /opt (kB). $1 = минимум kB
check_opt_space() {
    _need_kb="${1:-12000}"
    _avail=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$_avail" ] || ! [ "$_avail" -ge 0 ] 2>/dev/null; then
        _avail=$(df -P -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
    fi
    if [ -z "$_avail" ] || ! [ "$_avail" -ge 0 ] 2>/dev/null; then
        echo "WARNING: не удалось определить свободное место на /opt"
        df -h /opt 2>/dev/null || true
        return 0
    fi
    echo "Свободно на /opt: ${_avail} kB (нужно ≥ ${_need_kb} kB)"
    if [ "$_avail" -lt "$_need_kb" ]; then
        echo ""
        printf '%s\n' "${RED}ERROR: недостаточно места на /opt${NC}"
        echo "  Доступно: ${_avail} kB"
        echo "  Требуется: ≥ ${_need_kb} kB"
        echo "  Освободите место (логи, старые пакеты, /opt/tmp) и повторите."
        echo ""
        df -h /opt 2>/dev/null || df -h 2>/dev/null || true
        return 1
    fi
    return 0
}

get_local_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE" 2>/dev/null | head -n1 | tr -d ' \r\n'
        return
    fi
    if [ -x "$BIN_PATH" ]; then
        ver=$("$BIN_PATH" --version 2>/dev/null | head -n1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
        [ -n "$ver" ] && echo "$ver" && return
    fi
    echo ""
}

get_latest_ipk_meta() {
    LATEST_VER=""
    LATEST_IPK_NAME=""
    LATEST_IPK_URL=""
    html=$(_http_get "$PANEL_IPK_BASE/") || true
    [ -n "$html" ] || return 1
    names=$(printf '%s\n' "$html" | grep -oE "telemt-panel_[0-9]+\.[0-9]+\.[0-9]+-[0-9]+_${PANEL_IPK_ARCH}\.ipk" | sort -u) || true
    [ -n "$names" ] || return 1
    best_name=""
    best_a=0; best_b=0; best_c=0; best_r=0
    for n in $names; do
        ver=$(printf '%s\n' "$n" | sed -n "s/^telemt-panel_\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-.*/\1/p")
        rev=$(printf '%s\n' "$n" | sed -n "s/^telemt-panel_[0-9.]*-\([0-9][0-9]*\)_.*/\1/p")
        a=$(echo "$ver" | cut -d. -f1)
        b=$(echo "$ver" | cut -d. -f2)
        c=$(echo "$ver" | cut -d. -f3)
        r=${rev:-0}
        newer=0
        if [ "$a" -gt "$best_a" ] 2>/dev/null; then newer=1
        elif [ "$a" -eq "$best_a" ] 2>/dev/null; then
            if [ "$b" -gt "$best_b" ] 2>/dev/null; then newer=1
            elif [ "$b" -eq "$best_b" ] 2>/dev/null; then
                if [ "$c" -gt "$best_c" ] 2>/dev/null; then newer=1
                elif [ "$c" -eq "$best_c" ] 2>/dev/null && [ "$r" -gt "$best_r" ] 2>/dev/null; then newer=1
                fi
            fi
        fi
        if [ -z "$best_name" ] || [ "$newer" -eq 1 ]; then
            best_name="$n"
            best_a=$a; best_b=$b; best_c=$c; best_r=$r
            LATEST_VER="$ver"
        fi
    done
    [ -n "$best_name" ] || return 1
    LATEST_IPK_NAME="$best_name"
    LATEST_IPK_URL="$PANEL_IPK_BASE/$best_name"
    return 0
}

get_latest_version() {
    if [ "$PANEL_SOURCE" = "ipk" ]; then
        if get_latest_ipk_meta; then
            echo "$LATEST_VER"
            return 0
        fi
        echo ""
        return 0
    fi
    ver=$(_http_get "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | \
        grep '"tag_name"' | head -n1 | cut -d '"' -f 4) || true
    echo "$ver"
}

install_init_script() {
    mkdir -p /opt/etc/init.d /tmp/log /opt/var/run
    cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh

ENABLED=yes
PROCS=telemt-panel
ARGS="-config /opt/etc/$PROCS/config.toml"
PREARGS=""
DESC="Telemt Panel"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
    chmod +x "$INIT_SCRIPT"
}

download_and_install_binary() {
    _ver="$1"
    mkdir -p "$TMPDIR" /opt/sbin "$PANEL_DIR"

    if [ "$PANEL_SOURCE" = "ipk" ]; then
        if [ -z "${LATEST_IPK_URL:-}" ]; then
            get_latest_ipk_meta || true
        fi
        if [ -z "${LATEST_IPK_URL:-}" ]; then
            echo "ERROR: не найден telemt-panel_*.ipk в $PANEL_IPK_BASE/"
            return 1
        fi
        echo "Downloading telemt-panel ipk $_ver..."
        echo "  $LATEST_IPK_URL"
        IPK_PATH="/tmp/telemt-panel_$$.ipk"
        _http_download "$LATEST_IPK_URL" "$IPK_PATH" || { rm -f "$IPK_PATH"; return 1; }
        echo "opkg install $IPK_PATH ..."
        # Depends: telemt — если telemt стоит бинарником без opkg-пакета, нужен --force-depends
        if ! opkg install --force-reinstall "$IPK_PATH"; then
            echo "retry: --force-reinstall --force-depends..."
            if ! opkg install --force-reinstall --force-depends "$IPK_PATH"; then
                if ! opkg install --force-depends "$IPK_PATH"; then
                    echo "ERROR: opkg install failed"
                    rm -f "$IPK_PATH"
                    return 1
                fi
            fi
        fi
        rm -f "$IPK_PATH"
        if [ ! -x "$BIN_PATH" ] && [ -x /opt/sbin/telemt-panel ]; then
            BIN_PATH=/opt/sbin/telemt-panel
        fi
        if [ ! -x "$BIN_PATH" ]; then
            echo "ERROR: binary missing after opkg install"
            return 1
        fi
        echo "$_ver" > "$VERSION_FILE"
        echo "Package installed: telemt-panel $_ver [opkg/ipk]"
        rm -rf "$TMPDIR"
        return 0
    fi

    # GitHub tar.gz (aarch64 / x86_64)
    echo "Downloading telemt-panel $_ver ($PANEL_ARCHIVE)..."
    URL="https://github.com/$GITHUB_REPO/releases/download/${_ver}/${PANEL_ARCHIVE}"
    echo "  $URL"
    ARCHIVE_PATH="$TMPDIR/telemt-panel.tar.gz"
    _http_download "$URL" "$ARCHIVE_PATH" || return 1
    echo "Extracting..."
    tar -xzf "$ARCHIVE_PATH" -C "$TMPDIR"
    BINARY=$(find "$TMPDIR" -type f \( -name 'telemt-panel' -o -name 'telemt-panel-*' \) ! -name '*.tar.gz' 2>/dev/null | head -n1)
    if [ -z "$BINARY" ] || [ ! -f "$BINARY" ]; then
        echo "ERROR: telemt-panel binary not found in archive"
        ls -la "$TMPDIR" || true
        rm -rf "$TMPDIR"
        return 1
    fi
    cp "$BINARY" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    echo "$_ver" > "$VERSION_FILE"
    echo "Binary installed: $BIN_PATH ($_ver)"
    rm -rf "$TMPDIR"
    return 0
}

panel_is_running() {
    if [ -x "$INIT_SCRIPT" ]; then
        out=$("$INIT_SCRIPT" check 2>/dev/null) || true
        echo "$out" | grep -qi alive && return 0
    fi
    pidof telemt-panel >/dev/null 2>&1 && return 0
    return 1
}

start_panel() {
    install_init_script
    if [ -x "$INIT_SCRIPT" ]; then
        if "$INIT_SCRIPT" restart; then
            echo "telemt-panel started OK."
            return 0
        fi
    fi
    echo "WARNING: init start failed, trying foreground check..."
    "$BIN_PATH" -config "$PANEL_CONFIG" >/tmp/telemt-panel-start.err 2>&1 &
    TPID=$!
    sleep 2
    if kill -0 "$TPID" 2>/dev/null; then
        echo "Process running (pid $TPID)."
        return 0
    fi
    tail -n 30 /tmp/telemt-panel-start.err 2>/dev/null || true
    return 1
}

extract_telemt_auth() {
    # auth_header из [server.api]
    awk '
        /^\[server\.api\]/ { inapi=1; next }
        /^\[/ { inapi=0 }
        inapi && $0 ~ /^[[:space:]]*auth_header[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/["'\'' ]/, "")
            print
            exit
        }
    ' "$TELEMT_CONFIG" 2>/dev/null
}

extract_telemt_api_url() {
    listen=$(awk '
        /^\[server\.api\]/ { inapi=1; next }
        /^\[/ { inapi=0 }
        inapi && $0 ~ /^[[:space:]]*listen[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/["'\'' ]/, "")
            print
            exit
        }
    ' "$TELEMT_CONFIG" 2>/dev/null) || true
    listen=${listen:-127.0.0.1:9091}
    case "$listen" in
        *://*) echo "$listen" ;;
        *) echo "http://$listen" ;;
    esac
}

# --- deps + versions ---
ensure_deps 0

HAS_CONFIG=0
HAS_BIN=0
[ -f "$PANEL_CONFIG" ] && HAS_CONFIG=1
[ -x "$BIN_PATH" ] && HAS_BIN=1

LOCAL_VER=$(get_local_version)

# --- 5 последних релизов GitHub (включая Pre-release) ---
# stdout: "tag prerelease" (0|1)
list_panel_releases() {
    _json=""
    for _url in \
        "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=8" \
        "https://ghproxy.net/https://api.github.com/repos/$GITHUB_REPO/releases?per_page=8"
    do
        _json=$(_http_get "$_url") || _json=""
        [ -n "$_json" ] || continue
        case "$_json" in *'"message":'*) continue ;; esac
        printf '%s\n' "$_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"|"prerelease"[[:space:]]*:[[:space:]]*(true|false)' | \
        {
            _tag=""; _n=0
            while IFS= read -r _line || [ -n "$_line" ]; do
                case "$_line" in
                    *'"tag_name"'*)
                        _tag=$(printf '%s' "$_line" | sed -n 's/.*"\([^"]*\)"$/\1/p')
                        ;;
                    *'"prerelease"'*)
                        if [ -n "$_tag" ]; then
                            case "$_line" in
                                *true*) printf '%s 1\n' "$_tag" ;;
                                *)      printf '%s 0\n' "$_tag" ;;
                            esac
                            _tag=""
                            _n=$((_n + 1))
                            [ "$_n" -ge 5 ] && break
                        fi
                        ;;
                esac
            done
        }
        return 0
    done
    return 1
}

# Выбор версии → LATEST_VER. Отмена → exit 0.
pick_panel_version() {
    _tmp="/tmp/telemt-panel-rels-$$"
    _list=$(list_panel_releases 2>/dev/null) || _list=""
    if [ -z "$_list" ]; then
        echo "WARNING: не удалось получить список релизов GitHub — будет latest."
        LATEST_VER=""
        rm -f "$_tmp"
        return 0
    fi
    printf '%s\n' "$_list" | head -5 > "$_tmp"
    _latest_stable=$(awk '$2==0 {print $1; exit}' "$_tmp")

    echo ""
    printf '%s\n' "${BOLD}Выберите версию telemt-panel:${NC}"
    _i=1
    while IFS=' ' read -r _tag _pre; do
        [ -n "$_tag" ] || continue
        if [ "$_pre" = "1" ]; then
            printf '  %d. %s%s%s  %s(Pre-release)%s\n' "$_i" "$YELLOW" "$_tag" "$NC" "$YELLOW" "$NC"
        elif [ -n "$_latest_stable" ] && [ "$_tag" = "$_latest_stable" ]; then
            printf '  %d. %s%s%s  %s(Release — Latest)%s\n' "$_i" "$GREEN" "$_tag" "$NC" "$GREEN" "$NC"
        else
            printf '  %d. %s  (Release)\n' "$_i" "$_tag"
        fi
        _i=$((_i + 1))
    done < "$_tmp"
    echo "  0. Отмена"
    echo ""
    printf "Номер версии [1]: "
    read _choice || true
    case "$_choice" in
        "") _choice=1 ;;
        0|q|Q)
            rm -f "$_tmp"
            echo "Отменено."
            exit 0
            ;;
    esac
    if ! echo "$_choice" | grep -qE '^[0-9]+$' || [ "$_choice" -lt 1 ] || [ "$_choice" -gt 5 ]; then
        rm -f "$_tmp"
        echo "ERROR: неверный выбор."
        exit 1
    fi
    LATEST_VER=$(sed -n "${_choice}p" "$_tmp" | awk '{print $1}')
    rm -f "$_tmp"
    if [ -z "$LATEST_VER" ]; then
        echo "ERROR: версия не найдена."
        exit 1
    fi
    echo "Выбрана версия: $LATEST_VER"
    return 0
}

# Внешний override (env) или интерактивный выбор
if [ -n "${TELEMT_PANEL_VERSION:-}" ]; then
    LATEST_VER="$TELEMT_PANEL_VERSION"
    echo "Requested version: $LATEST_VER (TELEMT_PANEL_VERSION)"
else
    pick_panel_version
    if [ -z "$LATEST_VER" ]; then
        if [ "$PANEL_SOURCE" = "ipk" ]; then
            echo "Detecting latest telemt-panel from $PANEL_IPK_BASE ..."
        else
            echo "Detecting latest telemt-panel from GitHub ($GITHUB_REPO)..."
        fi
        LATEST_VER=$(get_latest_version)
        if [ -z "$LATEST_VER" ]; then
            ensure_deps 1
            LATEST_VER=$(get_latest_version)
        fi
    fi
fi
if [ -z "$LATEST_VER" ]; then
    echo "ERROR: Cannot detect latest telemt-panel version"
    exit 1
fi
echo "Target version: $LATEST_VER"
[ -n "$LOCAL_VER" ] && echo "Installed version: $LOCAL_VER" || echo "Installed version: (none)"

# Сразу после определения версии — проверка места (перед любой установкой/обновлением)
# Пропускаем только если бинарник уже актуален
if ! [ -n "$LOCAL_VER" ] || [ "$LOCAL_VER" != "$LATEST_VER" ] || [ ! -x "$BIN_PATH" ]; then
    check_opt_space 12000 || exit 1
fi

# =====================================================================
# UPDATE: config exists — preserve, update binary only
# =====================================================================
if [ "$HAS_CONFIG" -eq 1 ]; then
    echo ""
    echo "Найден существующий конфиг: $PANEL_CONFIG"
    echo "Настройки сохраняются."

    # подтянуть auth_header из telemt если изменился
    if [ -f "$TELEMT_CONFIG" ]; then
        TM_AUTH=$(extract_telemt_auth) || true
        TM_URL=$(extract_telemt_api_url) || true
        if [ -n "$TM_AUTH" ]; then
            PN_AUTH=$(awk '
                /^\[telemt\]/ { insec=1; next }
                /^\[/ { insec=0 }
                insec && $0 ~ /^[[:space:]]*auth_header[[:space:]]*=/ {
                    sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit
                }
            ' "$PANEL_CONFIG" 2>/dev/null) || true
            if [ -n "$PN_AUTH" ] && [ "$PN_AUTH" != "$TM_AUTH" ]; then
                echo "Синхронизация auth_header telemt → panel..."
                # простое обновление строк
                sed -i "s|^auth_header *=.*|auth_header = \"$TM_AUTH\"|" "$PANEL_CONFIG" 2>/dev/null || true
            fi
            if [ -n "$TM_URL" ]; then
                sed -i "s|^url *=.*|url = \"$TM_URL\"|" "$PANEL_CONFIG" 2>/dev/null || true
            fi
            sed -i "s|^binary_path *=.*telemt\"|binary_path = \"/opt/usr/bin/telemt\"|" "$PANEL_CONFIG" 2>/dev/null || true
        fi
    fi

    if [ -n "$LOCAL_VER" ] && [ "$LOCAL_VER" = "$LATEST_VER" ] && [ "$HAS_BIN" -eq 1 ]; then
        echo "Уже установлена актуальная версия ($LOCAL_VER)."
        echo "$LOCAL_VER" > "$VERSION_FILE"
        install_init_script
        if panel_is_running; then
            echo "telemt-panel уже запущен — restart не требуется."
        else
            start_panel || true
        fi
        echo ""
        echo "=== telemt-panel up-to-date ($LOCAL_VER) ==="
        echo "Config: $PANEL_CONFIG"
        exit 0
    fi

    ensure_deps 1
    echo "Обновление: ${LOCAL_VER:-unknown} → $LATEST_VER"
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    fi
    download_and_install_binary "$LATEST_VER" || exit 1
    install_init_script
    start_panel || true
    echo ""
    echo "=== telemt-panel updated to $LATEST_VER ==="
    echo "Config preserved: $PANEL_CONFIG"
    exit 0
fi

# =====================================================================
# FRESH INSTALL
# =====================================================================
echo ""
echo "Конфиг не найден — полная установка."
ensure_deps 1

if [ ! -f "$TELEMT_CONFIG" ]; then
    printf '%s\n' "${RED}ERROR: $TELEMT_CONFIG не найден. Сначала установите telemt.${NC}"
    exit 1
fi

DEFAULT_PORT=8080
echo "Проверка порта $DEFAULT_PORT..."
if netstat -tuln 2>/dev/null | grep -E "[:.]$DEFAULT_PORT\b" >/dev/null 2>&1; then
    echo "Порт $DEFAULT_PORT занят."
    printf "Введите порт для telemt-panel: "
    read LISTEN_PORT || true
    while [ -z "$LISTEN_PORT" ] || netstat -tuln 2>/dev/null | grep -E "[:.]$LISTEN_PORT\b" >/dev/null 2>&1; do
        echo "Порт занят или пустой."
        printf "Введите другой порт: "
        read LISTEN_PORT || true
    done
else
    LISTEN_PORT=$DEFAULT_PORT
fi
echo "Порт: $LISTEN_PORT"

echo "Введите пароль для входа в панель (admin):"
read PASS || true
if [ -z "$PASS" ]; then
    echo "ERROR: пароль не может быть пустым"
    exit 1
fi

# бинарник нужен для hash-password — ставим сначала
if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
fi
download_and_install_binary "$LATEST_VER" || exit 1

echo "Генерация password_hash..."
PASSWORD_HASH=$(echo "$PASS" | "$BIN_PATH" hash-password 2>&1 | tail -n1)
if [ -z "$PASSWORD_HASH" ]; then
    echo "ERROR: не удалось получить password_hash"
    exit 1
fi
echo "password_hash получен."

JWT_SECRET=$(openssl rand -hex 32)
AUTH_HEADER=$(extract_telemt_auth) || true
if [ -z "$AUTH_HEADER" ]; then
    # fallback: любая строка auth_header
    AUTH_HEADER=$(grep -E '^[[:space:]]*auth_header[[:space:]]*=' "$TELEMT_CONFIG" | head -n1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?.*/\1/') || true
fi
if [ -z "$AUTH_HEADER" ]; then
    printf '%s\n' "${RED}ERROR: auth_header не найден в $TELEMT_CONFIG${NC}"
    exit 1
fi
TELEMT_URL=$(extract_telemt_api_url)

mkdir -p "$PANEL_DIR"
cat > "$PANEL_CONFIG" <<EOF
listen = "0.0.0.0:$LISTEN_PORT"

[telemt]
url = "$TELEMT_URL"
auth_header = "$AUTH_HEADER"
binary_path = "/opt/usr/bin/telemt"

[panel]
binary_path = "/opt/sbin/telemt-panel"

[tls]

[geoip]

[auth]
username = "admin"
password_hash = "$PASSWORD_HASH"
jwt_secret = "$JWT_SECRET"
session_ttl = "24h"

[users]
EOF

install_init_script
start_panel || true

# LAN IP for URL
IP=$(ip -4 -o addr show br0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "$IP" ]; then
    IP=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | head -n1)
fi

echo ""
echo "=== telemt-panel installed ==="
echo "Version: $LATEST_VER"
echo "Config: $PANEL_CONFIG"
echo "Port: $LISTEN_PORT"
echo "Login: admin"
echo "Init: $INIT_SCRIPT"
echo ""
printf '%s\n' "${GREEN}http://${IP:-192.168.1.1}:$LISTEN_PORT${NC}"
printf '%s\n' "${RED}${BOLD}⚠️  Откройте порт $LISTEN_PORT в межсетевом экране (если заходите извне).${NC}"
