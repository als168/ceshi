#!/bin/sh
set -e

CERT_DIR="/etc/tuic"
WORK_DIR="$CERT_DIR"
CONFIG_FILE="$WORK_DIR/config.json"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-links.txt"
SERVICE_FILE="/etc/init.d/tuic"

MASQ_DOMAINS=("www.microsoft.com" "www.cloudflare.com" "www.bing.com" "www.apple.com" "www.amazon.com" "www.wikipedia.org" "cdnjs.cloudflare.com" "cdn.jsdelivr.net" "static.cloudflareinsights.com" "www.speedtest.net")
FAKE_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

mkdir -p "$WORK_DIR"

# --------------------- 用户信息持久化 ---------------------
if [ -f "$USER_FILE" ]; then
  UUID=$(sed -n '1p' "$USER_FILE")
  PASS=$(sed -n '2p' "$USER_FILE")
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  PASS=$(openssl rand -base64 16)
  echo "$UUID" > "$USER_FILE"
  echo "$PASS" >> "$USER_FILE"
fi

# --------------------- 下载 TUIC ---------------------
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  if [ -f "/.pterodactyl" ] || [ "$(free -m | awk '/Mem:/ {print $2}')" -lt 128 ]; then
    # 内存小 / Pterodactyl 环境 → Itsusinn 轻量版
    TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  else
    # 默认用官方 TUIC v5
    TAG=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r .tag_name)
    VERSION=${TAG#tuic-server-}
    TUIC_URL="https://github.com/tuic-protocol/tuic/releases/download/$TAG/tuic-server-${VERSION}-x86_64-unknown-linux-musl"
  fi
else
  echo "❌ 暂不支持架构: $ARCH"
  exit 1
fi

wget -O "$WORK_DIR/tuic-server" "$TUIC_URL"
chmod +x "$WORK_DIR/tuic-server"

# --------------------- 生成证书 ---------------------
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
if [ ! -f "$CERT_PEM" ] || ! openssl x509 -checkend 0 -noout -in "$CERT_PEM" >/dev/null 2>&1; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$FAKE_DOMAIN" -days 365 -nodes >/dev/null 2>&1
fi

# --------------------- 生成配置 ---------------------
PORT=28543
CC_ALGO="bbr"
cat > $CONFIG_FILE <<EOF
{
  "server": "[::]:$PORT",
  "users": {
    "$UUID": "$PASS"
  },
  "certificate": "$CERT_PEM",
  "private_key": "$KEY_PEM",
  "alpn": ["h3"],
  "congestion_control": "$CC_ALGO"
}
EOF

# --------------------- 获取公网 IP & 国家代码 ---------------------
IPV4=$(curl -s ipv4.icanhazip.com)
COUNTRY=$(curl -s "http://ip-api.com/line/${IPV4}?fields=countryCode" || echo "XX")

# --------------------- 输出单节点链接（带算法参数） ---------------------
ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
ENC_SNI=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)

LINK="tuic://$UUID:$ENC_PASS@$IPV4:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CC_ALGO#TUIC-${COUNTRY}-IPv4-$CC_ALGO"

echo "------------------------------------------------------------------------"
echo "UUID: $UUID"
echo "密码: $PASS"
echo "SNI: $FAKE_DOMAIN"
echo "端口: $PORT"
echo "拥塞算法: $CC_ALGO"
echo "单节点链接: $LINK"
echo "------------------------------------------------------------------------"

echo "$LINK" > "$LINK_FILE"
ln -sf "$LINK_FILE" /root/tuic-links.txt
echo "所有链接已保存到: $LINK_FILE (快捷访问: ~/tuic-links.txt)"

# --------------------- 生成 v2rayN 节点配置 ---------------------
V2RAYN_FILE="$WORK_DIR/v2rayn-tuic.json"
cat > $V2RAYN_FILE <<EOF
{
  "protocol": "tuic",
  "tag": "TUIC-$CC_ALGO",
  "settings": {
    "server": "$IPV4",
    "server_port": $PORT,
    "uuid": "$UUID",
    "password": "$PASS",
    "congestion_control": "$CC_ALGO",
    "alpn": ["h3"],
    "sni": "$FAKE_DOMAIN",
    "udp_relay_mode": "native",
    "disable_sni": false,
    "reduce_rtt": true
  }
}
EOF
echo "v2rayN 节点配置文件已生成: $V2RAYN_FILE"
