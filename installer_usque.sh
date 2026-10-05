#!/bin/sh
# installer_usque.sh — установка / обновление usque-keenetic для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/rndnaame/nfqws-menu
# Upstream-пакеты: https://side-effect-tm.github.io/usque-keenetic/
#
# Запуск:
#   sh installer_usque.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_usque.sh | sh

echo "=== usque-keenetic installer (Entware / Keenetic) ==="

# ANSI (portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

info()  { printf '%s\n' "${GREEN}[+]${NC} $*"; }
warn()  { printf '%s\n' "${YELLOW}[!]${NC} $*"; }
error() { printf '%s\n' "${RED}[!]${NC} $*"; }

PKG_NAME="usque-keenetic"
REPO_BASE="https://side-effect-tm.github.io/usque-keenetic"
OPKG_CONF="/opt/etc/opkg/${PKG_NAME}.conf"
INIT_SCRIPT="/opt/etc/init.d/S51usque"
CONF_FILE="/opt/etc/usque/usque.conf"

# ---------------------------------------------------------------------------
# Архитектура — логика как в nfqws-menu.sh (detect_arch / _arch_*)
# Без set -e: на BusyBox ash «[ -n x ] && y» и пустые подстановки валят скрипт.
# ---------------------------------------------------------------------------
ARCH=""
ARCH_RAW=""
ARCH_SOURCE=""   # opkg | conf | uname | none

# Нормализация сырого идентификатора → ARCH (mipsel|mips|aarch64|x86_64|x86).
# Пустой результат = не распознано. mipsel* / mipselsf* проверяются ДО mips*.
_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)                    echo "aarch64" ;;
    # 32-bit ARM: в репозиториях обычно нет отдельной ветки
    armv7*|armv6*|arm*)                 echo "" ;;
    mipsel*|mipselsf*|mips64el*)        echo "mipsel" ;;
    mips*|mipssf*)                      echo "mips" ;;
    x86_64*|amd64*|x64*)                echo "x86_64" ;;
    i[3-6]86*|x86*|i686*)               echo "x86" ;;
    *)                                  echo "" ;;
  esac
}

# Лучшая строка «arch NAME PRIORITY» из stdin (opkg print-architecture или opkg.conf).
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

# /opt/etc/opkg.conf — arch … или URL src/gz (mipselsf-k3.4, aarch64-k3.10, …)
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

  # 1) opkg print-architecture
  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  if [ -n "$ARCH" ]; then
    ARCH_SOURCE="opkg"
  fi

  # 2) /opt/etc/opkg.conf
  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf)
    ARCH=$(_arch_normalize "$ARCH_RAW")
    if [ -n "$ARCH" ]; then
      ARCH_SOURCE="conf"
    fi
  fi

  # 3) uname -m (mips* не берём — на Keenetic врёт)
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

is_pkg_installed() {
  if opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
    return 0
  fi
  return 1
}

ensure_repo() {
  mkdir -p /opt/etc/opkg
  echo "src/gz ${PKG_NAME} ${REPO_BASE}/${ARCH}" > "$OPKG_CONF"
  info "Репозиторий: ${REPO_BASE}/${ARCH}"
  info "Записан: $OPKG_CONF"
  if ! opkg update; then
    error "opkg update не удался. Проверьте сеть / DNS / DPI."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
info "Определение архитектуры..."
detect_arch

if [ -z "$ARCH" ]; then
  error "Архитектура не определена (opkg print-architecture / opkg.conf)."
  error "На Keenetic uname -m для mips/mipsel часто врёт — проверьте /opt/etc/opkg.conf"
  exit 1
fi

# Цвет как в меню: opkg=зелёный, conf/uname=жёлтый
case "$ARCH_SOURCE" in
  opkg) arch_col="$GREEN" ;;
  conf|uname) arch_col="$YELLOW" ;;
  *) arch_col="$DIM" ;;
esac
info "Архитектура: ${arch_col}${ARCH}${NC} (источник: $ARCH_SOURCE${ARCH_RAW:+, raw=$ARCH_RAW})"

if is_pkg_installed; then
  info "Пакет $PKG_NAME уже установлен — обновление..."
  if ! ensure_repo; then
    exit 1
  fi
  if opkg upgrade "$PKG_NAME"; then
    info "Обновление завершено."
  else
    warn "opkg upgrade не применил изменений (возможно, уже актуальная версия)."
  fi
else
  info "Пакет $PKG_NAME не установлен — установка..."
  if ! ensure_repo; then
    exit 1
  fi
  if ! opkg install "$PKG_NAME"; then
    error "opkg install $PKG_NAME не удался."
    error "Проверьте: opkg update && opkg install $PKG_NAME"
    exit 1
  fi
  info "Установка завершена."
fi

echo
printf '%s\n' "${BOLD}Управление сервисом${NC}"
echo "  $INIT_SCRIPT (start | stop | restart | status)"
echo
printf '%s\n' "${BOLD}Конфигурация${NC}"
echo "  $CONF_FILE"
cat << 'EOF'

# Интерфейс. Определяется автоматически при установке.
# Должен быть вида opkgtun*
IFACE="opkgtun0"
EOF

echo
info "Готово."
exit 0
