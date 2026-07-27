#!/bin/bash
# ================================================================= #
# EasyTier Linux 一键部署、持续监控与运维管理一体化工具箱
# 支持架构: x86_64 / amd64, aarch64 / arm64
# ================================================================= #

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

INSTALL_DIR="/opt/easytier"
CONF_DIR="/etc/EasyTier"
CONFIG_FILE="${CONF_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/easytier.service"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[!] 请使用 root 权限运行此脚本 (sudo bash $0)${PLAIN}"
        exit 1
    fi
}

# 键盘输入辅助函数
read_tty() {
    local prompt="$1"
    local var_name="$2"
    if [ -t 0 ]; then
        read -r -p "$prompt" "$var_name"
    else
        read -r -p "$prompt" "$var_name" < /dev/tty
    fi
}

# 1. 架构检测
get_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ET_ARCH="x86_64" ;;
        aarch64|arm64) ET_ARCH="aarch64" ;;
        *)
            echo -e "${RED}[!] 暂不支持当前系统架构: $ARCH${PLAIN}"
            exit 1
            ;;
    esac
}

# 2. 获取最新版本
get_latest_version() {
    LATEST_VERSION=$(curl -s --connect-timeout 5 -m 10 https://api.github.com/repos/EasyTier/EasyTier/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION="v2.2.0"
    fi
}

# 3. 核心安装逻辑
install_easytier() {
    get_arch
    echo -e "${BLUE}[1/5] 正在获取最新版本...${PLAIN}"
    get_latest_version
    echo -e "${GREEN}[+] 获取版本: $LATEST_VERSION (${ET_ARCH})${PLAIN}"

    ZIP_NAME="easytier-linux-${ET_ARCH}-${LATEST_VERSION}.zip"
    GITHUB_URL="https://github.com/EasyTier/EasyTier/releases/download/${LATEST_VERSION}/${ZIP_NAME}"

    echo -e "${YELLOW}[?] 请选择下载源：${PLAIN}"
    echo " 1) 直连 GitHub 官方"
    echo " 2) 使用 hk.gh-proxy.org 加速镜像 (推荐国内节点)"
    read_tty "选择 [1-2] (默认 2): " dl_choice
    dl_choice=${dl_choice:-2}

    if [ "$dl_choice" = "2" ]; then
        DOWNLOAD_URL="https://hk.gh-proxy.org/${GITHUB_URL}"
    else
        DOWNLOAD_URL="${GITHUB_URL}"
    fi

    TMP_ZIP="/tmp/${ZIP_NAME}"
    echo -e "${BLUE}[2/5] 开始下载 EasyTier 核心程序...${PLAIN}"
    if command -v wget &> /dev/null; then
        wget -c -O "$TMP_ZIP" "$DOWNLOAD_URL"
    else
        curl -L -o "$TMP_ZIP" "$DOWNLOAD_URL"
    fi

    if [ ! -f "$TMP_ZIP" ] || [ ! -s "$TMP_ZIP" ]; then
        echo -e "${RED}[!] 下载失败，请检查网络。${PLAIN}"
        rm -f "$TMP_ZIP"
        return 1
    fi

    # 安装依赖
    if ! command -v unzip &> /dev/null; then
        echo -e "${YELLOW}[*] 安装依赖 unzip...${PLAIN}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y && apt-get install -y unzip cron
        elif command -v yum &> /dev/null; then
            yum install -y unzip crontabs
        elif command -v dnf &> /dev/null; then
            dnf install -y unzip crontabs
        fi
    fi

    echo -e "${BLUE}[3/5] 解压并安装程序...${PLAIN}"
    mkdir -p "$INSTALL_DIR" "$CONF_DIR"
    rm -rf "${INSTALL_DIR:?}"/*
    unzip -o "$TMP_ZIP" -d "$INSTALL_DIR"
    rm -f "$TMP_ZIP"

    # 平铺解压目录
    find "$INSTALL_DIR" -mindepth 2 -type f -exec mv {} "$INSTALL_DIR/" \; 2>/dev/null
    find "$INSTALL_DIR" -mindepth 1 -type d -exec rm -rf {} + 2>/dev/null
    chmod +x "$INSTALL_DIR"/easytier-* 2>/dev/null

    ln -sf "$INSTALL_DIR/easytier-core" /usr/local/bin/easytier-core
    ln -sf "$INSTALL_DIR/easytier-cli" /usr/local/bin/easytier-cli

    # 将本脚本写入 /usr/local/bin/easytier-menu 方便后续随时调出菜单
    cp -f "$0" /usr/local/bin/easytier-menu
    chmod +x /usr/local/bin/easytier-menu
    ln -sf /usr/local/bin/easytier-menu /usr/local/bin/easytier 2>/dev/null

    echo -e "${GREEN}[+] 核心安装完成！命令行工具 easytier-menu 已注册。${PLAIN}"
}

# 4. 引导配置生成
configure_easytier() {
    echo -e "${BLUE}[4/5] 开始引导式组网配置...${PLAIN}"
    DEFAULT_HOSTNAME=$(hostname)
    read_tty "▶ 1. 请输入节点主机名 [$DEFAULT_HOSTNAME]: " hostname
    hostname=${hostname:-$DEFAULT_HOSTNAME}

    read_tty "▶ 2. 请输入虚拟 IPv4 地址/掩码 [例如: 10.10.10.2/24]: " ipv4
    while [ -z "$ipv4" ]; do
        read_tty " [!] 虚拟 IP 不能为空: " ipv4
    done

    read_tty "▶ 3. 请输入虚拟网络名称 [默认: my_easytier_net]: " network_name
    network_name=${network_name:-my_easytier_net}

    RANDOM_SECRET=$(openssl rand -base64 12 2>/dev/null | tr -d '+/=' | cut -c1-12)
    RANDOM_SECRET=${RANDOM_SECRET:-secure_psk_123}
    read_tty "▶ 4. 请输入虚拟网络密码 [默认随机: $RANDOM_SECRET]: " network_secret
    network_secret=${network_secret:-$RANDOM_SECRET}

    read_tty "▶ 5. 是否接收其他节点主动连接？(Y/n) [默认启用]: " accept_listeners
    accept_listeners=${accept_listeners:-y}

    PEERS_ARRAY=()
    read_tty "▶ 6. 是否需要配置主动连接的 Peer 节点？(y/N): " has_peers
    if [[ "$has_peers" =~ ^[Yy]$ ]]; then
        while true; do
            read_tty " 请输入 Peer 地址 (如 tcp://1.2.3.4:11010，留空结束): " peer_uri
            [ -z "$peer_uri" ] && break
            PEERS_ARRAY+=("$peer_uri")
        done
    fi

    PROXIES_ARRAY=()
    read_tty "▶ 7. 是否需要代理导出本地物理子网？(y/N): " has_proxy
    if [[ "$has_proxy" =~ ^[Yy]$ ]]; then
        while true; do
            read_tty " 请输入本地局域网 CIDR (如 192.168.1.0/24，留空结束): " proxy_cidr
            [ -z "$proxy_cidr" ] && break
            PROXIES_ARRAY+=("$proxy_cidr")
        done
    fi

    cat <<EOF > "$CONFIG_FILE"
hostname = "${hostname}"
instance_name = "default"
ipv4 = "${ipv4}"
dhcp = false
EOF

    if [[ "$accept_listeners" =~ ^[Yy]$ ]]; then
        cat <<EOF >> "$CONFIG_FILE"
listeners = [
  "tcp://0.0.0.0:11010",
  "udp://0.0.0.0:11010"
]
EOF
    else
        cat <<EOF >> "$CONFIG_FILE"
listeners = []
EOF
    fi

    cat <<EOF >> "$CONFIG_FILE"
rpc_portal = "127.0.0.1:15888"

[network_identity]
network_name = "${network_name}"
network_secret = "${network_secret}"
EOF

    if [ ${#PROXIES_ARRAY[@]} -gt 0 ]; then
        for cidr in "${PROXIES_ARRAY[@]}"; do
            printf "\n[[proxy_network]]\ncidr = \"%s\"\n" "$cidr" >> "$CONFIG_FILE"
        done
    fi

    if [ ${#PEERS_ARRAY[@]} -gt 0 ]; then
        for peer in "${PEERS_ARRAY[@]}"; do
            printf "\n[[peer]]\nuri = \"%s\"\n" "$peer" >> "$CONFIG_FILE"
        done
    fi

    cat <<EOF >> "$CONFIG_FILE"

[flags]
no_tun = false
enable_encryption = true
latency_first = false
EOF
    echo -e "${GREEN}[+] 配置文件写入完成: $CONFIG_FILE${PLAIN}"
}

# 5. Systemd 注册
register_systemd() {
    echo -e "${BLUE}[5/5] 注册并启动 Systemd 服务...${PLAIN}"
    cat <<'EOF' > "$SERVICE_FILE"
[Unit]
Description=EasyTier Decentralized Mesh VPN Daemon
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/EasyTier
ExecStart=/usr/local/bin/easytier-core -c /etc/EasyTier/config.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now easytier
    echo -e "${GREEN}[+] Systemd 服务已就绪！${PLAIN}"
}

# 📊 功能：动态监控看板
monitor_dashboard() {
    if ! systemctl is-active --quiet easytier; then
        echo -e "${RED}[!] EasyTier 服务未在运行，无法获取实时状态。${PLAIN}"
        read_tty "按回车键返回主菜单..." _
        return
    fi

    while true; do
        clear
        echo -e "${BLUE}========================================================================${PLAIN}"
        echo -e "          EasyTier 节点动态监控看板 (按 Ctrl+C 或输入 q 回车退出) "
        echo -e "         刷新时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "${BLUE}========================================================================${PLAIN}"
        
        echo -e "${YELLOW}[本地节点信息]${PLAIN}"
        easytier-cli node 2>/dev/null || echo "无法获取节点数据"
        echo ""

        echo -e "${YELLOW}[对等节点 (Peer) 链路状态]${PLAIN}"
        easytier-cli peer 2>/dev/null || echo "无活动的 Peer 连接"
        echo ""

        echo -e "${YELLOW}[虚拟网络路由表]${PLAIN}"
        easytier-cli route 2>/dev/null || echo "无活动路由"
        echo -e "${BLUE}========================================================================${PLAIN}"

        read -t 3 -n 1 input
        if [[ "$input" =~ [Qq] ]]; then
            break
        fi
    done
}

# 🛡️ 功能：保活 Watchdog 脚本管理
toggle_watchdog() {
    CRON_JOB="*/2 * * * * /bin/bash ${WATCHDOG_SCRIPT} >/dev/null 2>&1"

    if crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT"; then
        echo -e "${YELLOW}[*] 当前自动保活 Cron 任务已开启。${PLAIN}"
        read_tty "是否关闭自动保活监控？(y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT") | crontab -
            rm -f "$WATCHDOG_SCRIPT"
            echo -e "${GREEN}[+] 保活监控已关闭。${PLAIN}"
        fi
    else
        echo -e "${BLUE}[*] 正在配置后台故障自愈 Watchdog 脚本...${PLAIN}"
        cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
# EasyTier 进程与网络自愈脚本
if ! pgrep -x "easytier-core" > /dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Watchdog] 发现 easytier-core 进程崩溃，尝试重启服务..." >> /var/log/easytier-watchdog.log
    systemctl restart easytier
fi
EOF
        chmod +x "$WATCHDOG_SCRIPT"
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo -e "${GREEN}[+] 自动化保活监控已开启！(每 2 分钟巡检一次，日志记录在 /var/log/easytier-watchdog.log)${PLAIN}"
    fi
    read_tty "按回车键返回..." _
}

# 🚀 功能：检查并平滑升级
upgrade_easytier() {
    get_arch
    get_latest_version
    echo -e "${BLUE}[*] 当前最新版本为: $LATEST_VERSION${PLAIN}"
    read_tty "是否确认更新/重新覆盖安装核心二进制程序？(y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        systemctl stop easytier 2>/dev/null
        install_easytier
        systemctl restart easytier
        echo -e "${GREEN}[+] 升级完成，服务已重启！${PLAIN}"
    fi
    read_tty "按回车键返回..." _
}

# 🗑️ 功能：彻底卸载
uninstall_easytier() {
    echo -e "${RED}[!] 警告：此操作将彻底停止 EasyTier、删除配置文件及服务！${PLAIN}"
    read_tty "请输入 'YES' 确认卸载: " confirm
    if [ "$confirm" = "YES" ]; then
        echo -e "${BLUE}[*] 停止并清理服务...${PLAIN}"
        systemctl stop easytier 2>/dev/null
        systemctl disable easytier 2>/dev/null
        
        # 清理 Cron
        (crontab -l 2>/dev/null | grep -v "$WATCHDOG_SCRIPT") | crontab - 2>/dev/null
        
        # 清理文件
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        rm -rf "$INSTALL_DIR" "$CONF_DIR"
        rm -f /usr/local/bin/easytier-core /usr/local/bin/easytier-cli /usr/local/bin/easytier-menu /usr/local/bin/easytier
        rm -f /var/log/easytier-watchdog.log

        echo -e "${GREEN}[+] EasyTier 已从系统中完全卸载。${PLAIN}"
        exit 0
    fi
}

# 主控制菜单
show_menu() {
    while true; do
        clear
        STATUS_STR="${RED}未运行${PLAIN}"
        if systemctl is-active --quiet easytier; then
            PID=$(pgrep -x "easytier-core")
            STATUS_STR="${GREEN}运行中 (PID: $PID)${PLAIN}"
        fi

        WATCHDOG_STR="${RED}未开启${PLAIN}"
        if crontab -l 2>/dev/null | grep -q "$WATCHDOG_SCRIPT"; then
            WATCHDOG_STR="${GREEN}已启用${PLAIN}"
        fi

        echo -e "${BLUE}======================================================${PLAIN}"
        echo -e "       EasyTier 运维管理与持续监控工具箱 "
        echo -e "  服务状态: ${STATUS_STR}  |  自动保活: ${WATCHDOG_STR}"
        echo -e "${BLUE}======================================================${PLAIN}"
        echo " 1. 📊 打开动态实时监控看板 (Peers/路由/节点状态)"
        echo " 2. 📜 查看服务实时运行日志 (journalctl)"
        echo " ----------------------------------------------------"
        echo " 3. ▶️  启动 EasyTier 服务"
        echo " 4. ⏹️  停止 EasyTier 服务"
        echo " 5. 🔄 重启 EasyTier 服务"
        echo " ----------------------------------------------------"
        echo " 6. ⚙️  修改节点配置 (config.toml)"
        echo " 7. 🛡️  开/关后台定时保活自愈监控 (Watchdog Cron)"
        echo " 8. 🚀 检查并升级到最新版本"
        echo " 9. 🔧 重新运行配置引导向导"
        echo "10. 🗑️ 彻底卸载 EasyTier"
        echo " 0. 退出菜单"
        echo -e "${BLUE}======================================================${PLAIN}"
        read_tty "请输入选项 [0-10]: " menu_choice

        case "$menu_choice" in
            1) monitor_dashboard ;;
            2) 
                echo -e "${BLUE}[*] 正在调出日志 (按 Ctrl+C 退出)...${PLAIN}"
                journalctl -u easytier -f -n 50
                ;;
            3) 
                systemctl start easytier
                echo -e "${GREEN}[+] 服务已启动${PLAIN}"
                sleep 1.5
                ;;
            4) 
                systemctl stop easytier
                echo -e "${YELLOW}[+] 服务已停止${PLAIN}"
                sleep 1.5
                ;;
            5) 
                systemctl restart easytier
                echo -e "${GREEN}[+] 服务已重启${PLAIN}"
                sleep 1.5
                ;;
            6) 
                EDITOR_BIN="nano"
                command -v vim &>/dev/null && EDITOR_BIN="vim"
                command -v vi &>/dev/null && EDITOR_BIN="vi"
                $EDITOR_BIN "$CONFIG_FILE"
                read_tty "配置文件已修改，是否立即重启服务生效？(Y/n): " rs
                rs=${rs:-y}
                if [[ "$rs" =~ ^[Yy]$ ]]; then
                    systemctl restart easytier
                    echo -e "${GREEN}[+] 服务已重启生效${PLAIN}"
                    sleep 1.5
                fi
                ;;
            7) toggle_watchdog ;;
            8) upgrade_easytier ;;
            9) 
                configure_easytier
                systemctl restart easytier
                echo -e "${GREEN}[+] 重配置完成并已重启服务！${PLAIN}"
                sleep 2
                ;;
            10) uninstall_easytier ;;
            0) exit 0 ;;
            *) echo -e "${RED}[!] 无效选项${PLAIN}" && sleep 1 ;;
        esac
    done
}

# 脚本入口处理
check_root

if [ ! -f "/usr/local/bin/easytier-core" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}[*] 检测到系统尚未安装或配置 EasyTier，启动首次安装向导...${PLAIN}"
    install_easytier
    configure_easytier
    register_systemd
    read_tty "安装配置完成！按回车键进入管理菜单..." _
fi

show_menu
