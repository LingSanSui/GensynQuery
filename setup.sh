#!/bin/bash

# StandX-MM-Swarm 自动化部署脚本
#
# 使用方法:
# 1. 基础部署: ./setup.sh [GIT_TOKEN]
# 2. 带 Tailscale 组网部署: export TS_AUTH_KEY="tskey-xxx" && ./setup.sh [GIT_TOKEN]
#
# 环境变量:
#   TS_AUTH_KEY: Tailscale Reusable Auth Key (可选，用于自动组网)
#   ENABLE_SOCKS5: 设置为 "true" 可自动安装 Socks5 代理 (默认交互式询问)

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ==========================================
# 0. 内存优化 (Swap 自动配置)
# 针对 1GB RAM 机器防止 OOM
# ==========================================

# 辅助函数: 等待 apt 锁释放
wait_for_apt_lock() {
    echo "检查 apt/dpkg 锁状态..."
    while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "等待其他 apt/dpkg 进程结束..."
        sleep 5
    done
}

echo -e "${YELLOW}检查内存与 Swap 配置...${NC}"

# 检查是否存在 swapfile
if [ -f /swapfile ]; then
    echo -e "${GREEN}Swap 文件已存在。${NC}"
else
    # 检查当前内存
    TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    # 如果内存小于 2GB (约 2000000 KB)，或者强制创建
    echo -e "${YELLOW}正在创建 2GB Swap 文件以防止 OOM...${NC}"
    
    # 1. 创建 2GB 文件 (2G = 2 * 1024 * 1024 = 2097152 blocks of 1KB, or just use G suffix if fallocate supports)
    # 优先使用 fallocate (速度快)，如果失败则回退到 dd
    if command -v fallocate > /dev/null; then
        sudo fallocate -l 2G /swapfile
    else
        sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
    fi

    # 2. 设置权限
    sudo chmod 600 /swapfile

    # 3. 启用 Swap
    sudo mkswap /swapfile
    sudo swapon /swapfile

    # 4. 写入 fstab 确保重启生效
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi

    # 5. 调整内核参数 vm.swappiness
    # 默认通常是 60，对于小内存机器，60 是合理的 (积极使用 swap)
    # 如果需要更积极，可以设为 60-80；如果只想保命，设 10-60。
    # 用户要求：调整为 60 (通常默认就是 60，但显式设置确保一致性)
    sudo sysctl vm.swappiness=60
    # 写入 sysctl.conf
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo 'vm.swappiness=60' | sudo tee -a /etc/sysctl.conf
    else
        sudo sed -i 's/vm.swappiness.*/vm.swappiness=60/' /etc/sysctl.conf
    fi

    echo -e "${GREEN}Swap 配置完成: 2GB 已挂载。${NC}"
fi

# 显示当前内存状态
free -h

# ==========================================
# 1. Tailscale 自动组网
# ==========================================
if [ -n "$TS_AUTH_KEY" ]; then
    echo -e "${YELLOW}检测到 TS_AUTH_KEY，准备安装并配置 Tailscale...${NC}"
    
    # 等待 apt 锁
    wait_for_apt_lock
    
    # 检查并安装 Tailscale
    if ! command -v tailscale &> /dev/null; then
        echo "正在安装 Tailscale..."
        # 增加重试逻辑
        for i in {1..3}; do
            curl -fsSL https://tailscale.com/install.sh | sh && break
            echo -e "${RED}Tailscale 安装失败，5秒后重试 ($i/3)...${NC}"
            sleep 5
        done
    else
        echo "Tailscale 已安装"
    fi

    # 启动 Tailscale
    echo "正在加入 Tailscale 网络..."
    sudo tailscale up --authkey=$TS_AUTH_KEY --accept-routes --timeout=30s
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Tailscale 组网成功!${NC}"
    else
        echo -e "${RED}Tailscale 组网失败，请检查 Key 是否有效或网络连接。${NC}"
    fi
else
    echo -e "${YELLOW}未提供 TS_AUTH_KEY，跳过 Tailscale 配置。${NC}"
fi

# ==========================================
# 2. 检查并安装 Docker
# ==========================================
if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    
    # 等待 apt 锁
    wait_for_apt_lock

    # 尝试使用官方脚本，如果失败可以考虑阿里云镜像 (针对亚洲/国内优化)
    # 但由于目标是香港/日本/新加坡，官方源通常没问题，主要是偶尔网络抖动
    for i in {1..3}; do
        curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh && break
        echo -e "${RED}Docker 安装失败，5秒后重试 ($i/3)...${NC}"
        sleep 5
    done
    rm -f get-docker.sh
    echo "Docker 安装完成"
else
    echo "Docker 已安装"
fi

# ==========================================
# 2.5. (可选) 安装 Socks5 代理
# ==========================================
# 默认直接安装，除非环境变量 ENABLE_SOCKS5=false
INSTALL_SOCKS5=true

if [ "$ENABLE_SOCKS5" == "false" ]; then
    INSTALL_SOCKS5=false
fi

if [ "$INSTALL_SOCKS5" == "true" ]; then
    echo -e "${YELLOW}正在安装 Socks5 代理 (gost)...${NC}"
    
    # 拉取镜像
    docker pull ginuerzh/gost
    
    # 清理旧容器
    docker stop socks5-proxy 2>/dev/null || true
    docker rm socks5-proxy 2>/dev/null || true
    
    # 启动容器 (使用 host 网络模式以获得最佳性能和直接端口监听)
    docker run -d --name socks5-proxy \
        --restart always \
        --network host \
        --log-opt max-size=10m \
        ginuerzh/gost \
        -L "socks5://ygy:Xnb666888.@:9876"
        
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Socks5 代理启动成功!${NC}"
        echo -e "地址: ${GREEN}<本机IP>:9876${NC}"
        echo -e "认证: ${GREEN}ygy / Xnb666888.${NC}"
    else
        echo -e "${RED}Socks5 代理启动失败，请检查 Docker 日志。${NC}"
    fi
else
    echo "跳过 Socks5 代理安装。"
fi

# ==========================================
# 3. 拉取/更新代码
# ==========================================
GIT_TOKEN=$1
# 默认仓库地址
REPO_URL="https://github.com/LingSanSui/StandX-MM-Swarm.git"

if [ -n "$GIT_TOKEN" ]; then
    # 插入 Token 到 URL
    REPO_URL="https://$GIT_TOKEN@github.com/LingSanSui/StandX-MM-Swarm.git"
fi

echo -e "${YELLOW}准备拉取代码...${NC}"

# 定义重试函数
git_retry() {
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        "$@" && return 0
        echo -e "${RED}Git 操作失败，等待 5 秒后重试 ($attempt/$max_attempts)...${NC}"
        sleep 5
        ((attempt++))
    done
    return 1
}

if [ -d "StandX-MM-Swarm" ]; then
    echo "目录已存在，执行 git pull..."
    cd StandX-MM-Swarm
    # 尝试重置并拉取，防止本地冲突
    git_retry git fetch origin
    git reset --hard origin/main
    git_retry git pull
else
    echo "目录不存在，执行 git clone..."
    git_retry git clone $REPO_URL
    cd StandX-MM-Swarm
fi

# ==========================================
# 4. 配置文件处理
# ==========================================
if [ ! -f .env ]; then
    echo "创建 .env 模版..."
    cat <<EOF > .env
# StandX Configuration
STANDX_AUTH_URL=https://api.standx.com
STANDX_PERPS_URL=https://perps.standx.com
STANDX_WS_URL=wss://perps.standx.com/ws-stream/v1

# Swarm Configuration
SWARM_MANAGER_IP=http://localhost:8501
EOF
    echo -e "${YELLOW}.env 文件已创建!${NC}"
fi

# ==========================================
# 5. 构建并启动 Docker 容器
# ==========================================

# 获取 Tailscale IP (用于绑定)
TS_BIND_IP="0.0.0.0"
if command -v tailscale &> /dev/null; then
    TS_IP_CHECK=$(tailscale ip -4)
    if [ -n "$TS_IP_CHECK" ]; then
        echo -e "${GREEN}检测到 Tailscale IP: $TS_IP_CHECK${NC}"
        
        # 尝试优雅停止旧服务
        echo -e "${YELLOW}正在尝试通知旧服务停止运行 (POST /stop)...${NC}"
        # 设置2秒超时，忽略输出
        if curl -X POST "http://$TS_IP_CHECK:8000/stop" --max-time 2 >/dev/null 2>&1; then
             echo -e "${GREEN}停止指令发送成功，等待服务清理...${NC}"
        else
             echo -e "${YELLOW}停止指令发送失败或超时 (可能服务未运行)，继续后续步骤...${NC}"
        fi
        # 等待3秒
        sleep 3

        # 安装 Tailscale 保活服务
        echo "安装 Tailscale 保活服务..."
        sudo cp scripts/keepalive_tailscale.sh /usr/local/bin/standx-keepalive-tailscale.sh
        sudo chmod +x /usr/local/bin/standx-keepalive-tailscale.sh
        sudo cp scripts/standx-tailscale-keepalive.service /etc/systemd/system/
        
        sudo systemctl daemon-reload
        sudo systemctl enable standx-tailscale-keepalive.service
        sudo systemctl start standx-tailscale-keepalive.service
        echo -e "${GREEN}Tailscale 保活服务已启动 (standx-tailscale-keepalive)${NC}"

        echo -e "${YELLOW}为了安全，Agent 将仅绑定到 Tailscale IP (仅内网访问)。${NC}"
        TS_BIND_IP=$TS_IP_CHECK
    else
        echo -e "${YELLOW}Tailscale 已安装但未获取到 IP，回退到 0.0.0.0${NC}"
    fi
else
    echo -e "${YELLOW}未检测到 Tailscale，Agent 将绑定到 0.0.0.0 (公网可访问)${NC}"
fi


# 1. 停止并清理旧容器
echo "停止旧容器..."
docker stop standx-bot-container || true
docker rm standx-bot-container || true

# 2. 清理旧镜像 (只清理名为 standx-bot 的镜像，避免清理掉基础镜像)
# 使用 2>/dev/null 忽略报错 (例如镜像不存在时)
echo "清理旧镜像..."
docker rmi standx-bot 2>/dev/null || true

echo "构建 Docker 镜像..."
docker build --network host -t standx-bot .

echo "启动容器..."

# 启动新容器 
# 限制内存使用，防止彻底卡死宿主机 (预留 100M 给系统)
# 对于 1GB 机器，限制容器使用 800M
docker run -d \
  --name standx-bot-container \
  --restart always \
  --network host \
  --memory="800m" \
  --memory-swap="2g" \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  -v $(pwd)/.env:/app/.env \
  standx-bot \
  uvicorn app.agent:app --host $TS_BIND_IP --port 8000

echo -e "${GREEN}部署完成! 服务运行在 $TS_BIND_IP:8000${NC}"

# ==========================================
# 6. 结果汇总
# ==========================================
if command -v tailscale &> /dev/null; then
    TS_IP=$(tailscale ip -4)
    if [ -n "$TS_IP" ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Tailscale IP: ${TS_IP}${NC}"
        echo -e "${GREEN}请复制此 IP 到 nodes.json 中${NC}"
        echo -e "${GREEN}========================================${NC}"
    fi
fi
