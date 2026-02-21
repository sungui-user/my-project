#!/bin/bash

set -e

echo "=== Installing iptables ==="
apt install iptables -y

echo "=== Installing Xray ==="
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

echo "=== Writing Xray config ==="
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 40000,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "d252bb1e-82f6-442b-80c1-9fc97f8f730d"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      }
    },
    {
      "port": 30000,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-256-gcm",
        "password": "Dnxb1BYF3MiWeociRVa0pfuBRHuB0hUDAMDk/UF3OV8=",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

echo "=== Opening firewall ports ==="
if command -v ufw >/dev/null 2>&1; then
  echo "Allowing ports via UFW..."
  ufw allow 40000/tcp
  ufw allow 30000/tcp
fi

echo "Allowing ports via iptables..."
iptables -C INPUT -p tcp --dport 40000 -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p tcp --dport 40000 -j ACCEPT
iptables -C INPUT -p tcp --dport 30000 -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p tcp --dport 30000 -j ACCEPT
iptables -C INPUT -p udp --dport 30000 -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p udp --dport 30000 -j ACCEPT

echo "=== Restarting and enabling Xray ==="
systemctl restart xray
systemctl enable xray

echo ""
echo "=== Xray Installation Complete ==="
systemctl status xray --no-pager