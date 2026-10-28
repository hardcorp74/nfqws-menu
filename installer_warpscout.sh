#!/bin/sh
# installer_warpscout.sh — меню warpscout для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/vernette/warpscout
# Обёртка: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка / обновление warpscout
# 2) Создать аккаунт (warpscout register)
# 3) Сканирование адресов (AWG → /opt/root/warpscout-awg.list)
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
GITHUB_REPO="vernette/warpscout"
# фиксированная версия с готовым mipsel-бинарником в этом репозитории
PIN_VERSION="0.16.1"
ARM64_URL="https://github.com/vernette/warpscout/releases/download/v${PIN_VERSION}/warpscout_${PIN_VERSION}_linux_arm64.tar.gz"
MIPSEL_URL="https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/warpscout/warpscout-${PIN_VERSION}-mipsle"
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
      # минимальный размер (бинарник ~ несколько МБ)
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

  # warpscout по умолчанию пишет warpscout-account.json рядом с CWD
  cd /opt/root || cd /tmp || true
  if ! "$BIN" register; then
    error "register завершился с ошибкой."
    warn "При блокировке api.cloudflareclient.com см. документацию warpscout (account)."
    return 1
  fi

  # перенос, если создался не в /opt/root
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
# 3) Сканирование AWG
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

  # account рядом с CWD — переходим в /opt/root
  cd /opt/root || true

  info "Команда: warpscout scan -p awg -P -o $SCAN_OUT"
  info "Это может занять несколько минут..."
  echo

  if ! "$BIN" scan -p awg -P -o "$SCAN_OUT"; then
    error "scan завершился с ошибкой."
    return 1
  fi

  if [ -f "$SCAN_OUT" ] && [ -s "$SCAN_OUT" ]; then
    n=$(wc -l < "$SCAN_OUT" 2>/dev/null | tr -d ' ')
    info "Готово: $SCAN_OUT (${n:-?} строк)"
  else
    warn "Файл отчёта пуст или не создан: $SCAN_OUT"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 88) Удаление
# ---------------------------------------------------------------------------
do_remove() {
  echo
  info "Удаление warpscout"
  if ! is_installed && [ ! -f "$ACCOUNT_FILE" ] && [ ! -f "$SCAN_OUT" ]; then
    warn "Ничего не найдено."
    return 0
  fi

  if ! confirm_yes "Удалить warpscout и связанные файлы?"; then
    info "Отменено."
    return 0
  fi

  remove_data=0
  if [ -f "$ACCOUNT_FILE" ] || [ -f "$SCAN_OUT" ]; then
    confirm_yes "Также удалить аккаунт и список ($ACCOUNT_FILE, $SCAN_OUT)?" && remove_data=1
  fi

  if [ -f "$BIN" ]; then
    rm -f "$BIN" "${BIN}.bak" 2>/dev/null || true
    info "  удалён: $BIN"
  fi

  if [ "$remove_data" = "1" ]; then
    [ -f "$ACCOUNT_FILE" ] && rm -f "$ACCOUNT_FILE" && info "  удалён: $ACCOUNT_FILE"
    [ -f "$SCAN_OUT" ] && rm -f "$SCAN_OUT" && info "  удалён: $SCAN_OUT"
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
    echo "  3) Сканирование адресов (AWG → list)"
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
      88) do_remove; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
