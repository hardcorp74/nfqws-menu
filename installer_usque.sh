#!/bin/sh
# installer_usque.sh — меню usque-keenetic для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/rndnaame/nfqws-menu
#
# 1) Установка usque-keenetic (side-effect-tm opkg)
# 2) Обновление bin usque (Diniboy1123/usque releases)
# 3) Удаление usque-keenetic
#
# Запуск:
#   sh installer_usque.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_usque.sh | sh

echo "=== usque-keenetic installer (Entware / Keenetic) ==="

# ANSI (portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[!]${NC} $*"; }

PKG_NAME="usque-keenetic"
# Универсальный репозиторий side-effect-tm (aarch64 / mipsel / mips)
REPO_URL_ALL="https://side-effect-tm.github.io/usque-keenetic/all"
REPO_BASE="https://side-effect-tm.github.io/usque-keenetic"
OPKG_CONF="/opt/etc/opkg/${PKG_NAME}.conf"
INIT_SCRIPT="/opt/etc/init.d/S51usque"
CONF_FILE="/opt/etc/usque/usque.conf"
USQUE_BIN="/opt/usr/bin/usque"
DINIBOY_REPO="Diniboy1123/usque"
TMPDIR="/tmp/usque-installer-$$"

# ---------------------------------------------------------------------------
# Архитектура — логика как в nfqws-menu.sh
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""

_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)                    echo "aarch64" ;;
    armv7*|armv6*|arm*)                 echo "" ;;
    mipsel*|mipselsf*|mips64el*)        echo "mipsel" ;;
    mips*|mipssf*)                      echo "mips" ;;
    x86_64*|amd64*|x64*)                echo "x86_64" ;;
    i[3-6]86*|x86*|i686*)               echo "x86" ;;
    *)                                  echo "" ;;
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
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi

  from_url=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      src/gz*|src\ *)
        case "$line" in
          *mipselsf*|*mips64el*) from_url="mipselsf"; break ;;
          *mipssf*)              from_url="mipssf"; break ;;
          *aarch64*|*arm64*)     from_url="aarch64"; break ;;
          */x64*|*x86_64*)       from_url="x86_64"; break ;;
          */x86*|*i386*)         from_url="x86"; break ;;
        esac
        ;;
    esac
  done < "$conf"
  if [ -n "$from_url" ]; then
    printf '%s\n' "$from_url"
  fi
}

detect_arch() {
  um=""
  cand=""
  ARCH=""
  ARCH_RAW=""
  ARCH_SOURCE=""

  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  if [ -n "$ARCH" ]; then
    ARCH_SOURCE="opkg"
  fi

  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf)
    ARCH=$(_arch_normalize "$ARCH_RAW")
    if [ -n "$ARCH" ]; then
      ARCH_SOURCE="conf"
    fi
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

  if [ -z "$ARCH_SOURCE" ]; then
    ARCH_SOURCE="none"
  fi
}

# ARCH меню → суффикс ассета Diniboy (linux_*)
arch_to_diniboy() {
  case "$1" in
    aarch64) echo "arm64" ;;
    mipsel)  echo "mipsle" ;;
    mips)    echo "mips" ;;
    x86_64)  echo "amd64" ;;
    x86)     echo "386" ;;
    *)       echo "" ;;
  esac
}

need_arch() {
  if [ -z "$ARCH" ]; then
    detect_arch
  fi
  if [ -z "$ARCH" ]; then
    error "Архитектура не определена (opkg print-architecture / opkg.conf)."
    error "На Keenetic uname -m для mips/mipsel часто врёт — проверьте /opt/etc/opkg.conf"
    return 1
  fi
  case "$ARCH_SOURCE" in
    opkg) arch_col="$GREEN" ;;
    conf|uname) arch_col="$YELLOW" ;;
    *) arch_col="$DIM" ;;
  esac
  info "Архитектура: ${arch_col}${ARCH}${NC} (источник: $ARCH_SOURCE${ARCH_RAW:+, raw=$ARCH_RAW})"
  return 0
}

is_pkg_installed() {
  if opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
    return 0
  fi
  return 1
}

http_get() {
  # http_get URL DEST
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" -T 120 "$url"
  else
    error "Нужны curl или wget."
    return 1
  fi
}

http_get_stdout() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O- -T 30 "$url"
  else
    return 1
  fi
}

read_choice() {
  # читаем с tty, чтобы работало и через pipe / run_remote_sh
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

# ---------------------------------------------------------------------------
# 1) Установка usque-keenetic (side-effect-tm)
# ---------------------------------------------------------------------------
do_install() {
  echo
  info "Установка $PKG_NAME (side-effect-tm)"
  need_arch || return 1

  if is_pkg_installed; then
    info "Пакет уже установлен — обновление через opkg..."
  else
    info "Пакет не установлен — установка..."
  fi

  mkdir -p /opt/etc/opkg
  # Универсальный репозиторий (рекомендован upstream); fallback на per-arch
  echo "src/gz ${PKG_NAME} ${REPO_URL_ALL}" > "$OPKG_CONF"
  info "Репозиторий: ${REPO_URL_ALL}"
  info "Записан: $OPKG_CONF"

  if ! opkg update; then
    warn "opkg update с /all не удался — пробуем per-arch: ${REPO_BASE}/${ARCH}"
    echo "src/gz ${PKG_NAME} ${REPO_BASE}/${ARCH}" > "$OPKG_CONF"
    if ! opkg update; then
      error "opkg update не удался. Проверьте сеть / DNS / DPI."
      return 1
    fi
  fi

  if is_pkg_installed; then
    if opkg upgrade "$PKG_NAME"; then
      info "Обновление завершено."
    else
      warn "opkg upgrade без изменений (возможно, уже актуальная версия)."
    fi
  else
    if ! opkg install "$PKG_NAME"; then
      error "opkg install $PKG_NAME не удался."
      return 1
    fi
    info "Установка завершена."
  fi

  echo
  printf '%s\n' "${BOLD}Управление сервисом${NC}"
  echo "  $INIT_SCRIPT (start | stop | restart | status)"
  echo
  printf '%s\n' "${BOLD}Конфигурация${NC}"
  echo "  $CONF_FILE"
  echo "  IFACE=\"opkgtun0\"   # вид opkgtun*"
  if [ -x "$USQUE_BIN" ]; then
    info "Бинарник: $USQUE_BIN"
    "$USQUE_BIN" version 2>/dev/null || "$USQUE_BIN" --version 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 2) Обновление bin (Diniboy1123/usque)
# ---------------------------------------------------------------------------
do_update_bin() {
  echo
  info "Обновление бинарника usque (Diniboy1123/usque)"
  need_arch || return 1

  if [ ! -x "$USQUE_BIN" ] && ! is_pkg_installed; then
    error "usque не установлен. Сначала пункт 1 (установка usque-keenetic)."
    return 1
  fi

  darch=$(arch_to_diniboy "$ARCH")
  if [ -z "$darch" ]; then
    error "Нет готового бинарника Diniboy для ARCH=$ARCH"
    return 1
  fi
  info "Целевой ассет: linux_${darch}"

  # Последний релиз через GitHub API
  info "Запрос latest release..."
  api_json=$(http_get_stdout "https://api.github.com/repos/${DINIBOY_REPO}/releases/latest") || api_json=""
  if [ -z "$api_json" ]; then
    error "Не удалось получить список релизов GitHub."
    return 1
  fi

  tag=$(printf '%s' "$api_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  # version без ведущего v для имени файла: usque_4.2.1_linux_arm64.zip
  ver=$(printf '%s' "$tag" | sed 's/^v//')
  if [ -z "$ver" ]; then
    error "Не удалось разобрать tag_name из API."
    return 1
  fi
  info "Релиз: $tag"

  asset="usque_${ver}_linux_${darch}.zip"
  url=$(printf '%s' "$api_json" | sed -n "s/.*\"browser_download_url\"[[:space:]]*:[[:space:]]*\"\\([^\"]*${asset}\\)\".*/\\1/p" | head -1)
  if [ -z "$url" ]; then
    # fallback прямой URL
    url="https://github.com/${DINIBOY_REPO}/releases/download/${tag}/${asset}"
  fi
  info "Скачивание: $url"

  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  zipfile="$TMPDIR/$asset"
  if ! http_get "$url" "$zipfile"; then
    error "Скачивание не удалось."
    rm -rf "$TMPDIR"
    return 1
  fi
  sz=$(wc -c < "$zipfile" 2>/dev/null | tr -d ' \t')
  if [ -z "$sz" ] || [ "$sz" -lt 10000 ]; then
    error "Файл слишком маленький (${sz:-0} Б) — возможно, ошибка загрузки."
    rm -rf "$TMPDIR"
    return 1
  fi
  info "Скачано: ${sz} Б"

  # Распаковка
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$zipfile" -d "$TMPDIR" || {
      error "unzip не смог распаковать архив."
      rm -rf "$TMPDIR"
      return 1
    }
  elif command -v busybox >/dev/null 2>&1 && busybox unzip -h >/dev/null 2>&1; then
    busybox unzip -o -q "$zipfile" -d "$TMPDIR" || {
      error "busybox unzip не смог распаковать архив."
      rm -rf "$TMPDIR"
      return 1
    }
  else
    error "Нужен unzip (opkg install unzip)."
    rm -rf "$TMPDIR"
    return 1
  fi

  newbin=""
  for c in "$TMPDIR/usque" "$TMPDIR"/*/usque; do
    if [ -f "$c" ]; then
      newbin="$c"
      break
    fi
  done
  if [ -z "$newbin" ] || [ ! -f "$newbin" ]; then
    error "В архиве не найден бинарник usque."
    rm -rf "$TMPDIR"
    return 1
  fi

  # Остановка сервиса перед заменой
  if [ -x "$INIT_SCRIPT" ]; then
    info "Остановка сервиса..."
    "$INIT_SCRIPT" stop 2>/dev/null || true
  fi

  mkdir -p "$(dirname "$USQUE_BIN")"
  if [ -f "$USQUE_BIN" ]; then
    cp -a "$USQUE_BIN" "${USQUE_BIN}.bak" 2>/dev/null || true
    info "Бэкап: ${USQUE_BIN}.bak"
  fi
  cp -f "$newbin" "$USQUE_BIN"
  chmod +x "$USQUE_BIN"
  info "Установлен: $USQUE_BIN ($tag)"

  if [ -x "$USQUE_BIN" ]; then
    "$USQUE_BIN" version 2>/dev/null || "$USQUE_BIN" --version 2>/dev/null || true
  fi

  if [ -x "$INIT_SCRIPT" ]; then
    info "Запуск сервиса..."
    "$INIT_SCRIPT" start 2>/dev/null || warn "Не удалось запустить $INIT_SCRIPT"
  fi

  rm -rf "$TMPDIR"
  info "Бинарник обновлён."
  return 0
}

# ---------------------------------------------------------------------------
# 3) Удаление
# ---------------------------------------------------------------------------
do_remove() {
  echo
  info "Удаление $PKG_NAME"
  if ! is_pkg_installed && [ ! -x "$USQUE_BIN" ] && [ ! -x "$INIT_SCRIPT" ]; then
    warn "Пакет не установлен."
    return 0
  fi

  if ! confirm_yes "Удалить $PKG_NAME и связанные файлы?"; then
    info "Отменено."
    return 0
  fi

  if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop 2>/dev/null || true
  fi

  if is_pkg_installed; then
    opkg remove --autoremove "$PKG_NAME" 2>/dev/null || opkg remove "$PKG_NAME" 2>/dev/null || true
    info "Пакет удалён через opkg."
  fi

  [ -f "$OPKG_CONF" ] && rm -f "$OPKG_CONF" && info "  удалён: $OPKG_CONF"
  # конфиг и сессию оставляем по умолчанию — можно переустановить без re-register
  if confirm_yes "Также удалить конфиг и сессию (/opt/etc/usque)?"; then
    rm -rf /opt/etc/usque
    info "  удалён каталог: /opt/etc/usque"
  fi

  # бинарник мог остаться после ручного обновления
  if [ -f "$USQUE_BIN" ] && ! is_pkg_installed; then
    rm -f "$USQUE_BIN" "${USQUE_BIN}.bak" 2>/dev/null || true
    info "  удалён: $USQUE_BIN"
  fi

  info "Готово."
  return 0
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------
show_status() {
  st=""
  if is_pkg_installed; then
    ver=$(opkg list-installed 2>/dev/null | sed -n "s/^${PKG_NAME} - //p" | head -1)
    st="пакет ${ver:-ok}"
  fi
  if [ -x "$USQUE_BIN" ]; then
    st="${st:+$st, }bin"
  fi
  if [ -x "$INIT_SCRIPT" ]; then
    st="${st:+$st, }init"
  fi
  if [ -n "$st" ]; then
    info "Обнаружено: $st"
  else
    printf '%s\n' "${DIM}Не установлено${NC}"
  fi
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    printf '%s\n' "${CYAN}================================================${NC}"
    printf '%s\n' "${CYAN}${BOLD}           usque-keenetic${NC}"
    printf '%s\n' "${CYAN}================================================${NC}"
    echo
    printf '%s\n' "${DIM}Usque — неофициальный клиент Cloudflare WARP с MASQUE:${NC}"
    printf '%s\n' "${DIM}туннель через протокол Cloudflare, интерфейс opkgtun*${NC}"
    printf '%s\n' "${DIM}и маршрутизация по DNS/IP в веб-интерфейсе Keenetic.${NC}"
    echo
    printf '%s\n' "${DIM}пакет: side-effect-tm/usque-keenetic (opkg)${NC}"
    printf '%s\n' "${DIM}bin:   Diniboy1123/usque (GitHub releases)${NC}"
    printf '%s\n' "${DIM}(Entware / Keenetic; aarch64, mipsel, mips)${NC}"
    echo
    show_status
    echo
    echo "  1) Установка (usque-keenetic / side-effect-tm)"
    echo "  2) Обновление bin (usque / Diniboy1123)"
    echo "  3) Удаление usque-keenetic"
    echo "  0) Выход"
    echo
    printf '%s' "${BOLD}Выбор: ${NC}"
    choice=$(read_choice)
    echo
    case "$choice" in
      1) do_install; pause ;;
      2) do_update_bin; pause ;;
      3) do_remove; pause ;;
      0|"") info "Выход."; exit 0 ;;
      *) warn "Неверный пункт"; pause ;;
    esac
  done
}

main_menu
