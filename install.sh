#!/bin/bash

# ================================================================= #
#  EasyTier Linux 一键安装、引导配置与 Systemd 持久化脚本
#  支持架构: x86_64, aarch64 (ARM64)
#  设计目标: 零门槛一键部署, 智能寻路, 自动防坑
# ================================================================= #

# 终端颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

# 必须使用 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] 请使用 root 权限运行此脚本 (sudo bash install.sh)${PLAIN}"
    exit 1
fi

# 欢迎语
echo -e "${BLUE}"
echo "======================================================"
echo "    EasyTier Linux 自动部署与引导配置一体化脚本       "
echo "    作者: 自建极客开源计划                            "
echo "======================================================"
echo -e "${PLAIN}"

# 1. 架构检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ET_ARCH="x86_64" ;;
    aarch64) ET_ARCH="aarch64" ;;
    *)       
        echo -e "${RED}[!] 暂不支持当前系统架构: $ARCH${PLAIN}"
        exit 1 
        ;;
esac
echo -e "${GREEN}[+] 检测到系统架构为: $ARCH ($ET_ARCH)${PLAIN}"

# 2. 获取最新版本号
echo -e "${BLUE}[1/6] 正在通过 GitHub API 获取最新版本号...${PLAIN}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/EasyTier/EasyTier/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_VERSION" ]; then
    LATEST_VERSION="v2.6.4"
    echo -e "${YELLOW}[!] 无法获取最新版本号，将回退使用默认稳定版: $LATEST_VERSION${PLAIN}"
else
    echo -e "${GREEN}[+] 成功获取最新版本号: $LATEST_VERSION${PLAIN}"
fi

# 3. 选择下载加速代理
ZIP_NAME="easytier-linux-${ET_ARCH}-${LATEST_VERSION}.zip"
GITHUB_URL="https://github.com/EasyTier/EasyTier/releases/download/${LATEST_VERSION}/${ZIP_NAME}"

echo -e "${YELLOW}[?] 由于国内直接连接 GitHub 较慢，是否使用加速代理进行下载？${PLAIN}"
echo "  1) 直连 GitHub 官方 (适合海外 VPS)"
echo "  2) 使用 ghfast.top 加速代理 (推荐国内节点使用)"
read -r -p "请选择下载方式 [1-2] (默认: 2): " download_choice
download_choice=${download_choice:-2}

if [ "$download_choice" -eq 2 ]; then
    DOWNLOAD_URL="https://ghfast.top/${GITHUB_URL}"
else
    DOWNLOAD_URL="${GITHUB_URL}"
fi

# 4. 下载与安装
INSTALL_DIR="/opt/easytier"
CONF_DIR="/etc/EasyTier"
TMP_ZIP="/tmp/${ZIP_NAME}"

echo -e "${BLUE}[2/6] 开始下载 EasyTier 核心程序...${PLAIN}"
echo -e "下载地址: ${BLUE}${DOWNLOAD_URL}${PLAIN}"

# 优先使用 wget，其次 curl
if command -v wget &> /dev/null; then
    wget -O "$TMP_ZIP" "$DOWNLOAD_URL"
elif command -v curl &> /dev/null; then
    curl -L -o "$TMP_ZIP" "$DOWNLOAD_URL"
else
    echo -e "${RED}[!] 系统未检测到 wget 或 curl，请先安装后再运行本脚本。${PLAIN}"
    exit 1
fi

if [ ! -f "$TMP_ZIP" ] || [ ! -s "$TMP_ZIP" ]; then
    echo -e "${RED}[!] 核心文件下载失败，请检查网络或更换下载源后重试。${PLAIN}"
    exit 1
fi

# 确保解压工具 unzip 存在
if ! command -v unzip &> /dev/null; then
    echo -e "${YELLOW}[*] 安装依赖工具 unzip...${PLAIN}"
    apt-get install -y unzip || yum install -y unzip || dnf install -y unzip || pacman -Sy --noconfirm unzip
fi

echo -e "${BLUE}[3/6] 解压安装核心程序...${PLAIN}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONF_DIR"
unzip -o "$TMP_ZIP" -d "$INSTALL_DIR"
rm -f "$TMP_ZIP"

# 建立全局软链接（环境变量）
ln -sf "$INSTALL_DIR/easytier-core" /usr/local/bin/easytier-core
ln -sf "$INSTALL_DIR/easytier-cli" /usr/local/bin/easytier-cli
chmod +x /usr/local/bin/easytier-core /usr/local/bin/easytier-cli

echo -e "${GREEN}[+] 核心程序安装成功，软链接配置完成！${PLAIN}"

# 5. 引导式配置文件生成
echo -e "${BLUE}"
echo "======================================================"
echo "    [4/6] 开始进行引导式组网配置                      "
echo "======================================================"
echo -e "${PLAIN}"

# 主机名
DEFAULT_HOSTNAME=$(hostname)
read -r -p "▶ 1. 请输入本节点的主机名 [$DEFAULT_HOSTNAME]: " hostname
hostname=${hostname:-$DEFAULT_HOSTNAME}

# 虚拟 IP
read -r -p "▶ 2. 请输入本节点的虚拟 IPv4 物理网卡 IP [例如: 10.10.10.2/24]: " ipv4
while [ -z "$ipv4" ]; do
    read -r -p "   [!] 虚拟 IP 不能为空，请重新输入: " ipv4
done

# 网络名称
read -r -p "▶ 3. 请输入虚拟网络名称 [默认: my_easytier_net]: " network_name
network_name=${network_name:-"my_easytier_net"}

# 密码生成
RANDOM_SECRET=$(openssl rand -base64 12 2>/dev/null | tr -d '+/=' | cut -c1-12)
RANDOM_SECRET=${RANDOM_SECRET:-"secure_psk_123"}
read -r -p "▶ 4. 请输入虚拟网络密码/密钥 [默认随机生成: $RANDOM_SECRET]: " network_secret
network_secret=${network_secret:-$RANDOM_SECRET}

# 侦听器
read -r -p "▶ 5. 本节点是否接收其他节点的主动连接？(Y/n) [默认启用]: " accept_listeners
accept_listeners=${accept_listeners:-"y"}

# 对等节点 (Peer)
peers_config=""
read -r -p "▶ 6. 是否需要配置主动连接的 Peer 节点？(y/N) [默认不连接]: " has_peers
if [[ "$has_peers" =~ ^[Yy]$ ]]; then
    while true; do
        read -r -p "   请输入 Peer 地址 (例如 tcp://1.2.3.4:11010，直接回车结束输入): " peer_uri
        [ -z "$peer_uri" ] && break
        peers_config="${peers_config}\n[[peer]]\nuri = \"${peer_uri}\""
    done
fi

# 子网代理 (Proxy Network)
proxy_config=""
read -r -p "▶ 7. 是否需要代理并发布本地物理局域网网段？(y/N) [默认不代理]: " has_proxy
if [[ "$has_proxy" =~ ^[Yy]$ ]]; then
    while true; do
        read -r -p "   请输入本地局域网 CIDR (例如 192.168.1.0/24，直接回车结束输入): " proxy_cidr
        [ -z "$proxy_cidr" ] && break
        proxy_config="${proxy_config}\n[[proxy_network]]\ncidr = \"${proxy_cidr}\""
    done
fi

# 6. 生成写入 TOML
CONFIG_FILE="${CONF_DIR}/config.toml"
echo -e "${BLUE}[5/6] 正在写入配置文件...${PLAIN}"

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

# 写入子网代理
if [ -n "$proxy_config" ]; then
    echo -e "$proxy_config" >> "$CONFIG_FILE"
fi

# 写入对等连接
if [ -n "$peers_config" ]; then
    echo -e "$peers_config" >> "$CONFIG_FILE"
fi

# 写入 flags 开关（默认关闭延迟优先，确保在 OSPF 拓扑下能无阻碍直连）
cat <<EOF >> "$CONFIG_FILE"

[flags]
no_tun = false
enable_encryption = true
latency_first = false
EOF

echo -e "${GREEN}[+] 配置文件已成功写入: $CONFIG_FILE${PLAIN}"

# 7. 编写并注册 Systemd 服务
echo -e "${BLUE}[6/6] 正在注册并启动 Systemd 服务守护进程...${PLAIN}"
SERVICE_FILE="/etc/systemd/system/easytier.service"

# 清理可能残留的手动测试进程以防端口冲突
sudo killall easytier-core 2>/dev/null
sudo pkill -9 -f easytier-core 2>/dev/null

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

# 启动并使能服务
systemctl daemon-reload
systemctl enable --now easytier

echo -e "${GREEN}"
echo "======================================================"
echo "    EasyTier 部署与持久化配置完成！                   "
echo "======================================================"
echo -e "${PLAIN}"

# 查看服务状态
systemctl status easytier --no-pager

echo -e "\n${BLUE}常用运维命令提示：${PLAIN}"
echo -e "  查看网络直连状态:  ${GREEN}easytier-cli peer${PLAIN}"
echo -e "  查看虚拟路由表:    ${GREEN}easytier-cli route${PLAIN}"
echo -e "  查看本地侦听端口:  ${GREEN}easytier-cli node${PLAIN}"
echo -e "  查看实时服务日志:  ${GREEN}sudo journalctl -u easytier -f${PLAIN}"
echo -e "  重启服务守护进程:  ${GREEN}sudo systemctl restart easytier${PLAIN}"
