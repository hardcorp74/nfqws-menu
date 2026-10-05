#!/bin/sh
# installer_usque.sh — установка / обновление usque-keenetic для Entware (Keenetic / Netcraze)
# Репозиторий: https://github.com/rndnaame/nfqws-menu
# Upstream-пакеты: https://side-effect-tm.github.io/usque-keenetic/
#
# Запуск:
#   sh installer_usque.sh
#   curl -fsSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/installer_usque.sh | sh

set -e

echo "=== usque-keenetic installer (Entware / Keenetic) ==="

# ANSI (portable для ash/BusyBox)
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BOLD=$(printf '\033[1m')
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
# Архитектура (как в nfqws-menu / installer_telemt_v3)
# ---------------------------------------------------------------------------
_arch_normalize() {
  case "$1" in
    aarch64*|arm64*)             echo "aarch64" ;;
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

  ARCH_RAW=$(_arch_from_opkg)
  ARCH=$(_arch_normalize "$ARCH_RAW")
  [ -n "$ARCH" ] && ARCH_SOURCE="opkg"

  if [ -z "$ARCH" ]; then
    ARCH_RAW=$(_arch_from_opkg_conf /opt/etc/opkg.conf)
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

  [ -z "$ARCH_SOURCE" ] && ARCH_SOURCE="none"
}

is_pkg_installed() {
  opkg list-installed 2>/dev/null | grep -q "^${PKG_NAME} "
}

ensure_repo() {
  mkdir -p /opt/etc/opkg
  echo "src/gz ${PKG_NAME} ${REPO_BASE}/${ARCH}" > "$OPKG_CONF"
  info "Репозиторий: ${REPO_BASE}/${ARCH}"
  info "Записан: $OPKG_CONF"
  opkg update
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
detect_arch

if [ -z "$ARCH" ]; then
  error "Архитектура не определена (opkg print-architecture / opkg.conf)."
  error "На Keenetic uname -m для mips/mipsel часто врёт — проверьте /opt/etc/opkg.conf"
  exit 1
fi

info "Архитектура: $ARCH (источник: $ARCH_SOURCE${ARCH_RAW:+, raw=$ARCH_RAW})"

if is_pkg_installed; then
  info "Пакет $PKG_NAME уже установлен — обновление..."
  ensure_repo
  opkg upgrade "$PKG_NAME" || {
    warn "opkg upgrade не применил изменений (возможно, уже актуальная версия)."
  }
  info "Обновление завершено."
else
  info "Пакет $PKG_NAME не установлен — установка..."
  ensure_repo
  opkg install "$PKG_NAME"
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
