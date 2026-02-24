#!/bin/bash

# ==========================================
# 项目: LiJiaHao-Dev VPS-Ultra-Toolbox
# 功能: 动态 Swap | BBR+ | VLESS-Reality | WARP 分流
# 优化: NAT/LXC 容器兼容 · 极限内存友好版
# ==========================================

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}################################################${RESET}"
echo -e "${GREEN}#          LiJiaHao-Dev VPS Optimizer          #${RESET}"
echo -e "${GREEN}#    Dynamic Swap | BBR+ | VLESS-Reality       #${RESET}"
echo -e "${GREEN}#       NAT/LXC Compatible · Ultra-Lite        #${RESET}"
echo -e "${GREEN}################################################${RESET}"

# ==========================================
# 1. 基础环境自检
# ==========================================
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请使用 root 用户运行此脚本！${RESET}"
  exit 1
fi

echo -e "${YELLOW}---> [1/7] 正在初始化系统环境...${RESET}"

# 检测虚拟化架构，用于后续容器兼容性判断
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
echo -e "${CYAN}当前虚拟化环境: ${VIRT_TYPE}${RESET}"

IS_CONTAINER=false
case "$VIRT_TYPE" in
  lxc|lxc-libvirt|openvz|container-other)
    IS_CONTAINER=true
    echo -e "${YELLOW}[容器模式] 检测到 LXC/OpenVZ 容器，已启用兼容性保护。${RESET}"
    ;;
esac

# 精简依赖安装：移除 jq（脚本实际未使用），保留核心工具
# qrencode 用于二维码生成，openssl 用于 ShortID，lsof 用于端口检测
apt update -y > /dev/null 2>&1
apt install -y curl wget openssl qrencode lsof > /dev/null 2>&1

# 获取公网 IP
PUBLIC_IP=$(curl -s4 --connect-timeout 5 ipv4.icanhazip.com)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}错误: 无法获取公网 IP，请检查网络！${RESET}"
    exit 1
fi

# ==========================================
# 2. 动态 Swap 部署（容器兼容）
# ==========================================
echo -e "${YELLOW}---> [2/7] 正在检测系统资源并配置动态 Swap...${RESET}"
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
FREE_DISK=$(df -m / | awk 'NR==2{print $4}')
echo -e "当前状态: 内存 ${TOTAL_RAM}MB | 根目录可用硬盘 ${FREE_DISK}MB"

if [ "$TOTAL_RAM" -ge 3000 ]; then
    echo -e "${GREEN}物理内存充足，跳过 Swap 设置。${RESET}"
elif [ "$(swapon --show 2>/dev/null | wc -l)" -gt 0 ]; then
    echo -e "${GREEN}系统已存在 Swap，跳过设置。${RESET}"
else
    # 根据剩余磁盘空间计算 Swap 大小
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

        # fallocate 失败时回退 dd（部分容器文件系统不支持 fallocate）
        if ! fallocate -l ${SWAP_SIZE}M /swapfile 2>/dev/null; then
            echo -e "${YELLOW}fallocate 不可用，尝试 dd 方式创建 Swapfile...${RESET}"
            dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE} 2>/dev/null || true
        fi

        if [ -f /swapfile ]; then
            chmod 600 /swapfile
            mkswap /swapfile > /dev/null 2>&1 || true

            # ★ 容器兼容：使用 || true 捕获 swapon 权限错误
            if swapon /swapfile 2>/dev/null; then
                # 避免重复写入 fstab
                grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                echo -e "${GREEN}Swap 部署完成！${RESET}"
            else
                echo -e "${YELLOW}[容器限制] 检测到容器环境限制，跳过 Swap 挂载（Swapfile 已创建但未激活）。${RESET}"
                rm -f /swapfile
            fi
        else
            echo -e "${RED}警告: Swapfile 创建失败，跳过 Swap 部署！${RESET}"
        fi
    else
        echo -e "${RED}警告: 硬盘空间极危，跳过 Swap 部署！${RESET}"
    fi
fi

# ==========================================
# 3. 内核网络提速（BBR，容器兼容）
# ==========================================
echo -e "${YELLOW}---> [3/7] 正在尝试内核级 TCP 拥塞控制优化...${RESET}"

if [ "$IS_CONTAINER" = true ]; then
    echo -e "${YELLOW}[容器模式] 容器环境下 sysctl 写入可能受限，将尝试运行时生效（不修改 sysctl.conf）...${RESET}"
    # 仅尝试运行时设置，失败则静默跳过
    sysctl -w net.core.default_qdisc=fq 2>/dev/null             || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null   || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_wmem="4096 16384 16777216" 2>/dev/null || true
    # 验证 BBR 是否实际生效
    ACTUAL_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$ACTUAL_CC" = "bbr" ]; then
        echo -e "${GREEN}BBR 已在运行时生效（拥塞算法: bbr）！${RESET}"
    else
        echo -e "${YELLOW}[容器限制] BBR 未能生效（当前算法: ${ACTUAL_CC}），已优雅跳过，不影响部署。${RESET}"
    fi
else
    # 物理机 / KVM：追加写入 sysctl.conf 并持久化
    # 避免重复追加
    if ! grep -q 'tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then
        cat >> /etc/sysctl.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
SYSCTL
    fi
    sysctl -p > /dev/null 2>&1 || true
    echo -e "${GREEN}BBR 与 TCP 缓冲区优化已写入并生效！${RESET}"
fi

# ==========================================
# 4. 端口冲突避让与 Xray 核心安装
# ==========================================
echo -e "${YELLOW}---> [4/7] 正在部署 Xray 核心...${RESET}"

LISTEN_PORT=443
if lsof -i:$LISTEN_PORT > /dev/null 2>&1; then
    LISTEN_PORT=$((RANDOM % 10000 + 40000))
    echo -e "${YELLOW}443 端口被占用，自动回退到高位端口: ${LISTEN_PORT}${RESET}"
fi

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

if ! command -v xray > /dev/null 2>&1; then
    echo -e "${RED}错误: Xray 安装失败，请检查网络或手动安装！${RESET}"
    exit 1
fi
echo -e "${GREEN}Xray 核心安装完成！${RESET}"

# ==========================================
# 5. 生成 Reality 加密凭证
# ==========================================
echo -e "${YELLOW}---> [5/7] 正在生成 VLESS-Reality 加密凭证...${RESET}"

UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public"  | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
SNI="images.apple.com"

echo -e "${GREEN}UUID / 密钥对生成完毕。${RESET}"

# ==========================================
# 6. 可选 WARP 分流（含 NAT 风险警告）
# ==========================================
echo -e "${YELLOW}---> [6/7] 可选模块：WARP 解锁配置${RESET}"
echo -e "${RED}[!!!警告!!!] NAT/LXC 容器通常缺失 tun/tap 内核模块，强行安装 WARP"
echo -e "            可能导致机器断网失联！如果是 NAT 机器请务必选 n ！${RESET}"
read -p "是否需要安装 WARP 解决 Google 验证码并解锁 Netflix? (y/n) [NAT机推荐选n]: " INSTALL_WARP

WARP_OUTBOUND=""
WARP_ROUTING=""

if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}正在安装并注册 Cloudflare WARP...${RESET}"
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt update -y > /dev/null 2>&1 && apt install -y cloudflare-warp > /dev/null 2>&1
    warp-cli --accept-tos register  > /dev/null 2>&1
    warp-cli --accept-tos set-mode proxy > /dev/null 2>&1
    warp-cli --accept-tos connect   > /dev/null 2>&1

    WARP_OUTBOUND=',{"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}}'
    WARP_ROUTING=',{"type":"field","domain":["geosite:google","geosite:netflix","geosite:disney"],"outboundTag":"warp"}'
    echo -e "${GREEN}WARP Socks5 分流已准备完毕！${RESET}"
else
    echo -e "${GREEN}已跳过 WARP 安装。${RESET}"
fi

# ==========================================
# 写入 Xray 配置文件
# ==========================================
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${LISTEN_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${SNI}:443",
        "xver": 0,
        "serverNames": ["${SNI}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole","tag": "block"}
    ${WARP_OUTBOUND}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}
      ${WARP_ROUTING}
    ]
  }
}
EOF

# ==========================================
# 启动 Xray 服务 & 放行防火墙
# ==========================================
command -v ufw > /dev/null 2>&1 && ufw allow ${LISTEN_PORT}/tcp > /dev/null 2>&1
systemctl restart xray
systemctl enable xray > /dev/null 2>&1
echo -e "${GREEN}Xray 服务已启动并设置为开机自启。${RESET}"

# ==========================================
# 7. 生成结果交付
# ==========================================
echo -e "${YELLOW}---> [7/7] 部署完成！正在生成链接...${RESET}"
sleep 1

VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#LJH-Dev-Node"

echo -e "\n${GREEN}================================================${RESET}"
echo -e "${YELLOW}节点协议:${RESET}  VLESS + TCP + REALITY + Vision"
echo -e "${YELLOW}服务器 IP:${RESET} ${PUBLIC_IP}"
echo -e "${YELLOW}内部端口:${RESET} ${LISTEN_PORT}"
echo -e "${YELLOW}伪装域名:${RESET} ${SNI}"
echo -e "${GREEN}================================================${RESET}\n"

echo -e "${YELLOW}Shadowrocket / v2rayNG 导入链接:${RESET}"
echo -e "${GREEN}${VLESS_LINK}${RESET}\n"

echo -e "${YELLOW}手机端扫描二维码快速导入:${RESET}"
qrencode -t ANSIUTF8 "$VLESS_LINK"

# ★ NAT 机专属提醒
echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${RED}║         【NAT 机专属提醒 · 必读！】                          ║${RESET}"
echo -e "${RED}║  当前链接使用的是服务器「内部端口」(${LISTEN_PORT})。           ║${RESET}"
echo -e "${RED}║  ① 请登录您的服务商控制面板，将内部端口 ${LISTEN_PORT} 映射    ║${RESET}"
echo -e "${RED}║     到一个公网可访问的「外部端口」。                          ║${RESET}"
echo -e "${RED}║  ② 在您的代理客户端中，手动将端口改为「外部端口」后          ║${RESET}"
echo -e "${RED}║     方可正常连接，否则将无法建立连接！                       ║${RESET}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${RESET}\n"

echo -e "${RED}[安全提醒] 建议随后手动修改 SSH 端口（默认 22），降低安全风险。${RESET}"

# ==========================================
# 8. 清理缓存（256MB 内存优化）
# ==========================================
echo -e "${YELLOW}正在清理 APT 缓存以释放内存与磁盘...${RESET}"
apt autoremove -y > /dev/null 2>&1
apt clean > /dev/null 2>&1
echo -e "${GREEN}缓存清理完毕。${RESET}"

echo -e "\n${GREEN}感谢使用 LiJiaHao-Dev 脚本！Enjoy your network!${RESET}\n"
