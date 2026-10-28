#!/bin/sh
# installer_warpscout.sh — меню warpscout для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/vernette/warpscout
# Обёртка: https://github.com/rndnaame/nfqws-menu
#
# Версионирование (MAJOR.MINOR.PATCH): при любых правках бампать SCRIPT_VERSION.
#   PATCH — мелкие фиксы; MINOR — новое поведение; MAJOR — ломающие изменения.
#
# 1) Установка / обновление warpscout
# 2) Создать аккаунт (warpscout register)
# 3) Сканирование адресов (AWG → list + conf)
# 4) Применить conf в awg-manager (если установлен)
# 88) Удаление
#
# Запуск:
#   sh installer_warpscout.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_warpscout.sh | sh

SCRIPT_VERSION="0.1.9"

# ANSI (portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
BLUE=$(printf '\033[0;34m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[!]${NC} $*"; }

BIN="/opt/bin/warpscout"
ACCOUNT_FILE="/opt/root/warpscout-account.json"
SCAN_OUT="/opt/root/warpscout-awg.list"
CONF_OUT="/opt/root/warpscout-awg.conf"
GITHUB_REPO="vernette/warpscout"
# фиксированная версия с готовым mipsel-бинарником в этом репозитории
PIN_VERSION="0.16.1"
ARM64_URL="https://github.com/vernette/warpscout/releases/download/v${PIN_VERSION}/warpscout_${PIN_VERSION}_linux_arm64.tar.gz"
MIPSEL_URL="https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/warpscout/warpscout-${PIN_VERSION}-mipsle"
AWG_SETTINGS="/opt/etc/awg-manager/settings.json"
AWG_API_KEY_FILE="/opt/etc/awg-manager/.api_key"
TMPDIR="/tmp/warpscout-installer-$$"
trap 'rm -rf "$TMPDIR" 2>/dev/null' EXIT INT TERM

# ---------------------------------------------------------------------------
# Архитектура
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""

_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)             echo "aarch64" ;;
    armv7*|armv6*|arm*)          echo "" ;;
    mipsel*|mipselsf*|mips64el*) echo "mipsel" ;;
    mips*|mipssf*)               echo "mips" ;;
    x86_64*|amd64*|x64*)         echo "x86_64" ;;
    i[3-6]86*|x86*|i686*)        echo "x86" ;;
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
  name=$(grep -E '^[[:space:]]*arch[[:space:]]+' "$conf" 2>/dev/null | _arch_pick_best)
  [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      src/gz*|src\ *)
        case "$line" in
          *mipselsf*|*mips64el*) printf '%s\n' "mipselsf"; return 0 ;;
          *mipssf*)              printf '%s\n' "mipssf"; return 0 ;;
          *aarch64*|*arm64*)     printf '%s\n' "aarch64"; return 0 ;;
        esac
        ;;
    esac
  done < "$conf"
}

detect_arch() {
  ARCH=""
  ARCH_RAW=""
  ARCH_SOURCE=""

  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  [ -n "$ARCH" ] && ARCH_SOURCE="opkg"

  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf)
    ARCH=$(_arch_normalize "$ARCH_RAW")
    [ -n "$ARCH" ] && ARCH_SOURCE="conf"
  fi

  if [ -z "$ARCH" ]; then
    um=$(uname -m 2>/dev/null)
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
  [ -z "$ARCH_SOURCE" ] && ARCH_SOURCE="none"
}

need_arch() {
  [ -z "$ARCH" ] && detect_arch
  if [ -z "$ARCH" ]; then
    error "Не удалось определить архитектуру."
    return 1
  fi
  case "$ARCH" in
    aarch64|mipsel)
      return 0
      ;;
    mips)
      error "mips (big-endian) не поддерживается — нужен mipsel-бинарник."
      return 1
      ;;
    *)
      error "Архитектура $ARCH не поддерживается (нужны aarch64 / mipsel)."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# HTTP / зеркала
# ---------------------------------------------------------------------------
github_alt_urls() {
  url="$1"
  case "$url" in
    https://github.com/*/releases/download/*)
      printf '%s\n' "$url"
      printf '%s\n' "https://ghproxy.net/${url}"
      printf '%s\n' "https://mirror.ghproxy.com/${url}"
      printf '%s\n' "https://gh.ddlc.top/${url}"
      printf '%s\n' "https://gitproxy.click/${url}"
      ;;
    https://raw.githubusercontent.com/*)
      rest="${url#https://raw.githubusercontent.com/}"
      owner="${rest%%/*}"; rest="${rest#*/}"
      repo="${rest%%/*}"; rest="${rest#*/}"
      ref="${rest%%/*}"; path_rest="${rest#*/}"
      printf '%s\n' "$url"
      if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$ref" ]; then
        printf '%s\n' "https://fastly.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path_rest}"
        printf '%s\n' "https://cdn.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path_rest}"
      fi
      printf '%s\n' "https://ghproxy.net/${url}"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

_http_get_one() {
  u="$1"
  d="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 180 "$u" -o "$d" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$d" -T 180 "$u" 2>/dev/null
  else
    return 1
  fi
}

http_get() {
  url="$1"
  dest="$2"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    error "Нужны curl или wget."
    return 1
  fi
  rm -f "$dest"
  for alt in $(github_alt_urls "$url"); do
    [ -n "$alt" ] || continue
    info "Пробуем: $alt"
    if _http_get_one "$alt" "$dest" && [ -s "$dest" ]; then
      [ "$alt" != "$url" ] && info "Скачано через зеркало"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
read_choice() {
  if [ -c /dev/tty ]; then
    read -r choice < /dev/tty
  else
    read -r choice
  fi
  printf '%s' "$choice"
}

confirm_yes() {
  printf '%s' "${YELLOW}[?]${NC} $1 [y/N]: "
  c=$(read_choice)
  case "$c" in
    y|Y|yes|YES|д|Д|да|Да) return 0 ;;
    *) return 1 ;;
  esac
}

pause() {
  printf '%s' "${DIM}Нажмите Enter...${NC} "
  read_choice >/dev/null
}

is_installed() {
  [ -x "$BIN" ]
}

installed_version() {
  if [ -x "$BIN" ]; then
    v=$("$BIN" version 2>/dev/null | head -1)
    if [ -n "$v" ]; then
      printf '%s\n' "$v" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
      return 0
    fi
  fi
  return 1
}

has_account() {
  [ -f "$ACCOUNT_FILE" ] && [ -s "$ACCOUNT_FILE" ]
}

has_conf() {
  [ -f "$CONF_OUT" ] && [ -s "$CONF_OUT" ]
}

is_awg_manager_installed() {
  if opkg list-installed 2>/dev/null | grep -q '^awg-manager '; then
    return 0
  fi
  [ -d /opt/etc/awg-manager ]
}

show_status() {
  st=""
  if is_installed; then
    ver=$(installed_version 2>/dev/null) || ver=""
    st="bin ${ver:-ok}"
  fi
  if has_account; then
    st="${st:+$st, }аккаунт ✓"
  else
    st="${st:+$st, }аккаунт ✗"
  fi
  if [ -f "$SCAN_OUT" ] && [ -s "$SCAN_OUT" ]; then
    n=$(wc -l < "$SCAN_OUT" 2>/dev/null | tr -d ' ')
    st="${st:+$st, }list ${n:-?} строк"
  fi
  if has_conf; then
    st="${st:+$st, }conf ✓"
  fi
  if is_awg_manager_installed; then
    st="${st:+$st, }awg-manager ✓"
  fi
  if [ -n "$st" ]; then
    info "Обнаружено: $st"
  else
    printf '%s\n' "${DIM}Не установлено${NC}"
  fi
}

# ---------------------------------------------------------------------------
# 1) Установка / обновление
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка / обновление warpscout"
  need_arch || return 1

  mkdir -p /opt/bin /opt/root "$TMPDIR" 2>/dev/null || true

  case "$ARCH" in
    aarch64)
      archive="$TMPDIR/warpscout.tar.gz"
      info "Архитектура: aarch64 → ${ARM64_URL}"
      if ! http_get "$ARM64_URL" "$archive"; then
        error "Не удалось скачать архив."
        return 1
      fi
      sz=$(wc -c < "$archive" 2>/dev/null | tr -d ' ')
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
      if [ "$sz" -lt 100000 ]; then
        error "Архив слишком маленький (${sz} байт) — обрыв или HTML-ошибка."
        return 1
      fi
      info "Распаковка..."
      if ! tar -xzf "$archive" -C "$TMPDIR" 2>/dev/null; then
        error "Не удалось распаковать архив."
        return 1
      fi
      src=""
      if [ -f "$TMPDIR/warpscout" ]; then
        src="$TMPDIR/warpscout"
      else
        src=$(find "$TMPDIR" -type f -name 'warpscout' 2>/dev/null | head -1)
      fi
      if [ -z "$src" ] || [ ! -f "$src" ]; then
        error "В архиве не найден бинарник warpscout."
        return 1
      fi
      ;;
    mipsel)
      src="$TMPDIR/warpscout"
      info "Архитектура: mipsel → ${MIPSEL_URL}"
      if ! http_get "$MIPSEL_URL" "$src"; then
        error "Не удалось скачать mipsel-бинарник."
        return 1
      fi
      sz=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
      if [ "$sz" -lt 100000 ]; then
        error "Файл слишком маленький (${sz} байт) — обрыв или HTML-ошибка."
        return 1
      fi
      ;;
    *)
      error "Неподдерживаемая ARCH=$ARCH"
      return 1
      ;;
  esac

  if [ -x "$BIN" ]; then
    cp -f "$BIN" "${BIN}.bak" 2>/dev/null || true
  fi

  if ! cp -f "$src" "$BIN"; then
    error "Не удалось скопировать в $BIN"
    return 1
  fi
  chmod +x "$BIN" 2>/dev/null || true

  ver=$(installed_version 2>/dev/null) || ver=""
  info "Установлено: $BIN ${ver:+(v$ver)}"
  printf '%s\n' "${DIM}Репозиторий: https://github.com/${GITHUB_REPO}${NC}"
  return 0
}

# ---------------------------------------------------------------------------
# 2) Создать аккаунт
# ---------------------------------------------------------------------------
do_register() {
  echo
  info "Создание аккаунта WARP (warpscout register)"
  if ! is_installed; then
    error "warpscout не установлен. Сначала пункт 1."
    return 1
  fi

  mkdir -p /opt/root 2>/dev/null || true

  if has_account; then
    warn "Файл аккаунта уже есть: $ACCOUNT_FILE"
    if ! confirm_yes "Пересоздать аккаунт?"; then
      info "Отменено."
      return 0
    fi
    rm -f "$ACCOUNT_FILE" 2>/dev/null || true
  fi

  cd /opt/root || cd /tmp || true
  if ! "$BIN" register; then
    error "register завершился с ошибкой."
    warn "При блокировке api.cloudflareclient.com см. документацию warpscout (account)."
    return 1
  fi

  if [ ! -f "$ACCOUNT_FILE" ]; then
    for cand in \
      ./warpscout-account.json \
      /tmp/warpscout-account.json \
      "$(dirname "$BIN")/warpscout-account.json"
    do
      if [ -f "$cand" ]; then
        mv -f "$cand" "$ACCOUNT_FILE" 2>/dev/null || cp -f "$cand" "$ACCOUNT_FILE"
        break
      fi
    done
  fi

  if has_account; then
    info "Аккаунт сохранён: $ACCOUNT_FILE"
    return 0
  fi
  error "Файл аккаунта не найден после register."
  return 1
}

# ---------------------------------------------------------------------------
# 3) Сканирование AWG (+ готовый conf)
# ---------------------------------------------------------------------------
do_scan() {
  echo
  info "Сканирование адресов (протокол AWG)"
  if ! is_installed; then
    error "warpscout не установлен. Сначала пункт 1."
    return 1
  fi
  if ! has_account; then
    error "Нет аккаунта. Сначала пункт 2 (register)."
    return 1
  fi

  mkdir -p /opt/root 2>/dev/null || true
  cd /opt/root || true

  info "Команда: warpscout scan -p awg -P -o $SCAN_OUT -conf $CONF_OUT"
  info "Это может занять несколько минут..."
  echo

  if ! "$BIN" scan -p awg -P -o "$SCAN_OUT" -conf "$CONF_OUT"; then
    error "scan завершился с ошибкой."
    return 1
  fi

  if [ -f "$SCAN_OUT" ] && [ -s "$SCAN_OUT" ]; then
    n=$(wc -l < "$SCAN_OUT" 2>/dev/null | tr -d ' ')
    info "Отчёт: $SCAN_OUT (${n:-?} строк)"
  else
    warn "Файл отчёта пуст или не создан: $SCAN_OUT"
  fi

  if has_conf; then
    info "Конфиг лучшего эндпоинта: $CONF_OUT"
    printf '%s\n' "${DIM}--- начало conf ---${NC}"
    head -n 40 "$CONF_OUT" 2>/dev/null || true
    printf '%s\n' "${DIM}--- конец (первые 40 строк) ---${NC}"
  else
    warn "Конфиг не создан: $CONF_OUT"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4) Применить conf в awg-manager
# ---------------------------------------------------------------------------
awg_port() {
  p=""
  if [ -f "$AWG_SETTINGS" ]; then
    p=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$AWG_SETTINGS" 2>/dev/null | head -1)
  fi
  [ -n "$p" ] || p=2222
  printf '%s\n' "$p"
}

awg_api_base() {
  printf 'http://127.0.0.1:%s/api' "$(awg_port)"
}

# Достаём API-ключ в AWG_KEY (глобально).
# Промпты только в stderr — иначе key=$(...) глотает вывод и «зависает».
awg_load_api_key() {
  AWG_KEY=""
  if [ -f "$AWG_SETTINGS" ]; then
    for field in apiKey api_key ApiKey APIKey; do
      AWG_KEY=$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$AWG_SETTINGS" 2>/dev/null | head -1)
      [ -n "$AWG_KEY" ] && break
    done
  fi
  if [ -z "$AWG_KEY" ] && [ -f "$AWG_API_KEY_FILE" ]; then
    AWG_KEY=$(tr -d '\r\n' < "$AWG_API_KEY_FILE" 2>/dev/null)
  fi
  if [ -z "$AWG_KEY" ]; then
    printf '%s\n' "${YELLOW}[?]${NC} API-ключ awg-manager (Настройки → Расширенные → API Key):" >&2
    printf '    ' >&2
    AWG_KEY=$(read_choice)
    printf '\n' >&2
    if [ -n "$AWG_KEY" ]; then
      mkdir -p /opt/etc/awg-manager 2>/dev/null || true
      printf '%s\n' "$AWG_KEY" > "$AWG_API_KEY_FILE" 2>/dev/null || true
      chmod 600 "$AWG_API_KEY_FILE" 2>/dev/null || true
      info "Ключ сохранён в $AWG_API_KEY_FILE" >&2
    fi
  fi
  [ -n "$AWG_KEY" ]
}

# Список туннелей → файл: id|name|status|endpoint
# Ответ: {"success":true,"data":[{...},...]}
awg_list_tunnels() {
  base="$1"
  key="$2"
  out="$3"
  : > "$out"
  if ! command -v curl >/dev/null 2>&1; then
    error "Нужен curl для API awg-manager."
    return 1
  fi

  # -sS: без прогресса; жёсткие таймауты; без -f (чтобы увидеть тело при 401)
  resp=$(curl -sS --connect-timeout 3 --max-time 10 \
    -H "Authorization: Bearer ${key}" \
    "${base}/tunnels/list" 2>/dev/null) || resp=""

  if [ -z "$resp" ]; then
    error "Пустой ответ от ${base}/tunnels/list"
    error "Проверьте, что awg-manager запущен и API-ключ верный."
    return 1
  fi
  case "$resp" in
    *'"success":false'*|*'"success": false'*)
      err=$(printf '%s' "$resp" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      error "API: ${err:-ошибка}"
      return 1
      ;;
  esac

  # Без pipe→while (subshell): пишем через временный файл кусков
  tmpc="$out.chunks"
  # Разделитель объектов: каждая «{» — новый фрагмент
  printf '%s' "$resp" | tr '{' '\n' > "$tmpc" 2>/dev/null || true
  : > "$out"
  while IFS= read -r chunk || [ -n "$chunk" ]; do
    case "$chunk" in
      *'"id"'*)
        tid=$(printf '%s' "$chunk" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        # пропускаем служебные вложенные объекты без id туннеля вида awg*
        [ -n "$tid" ] || continue
        case "$tid" in
          awg*|wg*|tun*|id-*) ;;
          *)
            # всё равно принимаем любые id из data[]
            ;;
        esac
        tname=$(printf '%s' "$chunk" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        tstat=$(printf '%s' "$chunk" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        tend=$(printf '%s' "$chunk" | sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        # "address":"172.16.0.3, 2606:..." или "172.16.0.2/32"
        taddr=$(printf '%s' "$chunk" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        taddr_v4=$(printf '%s' "$taddr" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
          sed -n 's|^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\(/[0-9]*\)\{0,1\}$|\1|p' | head -1)
        # отсекаем куски без status (вложенные pingCheck и т.п.)
        [ -n "$tstat" ] || continue
        # id|name|status|endpoint|ipv4
        printf '%s|%s|%s|%s|%s\n' "$tid" "${tname:-?}" "${tstat:-?}" "${tend:-}" "${taddr_v4:-}" >> "$out"
        ;;
    esac
  done < "$tmpc"
  rm -f "$tmpc" 2>/dev/null || true
  [ -s "$out" ]
}

# IPv4 из строки Address conf (без /prefix)
awg_conf_ipv4() {
  conf="$1"
  grep -iE '^[[:space:]]*Address[[:space:]]*=' "$conf" 2>/dev/null | head -1 | \
    sed 's/^[^=]*=[[:space:]]*//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
    sed -n 's|^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\(/[0-9]*\)\{0,1\}$|\1|p' | head -1
}

# Подставить Address = IP/32 в conf (сохраняя остальное)
awg_patch_conf_address() {
  conf="$1"
  newip="$2"
  [ -f "$conf" ] || return 1
  [ -n "$newip" ] || return 1
  tmp="$conf.addrnew"
  if grep -qiE '^[[:space:]]*Address[[:space:]]*=' "$conf" 2>/dev/null; then
    # заменяем только первый IPv4 в значении; префикс /32 если был или по умолчанию
    sed -E "s|^([[:space:]]*[Aa][Dd][Dd][Rr][Ee][Ss][Ss][[:space:]]*=[[:space:]]*)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?|\1${newip}/32|" \
      "$conf" > "$tmp" 2>/dev/null || return 1
  else
    # добавить в [Interface]
    if grep -q '^\[Interface\]' "$conf" 2>/dev/null; then
      awk -v ip="$newip" '
        BEGIN { done=0 }
        /^\[Interface\]/ { inif=1 }
        inif && /^\[/ && !/^\[Interface\]/ {
          if (!done) { print "Address = " ip "/32"; done=1 }
          inif=0
        }
        { print }
        END { if (!done) print "Address = " ip "/32" }
      ' "$conf" > "$tmp" 2>/dev/null || return 1
    else
      { printf 'Address = %s/32\n' "$newip"; cat "$conf"; } > "$tmp" || return 1
    fi
  fi
  mv -f "$tmp" "$conf" || return 1
  return 0
}

# Если IPv4 conf занят другими туннелями (кроме skip_id) — взять свободный 172.16.0.x
# listf: id|name|status|endpoint|ipv4
# conf: файл для правки
# Важно: не использовать имя tid в while — в ash оно затирает переменную вызывающего кода.
awg_ensure_free_address() {
  conf="$1"
  listf="$2"
  skip_id="${3:-}"

  cur=$(awg_conf_ipv4 "$conf")
  if [ -z "$cur" ]; then
    warn "В conf нет Address (IPv4) — пропускаем проверку конфликта."
    return 0
  fi

  conflict=0
  conflict_id=""
  if [ -s "$listf" ]; then
    while IFS='|' read -r _aid _aname _astat _aend _aaddr || [ -n "$_aid" ]; do
      [ -n "$_aid" ] || continue
      [ -n "$_aaddr" ] || continue
      if [ -n "$skip_id" ] && [ "$_aid" = "$skip_id" ]; then
        continue
      fi
      if [ "$_aaddr" = "$cur" ]; then
        conflict=1
        conflict_id="$_aid"
        break
      fi
    done < "$listf"
  fi

  if [ "$conflict" != "1" ]; then
    info "Address $cur свободен (или только у текущего туннеля)."
    return 0
  fi
  warn "Адрес $cur уже у туннеля ${conflict_id} — ищем свободный."

  usedf="$TMPDIR/used-addr.txt"
  : > "$usedf"
  if [ -s "$listf" ]; then
    while IFS='|' read -r _aid _aname _astat _aend _aaddr || [ -n "$_aid" ]; do
      [ -n "$_aaddr" ] || continue
      if [ -n "$skip_id" ] && [ "$_aid" = "$skip_id" ]; then
        continue
      fi
      printf '%s\n' "$_aaddr" >> "$usedf"
    done < "$listf"
  fi

  free=""
  n=2
  while [ "$n" -le 254 ]; do
    cand="172.16.0.$n"
    if ! grep -qxF "$cand" "$usedf" 2>/dev/null; then
      free="$cand"
      break
    fi
    n=$((n + 1))
  done

  if [ -z "$free" ]; then
    error "Нет свободного адреса в 172.16.0.0/24"
    return 1
  fi

  if awg_patch_conf_address "$conf" "$free"; then
    info "Address: $cur → $free"
    if [ "$conf" != "$CONF_OUT" ] && [ -f "$CONF_OUT" ]; then
      awg_patch_conf_address "$CONF_OUT" "$free" 2>/dev/null || true
    fi
    return 0
  fi
  error "Не удалось записать Address = $free"
  return 1
}


# Разбор секции «Best endpoint per node» из list → файл: NODE|ENDPOINT|TUN_PING|LOSS|LOCATION
# Пример строки:
# ARN    188.114.96.199:2408    27ms          25ms      0%     RU         Stockholm, SE
awg_parse_best_endpoints() {
  list="$1"
  out="$2"
  : > "$out"
  [ -f "$list" ] || return 1

  in_best=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'Best endpoint per node'*)
        in_best=1
        continue
        ;;
    esac
    [ "$in_best" = "1" ] || continue
    # пропускаем заголовок таблицы и пустые
    case "$line" in
      ''|\#*) continue ;;
      NODE[[:space:]]*) continue ;;
    esac
    # NODE ENDPOINT ... LOSS SEEN NODE_LOCATION...
    # awk: $1=NODE $2=ENDPOINT $5=LOSS $7+=location (после SEEN AS)
    set -- $line
    node="$1"
    ep="$2"
    # минимум: NODE + ip:port
    [ -n "$node" ] && [ -n "$ep" ] || continue
    case "$ep" in
      *:* ) ;;
      *) continue ;;
    esac
    # tun ping / loss — позиции зависят от выравнивания; ищем LOSS как *%
    loss=""
    tunp=""
    loc=""
    # проход по полям
    i=0
    for f in $line; do
      i=$((i + 1))
      case "$f" in
        *ms)
          # первое *ms после endpoint — ENDPOINT PING, второе — TUN PING
          if [ -z "$tunp" ]; then
            # пропускаем endpoint ping (первое ms после ep)
            if [ "$i" -gt 2 ]; then
              if [ -z "$_ep_ping" ]; then
                _ep_ping="$f"
              else
                tunp="$f"
              fi
            fi
          fi
          ;;
        *%)
          [ -z "$loss" ] && loss="$f"
          ;;
      esac
    done
    # location: всё после SEEN AS (обычно 2-буквенный код страны)
    # проще: с конца — NODE LOCATION = поля после LOSS и SEEN
    loc=$(printf '%s\n' "$line" | awk '{
      # найти поле с % (LOSS), следующее — SEEN AS, остальное — location
      for (i=1;i<=NF;i++) if ($i ~ /%$/) { start=i+2; break }
      loc=""
      for (j=start;j<=NF;j++) loc = (loc ? loc " " : "") $j
      print loc
    }')
    tunp=$(printf '%s\n' "$line" | awk '{
      n=0
      for (i=3;i<=NF;i++) if ($i ~ /ms$/) { n++; if (n==2) { print $i; exit } }
    }')
    loss=$(printf '%s\n' "$line" | awk '{
      for (i=1;i<=NF;i++) if ($i ~ /%$/) { print $i; exit }
    }')
    _ep_ping=""
    printf '%s|%s|%s|%s|%s\n' "$node" "$ep" "${tunp:-?}" "${loss:-?}" "${loc:-}" >> "$out"
  done < "$list"
  [ -s "$out" ]
}

# Выбор endpoint из best-per-node. Результат: SELECTED_EP, SELECTED_NODE
awg_pick_endpoint() {
  SELECTED_EP=""
  SELECTED_NODE=""
  bestf="$TMPDIR/best-ep.txt"
  mkdir -p "$TMPDIR" 2>/dev/null || true

  if [ ! -f "$SCAN_OUT" ] || [ ! -s "$SCAN_OUT" ]; then
    error "Нет списка: $SCAN_OUT (сначала п. 3)."
    return 1
  fi
  if ! awg_parse_best_endpoints "$SCAN_OUT" "$bestf"; then
    error "Не удалось разобрать «Best endpoint per node» в $SCAN_OUT"
    return 1
  fi

  echo
  printf '%s\n' "${BOLD}Лучший endpoint по нодам (из list):${NC}"
  i=0
  while IFS='|' read -r node ep tunp loss loc || [ -n "$node" ]; do
    [ -n "$node" ] || continue
    i=$((i + 1))
    mark=""
    case "$node" in
      DME) mark=" ${YELLOW}(часто DPI)${NC}" ;;
    esac
    printf '  %s%d)%s  %s%-4s%s  %s  %s[tun %s · loss %s]%s  %s%s\n' \
      "$BOLD" "$i" "$NC" "$CYAN" "$node" "$NC" "$ep" \
      "$DIM" "$tunp" "$loss" "$NC" "${loc}" "$mark"
  done < "$bestf"

  # текущий Endpoint из conf
  cur=$(grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "$CONF_OUT" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$cur" ] && printf '%s\n' "${DIM}  сейчас в conf: Endpoint = ${cur}${NC}"

  echo "  0) Отмена"
  echo
  printf '  %sВыбор endpoint:%s ' "$BOLD" "$NC"
  sel=$(read_choice)
  echo

  case "$sel" in
    0|"") info "Отменено."; return 1 ;;
    *[!0-9]*) warn "Неверный выбор."; return 1 ;;
  esac
  if [ "$sel" -lt 1 ] || [ "$sel" -gt "$i" ]; then
    warn "Неверный номер."; return 1
  fi

  SELECTED_NODE=$(sed -n "${sel}p" "$bestf" | cut -d'|' -f1)
  SELECTED_EP=$(sed -n "${sel}p" "$bestf" | cut -d'|' -f2)
  if [ -z "$SELECTED_EP" ]; then
    error "Пустой endpoint."
    return 1
  fi
  info "Выбрано: $SELECTED_NODE → $SELECTED_EP"
  return 0
}

# Подставить Endpoint в conf → dest (остальное без изменений)
awg_patch_conf_endpoint() {
  src="$1"
  dest="$2"
  ep="$3"
  [ -f "$src" ] || return 1
  [ -n "$ep" ] || return 1

  if grep -qiE '^[[:space:]]*Endpoint[[:space:]]*=' "$src" 2>/dev/null; then
    # сохраняем отступ и регистр ключа
    sed -E "s|^([[:space:]]*[Ee][Nn][Dd][Pp][Oo][Ii][Nn][Tt][[:space:]]*=[[:space:]]*).*$|\1${ep}|" \
      "$src" > "$dest" 2>/dev/null || return 1
  else
    # добавить в конец секции [Peer], иначе в конец файла
    if grep -q '^\[Peer\]' "$src" 2>/dev/null; then
      awk -v ep="$ep" '
        BEGIN { done=0 }
        /^\[Peer\]/ { inpeer=1 }
        inpeer && /^\[/ && !/^\[Peer\]/ {
          if (!done) { print "Endpoint = " ep; done=1 }
          inpeer=0
        }
        { print }
        END { if (!done) print "Endpoint = " ep }
      ' "$src" > "$dest" 2>/dev/null || return 1
    else
      { cat "$src"; printf '\nEndpoint = %s\n' "$ep"; } > "$dest" || return 1
    fi
  fi
  # обновить и основной conf на диске
  cp -f "$dest" "$src" 2>/dev/null || true
  return 0
}


# Старт/рестарт туннеля через API (после replace, если был stopped — API сам не поднимает)
awg_control() {
  # awg_control start|stop|restart ID
  action="$1"
  tid="$2"
  key="$3"
  base="$4"
  [ -n "$tid" ] || return 1
  resp=$(curl -sS --connect-timeout 5 --max-time 30 \
    -X POST "${base}/control/${action}?id=${tid}" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null) || resp=""
  if printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    info "control/${action} id=${tid}: OK"
    return 0
  fi
  err=$(printf '%s' "$resp" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -z "$err" ] && err=$(printf '%s' "$resp" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  warn "control/${action} id=${tid}: ${err:-fail}"
  [ -n "$resp" ] && printf '%s\n' "${DIM}$resp${NC}" | head -c 300 && echo
  return 1
}

do_apply_awg() {
  echo
  info "Применить conf в awg-manager"
  if ! is_awg_manager_installed; then
    error "awg-manager не установлен (opkg / /opt/etc/awg-manager)."
    return 1
  fi
  if ! has_conf; then
    error "Нет конфига: $CONF_OUT"
    error "Сначала выполните пункт 3 (сканирование)."
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    error "Нужен curl."
    return 1
  fi

  mkdir -p "$TMPDIR" 2>/dev/null || true

  # 1) выбор endpoint из list → правка conf
  if ! awg_pick_endpoint; then
    return 1
  fi
  conf_use="$TMPDIR/warpscout-awg-apply.conf"
  if ! awg_patch_conf_endpoint "$CONF_OUT" "$conf_use" "$SELECTED_EP"; then
    error "Не удалось подставить Endpoint = $SELECTED_EP в conf."
    return 1
  fi
  info "В $CONF_OUT: Endpoint = $SELECTED_EP"

  # 2) API
  base=$(awg_api_base)
  info "API: $base"

  if ! awg_load_api_key; then
    error "API-ключ не задан."
    return 1
  fi
  key="$AWG_KEY"

  listf="$TMPDIR/awg-tunnels.txt"
  info "Запрос списка туннелей..."
  if ! awg_list_tunnels "$base" "$key" "$listf"; then
    warn "Список туннелей пуст или недоступен — можно импортировать новый."
  fi

  echo
  printf '%s\n' "${BOLD}Туннели awg-manager:${NC}"
  i=0
  if [ -s "$listf" ]; then
    while IFS='|' read -r tid tname tstat tend taddr || [ -n "$tid" ]; do
      [ -n "$tid" ] || continue
      i=$((i + 1))
      printf '  %s%d)%s  %s  %s[%s]%s  %s%s\n' \
        "$BOLD" "$i" "$NC" "$tid" "$DIM" "$tstat" "$NC" \
        "${tname}${tend:+ · $tend}" "${taddr:+ · $taddr}"
    done < "$listf"
  fi
  new_idx=$((i + 1))
  printf '  %s%d)%s  Импорт нового туннеля (POST /import/conf)\n' "$BOLD" "$new_idx" "$NC"
  echo "  0) Отмена"
  echo
  printf '  %sВыбор туннеля:%s ' "$BOLD" "$NC"
  sel=$(read_choice)
  echo

  case "$sel" in
    0|"") info "Отменено."; return 0 ;;
  esac

  # импорт нового — конфликт Address со всеми существующими туннелями
  if [ "$sel" = "$new_idx" ]; then
    if ! awg_ensure_free_address "$conf_use" "$listf" ""; then
      return 1
    fi

    def_name="WARP-${SELECTED_NODE}"
    printf '%s' "${YELLOW}[?]${NC} Имя нового туннеля [${def_name}]: "
    tname=$(read_choice)
    echo
    [ -n "$tname" ] || tname="$def_name"
    printf '%s' "${YELLOW}[?]${NC} Backend (kernel/nativewg) [nativewg]: "
    backend=$(read_choice)
    echo
    [ -n "$backend" ] || backend="nativewg"

    bodyf="$TMPDIR/awg-import.json"
    {
      printf '{"content":"'
      tr -d '\r' < "$conf_use" | sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g' | awk '{printf "%s\\n",$0}'
      printf '","name":"%s","backend":"%s"}' "$tname" "$backend"
    } > "$bodyf"

    info "POST ${base}/import/conf  name=$tname backend=$backend endpoint=$SELECTED_EP"
    resp=$(curl -sS --connect-timeout 5 --max-time 30 \
      -X POST "${base}/import/conf" \
      -H "Authorization: Bearer ${key}" \
      -H "Content-Type: application/json" \
      -d @"$bodyf" 2>/dev/null) || resp=""
    if printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
      info "Импорт успешен."
      printf '%s\n' "${DIM}$resp${NC}" | head -c 400
      echo
      return 0
    fi
    error "Импорт не удался."
    [ -n "$resp" ] && printf '%s\n' "$resp"
    return 1
  fi

  # выбор по номеру
  case "$sel" in
    *[!0-9]*) warn "Неверный выбор."; return 1 ;;
  esac
  if [ "$sel" -lt 1 ] || [ "$sel" -gt "$i" ]; then
    warn "Неверный номер."
    return 1
  fi

  tid=$(sed -n "${sel}p" "$listf" | cut -d'|' -f1)
  tname=$(sed -n "${sel}p" "$listf" | cut -d'|' -f2)
  if [ -z "$tid" ]; then
    error "Не удалось определить id туннеля."
    return 1
  fi

  # Замена конфига без delete (маршрутизация/привязки туннеля сохраняются).
  # API: stop (если running) → запись conf → start только если был running.
  # Поэтому после replace всегда явно start/restart.
  if ! awg_ensure_free_address "$conf_use" "$listf" "$tid"; then
    return 1
  fi

  if ! confirm_yes "Заменить conf «${tname}» (id=$tid) → Endpoint ${SELECTED_EP} [${SELECTED_NODE}]?"; then
    info "Отменено."
    return 0
  fi

  info "Остановка $tid (перед replace)..."
  awg_control stop "$tid" "$key" "$base" || true

  bodyf="$TMPDIR/awg-replace.json"
  {
    printf '{"content":"'
    tr -d '\r' < "$conf_use" | sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g' | awk '{printf "%s\\n",$0}'
    printf '"}'
  } > "$bodyf"

  info "POST ${base}/tunnels/replace?id=${tid}"
  resp=$(curl -sS --connect-timeout 5 --max-time 30 \
    -X POST "${base}/tunnels/replace?id=${tid}" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d @"$bodyf" 2>/dev/null) || resp=""
  if ! printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    error "replace не удался."
    [ -n "$resp" ] && printf '%s\n' "$resp"
    return 1
  fi
  info "Конфиг туннеля $tid заменён (Endpoint = $SELECTED_EP)."
  printf '%s\n' "${DIM}$resp${NC}" | head -c 400
  echo

  # После replace (особенно если туннель был stopped) API может не поднять его.
  sleep 1
  info "Запуск $tid..."
  if ! awg_control start "$tid" "$key" "$base"; then
    warn "start не удался — restart..."
    awg_control restart "$tid" "$key" "$base" || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 88) Удаление
# ---------------------------------------------------------------------------
do_remove() {
  echo
  info "Удаление warpscout"
  if ! is_installed && [ ! -f "$ACCOUNT_FILE" ] && [ ! -f "$SCAN_OUT" ] && [ ! -f "$CONF_OUT" ]; then
    warn "Ничего не найдено."
    return 0
  fi

  if ! confirm_yes "Удалить warpscout и связанные файлы?"; then
    info "Отменено."
    return 0
  fi

  remove_data=0
  if [ -f "$ACCOUNT_FILE" ] || [ -f "$SCAN_OUT" ] || [ -f "$CONF_OUT" ]; then
    confirm_yes "Также удалить аккаунт, list и conf?" && remove_data=1
  fi

  if [ -f "$BIN" ]; then
    rm -f "$BIN" "${BIN}.bak" 2>/dev/null || true
    info "  удалён: $BIN"
  fi

  if [ "$remove_data" = "1" ]; then
    [ -f "$ACCOUNT_FILE" ] && rm -f "$ACCOUNT_FILE" && info "  удалён: $ACCOUNT_FILE"
    [ -f "$SCAN_OUT" ] && rm -f "$SCAN_OUT" && info "  удалён: $SCAN_OUT"
    [ -f "$CONF_OUT" ] && rm -f "$CONF_OUT" && info "  удалён: $CONF_OUT"
  fi

  info "Готово."
  return 0
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------
main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}           warpscout  v${SCRIPT_VERSION}${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}  Поиск рабочих эндпоинтов Cloudflare WARP${NC}"
    printf '%s\n' "${DIM}  https://github.com/${GITHUB_REPO}${NC}"
    printf '%s\n' "${DIM}  pin: v${PIN_VERSION}  ·  bin → ${BIN}${NC}"
    echo
    show_status
    echo
    printf '%s\n' "${DIM}  ──────────────────────────────────────────${NC}"
    echo "  1) Установка / обновление warpscout"
    echo "  2) Создать аккаунт (register)"
    echo "  3) Сканирование адресов (AWG → list + conf)"
    if is_awg_manager_installed; then
      echo "  4) Применить conf в awg-manager"
    else
      printf '  %s4) Применить conf в awg-manager%s  %s(нужен awg-manager)%s\n' \
        "$DIM" "$NC" "$DIM" "$NC"
    fi
    printf '%s\n' "${DIM}  ──────────────────────────────────────────${NC}"
    echo "  88) Удаление"
    echo "  0) Выход"
    printf '%s\n' "${DIM}  ──────────────────────────────────────────${NC}"
    echo
    printf '  %sВыбор:%s ' "$BOLD" "$NC"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_register; pause ;;
      3) do_scan; pause ;;
      4)
        if is_awg_manager_installed; then
          do_apply_awg; pause
        else
          error "awg-manager не установлен."
          pause
        fi
        ;;
      88) do_remove; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
