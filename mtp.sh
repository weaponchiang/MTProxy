#!/usr/bin/env bash
#=========================================================
#   System Required: CentOS 7+ / Debian 8+ / Ubuntu 16+
#   Description: MTProxy (Go & Python) One-click Installer
#=========================================================

set -Eeuo pipefail
IFS=$'\n\t'

Red="\033[31m"; Green="\033[32m"; Yellow="\033[33m"; Blue="\033[34m"; Nc="\033[0m"

BIN_PATH="/usr/local/bin/mtg"
PY_DIR="/opt/mtprotoproxy"
VENV_DIR="${PY_DIR}/venv"
MTP_CMD="/usr/local/bin/mtp"
CONFIG_DIR="/etc/mtg"
SERVICE_FILE="/etc/systemd/system/mtg.service"
SCRIPT_URL="https://raw.githubusercontent.com/weaponchiang/MTProxy/main/mtp.sh"

log()  { echo -e "${Blue}[INFO]${Nc} $*"; }
ok()   { echo -e "${Green}[OK]${Nc} $*"; }
warn() { echo -e "${Yellow}[WARN]${Nc} $*"; }
die()  { echo -e "${Red}[ERR]${Nc} $*"; exit 1; }

trap 'die "发生错误：第 ${LINENO} 行：${BASH_COMMAND}"' ERR

check_root() { [[ "$(id -u)" == "0" ]] || die "请以 root 运行！"; }
check_init_system() { [[ -x /usr/bin/systemctl ]] || die "仅支持 Systemd 系统。"; }

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_pm() {
  if have_cmd apt-get; then echo "apt"; return; fi
  if have_cmd dnf; then echo "dnf"; return; fi
  if have_cmd yum; then echo "yum"; return; fi
  die "未检测到包管理器(apt/yum/dnf)。"
}

wait_dpkg_lock() {
  # 解决 apt-daily / unattended-upgrades 占锁导致“卡住”
  if [[ -e /var/lib/dpkg/lock-frontend || -e /var/lib/dpkg/lock ]]; then
    log "检测到 dpkg 可能被占用，等待锁释放（最多 180 秒）..."
  fi
  local i
  for i in {1..180}; do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then sleep 1; continue; fi
    if fuser /var/lib/dpkg/lock >/dev/null 2>&1; then sleep 1; continue; fi
    return 0
  done
  # 如果仍占用，给出提示而不是无限卡死
  die "dpkg/apt 锁 180 秒未释放。可执行：systemctl stop apt-daily.service apt-daily-upgrade.service 或等待后台更新结束。"
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none

  wait_dpkg_lock
  log "apt-get update..."
  apt-get update -y -qq

  wait_dpkg_lock
  log "apt-get install: $*"
  apt-get install -y --no-install-recommends \
    -o Dpkg::Lock::Timeout=180 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

open_port() {
  local PORT="${1:-}"
  [[ -n "$PORT" ]] || return 0
  if have_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --add-port="${PORT}/tcp" --permanent && firewall-cmd --reload
  fi
  if have_cmd ufw && ufw status | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null
  fi
  iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
}

close_port() {
  local PORT="${1:-}"
  [[ -n "$PORT" ]] || return 0
  if have_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --zone=public --remove-port="${PORT}/tcp" --permanent && firewall-cmd --reload
  fi
  if have_cmd ufw; then ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true; fi
  iptables -D INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
}

update_script() {
  log "正在从远程更新脚本..."
  local TMP_FILE; TMP_FILE="$(mktemp)"
  if wget -qO "$TMP_FILE" "$SCRIPT_URL"; then
    mv "$TMP_FILE" "$MTP_CMD" && chmod +x "$MTP_CMD"
    cp "$MTP_CMD" "$0" 2>/dev/null || true
    ok "管理脚本更新成功！请重新运行。"
    exit 0
  else
    rm -f "$TMP_FILE"
    die "更新失败，请检查网络。"
  fi
}

install_mtp() {
  echo -e "${Yellow}请选择版本：${Nc}"
  echo -e "1) Go 版      (9seconds - 推荐)"
  echo -e "2) Python 版  (alexbers - 兼容)"
  read -r -p "选择 [1-2]: " core_choice
  [[ "$core_choice" == "2" ]] && install_py_version || install_go_version
}

install_go_version() {
  local ARCH VERSION
  ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
  VERSION="$(curl -fsSL https://api.github.com/repos/9seconds/mtg/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  VERSION="${VERSION:-v2.1.7}"

  log "下载 mtg ${VERSION} (${ARCH})..."
  wget -qO- "https://github.com/9seconds/mtg/releases/download/${VERSION}/mtg-${VERSION#v}-linux-${ARCH}.tar.gz" | tar xz -C /tmp
  mv /tmp/mtg-*/mtg "$BIN_PATH" && chmod +x "$BIN_PATH"

  mkdir -p "$CONFIG_DIR"
  read -r -p "伪装域名 (默认: azure.microsoft.com): " DOMAIN
  DOMAIN="${DOMAIN:-azure.microsoft.com}"
  SECRET="$("$BIN_PATH" generate-secret --hex "$DOMAIN")"
  read -r -p "监听端口 (默认随机): " PORT
  PORT="${PORT:-$((10000 + RANDOM % 20000))}"

  cat > "${CONFIG_DIR}/config" <<EOF
CORE=GO
PORT=${PORT}
SECRET=${SECRET}
DOMAIN=${DOMAIN}
EOF

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProxy Service (mtg)
After=network.target

[Service]
ExecStart=${BIN_PATH} simple-run 0.0.0.0:${PORT} ${SECRET}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  finish_install "$PORT"
}

install_py_version() {
  local PM; PM="$(detect_pm)"
  [[ "$PM" == "apt" ]] || die "Python 版当前只对 apt 系（Debian/Ubuntu）做了稳健优化。"

  log "配置 Python 环境（使用 venv，避免 break-system-packages）..."

  # 关键：用 venv + 尽量少装会编译的包
  apt_install ca-certificates curl git xxd python3 python3-venv python3-dev python3-pip python3-cryptography build-essential

  rm -rf "$PY_DIR"
  git clone --depth=1 https://github.com/alexbers/mtprotoproxy.git "$PY_DIR"

  log "创建 venv 并安装依赖..."
  python3 -m venv "$VENV_DIR"
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools >/dev/null

  # pycryptodome 可能编译慢：尽量用 wheel；失败也能给出明确错误
  "${VENV_DIR}/bin/pip" install pycryptodome >/dev/null

  mkdir -p "$CONFIG_DIR"
  read -r -p "伪装域名 (默认: azure.microsoft.com): " DOMAIN
  DOMAIN="${DOMAIN:-azure.microsoft.com}"
  RAW_S="$(head -c 16 /dev/urandom | xxd -ps -c 16 | tr -d '[:space:]')"
  D_HEX="$(echo -n "$DOMAIN" | xxd -p -c 256 | tr -d '[:space:]')"
  read -r -p "监听端口 (默认随机): " PORT
  PORT="${PORT:-$((10000 + RANDOM % 20000))}"

  cat > "${CONFIG_DIR}/config" <<EOF
CORE=PY
PORT=${PORT}
SECRET=ee${RAW_S}${D_HEX}
DOMAIN=${DOMAIN}
EOF

  cat > "${PY_DIR}/config.py" <<EOF
PORT = ${PORT}
USERS = { "tg": "${RAW_S}" }
MODES = { "classic": False, "secure": False, "tls": True }
TLS_DOMAIN = "${DOMAIN}"
EOF

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProxy Service (mtprotoproxy)
After=network.target

[Service]
WorkingDirectory=${PY_DIR}
ExecStart=${VENV_DIR}/bin/python ${PY_DIR}/mtprotoproxy.py ${PY_DIR}/config.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  finish_install "$PORT"
}

finish_install() {
  local PORT="${1:-}"
  open_port "$PORT"
  systemctl daemon-reload
  systemctl enable --now mtg
  wget -qO "$MTP_CMD" "$SCRIPT_URL" && chmod +x "$MTP_CMD" || true
  ok "安装成功！"
  show_info
}

show_info() {
  [[ -f "${CONFIG_DIR}/config" ]] || return 0
  # shellcheck disable=SC1090
  source "${CONFIG_DIR}/config"

  local IP4 IP6
  IP4="$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ipinfo.io/ip || true)"
  IP6="$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 --connect-timeout 5 icanhazip.com || true)"

  echo -e "\n${Green}======= MTProxy 信息 =======${Nc}"
  echo -e "端口: ${Yellow}${PORT}${Nc} | 域名: ${Blue}${DOMAIN}${Nc}"
  echo -e "密钥: ${Yellow}${SECRET}${Nc}"
  [[ -n "${IP4}" ]] && echo -e "IPv4: ${Green}tg://proxy?server=${IP4}&port=${PORT}&secret=${SECRET}${Nc}"
  [[ -n "${IP6}" ]] && echo -e "IPv6: ${Green}tg://proxy?server=[${IP6}]&port=${PORT}&secret=${SECRET}${Nc}"
  echo -e "============================\n"
}

uninstall_all() {
  warn "正在卸载..."
  if [[ -f "${CONFIG_DIR}/config" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_DIR}/config" || true
    close_port "${PORT:-}"
  fi
  systemctl stop mtg 2>/dev/null || true
  systemctl disable mtg 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload || true
  rm -rf "$CONFIG_DIR" "$PY_DIR" "$BIN_PATH" "$MTP_CMD"
  ok "已卸载。"
  exit 0
}

menu() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  clear || true
  echo -e "${Green}MTProxy (Go/Python) 管理脚本${Nc}"
  echo -e "----------------------------------"
  if systemctl is-active --quiet mtg; then
    # shellcheck disable=SC1090
    source "${CONFIG_DIR}/config" 2>/dev/null || true
    echo -e "服务状态: ${Green}● 运行中 (${CORE:-未知})${Nc}"
  elif [[ ! -f "$SERVICE_FILE" ]]; then
    echo -e "服务状态: ${Yellow}○ 未安装${Nc}"
  else
    echo -e "服务状态: ${Red}○ 已停止${Nc}"
  fi
  echo -e "----------------------------------"
  echo -e "1. 安装 / 重置"
  echo -e "3. 查看信息"
  echo -e "4. 更新脚本"
  echo -e "5. 重启服务"
  echo -e "6. 停止服务"
  echo -e "7. 卸载程序"
  echo -e "0. 退出"
  echo -e "----------------------------------"
  read -r -p "选择 [0-7]: " choice
  case "${choice:-0}" in
    1) install_mtp ;;
    3) show_info ;;
    4) update_script ;;
    5) systemctl restart mtg && ok "已重启" ;;
    6) systemctl stop mtg && ok "已停止" ;;
    7) uninstall_all ;;
    *) exit 0 ;;
  esac
}

check_root
check_init_system
menu