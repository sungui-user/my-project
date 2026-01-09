#!/bin/bash
set -euo pipefail

########################################
# 0. 基本检查
########################################
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

########################################
# 1. 系统版本检测（20.04 / 22.04 / 24.04）
########################################
. /etc/os-release

if [ "$ID" != "ubuntu" ]; then
  echo "Only Ubuntu supported"
  exit 1
fi

case "$VERSION_ID" in
  "20.04"|"22.04"|"24.04")
    UBUNTU_VER="$VERSION_ID"
    ;;
  *)
    echo "Unsupported Ubuntu version: $VERSION_ID"
    exit 1
    ;;
esac

########################################
# 安装 Zabbix 7.0 仓库（推荐）
########################################
ZBX_DEB="zabbix-release_latest+ubuntu${UBUNTU_VER}_all.deb"
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/${ZBX_DEB}
dpkg -i ${ZBX_DEB}
apt update

########################################
# 3. 安装组件
########################################
apt install -y zabbix-agent2 vnstat curl

########################################
# 4. 生成 vnstat LLD 脚本
########################################
mkdir -p /usr/local/bin
cat <<'EOF' >/usr/local/bin/vnstat_mainnet.sh
#!/bin/bash
# 自动识别默认路由网卡
IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && exit 1

echo "{\"data\":[{\"{#IFNAME}\":\"$IFACE\"}]}"
EOF

chmod +x /usr/local/bin/vnstat_mainnet.sh

########################################
# 5. 生成 vnstat 月流量脚本
########################################
cat <<'EOF' >/usr/local/bin/vnstat_mainnet_monthly.sh
#!/bin/bash
# 参数 $1 是网卡名
IFACE=$1
[ -z "$IFACE" ] && exit 1

CUR_MONTH=$(date '+%Y-%m')

vnstat -i "$IFACE" -m | awk -v month="$CUR_MONTH" '
function to_bytes(val, unit){
    if(unit=="B")   return val
    if(unit=="KiB") return val*1024
    if(unit=="MiB") return val*1024*1024
    if(unit=="GiB") return val*1024*1024*1024
    if(unit=="TiB") return val*1024*1024*1024*1024
    return 0
}

$1 == month {
    n = 0
    for(i=2;i<=NF;i++){
        if($i ~ /^[0-9.]+$/ && $(i+1) ~ /^(B|KiB|MiB|GiB|TiB)$/){
            n++
            if(n==1) rx = to_bytes($i, $(i+1))
            if(n==2) tx = to_bytes($i, $(i+1))
        }
    }
    printf "%.0f\n", rx + tx
    exit
}
'
EOF

chmod +x /usr/local/bin/vnstat_mainnet_monthly.sh

########################################
# 6. 获取主网卡 & 公网 IP
########################################
IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && { echo "Cannot detect main interface"; exit 1; }

PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(hostname -I | awk '{print $1}')

########################################
# 7. 强制重写 Zabbix Agent2 配置（IP 作为 Hostname）
########################################
CONF="/etc/zabbix/zabbix_agent2.conf"

# 1️⃣ 彻底删除所有相关参数（不管是否注释）
sed -i '/^[[:space:]]*Server[[:space:]]*=.*/d' "$CONF"
sed -i '/^[[:space:]]*ServerActive[[:space:]]*=.*/d' "$CONF"
sed -i '/^[[:space:]]*Hostname[[:space:]]*=.*/d' "$CONF"
sed -i '/^[[:space:]]*HostnameItem[[:space:]]*=.*/d' "$CONF"
sed -i '/^[[:space:]]*HostMetadata[[:space:]]*=.*/d' "$CONF"
sed -i '/^[[:space:]]*Timeout[[:space:]]*=.*/d' "$CONF"
sed -i '/^[[:space:]]*RefreshActiveChecks[[:space:]]*=.*/d' "$CONF"

# 2️⃣ 明确写入我们要的最终值（IP Hostname）
cat <<EOF >> "$CONF"

### ===== Managed by install script =====
Server=zabbix.luyaonet.com
ServerActive=zabbix.luyaonet.com

# 强制使用公网 IP 作为 Hostname
Hostname=${PUBLIC_IP}

HostMetadata=vps-ubuntu22
Timeout=30
RefreshActiveChecks=120
### ====================================
EOF


########################################
# 8. UserParameter 配置
########################################
cat <<EOF >/etc/zabbix/zabbix_agent2.d/vnstat.conf
UserParameter=mainnet.lld,/usr/local/bin/vnstat_mainnet.sh
UserParameter=mainnet.monthly[*],/usr/local/bin/vnstat_mainnet_monthly.sh \$1
EOF

########################################
# 9. vnstat 初始化
########################################
systemctl enable vnstat
systemctl restart vnstat

########################################
# 10. 启动 Zabbix Agent2
########################################
systemctl enable zabbix-agent2
systemctl restart zabbix-agent2

########################################
# 11. 防火墙
########################################
if command -v ufw >/dev/null 2>&1; then
  ufw allow 10050/tcp || true
fi

########################################
# 完成
########################################
echo "======================================"
echo "Zabbix Agent2 + vnstat install SUCCESS"
echo "Main IFACE : $IFACE"
echo "Hostname   : $PUBLIC_IP"
echo "======================================"
