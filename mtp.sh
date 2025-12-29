#!/usr/bin/env bash
#=========================================================
#   System Required: CentOS 7+ / Debian 8+ / Ubuntu 16+
#   Description: MTProxy (Go & Python) One-click Installer
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

# --- 1. 基础环境检查 ---

check_root() {
    [[ "$(id -u)" != "0" ]] && echo -e "${Red}错误: 请以 root 运行！${Nc}" && exit 1
}

check_init_system() {
    [[ ! -f /usr/bin/systemctl ]] && echo -e "${Red}错误: 仅支持 Systemd 系统。${Nc}" && exit 1
}

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

# --- 2. 安装/配置逻辑 ---

install_mtp() {
    echo -e "${Yellow}请选择要安装的版本：${Nc}"
    echo -e "1) Go 版     (作者: ${Blue}9seconds${Nc} - 极省资源，高性能)"
    echo -e "2) Python 版 (作者: ${Blue}alexbers${Nc} - 经典稳定，混淆性好)"
    read -p "选择 [1-2]: " core_choice

    if [ "$core_choice" == "2" ]; then
        install_py_version
    else
        install_go_version
    fi
}

install_go_version() {
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    VERSION=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    VERSION=${VERSION:-"v2.1.7"}
    
    echo -e "${Blue}正在安装 Go 版核心...${Nc}"
    wget -qO- "https://github.com/9seconds/mtg/releases/download/${VERSION}/mtg-${VERSION#v}-linux-${ARCH}.tar.gz" | tar xz -C /tmp
    mv /tmp/mtg-*/mtg "$BIN_PATH" && chmod +x "$BIN_PATH"
    
    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (默认: www.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-www.microsoft.com}
    SECRET=$($BIN_PATH generate-secret --hex "$DOMAIN")
    read -p "监听端口 (默认随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}

    echo -e "CORE=GO\nPORT=${PORT}\nSECRET=${SECRET}\nDOMAIN=${DOMAIN}" > "${CONFIG_DIR}/config"
    
    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy Go Service
After=network.target
[Service]
ExecStart=${BIN_PATH} simple-run 0.0.0.0:${PORT} ${SECRET}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    finish_install "$PORT"
}

install_py_version() {
    echo -e "${Blue}正在准备 Python 环境...${Nc}"
    dpkg --configure -a >/dev/null 2>&1
    apt-get update && apt-get install -y python3-dev python3-pip git xxd python3-cryptography
    
    rm -rf "$PY_DIR"
    git clone https://github.com/alexbers/mtprotoproxy.git "$PY_DIR"
    pip3 install pycryptodome uvloop --break-system-packages

    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (默认: www.icloud.com): " DOMAIN
    DOMAIN=${DOMAIN:-www.icloud.com}
    
    # 构造 Python 版所需的 16 进制 Raw Secret
    RAW_S=$(head -c 16 /dev/urandom | xxd -ps -c 16 | tr -d '[:space:]')
    D_HEX=$(echo -n "$DOMAIN" | xxd -p -c 256 | tr -d '[:space:]')
    FINAL_SECRET="ee${RAW_S}${D_HEX}"

    read -p "监听端口 (默认随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}

    echo -e "CORE=PY\nPORT=${PORT}\nSECRET=${FINAL_SECRET}\nDOMAIN=${DOMAIN}\nRAW_SECRET=${RAW_S}\nDOMAIN_HEX=${D_HEX}" > "${CONFIG_DIR}/config"

    # 关键修复： alexbers 版本必须按 [端口] [密钥] -t [域名HEX] 顺序排列
    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy Python Service
After=network.target
[Service]
WorkingDirectory=${PY_DIR}
ExecStart=/usr/bin/python3 mtprotoproxy.py ${PORT} ${RAW_S} -t ${D_HEX}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    finish_install "$PORT"
}

finish_install() {
    open_port "$1"
    systemctl daemon-reload && systemctl enable mtg && systemctl restart mtg
    wget -qO "$MTP_CMD" "$SCRIPT_URL" && chmod +x "$MTP_CMD"
    
    echo -e "\n${Green}==================================================${Nc}"
    echo -e "${Green}           MTProxy 安装并启动成功！               ${Nc}"
    echo -e "${Yellow}  现在你可以直接在任何地方输入 [ ${Red}mtp${Yellow} ] 管理脚本  ${Nc}"
    echo -e "${Green}==================================================${Nc}\n"
    show_info
}

# --- 3. 管理逻辑 ---

modify_config() {
    if [ ! -f "${CONFIG_DIR}/config" ]; then echo -e "${Red}请先安装！${Nc}"; return; fi
    source "${CONFIG_DIR}/config"
    OLD_PORT=$PORT
    
    read -p "新端口 (当前: $PORT): " NEW_PORT
    NEW_PORT=${NEW_PORT:-$PORT}
    read -p "新域名 (当前: $DOMAIN): " NEW_DOMAIN
    NEW_DOMAIN=${NEW_DOMAIN:-$DOMAIN}

    [ "$NEW_PORT" != "$OLD_PORT" ] && close_port "$OLD_PORT" && open_port "$NEW_PORT"

    if [ "$CORE" == "GO" ]; then
        NEW_SECRET=$($BIN_PATH generate-secret --hex "$NEW_DOMAIN")
        sed -i "s|simple-run .*|simple-run 0.0.0.0:${NEW_PORT} ${NEW_SECRET}|" /etc/systemd/system/mtg.service
        echo -e "CORE=GO\nPORT=${NEW_PORT}\nSECRET=${NEW_SECRET}\nDOMAIN=${NEW_DOMAIN}" > "${CONFIG_DIR}/config"
    else
        SECRET_RAW=$(head -c 16 /dev/urandom | xxd -ps -c 16 | tr -d '[:space:]')
        D_HEX=$(echo -n "$NEW_DOMAIN" | xxd -p -c 256 | tr -d '[:space:]')
        NEW_SECRET="ee${SECRET_RAW}${D_HEX}"
        # 再次确认修改配置时的参数顺序
        sed -i "s|python3 mtprotoproxy.py .*|python3 mtprotoproxy.py ${NEW_PORT} ${SECRET_RAW} -t ${D_HEX}|" /etc/systemd/system/mtg.service
        echo -e "CORE=PY\nPORT=${NEW_PORT}\nSECRET=${NEW_SECRET}\nDOMAIN=${NEW_DOMAIN}\nRAW_SECRET=${SECRET_RAW}\nDOMAIN_HEX=${D_HEX}" > "${CONFIG_DIR}/config"
    fi

    systemctl daemon-reload && systemctl restart mtg
    echo -e "${Green}配置修改成功！${Nc}"
    show_info
}

show_info() {
    [ ! -f "${CONFIG_DIR}/config" ] && return
    source "${CONFIG_DIR}/config"
    IP=$(curl -s4 ip.sb || curl -s4 ipinfo.io/ip)
    
    echo -e "\n${Green}======= MTProxy 信息 (${CORE}版) =======${Nc}"
    echo -e "端口  : ${Yellow}${PORT}${Nc}"
    echo -e "域名  : ${Blue}${DOMAIN}${Nc}"
    echo -e "密钥  : ${Yellow}${SECRET}${Nc}"
    echo -e "链接  : ${Green}tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}${Nc}"
    echo -e "========================================\n"
}

uninstall_mtp() {
    read -p "确定卸载吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    if [ -f "${CONFIG_DIR}/config" ]; then
        source "${CONFIG_DIR}/config"
        close_port "$PORT"
    fi
    systemctl stop mtg 2>/dev/null; systemctl disable mtg 2>/dev/null
    rm -f /etc/systemd/system/mtg.service
    rm -rf "$CONFIG_DIR" "$BIN_PATH" "$PY_DIR" "$MTP_CMD"
    echo -e "${Green}卸载成功。${Nc}"
}

# --- 4. 菜单界面 ---

menu() {
    clear
    echo -e "${Green}MTProxy (Go/Python) 多版本脚本${Nc}"
    echo -e "----------------------------"
    if pgrep -f "mtg|mtprotoproxy" >/dev/null; then
        echo -e "服务状态: ${Green}运行中${Nc}"
    else
        echo -e "服务状态: ${Red}未运行/未安装${Nc}"
    fi
    echo -e "----------------------------"
    echo -e "1. 安装 MTProxy"
    echo -e "2. 修改 端口或域名"
    echo -e "3. 查看 链接信息"
    echo -e "4. 更新 管理脚本"
    echo -e "5. 重启 服务"
    echo -e "6. 卸载 MTProxy"
    echo -e "0. 退出"
    echo -e "----------------------------"
    read -p "请选择 [0-6]: " choice
    case "$choice" in
        1) install_mtp ;;
        2) modify_config ;;
        3) show_info ;;
        4) 
            wget -qO "$MTP_CMD" "$SCRIPT_URL" && chmod +x "$MTP_CMD"
            echo -e "${Green}脚本已更新！${Nc}" ;;
        5) systemctl restart mtg; echo -e "${Green}已重启${Nc}" ;;
        6) uninstall_mtp ;;
        0) exit 0 ;;
    esac
}

check_root
check_init_system
menu
