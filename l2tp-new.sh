#!/bin/bash

VPN_IPSEC_PSK='vpnuser.com'
VPN_USER='vpnuser'
VPN_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

# 自动检测公网网卡名
PUBLIC_INTERFACE=$(ip route get 1 | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}')

echo "[+] 安装 strongSwan, xl2tpd 和依赖..."
apt update
apt install -y strongswan xl2tpd ppp lsof iptables curl ufw bsdmainutils

# 配置 IPsec
cat > /etc/ipsec.conf <<EOF
config setup
  charondebug="all"
  uniqueids=no

conn %default
  keyexchange=ikev1
  ikelifetime=8h
  keylife=1h
  rekey=no
  authby=secret
  ike=aes256-sha2_256-modp1024
  esp=aes256-sha2_256

conn L2TP-PSK
  keyexchange=ikev1
  left=%any
  leftid=$(curl -s https://ip.gs)
  leftsubnet=0.0.0.0/0
  leftfirewall=yes
  right=%any
  rightprotoport=17/1701
  type=transport
  auto=add
  dpdaction=restart
  dpddelay=30
  dpdtimeout=120
EOF

echo "%any  %any  : PSK \"$VPN_IPSEC_PSK\"" > /etc/ipsec.secrets

# 配置 xl2tpd
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = 192.168.18.10-192.168.18.250
local ip = 192.168.18.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# 配置 PPP
cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 1.1.1.1
auth
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu 1400
mru 1400
EOF

# 创建用户认证文件
echo "$VPN_USER    l2tpd   $VPN_PASSWORD   *" > /etc/ppp/chap-secrets

# 启用 IP 转发
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
echo 1 > /proc/sys/net/ipv4/ip_forward

# 设置 UFW 默认转发策略
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# 添加 UFW NAT 规则（before.rules）
UFW_RULES=/etc/ufw/before.rules
if ! grep -q "^*nat" $UFW_RULES; then
  sed -i "1i *nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 192.168.18.0/24 -o $PUBLIC_INTERFACE -j MASQUERADE\nCOMMIT\n" $UFW_RULES
fi

# 添加 SSH 放行（重要）
ufw allow 22/tcp
ufw allow 500/udp
ufw allow 4500/udp
ufw allow 1701/udp

# 启用 UFW
ufw disable
ufw --force enable

# 保留 legacy iptables 规则并允许 SSH
iptables -t nat -A POSTROUTING -s 192.168.18.0/24 -o $PUBLIC_INTERFACE -j MASQUERADE
iptables -I INPUT -p udp --dport 500 -j ACCEPT
iptables -I INPUT -p udp --dport 4500 -j ACCEPT
iptables -I INPUT -p udp --dport 1701 -j ACCEPT
iptables -I INPUT -p tcp --dport 22 -j ACCEPT  # 允许 SSH
iptables-save > /etc/iptables.rules

cat > /etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-pre-up.d/iptablesload

# 启动服务
systemctl enable strongswan-starter
systemctl restart strongswan-starter
systemctl enable xl2tpd
systemctl restart xl2tpd

# 创建 l2tp 命令
cat > /usr/local/bin/l2tp <<'EOF'
#!/bin/bash
PPP_SECRETS="/etc/ppp/chap-secrets"

function list_users() {
  echo -e "\n当前账户信息："
  echo -e "用户名\t密码"
  awk '!/^[[:space:]]*($|#)/ {print $1 "\t" $3}' $PPP_SECRETS | column -t
}

function add_user() {
  if [ $# -ne 2 ]; then
    echo "用法: l2tp -a 用户名 密码"
    exit 1
  fi
  if grep -q "^$1\s" $PPP_SECRETS; then
    echo "用户 $1 已存在！"
    exit 1
  fi
  echo "$1    l2tpd   $2   *" >> $PPP_SECRETS
  echo "用户 $1 添加成功。"
}

function del_user() {
  if [ $# -ne 1 ]; then
    echo "用法: l2tp -d 用户名"
    exit 1
  fi
  if ! grep -q "^$1\s" $PPP_SECRETS; then
    echo "用户 $1 不存在！"
    exit 1
  fi
  sed -i "/^$1\s/d" $PPP_SECRETS
  echo "用户 $1 删除成功。"
}

function start_vpn() {
  systemctl start strongswan-starter
  systemctl start xl2tpd
  echo "VPN 服务已启动。"
}

function stop_vpn() {
  systemctl stop xl2tpd
  systemctl stop strongswan-starter
  echo "VPN 服务已停止。"
}

case "$1" in
  -l)
    list_users
    ;;
  -a)
    shift
    add_user "$@"
    ;;
  -d)
    shift
    del_user "$@"
    ;;
  -start)
    start_vpn
    ;;
  -stop)
    stop_vpn
    ;;
  *)
    echo "用法: l2tp {-l|-a 用户名 密码|-d 用户名|-start|-stop}"
    ;;
esac
EOF

chmod +x /usr/local/bin/l2tp

# 输出结果
echo ""
echo "✅ L2TP/IPSec VPN 安装完成！"
echo "-----------------------------------------"
echo "服务器公网IP: $(curl -s https://ip.gs)"
echo "IPSec PSK:     $VPN_IPSEC_PSK"
echo "VPN 用户名:    $VPN_USER"
echo "VPN 密码:      $VPN_PASSWORD"
echo "-----------------------------------------"
echo "新增管理命令：l2tp"
echo "示例："
echo "  l2tp -l                # 查看账户"
echo "  l2tp -a username pass  # 增加账户"
echo "  l2tp -d username       # 删除账户"
echo "  l2tp -start            # 启动服务"
echo "  l2tp -stop             # 停止服务"
