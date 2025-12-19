#!/usr/bin/env bash
#=========================================================
#   System Required: CentOS 7+ / Debian 8+ / Ubuntu 16+ / Alpine
#   Description: MTProxy (Go version) One-click Installer
#   Github: https://github.com/9seconds/mtg
#   Optimized by: You
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
# 指向你自己的仓库，确保生成的快捷指令 'mtp' 拉取的是这个脚本
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

sync_time() {
    echo -e "${Blue}正在同步系统时间...${Nc}"
    # 尝试使用 timedatectl
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null
    fi
    # 强制 HTTP 时间同步 (兼容性最好，不依赖 NTP 端口)
    date -s "$(curl -sI g.cn | grep Date | cut -d' ' -f3-6)Z" >/dev/null 2>&1
    echo -e "${Green}时间同步完成。${Nc}"
}

detect_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        i386|i686) echo "386" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        *) echo "unsupported" ;;
    esac
}

get_latest_version() {
    latest_version=$(curl -s https://api.github.com/repos/9seconds/mtg/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        echo "$DEFAULT_VERSION"
    else
        echo "$latest_version"
    fi
}

# --- 2. 核心功能函数 ---

open_port() {
    local PORT=$1
    echo -e "${Blue}正在尝试开放防火墙端口: ${PORT}...${Nc}"
    
    # Firewalld
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent
            firewall-cmd --reload
        fi
    fi
    
    # UFW
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw allow ${PORT}/tcp
        fi
    fi

    # Iptables
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
            # 尝试保存
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save 2>/dev/null
            elif command -v service >/dev/null 2>&1; then
                 service iptables save 2>/dev/null
            fi
        fi
    fi
}

install_mtg() {
    check_deps
    sync_time
    ARCH=$(detect_arch)
    if [ "$ARCH" = "unsupported" ]; then 
        echo -e "${Red}不支持的架构: $(uname -m)${Nc}"
        exit 1
    fi

    echo -e "${Blue}正在获取最新版本信息...${Nc}"
    VERSION=$(get_latest_version)
    echo -e "检测到最新版本: ${Green}${VERSION}${Nc}"

    VER_NUM=${VERSION#v}
    FILENAME="mtg-${VER_NUM}-linux-${ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/${VERSION}/${FILENAME}"

    TMP_DIR=$(mktemp -d)
    echo -e "${Blue}正在下载核心: ${DOWNLOAD_URL}${Nc}"
    
    if ! wget -q --show-progress -O "${TMP_DIR}/${FILENAME}" "$DOWNLOAD_URL"; then
        echo -e "${Red}下载失败！请检查网络或 GitHub 连接。${Nc}"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "正在解压..."
    tar -xzf "${TMP_DIR}/${FILENAME}" -C "${TMP_DIR}"
    BINARY=$(find "${TMP_DIR}" -type f -name mtg | head -n 1)
    
    if [ -f "$BINARY" ]; then
        mv "$BINARY" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        echo -e "${Green}MTG 主程序安装成功！${Nc}"
    else
        echo -e "${Red}解压失败，未找到二进制文件。${Nc}"
        rm -rf "$TMP_DIR"
        exit 1
    fi
    rm -rf "$TMP_DIR"

    # 安装快捷指令
    echo -e "${Blue}正在安装快捷指令 'mtp'...${Nc}"
    wget -q -O "$MTP_CMD" "$SCRIPT_URL"
    if [ -s "$MTP_CMD" ]; then
        chmod +x "$MTP_CMD"
        echo -e "${Green}快捷指令安装成功！以后可以直接输入 'mtp' 管理。${Nc}"
    fi

    configure_mtg
}

configure_mtg() {
    mkdir -p "$CONFIG_DIR"
    echo -e "${Yellow}--- 配置 FakeTLS 模式 ---${Nc}"
    
    read -p "请输入伪装域名 (默认: www.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-www.microsoft.com}
    
    echo "正在生成密钥..."
    SECRET=$($BIN_PATH generate-secret --hex "$DOMAIN")
    
    read -p "请输入监听端口 (默认随机): " PORT
    if [ -z "$PORT" ]; then
        PORT=$((10000 + RANDOM % 20000))
    fi

    echo "PORT=${PORT}" > "${CONFIG_DIR}/config"
    echo "SECRET=${SECRET}" >> "${CONFIG_DIR}/config"
    echo "DOMAIN=${DOMAIN}" >> "${CONFIG_DIR}/config"

    open_port "$PORT"
    install_service "$PORT" "$SECRET"
}

install_service() {
    PORT=$1
    SECRET=$2
    SERVICE_FILE=""

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        SERVICE_FILE="/etc/systemd/system/mtg.service"
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MTG Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} simple-run 0.0.0.0:${PORT} ${SECRET}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtg
        systemctl restart mtg

    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        SERVICE_FILE="/etc/init.d/mtg"
        cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="mtg"
command="${BIN_PATH}"
command_args="simple-run 0.0.0.0:${PORT} ${SECRET}"
command_background=true
pidfile="/run/mtg.pid"
depend() {
    need net
}
EOF
        chmod +x "$SERVICE_FILE"
        rc-update add mtg default
        rc-service mtg restart
    fi

    sleep 2
    if check_status_bool; then
        echo -e "${Green}服务启动成功！${Nc}"
        show_info
    else
        echo -e "${Red}警告：服务启动失败。请检查端口是否被占用或系统日志。${Nc}"
    fi
}

# --- 3. 管理功能 ---

show_info() {
    if [ ! -f "${CONFIG_DIR}/config" ]; then
        echo -e "${Red}未检测到配置文件，请先安装。${Nc}"
        return
    fi
    source "${CONFIG_DIR}/config"
    
    echo -e "${Blue}正在获取 IP 地址...${Nc}"
    IPV4=$(curl -s4 --connect-timeout 3 ip.sb 2>/dev/null)
    IPV6=$(curl -s6 --connect-timeout 3 ip.sb 2>/dev/null)
    
    echo -e "\n${Green}======= MTProxy 配置信息 =======${Nc}"
    echo -e "端口  : ${Yellow}${PORT}${Nc}"
    echo -e "密钥  : ${Yellow}${SECRET}${Nc}"
    echo -e "域名  : ${Blue}${DOMAIN}${Nc}"
    
    if [ -n "$IPV4" ]; then
        echo -e "--------------------------------"
        echo -e "IPv4  : ${Yellow}${IPV4}${Nc}"
        echo -e "链接  : ${Green}tg://proxy?server=${IPV4}&port=${PORT}&secret=${SECRET}${Nc}"
    fi

    if [ -n "$IPV6" ]; then
        echo -e "--------------------------------"
        echo -e "IPv6  : ${Yellow}${IPV6}${Nc}"
        echo -e "链接  : ${Green}tg://proxy?server=[${IPV6}]&port=${PORT}&secret=${SECRET}${Nc}"
    fi
    
    echo -e "================================\n"
    echo -e "${Yellow}提示: 如无法连接，请务必检查云服务器后台防火墙/安全组是否放行 TCP 端口 ${PORT}。${Nc}\n"
}

enable_bbr() {
    echo -e "${Blue}正在检测 BBR...${Nc}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${Green}BBR 已经开启。${Nc}"
    else
        echo "正在开启 BBR..."
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${Green}BBR 开启成功！${Nc}"
    fi
}

uninstall_mtg() {
    echo -e "${Red}警告：此操作将删除所有配置和程序，并关闭对应端口。${Nc}"
    read -p "确定要完全卸载吗？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # 1. 读取端口以便关闭防火墙
    local REMOVE_PORT=""
    if [ -f "${CONFIG_DIR}/config" ]; then
        source "${CONFIG_DIR}/config"
        REMOVE_PORT=$PORT
    fi

    echo -e "${Blue}正在停止服务...${Nc}"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop mtg
        systemctl disable mtg
        rm -f /etc/systemd/system/mtg.service
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null
    else
        rc-service mtg stop
        rc-update del mtg default
        rm -f /etc/init.d/mtg
        rm -f /run/mtg.pid
    fi

    # 2. 清理防火墙规则
    if [ -n "$REMOVE_PORT" ]; then
        echo -e "${Blue}正在清理防火墙端口: ${REMOVE_PORT}...${Nc}"
        
        # Firewalld
        if command -v firewall-cmd >/dev/null 2>&1; then
            if systemctl is-active --quiet firewalld; then
                firewall-cmd --zone=public --remove-port=${REMOVE_PORT}/tcp --permanent 2>/dev/null
                firewall-cmd --reload 2>/dev/null
            fi
        fi
        
        # UFW
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow ${REMOVE_PORT}/tcp >/dev/null 2>&1
        fi

        # Iptables
        if command -v iptables >/dev/null 2>&1; then
            iptables -D INPUT -p tcp --dport ${REMOVE_PORT} -j ACCEPT 2>/dev/null
            iptables -D INPUT -p tcp --dport ${REMOVE_PORT} -j ACCEPT 2>/dev/null
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save 2>/dev/null
            elif command -v service >/dev/null 2>&1; then
                 service iptables save 2>/dev/null
            fi
        fi
    fi

    # 3. 删除文件
    rm -f "$BIN_PATH"
    rm -f "$MTP_CMD"
    rm -rf "$CONFIG_DIR"
    echo -e "${Green}卸载清理完毕。${Nc}"
}

# --- 4. 状态检测与菜单 ---

check_status_bool() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if systemctl is-active --quiet mtg; then return 0; else return 1; fi
    else
        if pgrep -x "mtg" >/dev/null; then return 0; else return 1; fi
    fi
}

check_status_display() {
    if [ ! -f "$BIN_PATH" ]; then
        echo -e "${Red}未安装 (Not Installed)${Nc}"
    elif check_status_bool; then
        echo -e "${Green}运行中 (Running)${Nc}"
    else
        echo -e "${Red}已停止 (Stopped)${Nc}"
    fi
}

menu() {
    clear
    echo -e "${Green}MTProxy (Go版) 一键管理脚本${Nc}"
    echo -e "----------------------------"
    echo -e "当前状态: $(check_status_display)"
    echo -e "----------------------------"
    echo -e "1. 安装 / 重置配置"
    echo -e "2. 查看 链接信息"
    echo -e "3. 开启 BBR 加速"
    echo -e "4. 停止 服务"
    echo -e "5. 重启 服务"
    echo -e "6. 卸载 MTProxy"
    echo -e "0. 退出"
    echo -e "----------------------------"
    read -p "请选择 [0-6]: " choice

    case "$choice" in
        1) install_mtg ;;
        2) show_info ;;
        3) enable_bbr ;;
        4) 
           if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl stop mtg; else rc-service mtg stop; fi
           echo -e "${Green}已执行停止指令。${Nc}" ;;
        5) 
           if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl restart mtg; else rc-service mtg restart; fi
           echo -e "${Green}已执行重启指令。${Nc}" ;;
        6) uninstall_mtg ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
}

# --- 入口 ---
check_root
check_init_system

if [ $# -gt 0 ]; then
    case "$1" in
        install) install_mtg ;;
        uninstall) uninstall_mtg ;;
        info) show_info ;;
        *) echo "Usage: $0 {install|uninstall|info}" ;;
    esac
else
    menu
fi
