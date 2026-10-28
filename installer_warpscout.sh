#!/bin/sh
# installer_warpscout.sh — меню warpscout для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/vernette/warpscout
# Обёртка: https://github.com/rndnaame/nfqws-menu
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

# Достаём API-ключ: settings.json → .api_key → ввод пользователя
awg_get_api_key() {
  key=""
  if [ -f "$AWG_SETTINGS" ]; then
    # возможные имена полей
    for field in apiKey api_key ApiKey APIKey; do
      key=$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$AWG_SETTINGS" 2>/dev/null | head -1)
      [ -n "$key" ] && break
    done
  fi
  if [ -z "$key" ] && [ -f "$AWG_API_KEY_FILE" ]; then
    key=$(tr -d '\r\n' < "$AWG_API_KEY_FILE" 2>/dev/null)
  fi
  if [ -z "$key" ]; then
    printf '%s\n' "${YELLOW}[?]${NC} API-ключ awg-manager (Настройки → Расширенные → API Key):"
    printf '    '
    key=$(read_choice)
    echo
    if [ -n "$key" ]; then
      mkdir -p /opt/etc/awg-manager 2>/dev/null || true
      printf '%s\n' "$key" > "$AWG_API_KEY_FILE" 2>/dev/null || true
      chmod 600 "$AWG_API_KEY_FILE" 2>/dev/null || true
    fi
  fi
  printf '%s\n' "$key"
}

# JSON-экранирование содержимого .conf для API
awg_json_escape_conf() {
  conf="$1"
  [ -f "$conf" ] || return 1
  # content как одна JSON-строка с \n
  { printf '{"content":"'; tr -d '\r' < "$conf" | sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g' | awk '{printf "%s\\n",$0}'; printf '"}'; }
}

# Список туннелей → файл: id|name|status|endpoint (по одной строке)
awg_list_tunnels() {
  base="$1"
  key="$2"
  out="$3"
  : > "$out"
  if ! command -v curl >/dev/null 2>&1; then
    error "Нужен curl для API awg-manager."
    return 1
  fi
  resp=$(curl -fsS --connect-timeout 5 --max-time 15 \
    -H "Authorization: Bearer ${key}" \
    "${base}/tunnels/list" 2>/dev/null) || resp=""
  if [ -z "$resp" ]; then
    error "Не удалось получить список туннелей (${base}/tunnels/list)."
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
  # Разбиваем объекты по "id":
  printf '%s' "$resp" | tr '{' '\n' | while IFS= read -r chunk || [ -n "$chunk" ]; do
    case "$chunk" in
      *'"id"'*)
        tid=$(printf '%s' "$chunk" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        [ -n "$tid" ] || continue
        tname=$(printf '%s' "$chunk" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        tstat=$(printf '%s' "$chunk" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        tend=$(printf '%s' "$chunk" | sed -n 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        printf '%s|%s|%s|%s\n' "$tid" "${tname:-?}" "${tstat:-?}" "${tend:-}"
        ;;
    esac
  done > "$out"
  [ -s "$out" ]
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

  base=$(awg_api_base)
  info "API: $base"
  key=$(awg_get_api_key)
  if [ -z "$key" ]; then
    error "API-ключ не задан."
    return 1
  fi

  listf="$TMPDIR/awg-tunnels.txt"
  mkdir -p "$TMPDIR" 2>/dev/null || true
  if ! awg_list_tunnels "$base" "$key" "$listf"; then
    warn "Список туннелей пуст или недоступен — можно импортировать новый."
  fi

  echo
  printf '%s\n' "${BOLD}Туннели awg-manager:${NC}"
  i=0
  if [ -s "$listf" ]; then
    while IFS='|' read -r tid tname tstat tend || [ -n "$tid" ]; do
      [ -n "$tid" ] || continue
      i=$((i + 1))
      printf '  %s%d)%s  %s  %s[%s]%s  %s\n' \
        "$BOLD" "$i" "$NC" "$tid" "$DIM" "$tstat" "$NC" "${tname}${tend:+ · $tend}"
    done < "$listf"
  fi
  new_idx=$((i + 1))
  printf '  %s%d)%s  Импорт нового туннеля (POST /import/conf)\n' "$BOLD" "$new_idx" "$NC"
  echo "  0) Отмена"
  echo
  printf '  %sВыбор:%s ' "$BOLD" "$NC"
  sel=$(read_choice)
  echo

  case "$sel" in
    0|"") info "Отменено."; return 0 ;;
  esac

  # импорт нового
  if [ "$sel" = "$new_idx" ]; then
    printf '%s' "${YELLOW}[?]${NC} Имя нового туннеля [WARP-warpscout]: "
    tname=$(read_choice)
    echo
    [ -n "$tname" ] || tname="WARP-warpscout"
    printf '%s' "${YELLOW}[?]${NC} Backend (kernel/nativewg) [kernel]: "
    backend=$(read_choice)
    echo
    [ -n "$backend" ] || backend="kernel"

    bodyf="$TMPDIR/awg-import.json"
    # {"content":"...","name":"...","backend":"..."}
    {
      printf '{"content":"'
      tr -d '\r' < "$CONF_OUT" | sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g' | awk '{printf "%s\\n",$0}'
      printf '","name":"%s","backend":"%s"}' "$tname" "$backend"
    } > "$bodyf"

    info "POST ${base}/import/conf  name=$tname backend=$backend"
    resp=$(curl -fsS --connect-timeout 5 --max-time 30 \
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

  if ! confirm_yes "Заменить конфиг туннеля «${tname}» (id=$tid)?"; then
    info "Отменено."
    return 0
  fi

  bodyf="$TMPDIR/awg-replace.json"
  {
    printf '{"content":"'
    tr -d '\r' < "$CONF_OUT" | sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g' | awk '{printf "%s\\n",$0}'
    printf '"}'
  } > "$bodyf"

  info "POST ${base}/tunnels/replace?id=${tid}"
  resp=$(curl -fsS --connect-timeout 5 --max-time 30 \
    -X POST "${base}/tunnels/replace?id=${tid}" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d @"$bodyf" 2>/dev/null) || resp=""
  if printf '%s' "$resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    info "Конфиг туннеля $tid заменён."
    printf '%s\n' "${DIM}$resp${NC}" | head -c 400
    echo
    return 0
  fi
  error "replace не удался."
  [ -n "$resp" ] && printf '%s\n' "$resp"
  return 1
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
    printf '%s\n' "${CYAN}${BOLD}                  warpscout${NC}"
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
