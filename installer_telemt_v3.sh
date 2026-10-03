#!/bin/sh

set -e
set -o pipefail

echo "=== Telemt installer for Entware (v3) ==="

CONFIG_DIR="/opt/etc/telemt"
CONFIG_FILE="$CONFIG_DIR/config.toml"
VERSION_FILE="$CONFIG_DIR/.version"
BIN_PATH="/opt/usr/bin/telemt"
INIT_SCRIPT="/opt/etc/init.d/S99telemt"
TMPDIR="/opt/tmp/telemt_dl"

# --- Detect architecture early (for feeds & binary) ---
ARCH=$(uname -m)
case "$ARCH" in
    aarch64)
        TELEMT_FILE="telemt-aarch64-linux-musl.tar.gz"
        ;;
    x86_64|amd64)
        TELEMT_FILE="telemt-x86_64-linux-musl.tar.gz"
        ;;
    mipsel|mips32|mips32r2)
        TELEMT_FILE="telemt-mipsel-linux-musl.tar.gz"
        if ! grep -q 'test.entware.net/mipssf-k3.4/4test/le' /opt/etc/opkg.conf 2>/dev/null; then
            echo "src/gz entware-mipssf-le https://test.entware.net/mipssf-k3.4/4test/le" >> /opt/etc/opkg.conf
            echo "Added mipsel (le) test feed"
        fi
        ;;
    mips)
        TELEMT_FILE="telemt-mips-linux-musl.tar.gz"
        if ! grep -q 'test.entware.net/mipssf-k3.4/4test/be' /opt/etc/opkg.conf 2>/dev/null; then
            echo "src/gz entware-mipssf-be https://test.entware.net/mipssf-k3.4/4test/be" >> /opt/etc/opkg.conf
            echo "Added mips (be) test feed"
        fi
        ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        echo "Supported: aarch64, x86_64, mipsel, mips"
        exit 1
        ;;
esac
echo "Architecture: $ARCH → $TELEMT_FILE"

# --- Helpers ---
get_local_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE" 2>/dev/null | head -n1 | tr -d ' \r\n'
        return
    fi
    if [ -x "$BIN_PATH" ]; then
        ver=$("$BIN_PATH" --version 2>/dev/null | head -n1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
        if [ -n "$ver" ]; then
            echo "$ver"
            return
        fi
    fi
    echo ""
}

get_latest_version() {
    ver=""
    if command -v wget >/dev/null 2>&1; then
        ver=$(wget -qO- https://api.github.com/repos/telemt/telemt/releases/latest 2>/dev/null | \
            grep '"tag_name"' | head -n1 | cut -d '"' -f 4)
    elif command -v curl >/dev/null 2>&1; then
        ver=$(curl -fsSL https://api.github.com/repos/telemt/telemt/releases/latest 2>/dev/null | \
            grep '"tag_name"' | head -n1 | cut -d '"' -f 4)
    fi
    echo "$ver"
}

ensure_deps() {
    # $1 = force (1 = всегда opkg update, 0 = только если чего-то не хватает)
    _force="${1:-0}"
    _need=0
    command -v openssl >/dev/null 2>&1 || _need=1
    command -v jq >/dev/null 2>&1 || _need=1
    command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || _need=1
    if [ "$_force" = "1" ] || [ "$_need" -eq 1 ]; then
        echo "Установка/проверка зависимостей..."
        opkg update
        opkg install openssl-util 2>/dev/null || true
        opkg install jq 2>/dev/null || true
        opkg install wget-ssl 2>/dev/null || opkg install wget 2>/dev/null || true
    fi
}

telemt_is_running() {
    if [ -x "$INIT_SCRIPT" ]; then
        out=$("$INIT_SCRIPT" check 2>/dev/null) || true
        echo "$out" | grep -qi alive && return 0
    fi
    pidof telemt >/dev/null 2>&1 && return 0
    return 1
}

init_script_ok() {
    [ -x "$INIT_SCRIPT" ] || return 1
    # в файле литералы $LOG_FILE / $PROCS (heredoc с кавычками)
    grep -qF 'ARGS="--log-file $LOG_FILE /opt/etc/$PROCS/config.toml"' "$INIT_SCRIPT" 2>/dev/null
}

install_init_script() {
    mkdir -p /opt/etc/init.d /tmp/log /tmp/cache /opt/var/run
    cat > "$INIT_SCRIPT" <<'EOF'
#!/bin/sh

ENABLED=yes
PROCS=telemt
LOG_FILE="/tmp/log/telemt.log"
ARGS="--log-file $LOG_FILE /opt/etc/$PROCS/config.toml"
PREARGS=""
DESC="Telemt MTProxy"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
    chmod +x "$INIT_SCRIPT"
}

download_and_install_binary() {
    _ver="$1"
    echo "Downloading Telemt $_ver ($TELEMT_FILE)..."
    mkdir -p "$TMPDIR"
    TARBALL_URL="https://github.com/telemt/telemt/releases/download/${_ver}/${TELEMT_FILE}"
    TARBALL_PATH="$TMPDIR/telemt.tar.gz"
    echo "  $TARBALL_URL"
    wget -O "$TARBALL_PATH" "$TARBALL_URL"
    echo "Extracting..."
    tar -xzf "$TARBALL_PATH" -C "$TMPDIR"
    TELEMT_BIN=$(find "$TMPDIR" -maxdepth 2 -type f -name telemt 2>/dev/null | head -n 1)
    if [ -z "$TELEMT_BIN" ]; then
        echo "ERROR: telemt binary not found in archive!"
        rm -rf "$TMPDIR"
        return 1
    fi
    mkdir -p /opt/usr/bin
    cp "$TELEMT_BIN" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    mkdir -p "$CONFIG_DIR"
    echo "$_ver" > "$VERSION_FILE"
    echo "Binary installed: $BIN_PATH ($_ver)"
    rm -rf "$TMPDIR"
    return 0
}

start_telemt() {
    mkdir -p /tmp/log /tmp/cache
    if [ -x "$INIT_SCRIPT" ]; then
        if "$INIT_SCRIPT" restart; then
            echo "Telemt started OK."
            return 0
        fi
    fi
    echo "WARNING: init start reported failure. Checking manually..."
    "$BIN_PATH" --log-file /tmp/log/telemt.log "$CONFIG_FILE" >/tmp/log/telemt-start.err 2>&1 &
    TPID=$!
    sleep 2
    if kill -0 "$TPID" 2>/dev/null; then
        echo "Process is running (pid $TPID)."
        return 0
    fi
    echo "Manual start also failed. Last errors:"
    tail -n 40 /tmp/log/telemt-start.err 2>/dev/null || true
    tail -n 40 /tmp/log/telemt.log 2>/dev/null || true
    return 1
}


sync_telemt_panel() {
    PANEL_CFG="/opt/etc/telemt-panel/config.toml"
    PANEL_INIT="/opt/etc/init.d/S99telemt-panel"
    [ -f "$PANEL_CFG" ] || return 0
    [ -f "$CONFIG_FILE" ] || return 0

    echo "Проверка связи telemt-panel ↔ telemt..."

    # auth_header / listen из [server.api] — значение после "=", кавычки снимаем
    TM_AUTH=$(awk '
        /^\[server\.api\]/ { inapi=1; next }
        /^\[/ { inapi=0 }
        inapi && $0 ~ /^[[:space:]]*auth_header[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/["'\'' ]/, "")
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null) || true

    TM_LISTEN=$(awk '
        /^\[server\.api\]/ { inapi=1; next }
        /^\[/ { inapi=0 }
        inapi && $0 ~ /^[[:space:]]*listen[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/["'\'' ]/, "")
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null) || true
    TM_LISTEN=${TM_LISTEN:-127.0.0.1:9091}
    case "$TM_LISTEN" in
        *://*) TM_URL="$TM_LISTEN" ;;
        *) TM_URL="http://$TM_LISTEN" ;;
    esac

    TM_BIN="$BIN_PATH"

    if [ -z "$TM_AUTH" ]; then
        echo "WARNING: auth_header не найден в $CONFIG_FILE — panel не синхронизируем"
        return 0
    fi

    # текущие значения panel
    PN_AUTH=$(awk '
        /^\[telemt\]/ { insec=1; next }
        /^\[/ { insec=0 }
        insec && $0 ~ /^[[:space:]]*auth_header[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit
        }
    ' "$PANEL_CFG" 2>/dev/null) || true
    PN_URL=$(awk '
        /^\[telemt\]/ { insec=1; next }
        /^\[/ { insec=0 }
        insec && $0 ~ /^[[:space:]]*url[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit
        }
    ' "$PANEL_CFG" 2>/dev/null) || true
    PN_BIN=$(awk '
        /^\[telemt\]/ { insec=1; next }
        /^\[/ { insec=0 }
        insec && $0 ~ /^[[:space:]]*binary_path[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit
        }
    ' "$PANEL_CFG" 2>/dev/null) || true

    NEED=0
    [ "$PN_AUTH" != "$TM_AUTH" ] && NEED=1
    [ "$PN_URL" != "$TM_URL" ] && NEED=1
    [ "$PN_BIN" != "$TM_BIN" ] && NEED=1

    if [ "$NEED" -eq 0 ]; then
        echo "telemt-panel: url/auth_header/binary_path уже совпадают с telemt"
        return 0
    fi

    echo "telemt-panel: обновляем [telemt] секцию..."
    echo "  url:          ${PN_URL:-<empty>} → $TM_URL"
    echo "  auth_header:  ${PN_AUTH:-<empty>} → $TM_AUTH"
    echo "  binary_path:  ${PN_BIN:-<empty>} → $TM_BIN"

    # правка через awk: если секция [telemt] есть — обновить поля; иначе дописать
    PANEL_TMP="${PANEL_CFG}.tmp.$$"
    awk -v url="$TM_URL" -v auth="$TM_AUTH" -v bin="$TM_BIN" '
        BEGIN { insec=0; done_url=0; done_auth=0; done_bin=0; has_sec=0 }
        /^\[telemt\]/ {
            print
            insec=1; has_sec=1
            next
        }
        /^\[/ {
            if (insec) {
                if (!done_url)  print "url = \"" url "\""
                if (!done_auth) print "auth_header = \"" auth "\""
                if (!done_bin)  print "binary_path = \"" bin "\""
                insec=0
            }
            print
            next
        }
        insec && /^url[[:space:]]*=/ {
            print "url = \"" url "\""
            done_url=1
            next
        }
        insec && /^auth_header[[:space:]]*=/ {
            print "auth_header = \"" auth "\""
            done_auth=1
            next
        }
        insec && /^binary_path[[:space:]]*=/ {
            print "binary_path = \"" bin "\""
            done_bin=1
            next
        }
        { print }
        END {
            if (insec) {
                if (!done_url)  print "url = \"" url "\""
                if (!done_auth) print "auth_header = \"" auth "\""
                if (!done_bin)  print "binary_path = \"" bin "\""
            } else if (!has_sec) {
                print ""
                print "[telemt]"
                print "url = \"" url "\""
                print "auth_header = \"" auth "\""
                print "binary_path = \"" bin "\""
            }
        }
    ' "$PANEL_CFG" > "$PANEL_TMP" && mv "$PANEL_TMP" "$PANEL_CFG"

    if [ -x "$PANEL_INIT" ]; then
        echo "Перезапуск telemt-panel..."
        "$PANEL_INIT" restart >/dev/null 2>&1 || "$PANEL_INIT" start >/dev/null 2>&1 || true
        echo "telemt-panel restart done."
    else
        echo "WARNING: $PANEL_INIT не найден — перезапустите panel вручную"
    fi
}

# --- Existing install detection ---
HAS_CONFIG=0
HAS_BIN=0
[ -f "$CONFIG_FILE" ] && HAS_CONFIG=1
[ -x "$BIN_PATH" ] && HAS_BIN=1

# Для проверки версии нужен wget/curl; тяжёлый opkg update — только если чего-то нет
ensure_deps 0

LOCAL_VER=$(get_local_version)
echo "Detecting latest Telemt version from GitHub..."
LATEST_VER=$(get_latest_version)
if [ -z "$LATEST_VER" ]; then
    echo "WARNING: не удалось получить latest с GitHub, пробуем с обновлением зависимостей..."
    ensure_deps 1
    LATEST_VER=$(get_latest_version)
fi
if [ -z "$LATEST_VER" ]; then
    echo "ERROR: Cannot detect latest version from GitHub!"
    exit 1
fi
echo "Latest version: $LATEST_VER"
[ -n "$LOCAL_VER" ] && echo "Installed version: $LOCAL_VER" || echo "Installed version: (none)"

# =====================================================================
# UPDATE PATH: config already exists — preserve it, only update binary
# =====================================================================
if [ "$HAS_CONFIG" -eq 1 ]; then
    echo ""
    echo "Найден существующий конфиг: $CONFIG_FILE"
    echo "Настройки сохраняются без изменений."

    if [ -n "$LOCAL_VER" ] && [ "$LOCAL_VER" = "$LATEST_VER" ] && [ "$HAS_BIN" -eq 1 ]; then
        echo "Уже установлена актуальная версия ($LOCAL_VER)."
        mkdir -p "$CONFIG_DIR"
        echo "$LOCAL_VER" > "$VERSION_FILE"
        # init только если отсутствует/устарел (со старым -d)
        if ! init_script_ok; then
            echo "Обновление init-скрипта..."
            install_init_script
        fi
        if telemt_is_running; then
            echo "Telemt уже запущен — restart не требуется."
        else
            echo "Telemt не запущен — стартуем..."
            start_telemt || true
        fi
        echo ""
        echo "=== Telemt up-to-date ($LOCAL_VER) ==="
        echo "Config: $CONFIG_FILE"
        echo "Log: /tmp/log/telemt.log"
        sync_telemt_panel || true
        exit 0
    fi

    # Нужно обновление бинарника — зависимости на всякий случай
    ensure_deps 1
    echo "Обновление бинарника: ${LOCAL_VER:-unknown} → $LATEST_VER"
    if [ -x "$INIT_SCRIPT" ]; then
        echo "Stopping Telemt..."
        "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    fi

    if ! download_and_install_binary "$LATEST_VER"; then
        echo "ERROR: failed to download/install binary"
        start_telemt || true
        exit 1
    fi

    install_init_script
    start_telemt || true

    echo ""
    echo "=== Telemt updated to $LATEST_VER ==="
    echo "Config preserved: $CONFIG_FILE"
    echo "Log: /tmp/log/telemt.log"
    sync_telemt_panel || true
    exit 0
fi

# =====================================================================
# FRESH INSTALL PATH: no config — interactive setup
# =====================================================================
echo ""
echo "Конфиг не найден — полная установка."
ensure_deps 1

echo "Detecting public IP via ip route get..."

ROUTE_INFO=$(ip route get 1.1.1.1 2>/dev/null | head -n1)

if [ -z "$ROUTE_INFO" ]; then
    echo "ERROR: Cannot determine route to 1.1.1.1!"
    exit 1
fi

DEF_IFACE=$(echo "$ROUTE_INFO" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
if [ -z "$DEF_IFACE" ]; then
    echo "ERROR: Cannot detect interface from ip route get!"
    exit 1
fi
case "$DEF_IFACE" in
    *@*) DEF_IFACE=$(echo "$DEF_IFACE" | cut -d'@' -f1) ;;
esac
echo "Default route interface: $DEF_IFACE"

AUTO_IP=$(echo "$ROUTE_INFO" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
if [ -z "$AUTO_IP" ]; then
    echo "ERROR: Cannot detect source IP from ip route get!"
    exit 1
fi
echo "Detected public IP: $AUTO_IP"

echo "Detecting TLS domain (ending with netcraze.io)..."
AUTO_DOMAIN=$(ndmc -c 'ip http ssl acme list' 2>/dev/null | grep "domain:" | awk '{print $2}' | grep "netcraze.io" | head -n 1) || true
echo "Domain: $AUTO_DOMAIN"

printf "Enter port (default 1443): "
read PORT || true
PORT=${PORT:-1443}

printf "Enter listen IP (default 0.0.0.0, detected WAN $AUTO_IP): "
read LISTEN_IP || true
LISTEN_IP=${LISTEN_IP:-0.0.0.0}
case "$LISTEN_IP" in
    *[!0-9a-fA-F:.]*|"")
        echo "WARNING: '$LISTEN_IP' is not a valid IP, using 0.0.0.0"
        LISTEN_IP="0.0.0.0"
        ;;
    *.*|*:*) ;;
    *)
        echo "WARNING: '$LISTEN_IP' is not a valid IP, using 0.0.0.0"
        LISTEN_IP="0.0.0.0"
        ;;
esac

printf "Enter public host for links (IP or domain, default $AUTO_IP): "
read PUBLIC_HOST || true
PUBLIC_HOST=${PUBLIC_HOST:-$AUTO_IP}

printf "Enter TLS domain (default $AUTO_DOMAIN): "
read TLS_DOMAIN || true
TLS_DOMAIN=${TLS_DOMAIN:-$AUTO_DOMAIN}

printf "Enter username (default user1): "
read USERNAME || true
USERNAME=${USERNAME:-user1}

printf "Enable read-only API mode? По умолчанию в telemt-panel вы сможете только просматривать статистику и редактировать конфиг (y/n, default y): "
read READONLY || true
READONLY=${READONLY:-y}
case "$READONLY" in
    y|Y) READONLY_FLAG=true ;;
    n|N) READONLY_FLAG=false ;;
    *) echo "Invalid input, using default: read-only = true"; READONLY_FLAG=true ;;
esac
echo "read-only mode: $READONLY_FLAG"

echo "Generating HEX16 secret..."
USER_SECRET=$(openssl rand -hex 16)
echo "Generated secret: $USER_SECRET"

echo "Generating API auth_header..."
AUTH_HEADER=$(openssl rand -hex 32)
echo "Generated auth_header: $AUTH_HEADER"

echo "Выберите интерфейс, через который прокси будет выходить в мир"
echo "(рекомендуется: $DEF_IFACE — default route к 1.1.1.1)"

_is_junk_iface() {
    case "$1" in
        lo|sit*|ip6tnl*|tunl*|gre*|gretap*|ethoip*|dummy*|ezcfg*|ntce*|xfrms*)
            return 0 ;;
        ra*|rai*|apcli*|apclii*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

_get_ipv4() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | \
        awk '!/^127\./ {print; exit}'
}

_IFACE_LIST=""
_IFACE_HAS_DEF=0
_raw_list=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | tr '\n' ' ') || true
for _raw in $_raw_list; do
    [ -n "$_raw" ] || continue
    if _is_junk_iface "$_raw"; then
        continue
    fi
    _ip4=$(_get_ipv4 "$_raw") || true
    [ -n "$_ip4" ] || continue
    if [ "$_raw" = "$DEF_IFACE" ]; then
        _IFACE_HAS_DEF=1
        _IFACE_LIST="$_raw $_IFACE_LIST"
    else
        _IFACE_LIST="$_IFACE_LIST $_raw"
    fi
done
if [ "$_IFACE_HAS_DEF" -eq 0 ] && [ -n "$DEF_IFACE" ]; then
    _IFACE_LIST="$DEF_IFACE $_IFACE_LIST"
fi
_IFACE_LIST=$(echo "$_IFACE_LIST" | awk '{for(i=1;i<=NF;i++) if(!seen[$i]++) printf "%s%s", (n++?" ":""), $i}')

echo "Доступные интерфейсы (UP + IPv4):"
i=1
for iface in $_IFACE_LIST; do
    [ -n "$iface" ] || continue
    _ip4=$(_get_ipv4 "$iface") || true
    _mark=""
    [ "$iface" = "$DEF_IFACE" ] && _mark=" ← default route"
    if [ -n "$_ip4" ]; then
        echo "  $i) $iface ($_ip4)$_mark"
    else
        echo "  $i) $iface$_mark"
    fi
    eval "iface_$i=\$iface"
    i=$((i+1))
done

COUNT=$((i-1))
if [ "$COUNT" -lt 1 ]; then
    echo "WARNING: не найдено подходящих интерфейсов, используем $DEF_IFACE"
    UP_IFACE="$DEF_IFACE"
else
    printf "Select upstream interface number (default 1 = %s): " "$DEF_IFACE"
    read IFNUM || true
    IFNUM=${IFNUM:-1}
    if [ "$IFNUM" -ge 1 ] 2>/dev/null && [ "$IFNUM" -le "$COUNT" ] 2>/dev/null; then
        eval "UP_IFACE=\$iface_$IFNUM"
    else
        echo "Invalid number, using default: $DEF_IFACE"
        UP_IFACE="$DEF_IFACE"
    fi
fi
UP_IFACE=${UP_IFACE:-$DEF_IFACE}
echo "Selected interface: $UP_IFACE"

while true; do
    echo "Checking if port $PORT is free..."
    if netstat -tuln 2>/dev/null | grep -E "[:.]$PORT\b" >/dev/null 2>&1; then
        echo "Port $PORT is already in use!"
        printf "Enter another port: "
        read PORT || true
    else
        echo "Port OK."
        break
    fi
done

echo "Checking domain resolution..."
if ! nslookup "$TLS_DOMAIN" 2>/dev/null | grep -q 'Address'; then
    echo "WARNING: Domain $TLS_DOMAIN does not resolve!"
    echo "Press Enter to continue anyway or Ctrl+C to abort."
    read _ || true
else
    echo "Domain OK."
fi

echo "=== Installing Telemt $LATEST_VER ==="
if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
fi
download_and_install_binary "$LATEST_VER" || exit 1
install_init_script

mkdir -p "$CONFIG_DIR/tlsfront" /tmp/log /tmp/cache
cd "$CONFIG_DIR"

echo "Writing config.toml..."

cat > config.toml <<EOF
[general]
use_middle_proxy = false
log_level = "silent"
upstream_connect_failfast_hard_errors = false
beobachten_file = "/tmp/cache/beobachten.txt"

[general.links]
show = "*"
public_host = "$PUBLIC_HOST"
public_port = $PORT

[server]
port = $PORT

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = [ "127.0.0.1/32", "::1/128" ]
minimal_runtime_enabled = true
minimal_runtime_cache_ttl_ms = 1000
read_only = $READONLY_FLAG
auth_header = "$AUTH_HEADER"

[[server.listeners]]
ip = "$LISTEN_IP"

[censorship]
tls_domain = "$TLS_DOMAIN"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"
mask_host = "$TLS_DOMAIN"
mask_shape_hardening_aggressive_mode = true

[access.users]
$USERNAME = "$USER_SECRET"

[[upstreams]]
type = "direct"
bindtodevice = "$UP_IFACE"
EOF

start_telemt || true

echo ""
echo "=== Telemt installed ==="
echo "Version: $LATEST_VER"
echo "Port: $PORT"
echo "Listen IP: $LISTEN_IP"
echo "Public host (links): $PUBLIC_HOST"
echo "TLS domain: $TLS_DOMAIN"
echo "User: $USERNAME"
echo "Secret: $USER_SECRET"
echo "Upstream interface: $UP_IFACE"
echo "tlsfront directory: $CONFIG_DIR/tlsfront"
echo "Log: /tmp/log/telemt.log"
echo ""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    curl -H "Authorization: $AUTH_HEADER" -s --connect-timeout 3 http://127.0.0.1:9091/v1/users 2>/dev/null | \
        jq -r '.data[] | "[\(.username)]", (.links.classic[]? | "classic: \(.)"), (.links.secure[]? | "secure: \(.)"), (.links.tls[]? | "tls: \(.)"), ""' 2>/dev/null || true
fi
echo ""
echo "⚠️ Не забудьте открыть порт $PORT в межсетевом экране!!!"
echo "Межсетевой экран -> Добавить правило -> Порт назначения равен $PORT. ✅ Включить правило. -> Сохранить"
echo "⚠️Если у вас не внешний IP, т.е. от провайдера вы получаете IP первый октет(цифра) которого 10|100|172|192, то подключиться к прокси вы сможете только внутри вашей локальной сети.⚠️"
sync_telemt_panel || true
