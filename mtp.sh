#!/usr/bin/env bash
#=========================================================
#   System Required: CentOS 7+ / Debian 8+ / Ubuntu 16+
#   Optimized for: alexbers/mtprotoproxy & 9seconds/mtg
#=========================================================

Red="\033[31m"
Green="\033[32m"
Yellow="\033[33m"
Blue="\033[34m"
Nc="\033[0m"

set -u

BIN_PATH="/usr/local/bin/mtg"
PY_DIR="/opt/mtprotoproxy"
MTP_CMD="/usr/local/bin/mtp"
CONFIG_DIR="/etc/mtg"
SCRIPT_URL="https://raw.githubusercontent.com/weaponchiang/MTProxy/main/mtp.sh"

check_root() {
    [[ "$(id -u)" != "0" ]] && echo -e "${Red}错误: 请以 root 运行！${Nc}" && exit 1
}

check_init_system() {
    [[ ! -f /usr/bin/systemctl ]] && echo -e "${Red}错误: 仅支持 Systemd 系统。${Nc}" && exit 1
}

# --- 功能函数 ---

open_port() {
    local PORT=$1
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent && firewall-cmd --reload
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow ${PORT}/tcp
    fi
    iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null
}

close_port() {
    local PORT=$1
    [[ -z "$PORT" ]] && return
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --remove-port=${PORT}/tcp --permanent && firewall-cmd --reload
    fi
    [[ -x "$(command -v ufw)" ]] && ufw delete allow ${PORT}/tcp >/dev/null 2>&1
    iptables -D INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null
}

install_mtp() {
    echo -e "${Yellow}选择版本：1. Go版 | 2. Python版${Nc}"
    read -p "选择: " choice
    if [[ "$choice" == "2" ]]; then install_py; else install_go; fi
}

install_go() {
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    wget -qO- "https://github.com/9seconds/mtg/releases/download/${VERSION}/mtg-${VERSION#v}-linux-${ARCH}.tar.gz" | tar xz -C /tmp
    mv /tmp/mtg-*/mtg "$BIN_PATH" && chmod +x "$BIN_PATH"
    
    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (www.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-www.microsoft.com}
    SECRET=$($BIN_PATH generate-secret --hex "$DOMAIN")
    read -p "端口 (随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}

    echo "CORE=GO
PORT=${PORT}
SECRET=${SECRET}
DOMAIN=${DOMAIN}" > "${CONFIG_DIR}/config"

    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy Service
After=network.target
[Service]
ExecStart=${BIN_PATH} simple-run 0.0.0.0:${PORT} ${SECRET}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    finish "$PORT"
}

install_py() {
    dpkg --configure -a >/dev/null 2>&1
    apt-get update && apt-get install -y python3-dev python3-pip git xxd python3-cryptography
    rm -rf "$PY_DIR"
    git clone https://github.com/alexbers/mtprotoproxy.git "$PY_DIR"
    pip3 install pycryptodome uvloop --break-system-packages

    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (www.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-www.microsoft.com}
    RAW_S=$(head -c 16 /dev/urandom | xxd -ps -c 16)
    D_HEX=$(echo -n "$DOMAIN" | xxd -p -c 256)
    
    read -p "端口 (随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}

    echo "CORE=PY
PORT=${PORT}
SECRET=ee${RAW_S}${D_HEX}
DOMAIN=${DOMAIN}
RAW_SECRET=${RAW_S}
DOMAIN_HEX=${D_HEX}" > "${CONFIG_DIR}/config"

    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy Service
After=network.target
[Service]
WorkingDirectory=${PY_DIR}
ExecStart=/usr/bin/python3 mtprotoproxy.py ${PORT} ${RAW_S} -t ${D_HEX}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    finish "$PORT"
}

finish() {
    open_port "$1"
    systemctl daemon-reload && systemctl enable mtg && systemctl restart mtg
    wget -qO "$MTP_CMD" "$SCRIPT_URL" && chmod +x "$MTP_CMD"
    echo -e "${Green}安装成功！快捷键: mtp${Nc}"
    show_info
}

show_info() {
    [[ ! -f "${CONFIG_DIR}/config" ]] && return
    source "${CONFIG_DIR}/config"
    IP=$(curl -s4 ip.sb || curl -s4 ipinfo.io/ip)
    echo -e "\n${Green}======= MTProxy 信息 =======${Nc}
端口  : ${Yellow}${PORT}${Nc}
域名  : ${Blue}${DOMAIN}${Nc}
密钥  : ${Yellow}${SECRET}${Nc}
链接  : ${Green}tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}${Nc}
============================\n"
}

# 菜单简写逻辑...
menu() {
    clear
    echo -e "${Green}MTProxy 管理脚本${Nc}"
    STATUS=$(pgrep -f "mtg|mtprotoproxy" >/dev/null && echo -e "${Green}运行中${Nc}" || echo -e "${Red}未运行${Nc}")
    echo -e "状态: $STATUS\n1. 安装\n2. 修改\n3. 信息\n4. 重启\n5. 卸载\n0. 退出"
    read -p "选择: " choice
    case "$choice" in
        1) install_mtp ;;
        2) source "${CONFIG_DIR}/config" && [[ "$CORE" == "PY" ]] && install_py || install_go ;;
        3) show_info ;;
        4) systemctl restart mtg && echo "已重启" ;;
        5) systemctl stop mtg; rm -rf "$CONFIG_DIR" "$BIN_PATH" "$PY_DIR" "$MTP_CMD" /etc/systemd/system/mtg.service; echo "已卸载" ;;
        *) exit 0 ;;
    esac
}

check_root
check_init_system
menu
