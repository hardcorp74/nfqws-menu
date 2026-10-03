#!/bin/sh

set -e
set -o pipefail

echo "=== Telemt installer for Entware (v3) ==="

# ANSI-цвета (printf — portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
YELLOW=$(printf '\033[1;33m')
GREEN=$(printf '\033[0;32m')
BOLD=$(printf '\033[1m')
NC=$(printf '\033[0m')

CONFIG_DIR="/opt/etc/telemt"
CONFIG_FILE="$CONFIG_DIR/config.toml"
VERSION_FILE="$CONFIG_DIR/.version"
BIN_PATH="/opt/usr/bin/telemt"
INIT_SCRIPT="/opt/etc/init.d/S99telemt"
TMPDIR="/tmp/telemt_dl"

# --- Detect architecture (как в nfqws-menu.sh) ---
# На Keenetic uname -m для mips/mipsel часто врёт → сначала opkg / opkg.conf.
# mipsel* проверяем ДО mips*.

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

detect_telemt_arch() {
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

    # uname: mips/mipsel на Keenetic не доверяем
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

detect_telemt_arch

case "$ARCH" in
    aarch64)
        TELEMT_SOURCE="github"
        TELEMT_FILE="telemt-aarch64-linux-musl.tar.gz"
        ;;
    x86_64)
        TELEMT_SOURCE="github"
        TELEMT_FILE="telemt-x86_64-linux-musl.tar.gz"
        ;;
    mipsel)
        # GitHub releases без mipsel — ставим .ipk с test.entware (нет Packages.gz)
        TELEMT_SOURCE="ipk"
        TELEMT_IPK_BASE="https://test.entware.net/mipssf-k3.4/4test/le"
        TELEMT_IPK_ARCH="mipsel-3.4"
        TELEMT_FILE=""
        ;;
    mips)
        TELEMT_SOURCE="ipk"
        TELEMT_IPK_BASE="https://test.entware.net/mipssf-k3.4/4test/be"
        TELEMT_IPK_ARCH="mips-3.4"
        TELEMT_FILE=""
        ;;
    *)
        echo "ERROR: Unsupported or unknown architecture: '${ARCH:-?}' (raw=${ARCH_RAW:-?}, src=${ARCH_SOURCE:-none})"
        echo "uname -m: $(uname -m 2>/dev/null || true)"
        echo "opkg print-architecture:"
        opkg print-architecture 2>/dev/null || true
        echo "Supported: aarch64, x86_64, mipsel, mips"
        exit 1
        ;;
esac
if [ "$TELEMT_SOURCE" = "ipk" ]; then
    echo "Architecture: $ARCH → ipk from $TELEMT_IPK_BASE (detect: ${ARCH_SOURCE:-?}, raw: ${ARCH_RAW:-?})"
else
    echo "Architecture: $ARCH → $TELEMT_FILE (detect: ${ARCH_SOURCE:-?}, raw: ${ARCH_RAW:-?})"
fi

# --- Helpers ---

# Свободное место на /opt (kB). $1 = минимум kB
check_opt_space() {
    _need_kb="${1:-11000}"
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
        if [ -n "$ver" ]; then
            echo "$ver"
            return
        fi
    fi
    echo ""
}

_http_get() {
    if command -v wget >/dev/null 2>&1; then
        wget -qO- "$1" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" 2>/dev/null
    fi
}

# latest telemt_X.Y.Z-N_<arch>.ipk из directory listing (без Packages.gz)
get_latest_ipk_meta() {
    # выставляет: LATEST_VER, LATEST_IPK_NAME, LATEST_IPK_URL
    LATEST_VER=""
    LATEST_IPK_NAME=""
    LATEST_IPK_URL=""
    html=$(_http_get "$TELEMT_IPK_BASE/") || true
    [ -n "$html" ] || return 1
    # telemt_3.5.7-1_mipsel-3.4.ipk
    names=$(printf '%s\n' "$html" | grep -oE "telemt_[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+_${TELEMT_IPK_ARCH}\\.ipk" | sort -u) || true
    [ -n "$names" ] || return 1
    # выбрать максимальный X.Y.Z-N (portable, без sort -V)
    best_name=""
    best_a=0; best_b=0; best_c=0; best_r=0
    for n in $names; do
        ver=$(printf '%s\n' "$n" | sed -n "s/^telemt_\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-.*/\1/p")
        rev=$(printf '%s\n' "$n" | sed -n "s/^telemt_[0-9.]*-\([0-9][0-9]*\)_.*/\1/p")
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
    LATEST_IPK_URL="$TELEMT_IPK_BASE/$best_name"
    return 0
}

get_latest_version() {
    ver=""
    if [ "${TELEMT_SOURCE:-github}" = "ipk" ]; then
        if get_latest_ipk_meta; then
            echo "$LATEST_VER"
            return 0
        fi
        echo ""
        return 0
    fi
    ver=$(_http_get https://api.github.com/repos/telemt/telemt/releases/latest | \
        grep '"tag_name"' | head -n1 | cut -d '"' -f 4) || true
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
    mkdir -p "$TMPDIR" /opt/usr/bin "$CONFIG_DIR"

    if [ "${TELEMT_SOURCE:-github}" = "ipk" ]; then
        # mips/mipsel: .ipk с test.entware (нет Packages.gz)
        # config.toml в conffiles — opkg не перезапишет существующий
        if [ -z "${LATEST_IPK_URL:-}" ] || [ -z "${LATEST_IPK_NAME:-}" ]; then
            get_latest_ipk_meta || true
        fi
        if [ -z "${LATEST_IPK_URL:-}" ]; then
            echo "ERROR: не найден telemt_*.ipk в $TELEMT_IPK_BASE/"
            return 1
        fi
        echo "Downloading Telemt ipk $_ver..."
        echo "  $LATEST_IPK_URL"
        # /tmp обычно tmpfs — не жрём место на /opt
        IPK_PATH="/tmp/telemt_$$.ipk"
        if command -v wget >/dev/null 2>&1; then
            wget -O "$IPK_PATH" "$LATEST_IPK_URL" || { rm -f "$IPK_PATH"; return 1; }
        else
            curl -fL -o "$IPK_PATH" "$LATEST_IPK_URL" || { rm -f "$IPK_PATH"; return 1; }
        fi
        echo "opkg install $IPK_PATH ..."
        # --force-reinstall: обновить уже стоящий пакет; conffiles сохранят config.toml
        if ! opkg install --force-reinstall "$IPK_PATH"; then
            echo "opkg install --force-reinstall failed, trying plain install..."
            if ! opkg install "$IPK_PATH"; then
                echo "ERROR: opkg install failed (мало места на /opt? df -h /opt)"
                rm -f "$IPK_PATH"
                return 1
            fi
        fi
        rm -f "$IPK_PATH"
        if [ ! -x "$BIN_PATH" ]; then
            # на всякий случай — путь из пакета
            if [ -x /opt/usr/bin/telemt ]; then
                BIN_PATH=/opt/usr/bin/telemt
            else
                echo "ERROR: telemt binary missing after opkg install"
                return 1
            fi
        fi
        mkdir -p "$CONFIG_DIR"
        echo "$_ver" > "$VERSION_FILE"
        echo "Package installed: telemt $_ver [opkg/ipk]"
        return 0
    fi

    echo "Downloading Telemt $_ver ($TELEMT_FILE)..."
    TARBALL_URL="https://github.com/telemt/telemt/releases/download/${_ver}/${TELEMT_FILE}"
    TARBALL_PATH="$TMPDIR/telemt.tar.gz"
    echo "  $TARBALL_URL"
    if command -v wget >/dev/null 2>&1; then
        wget -O "$TARBALL_PATH" "$TARBALL_URL" || return 1
    else
        curl -fL -o "$TARBALL_PATH" "$TARBALL_URL" || return 1
    fi
    echo "Extracting..."
    tar -xzf "$TARBALL_PATH" -C "$TMPDIR"
    TELEMT_BIN=$(find "$TMPDIR" -maxdepth 2 -type f -name telemt 2>/dev/null | head -n 1)
    if [ -z "$TELEMT_BIN" ]; then
        echo "ERROR: telemt binary not found in archive!"
        rm -rf "$TMPDIR"
        return 1
    fi
    cp "$TELEMT_BIN" "$BIN_PATH"
    chmod +x "$BIN_PATH"
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
if [ "${TELEMT_SOURCE:-github}" = "ipk" ]; then
    echo "Detecting latest Telemt version from $TELEMT_IPK_BASE ..."
else
    echo "Detecting latest Telemt version from GitHub..."
fi
LATEST_VER=$(get_latest_version)
if [ -z "$LATEST_VER" ]; then
    echo "WARNING: не удалось получить latest с GitHub, пробуем с обновлением зависимостей..."
    ensure_deps 1
    LATEST_VER=$(get_latest_version)
fi
if [ -z "$LATEST_VER" ]; then
    echo "ERROR: Cannot detect latest Telemt version!"
    exit 1
fi
echo "Latest version: $LATEST_VER"
[ -n "$LOCAL_VER" ] && echo "Installed version: $LOCAL_VER" || echo "Installed version: (none)"

# Сразу после определения версии — проверка места (перед любой установкой/обновлением)
# Пропускаем только если бинарник уже актуален
if ! [ -n "$LOCAL_VER" ] || [ "$LOCAL_VER" != "$LATEST_VER" ] || [ ! -x "$BIN_PATH" ]; then
    check_opt_space 11000 || exit 1
fi

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

echo "Detecting default route interface..."

# НЕ используем «ip route get 1.1.1.1» — на Keenetic часто уходит в WARP/WG
# (host-route 1.1.1.1 → nwg*), хотя default — ppp0.
DEF_IFACE=$(ip -4 route show default 2>/dev/null | awk '
    /^default/ {
        for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }
')
if [ -z "$DEF_IFACE" ]; then
    DEF_IFACE=$(ip route 2>/dev/null | awk '
        /^default/ {
            for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
        }
    ')
fi
if [ -z "$DEF_IFACE" ]; then
    # fallback: route -n
    DEF_IFACE=$(route -n 2>/dev/null | awk '$1 == "0.0.0.0" { print $NF; exit }')
fi
if [ -z "$DEF_IFACE" ]; then
    echo "ERROR: Cannot detect default route interface!"
    exit 1
fi
case "$DEF_IFACE" in
    *@*) DEF_IFACE=$(echo "$DEF_IFACE" | cut -d'@' -f1) ;;
esac
echo "Default route interface: $DEF_IFACE"

# IP с интерфейса default route (не src из route get 1.1.1.1)
AUTO_IP=$(ip -4 -o addr show dev "$DEF_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | awk '!/^127\./ {print; exit}')
if [ -z "$AUTO_IP" ]; then
    AUTO_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
fi
if [ -z "$AUTO_IP" ]; then
    echo "ERROR: Cannot detect WAN IP on $DEF_IFACE!"
    exit 1
fi
echo "Detected WAN IP ($DEF_IFACE): $AUTO_IP"

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

echo ""
echo "Режим read_only API (telemt):"
echo "  1 — (true)  только чтение: статистика и просмотр конфига в панели"
echo "  2 — (false) полный доступ API: пользователи, секреты, управление"
printf "Включить режим только чтения? (1/2, по умолчанию: 1): "
read READONLY || true
READONLY=${READONLY:-1}
case "$READONLY" in
    1|y|Y) READONLY_FLAG=true ;;
    2|n|N) READONLY_FLAG=false ;;
    *) echo "Неверный ввод, оставляем read-only = true"; READONLY_FLAG=true ;;
esac
echo "API read_only: $READONLY_FLAG"

echo "Generating HEX16 secret..."
USER_SECRET=$(openssl rand -hex 16)
echo "Generated secret: $USER_SECRET"

echo "Generating API auth_header..."
AUTH_HEADER=$(openssl rand -hex 32)
echo "Generated auth_header: $AUTH_HEADER"

echo "Выберите интерфейс, через который прокси будет выходить в мир"
echo "(рекомендуется: $DEF_IFACE — default route)"

_is_junk_iface() {
    case "$1" in
        lo|sit*|ip6tnl*|tunl*|gre*|gretap*|ethoip*|dummy*|ezcfg*|ntce*|xfrms*)
            return 0 ;;
        ra*|rai*|apcli*|apclii*)
            return 0 ;;
        br[0-9]*)
            # LAN bridge — не для upstream
            return 0 ;;
        *)
            return 1 ;;
    esac
}

_get_ipv4() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | \
        awk '!/^127\./ {print; exit}'
}

# RCI: description по IPv4 (http://127.0.0.1:79/rci/show/interface)
_RCI_DESC_FILE="/tmp/telemt_rci_iface_desc.$$"
rm -f "$_RCI_DESC_FILE"
_rci_json=""
if command -v curl >/dev/null 2>&1; then
    _rci_json=$(curl -s --connect-timeout 2 --max-time 4 "http://127.0.0.1:79/rci/show/interface" 2>/dev/null) || true
elif command -v wget >/dev/null 2>&1; then
    _rci_json=$(wget -qO- -T 4 "http://127.0.0.1:79/rci/show/interface" 2>/dev/null) || true
fi
if [ -n "$_rci_json" ] && command -v jq >/dev/null 2>&1; then
    # address|description (или interface-name / id)
    printf '%s\n' "$_rci_json" | jq -r '
        .. | objects |
        select(has("address") and (.address | type == "string") and (.address | test("^[0-9]+\\."))) |
        "\(.address)|\(if (.description // "") != "" then .description
            elif (.["interface-name"] // "") != "" then .["interface-name"]
            else (.id // "") end)"
    ' 2>/dev/null | while IFS= read -r _line; do
        [ -n "$_line" ] && printf '%s\n' "$_line"
    done > "$_RCI_DESC_FILE" || true
elif [ -n "$_rci_json" ]; then
    # без jq: грубый разбор пар address + ближайший description
    printf '%s\n' "$_rci_json" | awk '
        /"address"[[:space:]]*:[[:space:]]*"[0-9]+\./ {
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
                addr = substr($0, RSTART, RLENGTH)
            }
        }
        /"description"[[:space:]]*:/ {
            if (match($0, /"description"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                line = substr($0, RSTART, RLENGTH)
                sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*/, "", line)
                desc = line
            }
        }
        /"interface-name"[[:space:]]*:/ {
            if (desc == "" && match($0, /"interface-name"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
                line = substr($0, RSTART, RLENGTH)
                sub(/.*"interface-name"[[:space:]]*:[[:space:]]*"/, "", line)
                sub(/".*/, "", line)
                iname = line
            }
        }
        /^[[:space:]]*\}/ {
            if (addr != "") {
                d = desc
                if (d == "") d = iname
                if (d != "") print addr "|" d
            }
            addr = ""; desc = ""; iname = ""
        }
    ' > "$_RCI_DESC_FILE" 2>/dev/null || true
fi

_get_rci_desc() {
    _ip="$1"
    [ -n "$_ip" ] && [ -f "$_RCI_DESC_FILE" ] || { echo ""; return 0; }
    awk -F'|' -v ip="$_ip" '$1 == ip { print $2; exit }' "$_RCI_DESC_FILE" 2>/dev/null
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
    _desc=$(_get_rci_desc "$_ip4") || true
    _mark=""
    [ "$iface" = "$DEF_IFACE" ] && _mark=" ← default route"
    _extra=""
    [ -n "$_desc" ] && _extra=" — $_desc"
    if [ -n "$_ip4" ]; then
        echo "  $i) $iface ($_ip4)$_extra$_mark"
    else
        echo "  $i) $iface$_extra$_mark"
    fi
    eval "iface_$i=\$iface"
    i=$((i+1))
done
rm -f "$_RCI_DESC_FILE" 2>/dev/null || true

COUNT=$((i-1))
if [ "$COUNT" -lt 1 ]; then
    echo "WARNING: не найдено подходящих интерфейсов, используем $DEF_IFACE"
    UP_IFACE="$DEF_IFACE"
else
    printf "Интерфейс (номер 1-%s или имя, по умолчанию 1 = %s): " "$COUNT" "$DEF_IFACE"
    read IFSEL || true
    IFSEL=$(echo "${IFSEL:-1}" | tr -d ' \t\r')
    UP_IFACE=""
    # число из списка
    if [ "$IFSEL" -ge 1 ] 2>/dev/null && [ "$IFSEL" -le "$COUNT" ] 2>/dev/null; then
        eval "UP_IFACE=\$iface_$IFSEL"
    else
        # имя интерфейса (eth3, ppp0, nwg1, ...)
        case "$IFSEL" in
            *@*) IFSEL=$(echo "$IFSEL" | cut -d'@' -f1) ;;
        esac
        # есть в нашем списке?
        for iface in $_IFACE_LIST; do
            if [ "$iface" = "$IFSEL" ]; then
                UP_IFACE="$IFSEL"
                break
            fi
        done
        # вручную: проверяем существование в системе
        if [ -z "$UP_IFACE" ]; then
            if ip link show dev "$IFSEL" >/dev/null 2>&1; then
                UP_IFACE="$IFSEL"
                echo "Интерфейс $UP_IFACE принят (вне списка)."
            else
                echo "Интерфейс '$IFSEL' не найден — используем default: $DEF_IFACE"
                UP_IFACE="$DEF_IFACE"
            fi
        fi
    fi
fi
UP_IFACE=${UP_IFACE:-$DEF_IFACE}
# финальная проверка
if ! ip link show dev "$UP_IFACE" >/dev/null 2>&1; then
    echo "ERROR: интерфейс '$UP_IFACE' не существует в системе!"
    exit 1
fi
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
printf '%s\n' "${RED}${BOLD}⚠️  Не забудьте открыть порт $PORT в межсетевом экране!${NC}"
printf '%s\n' "${RED}   Межсетевой экран → Добавить правило → Порт назначения = $PORT → ✅ Включить → Сохранить${NC}"

# «Серый» IP: RFC1918 + CGNAT 100.64/10 — только тогда предупреждаем
_is_grey_ip() {
    _ip="$1"
    case "$_ip" in
        10.*|192.168.*|127.*) return 0 ;;
        169.254.*) return 0 ;;
        100.*)
            _o2=$(echo "$_ip" | cut -d. -f2)
            [ "$_o2" -ge 64 ] 2>/dev/null && [ "$_o2" -le 127 ] 2>/dev/null && return 0
            return 1
            ;;
        172.*)
            _o2=$(echo "$_ip" | cut -d. -f2)
            [ "$_o2" -ge 16 ] 2>/dev/null && [ "$_o2" -le 31 ] 2>/dev/null && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}
_check_ip="$AUTO_IP"
# если public_host — тоже IP, проверяем его
case "$PUBLIC_HOST" in
    *[!0-9.]*|"") ;;
    *) _check_ip="$PUBLIC_HOST" ;;
esac
if _is_grey_ip "$_check_ip"; then
    echo ""
    printf '%s\n' "${RED}${BOLD}⚠️  Обнаружен «серый» IP: $_check_ip${NC}"
    printf '%s\n' "${RED}   Адрес из частных/CGNAT диапазонов (10.x / 100.64–127.x / 172.16–31.x / 192.168.x).${NC}"
    printf '%s\n' "${RED}   С интернета к прокси, скорее всего, не подключиться — только из вашей локальной сети.${NC}"
    printf '%s\n' "${RED}   Нужен белый IP, проброс порта у провайдера или туннель (VPN/WARP и т.п.).${NC}"
fi
sync_telemt_panel || true
