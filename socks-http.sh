#!/bin/bash
set -e

# 固定参数
USER_NAME="user"
USER_PASS="123456"
SOCKS_BASE=10000
HTTP_BASE=11000
CONF_FILE="/etc/3proxy/3proxy.cfg"
OUT_FILE="/root/proxy_list.txt"

echo "=== [1/6] 安装依赖 ==="
apt update -y
apt install -y gcc make git ufw

echo "=== [2/6] 编译安装 3proxy ==="
cd /usr/local/src
[ -d 3proxy ] || git clone --branch 0.9.5 --depth 1 https://github.com/z3APA3A/3proxy.git
cd 3proxy
make -f Makefile.Linux

# 避免 Text file busy
systemctl stop 3proxy 2>/dev/null || true
cp bin/3proxy /usr/local/bin/3proxy

echo "=== [3/6] systemd 服务 ==="
cat > /etc/systemd/system/3proxy.service << EOL
[Unit]
Description=3Proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/3proxy $CONF_FILE
Restart=always
LimitNOFILE=500000

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reexec
systemctl daemon-reload

echo "=== [4/6] 自动识别公网 IP 并生成配置 ==="

IPS=$(ip -4 addr show scope global \
 | grep -Ev 'wg|tun|tap' \
 | awk '/inet /{print $2}' \
 | cut -d/ -f1 \
 | grep -Ev '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)')

mkdir -p /etc/3proxy /var/log/3proxy

# 基础配置
cat > $CONF_FILE << EOC
daemon
maxconn 5000
nserver 1.1.1.1
nserver 8.8.8.8
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy/3proxy.log D
rotate 30

auth strong
users $USER_NAME:CL:$USER_PASS
allow $USER_NAME
deny *
EOC

# 输出文件初始化
echo "" > $OUT_FILE

# 生成 SOCKS5 配置
echo "SOCKS5:" >> $OUT_FILE
i=1
for ip in $IPS; do
    SOCKS_PORT=$((SOCKS_BASE+i))
    echo "socks -p$SOCKS_PORT -i$ip -e$ip" >> $CONF_FILE
    echo "$ip:$SOCKS_PORT:$USER_NAME:$USER_PASS" >> $OUT_FILE

    # 放行防火墙
    ufw allow $SOCKS_PORT/tcp

    i=$((i+1))
done
echo "" >> $OUT_FILE

# 生成 HTTP 配置
echo "HTTP:" >> $OUT_FILE
i=1
for ip in $IPS; do
    HTTP_PORT=$((HTTP_BASE+i))
    echo "proxy -p$HTTP_PORT -i$ip -e$ip" >> $CONF_FILE
    echo "$ip:$HTTP_PORT:$USER_NAME:$USER_PASS" >> $OUT_FILE

    # 放行防火墙
    ufw allow $HTTP_PORT/tcp

    i=$((i+1))
done
echo "" >> $OUT_FILE

echo "=== [5/6] 启动 3proxy ==="
systemctl enable 3proxy
systemctl restart 3proxy

echo "=== [6/6] 启用 UFW 防火墙 ==="
ufw --force enable
ufw reload

echo
echo "✅ 安装完成"
echo "📄 代理清单：$OUT_FILE"
echo "--------------------------------"
cat $OUT_FILE
echo "--------------------------------"
