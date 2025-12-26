#!/usr/bin/env bash
#=========================================================
#   System Required: CentOS 7+ / Debian 8+ / Ubuntu 16+ / Alpine
#   Description: MTProxy (Go version) One-click Installer
#   Github: https://github.com/9seconds/mtg
#=========================================================

# 颜色定义
Red="\033[31m"
Green="\033[32m"
Yellow="\033[33m"
Blue="\033[34m"
Nc="\033[0m"

set -u

# --- 全局配置 ---
BIN_PATH="/usr/local/bin/mtg"
MTP_CMD="/usr/local/bin/mtp"
CONFIG_DIR="/etc/mtg"
DEFAULT_VERSION="v2.1.7"
# 脚本在线地址
SCRIPT_URL="https://raw.githubusercontent.com/weaponchiang/MTProxy/main/mtp.sh"

# --- 1. 系统检查与依赖 ---

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${Red}错误: 本脚本必须以 root 用户运行！${Nc}"
        exit 1
    fi
}

check_init_system() {
    if [ -f /etc/alpine-release ] || [ -f /sbin/openrc-run ]; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        echo -e "${Red}错误: 仅支持 Systemd 或 OpenRC 系统。${Nc}"
        exit 1
    fi
}

check_deps() {
    echo -e "${Blue}正在检查系统依赖...${Nc}"
    if command -v apk >/dev/null 2>&1; then
        PM="apk"
        PM_INSTALL="apk add --no-cache"
    elif command -v apt-get >/dev/null 2>&1; then
        PM="apt-get"
        PM_INSTALL="apt-get install -y"
        $PM update -q
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
        PM_INSTALL="yum install -y"
    else
        echo -e "${Red}未检测到支持的包管理器。${Nc}"
        return
    fi

    deps="curl wget tar grep coreutils ca-certificates"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "安装依赖: ${Yellow}$dep${Nc}"
            $PM_INSTALL $dep
        fi
    done
}

# --- 2. 核心功能函数 ---

open_port() {
    local PORT=$1
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent && firewall-cmd --reload
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow ${PORT}/tcp
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null
    fi
}

close_port() {
    local PORT=$1
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --remove-port=${PORT}/tcp --permanent && firewall-cmd --reload
    fi
    if command -v ufw >/dev/null 2>&1; then ufw delete allow ${PORT}/tcp >/dev/null 2>&1; fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null
    fi
}

update_script() {
    echo -e "${Blue}正在从远程更新脚本...${Nc}"
    TMP_FILE=$(mktemp)
    if wget -qO "$TMP_FILE" "$SCRIPT_URL"; then
        mv "$TMP_FILE" "$MTP_CMD"
        chmod +x "$MTP_CMD"
        cp "$MTP_CMD" "$0" 2>/dev/null
        echo -e "${Green}脚本更新成功！请重新运行 mtp 指令。${Nc}"
        exit 0
    else
        echo -e "${Red}脚本更新失败，请检查网络连接。${Nc}"
    fi
}

install_mtg() {
    check_deps
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) echo -e "${Red}不支持的架构${Nc}"; exit 1 ;;
    esac

    VERSION=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    VERSION=${VERSION:-$DEFAULT_VERSION}
    VER_NUM=${VERSION#v}
    
    DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/${VERSION}/mtg-${VER_NUM}-linux-${ARCH}.tar.gz"
    
    wget -qO- "$DOWNLOAD_URL" | tar xz -C /tmp
    mv /tmp/mtg-*/mtg "$BIN_PATH" && chmod +x "$BIN_PATH"
    
    # 安装快捷指令
    wget -qO "$MTP_CMD" "$SCRIPT_URL" && chmod +x "$MTP_CMD"
    
    configure_mtg
}

configure_mtg() {
    mkdir -p "$CONFIG_DIR"
    read -p "请输入伪装域名 (默认: www.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-www.microsoft.com}
    SECRET=$($BIN_PATH generate-secret --hex "$DOMAIN")
    read -p "请输入监听端口 (默认随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}

    echo -e "PORT=${PORT}\nSECRET=${SECRET}\nDOMAIN=${DOMAIN}" > "${CONFIG_DIR}/config"
    open_port "$PORT"
    install_service "$PORT" "$SECRET"
}

modify_config() {
    if [ ! -f "${CONFIG_DIR}/config" ]; then echo -e "${Red}未安装${Nc}"; return; fi
    source "${CONFIG_DIR}/config"
    OLD_PORT=$PORT
    
    read -p "新端口 (当前: $PORT): " NEW_PORT
    NEW_PORT=${NEW_PORT:-$PORT}
    read -p "新域名 (当前: $DOMAIN): " NEW_DOMAIN
    NEW_DOMAIN=${NEW_DOMAIN:-$DOMAIN}

    [[ "$NEW_PORT" != "$OLD_PORT" ]] && close_port "$OLD_PORT" && open_port "$NEW_PORT"
    
    NEW_SECRET=$($BIN_PATH generate-secret --hex "$NEW_DOMAIN")
    echo -e "PORT=${NEW_PORT}\nSECRET=${NEW_SECRET}\nDOMAIN=${NEW_DOMAIN}" > "${CONFIG_DIR}/config"
    
    install_service "$NEW_PORT" "$NEW_SECRET"
    echo -e "${Green}配置修改完成！${Nc}"
}

install_service() {
    PORT=$1; SECRET=$2
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTG
After=network.target
[Service]
ExecStart=${BIN_PATH} simple-run 0.0.0.0:${PORT} ${SECRET}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl restart mtg && systemctl enable mtg
    else
        cat > /etc/init.d/mtg <<EOF
#!/sbin/openrc-run
command="${BIN_PATH}"
command_args="simple-run 0.0.0.0:${PORT} ${SECRET}"
command_background=true
pidfile="/run/mtg.pid"
EOF
        chmod +x /etc/init.d/mtg && rc-service mtg restart && rc-update add mtg default
    fi
    show_info
}

show_info() {
    [ ! -f "${CONFIG_DIR}/config" ] && return
    source "${CONFIG_DIR}/config"
    IP4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 ipinfo.io/ip)
    IP6=$(curl -s6 --connect-timeout 5 ip.sb || curl -s6 ipinfo.io/ip)
    
    echo -e "\n${Green}======= MTProxy 配置信息 =======${Nc}"
    echo -e "端口  : ${Yellow}${PORT}${Nc}"
    echo -e "域名  : ${Blue}${DOMAIN}${Nc}"
    echo -e "密钥  : ${Yellow}${SECRET}${Nc}"
    if [ -n "$IP4" ]; then
        echo -e "IPv4链接: ${Green}tg://proxy?server=${IP4}&port=${PORT}&secret=${SECRET}${Nc}"
    fi
    if [ -n "$IP6" ]; then
        echo -e "IPv6链接: ${Green}tg://proxy?server=[${IP6}]&port=${PORT}&secret=${SECRET}${Nc}"
    fi
    echo -e "================================\n"
}

# --- 菜单 ---

check_status_display() {
    if [ ! -f "$BIN_PATH" ]; then echo -e "${Red}未安装${Nc}"
    elif pgrep -x "mtg" >/dev/null; then echo -e "${Green}运行中${Nc}"
    else echo -e "${Red}已停止${Nc}"; fi
}

menu() {
    clear
    echo -e "${Green}MTProxy (Go版) 管理脚本${Nc}"
    echo -e "状态: $(check_status_display)"
    echo -e "----------------------------"
    echo -e "1. 安装 MTProxy"
    echo -e "2. 修改 配置 (端口/域名)"
    echo -e "3. 查看 链接信息"
    echo -e "4. 更新 脚本"
    echo -e "5. 重启 服务"
    echo -e "6. 卸载 MTProxy"
    echo -e "0. 退出"
    echo -e "----------------------------"
    read -p "选择: " choice
    case "$choice" in
        1) install_mtg ;;
        2) modify_config ;;
        3) show_info ;;
        4) update_script ;;
        5) systemctl restart mtg 2>/dev/null || rc-service mtg restart 2>/dev/null ;;
        6) 
            source "${CONFIG_DIR}/config" && close_port "$PORT"
            systemctl stop mtg && rm -rf "$CONFIG_DIR" "$BIN_PATH" /etc/systemd/system/mtg.service
            echo -e "${Green}已卸载${Nc}" ;;
        0) exit 0 ;;
    esac
}

check_root
check_init_system
menu
