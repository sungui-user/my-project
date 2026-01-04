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
    if(unit=="B") return val
    else if(unit=="KiB") return val*1024
    else if(unit=="MiB") return val*1024*1024
    else if(unit=="GiB") return val*1024*1024*1024
    else return 0
}
$1 == month {
    rx = to_bytes($2, $3)
    tx = to_bytes($5, $6)
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
# 7. 配置 Zabbix Agent2
########################################
CONF="/etc/zabbix/zabbix_agent2.conf"

sed -i "s|^Server=.*|Server=zabbix.luyaonet.com|" $CONF
sed -i "s|^ServerActive=.*|ServerActive=zabbix.luyaonet.com|" $CONF
sed -i "s|^Hostname=.*|Hostname=$PUBLIC_IP|" $CONF

grep -q "^HostMetadata=" $CONF \
  && sed -i "s|^HostMetadata=.*|HostMetadata=vps-ubuntu22|" $CONF \
  || echo "HostMetadata=vps-ubuntu22" >> $CONF

grep -q "^Timeout=" $CONF \
  && sed -i "s|^Timeout=.*|Timeout=30|" $CONF \
  || echo "Timeout=30" >> $CONF

grep -q "^RefreshActiveChecks=" $CONF \
  && sed -i "s|^RefreshActiveChecks=.*|RefreshActiveChecks=120|" $CONF \
  || echo "RefreshActiveChecks=120" >> $CONF

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
