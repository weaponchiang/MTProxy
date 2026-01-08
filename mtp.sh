#!/usr/bin/env bash
# MTProxy 管理脚本
# 修复点：
# 1. set -e 下 check_root / check_init_system 误触发
# 2. apt 非交互，避免 dpkg-preconfigure 卡死
# 3. systemctl enable --now mtg

set -Eeuo pipefail

Red='\033[0;31m'
Green='\033[0;32m'
Yellow='\033[0;33m'
Nc='\033[0m'

WORKDIR="/opt/mtprotoproxy"
SERVICE_NAME="mtg"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

check_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo -e "${Red}错误: 请以 root 运行！${Nc}"
    exit 1
  fi
}

check_init_system() {
  if [[ ! -x /usr/bin/systemctl ]]; then
    echo -e "${Red}错误: 仅支持 systemd 系统。${Nc}"
    exit 1
  fi
}

init_env() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export UCF_FORCE_CONFFNEW=1

  dpkg --configure -a >/dev/null 2>&1 || true

  apt-get update -y
  apt-get install -y \
    ca-certificates curl git xxd \
    python3 python3-pip python3-venv python3-dev \
    python3-cryptography build-essential
}

install_python_mtproxy() {
  echo -e "${Green}[INFO] 安装 Python 版 MTProxy${Nc}"

  init_env

  rm -rf "$WORKDIR"
  git clone https://github.com/alexbers/mtprotoproxy.git "$WORKDIR"

  cd "$WORKDIR"
  python3 -m venv venv
  source venv/bin/activate

  pip install --upgrade pip
  pip install -r requirements.txt

  deactivate

  read -rp "伪装域名 (默认: azure.microsoft.com): " FAKE_DOMAIN
  FAKE_DOMAIN=${FAKE_DOMAIN:-azure.microsoft.com}

  read -rp "监听端口 (默认随机): " PORT
  PORT=${PORT:-$((RANDOM % 20000 + 20000))}

  SECRET=$(xxd -ps -l 16 /dev/urandom)

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTProxy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
ExecStart=$WORKDIR/venv/bin/python3 $WORKDIR/mtprotoproxy.py \\
  -p $PORT \\
  -H $FAKE_DOMAIN \\
  -S $SECRET \\
  --aes-pwd $WORKDIR/proxy-secret \\
  --allowed-clients $WORKDIR/clients \\
  --nat-info 0.0.0.0:443
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  IP4=$(curl -4 -s https://api.ipify.org || true)
  IP6=$(curl -6 -s https://api64.ipify.org || true)

  echo "======= MTProxy 信息 ======="
  echo "端口 : $PORT"
  echo "域名 : $FAKE_DOMAIN"
  echo "密钥 : $SECRET"
  [[ -n "$IP4" ]] && echo "IPv4: tg://proxy?server=$IP4&port=$PORT&secret=$SECRET"
  [[ -n "$IP6" ]] && echo "IPv6: tg://proxy?server=[$IP6]&port=$PORT&secret=$SECRET"
  echo "============================"
}

show_info() {
  systemctl status "$SERVICE_NAME" --no-pager || true
}

restart_service() {
  systemctl restart "$SERVICE_NAME"
}

stop_service() {
  systemctl stop "$SERVICE_NAME"
}

uninstall_all() {
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  rm -rf "$WORKDIR"
  systemctl daemon-reload
  echo -e "${Green}已卸载 MTProxy${Nc}"
}

menu() {
  clear
  echo "MTProxy 管理脚本"
  echo "----------------------------------"
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "服务状态 : ${Green}运行中${Nc}"
  else
    echo -e "服务状态 : ○ 未安装/未运行"
  fi
  echo "----------------------------------"
  echo "1. 安装 Python 版"
  echo "2. 查看信息"
  echo "3. 重启服务"
  echo "4. 停止服务"
  echo "5. 卸载"
  echo "0. 退出"
  echo "----------------------------------"
  read -rp "选择 [0-5]: " num
  case "$num" in
    1) install_python_mtproxy ;;
    2) show_info ;;
    3) restart_service ;;
    4) stop_service ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
}

main() {
  check_root
  check_init_system
  while true; do
    menu
    read -rp "按回车继续..." _
  done
}

main