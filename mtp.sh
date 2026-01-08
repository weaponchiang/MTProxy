install_py_version() {
    echo -e "${Blue}正在配置 Python 环境 (彻底静默模式)...${Nc}"
    
    # 1. 核心修复：预设 debconf 选项，自动选择默认并继续
    export DEBIAN_FRONTEND=noninteractive
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections >/dev/null 2>&1

    # 2. 针对 Debian 13/12 的特殊拦截：禁用 needrestart 的交互窗口
    # 并且告诉 apt 在安装时不要询问任何配置文件冲突
    apt-get update
    apt-get install -y -o Dpkg::Options::="--force-confdef" \
                   -o Dpkg::Options::="--force-confold" \
                   -o Dpkg::Options::="--force-confnew" \
                   --allow-downgrades --allow-remove-essential --allow-change-held-packages \
                   python3-dev python3-pip git xxd python3-cryptography

    # 3. 后续步骤保持不变
    rm -rf "$PY_DIR"
    git clone https://github.com/alexbers/mtprotoproxy.git "$PY_DIR"
    pip3 install pycryptodome uvloop --break-system-packages
    
    mkdir -p "$CONFIG_DIR"
    read -p "伪装域名 (默认: azure.microsoft.com): " DOMAIN
    DOMAIN=${DOMAIN:-azure.microsoft.com}
    RAW_S=$(head -c 16 /dev/urandom | xxd -ps -c 16 | tr -d '[:space:]')
    D_HEX=$(echo -n "$DOMAIN" | xxd -p -c 256 | tr -d '[:space:]')
    read -p "端口 (默认随机): " PORT
    PORT=${PORT:-$((10000 + RANDOM % 20000))}

    echo -e "CORE=PY\nPORT=${PORT}\nSECRET=ee${RAW_S}${D_HEX}\nDOMAIN=${DOMAIN}\nRAW_SECRET=${RAW_S}\nDOMAIN_HEX=${D_HEX}" > "${CONFIG_DIR}/config"
    cat > ${PY_DIR}/config.py <<EOF
PORT = ${PORT}
USERS = { "tg": "${RAW_S}" }
MODES = { "classic": False, "secure": False, "tls": True }
TLS_DOMAIN = "${DOMAIN}"
EOF
    cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProxy Python Service
After=network.target
[Service]
WorkingDirectory=${PY_DIR}
ExecStart=/usr/bin/python3 mtprotoproxy.py config.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    finish_install "$PORT"
}
