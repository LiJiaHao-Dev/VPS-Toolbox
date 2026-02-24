#!/bin/bash

# ==========================================
# 项目: LiJiaHao-Dev VPS-Ultra-Toolbox
# 功能: 动态 Swap | BBR+ | VLESS-Reality | WARP 分流
# ==========================================

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${GREEN}################################################${RESET}"
echo -e "${GREEN}#          LiJiaHao-Dev VPS Optimizer          #${RESET}"
echo -e "${GREEN}#        Dynamic Swap | BBR+ | VLESS-R         #${RESET}"
echo -e "${GREEN}################################################${RESET}"

# 1. 基础环境自检与清理
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 用户运行此脚本！${RESET}"
  exit 1
fi

echo -e "${YELLOW}---> [1/7] 正在初始化系统环境并清理残余...${RESET}"
apt update -y > /dev/null 2>&1
apt install -y curl wget jq openssl qrencode lsof > /dev/null 2>&1
apt autoremove -y > /dev/null 2>&1

# 获取公网 IP
PUBLIC_IP=$(curl -s4 --connect-timeout 5 ipv4.icanhazip.com)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}错误: 无法获取公网 IP，请检查网络！${RESET}"
    exit 1
fi

# 2. 动态 Swap 部署 (根据硬盘剩余空间智能计算)
echo -e "${YELLOW}---> [2/7] 正在检测系统资源并配置动态 Swap...${RESET}"
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
FREE_DISK=$(df -m / | awk 'NR==2{print $4}')

echo -e "当前状态: 内存 ${TOTAL_RAM}MB | 根目录可用硬盘 ${FREE_DISK}MB"

if [ "$TOTAL_RAM" -ge 3000 ]; then
    echo -e "${GREEN}物理内存充足，跳过 Swap 设置。${RESET}"
elif [ $(swapon --show | wc -l) -gt 0 ]; then
    echo -e "${GREEN}系统已存在 Swap，跳过设置。${RESET}"
else
    if [ "$FREE_DISK" -gt 10000 ]; then
        SWAP_SIZE=2048
    elif [ "$FREE_DISK" -gt 4000 ]; then
        SWAP_SIZE=1024
    elif [ "$FREE_DISK" -gt 2000 ]; then
        SWAP_SIZE=512
    else
        SWAP_SIZE=0
    fi

    if [ "$SWAP_SIZE" -gt 0 ]; then
        echo -e "分配 ${SWAP_SIZE}MB Swap..."
        fallocate -l ${SWAP_SIZE}M /swapfile
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}Swap 部署完成！${RESET}"
    else
        echo -e "${RED}警告: 硬盘空间极危，跳过 Swap 部署！${RESET}"
    fi
fi

# 3. 内核网络提速 (BBR 暴力优化)
echo -e "${YELLOW}---> [3/7] 正在进行内核级 TCP 拥塞控制优化...${RESET}"
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
EOF
sysctl -p > /dev/null 2>&1
echo -e "${GREEN}BBR 与 TCP 缓冲区优化已生效！${RESET}"

# 4. 端口冲突避让与 Xray 核心安装
echo -e "${YELLOW}---> [4/7] 正在部署 Xray 核心...${RESET}"
LISTEN_PORT=443
if lsof -i:$LISTEN_PORT > /dev/null 2>&1; then
    LISTEN_PORT=$((RANDOM % 10000 + 40000))
    echo -e "${YELLOW}443 端口被占用，自动回退到防扫高位端口: $LISTEN_PORT${RESET}"
fi

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

# 5. 生成 Reality 凭证
echo -e "${YELLOW}---> [5/7] 正在生成 VLESS-Reality 加密凭证...${RESET}"
UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
SNI="images.apple.com"

# 6. WARP 流媒体分流 (交互自选)
echo -e "${YELLOW}---> [6/7] 可选模块：WARP 解锁配置${RESET}"
read -p "是否需要安装 WARP 解决 Google 验证码并解锁 Netflix? (y/n): " INSTALL_WARP

WARP_OUTBOUND=""
WARP_ROUTING=""

if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "正在安装并注册 Cloudflare WARP..."
    # 极简版 WARP-CLI 代理模式配置
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt update -y > /dev/null 2>&1 && apt install -y cloudflare-warp > /dev/null 2>&1
    warp-cli --accept-tos register > /dev/null 2>&1
    warp-cli --accept-tos set-mode proxy > /dev/null 2>&1
    warp-cli --accept-tos connect > /dev/null 2>&1
    
    # 拼接 WARP JSON 块
    WARP_OUTBOUND=',{"protocol": "socks","tag": "warp","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}'
    WARP_ROUTING=',{"type": "field","domain": ["geosite:google","geosite:netflix","geosite:disney"],"outboundTag": "warp"}'
    echo -e "${GREEN}WARP Socks5 分流已准备完毕！${RESET}"
fi

# 写入完整配置文件
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID","flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [
    {"protocol": "freedom","tag": "direct"},
    {"protocol": "blackhole","tag": "block"}
    $WARP_OUTBOUND
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field","ip": ["geoip:private"],"outboundTag": "block"}
      $WARP_ROUTING
    ]
  }
}
EOF

# 启动与放行
if command -v ufw > /dev/null 2>&1; then ufw allow $LISTEN_PORT/tcp > /dev/null 2>&1; fi
systemctl restart xray
systemctl enable xray

# 7. 生成结果交付
echo -e "${YELLOW}---> [7/7] 部署完成！正在生成链接...${RESET}"
sleep 2

# 拼接 VLESS 链接
VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#LJH-Dev-Node"

echo -e "\n${GREEN}================================================${RESET}"
echo -e "${YELLOW}节点协议:${RESET} VLESS + TCP + REALITY + Vision"
echo -e "${YELLOW}服务器 IP:${RESET} $PUBLIC_IP"
echo -e "${YELLOW}监听端口:${RESET} $LISTEN_PORT"
echo -e "${YELLOW}伪装域名:${RESET} $SNI"
echo -e "${GREEN}================================================${RESET}\n"

echo -e "${YELLOW}Shadowrocket / v2rayNG 订阅链接 (请复制以下全段):${RESET}"
echo -e "${GREEN}${VLESS_LINK}${RESET}\n"

echo -e "${YELLOW}手机端扫描二维码快速导入:${RESET}"
qrencode -t ANSIUTF8 "$VLESS_LINK"

echo -e "\n${RED}[安全提醒] 检测到您可能仍在使用 22 端口，建议随后手动修改以降低系统负载。${RESET}"
echo -e "${GREEN}感谢使用 LiJiaHao-Dev 脚本！Enjoy your network!${RESET}\n"