#!/bin/bash
set -e

CERT_DIR="/etc/tuic"
WORK_DIR="$CERT_DIR"
CONFIG_FILE="$WORK_DIR/config.json"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-links.txt"
SERVICE_FILE="/etc/init.d/tuic"

MASQ_DOMAINS=("www.microsoft.com" "www.cloudflare.com" "www.bing.com" "www.apple.com" "www.amazon.com" "www.wikipedia.org")
FAKE_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}

mkdir -p "$WORK_DIR"

# ---------------- 管理菜单 ----------------
if [ -x "$WORK_DIR/tuic-server" ]; then
  echo "---------------------------------------"
  echo " TUIC 管理菜单"
  echo "---------------------------------------"
  echo "1) 修改端口"
  echo "2) 卸载 TUIC"
  echo "3) 查看节点信息"
  echo "4) 退出"
  read -p "请输入选项 [1-4]: " choice

  case "$choice" in
    1)
      read -p "请输入新的端口号: " NEW_PORT
      [ -z "$NEW_PORT" ] && echo "❌ 端口不能为空" && exit 1
      sed -i "s/\"server\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" "$CONFIG_FILE"
      echo "端口已修改为 $NEW_PORT"
      exit 0
      ;;
    2)
      echo "正在卸载 TUIC..."
      rm -rf "$WORK_DIR"
      echo "✅ TUIC 已卸载完成"
      exit 0
      ;;
    3)
      cat "$LINK_FILE"
      exit 0
      ;;
    4) echo "已退出"; exit 0 ;;
    *) echo "无效选项"; exit 1 ;;
  esac
fi

# ---------------- 用户信息持久化 ----------------
if [ -f "$USER_FILE" ]; then
  UUID=$(sed -n '1p' "$USER_FILE")
  PASS=$(sed -n '2p' "$USER_FILE")
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  PASS=$(openssl rand -base64 16)
  echo "$UUID" > "$USER_FILE"
  echo "$PASS" >> "$USER_FILE"
fi

# ---------------- 下载 TUIC ----------------
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  if [ -f "/.pterodactyl" ] || [ "$(free -m | awk '/Mem:/ {print $2}')" -lt 128 ]; then
    TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/v1.3.5/tuic-server-x86_64-linux"
  else
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

# ---------------- 证书检查 ----------------
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
if [ ! -f "$CERT_PEM" ] || ! openssl x509 -checkend 0 -noout -in "$CERT_PEM" >/dev/null 2>&1; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$FAKE_DOMAIN" -days 365 -nodes >/dev/null 2>&1
fi

# ---------------- 生成配置 ----------------
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

# ---------------- 输出链接 ----------------
IPV4=$(curl -s ipv4.icanhazip.com)
COUNTRY=$(curl -s "http://ip-api.com/line/${IPV4}?fields=countryCode" || echo "XX")
ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
ENC_SNI=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)

LINK="tuic://$UUID:$ENC_PASS@$IPV4:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CC_ALGO#TUIC-${COUNTRY}-IPv4-$CC_ALGO"

echo "$LINK" > "$LINK_FILE"
ln -sf "$LINK_FILE" /root/tuic-links.txt

# ---------------- v2rayN 配置 ----------------
cat > "$WORK_DIR/v2rayn-tuic.json" <<EOF
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
    "sni": "$FAKE_DOMAIN"
  }
}
EOF

# ---------------- Clash Meta 配置 ----------------
cat > "$WORK_DIR/clash-tuic.yaml" <<EOF
proxies:
  - name: "TUIC-${COUNTRY}-${CC_ALGO}"
    type: tuic
    server: $IPV4
    port: $PORT
    uuid: "$UUID"
    password: "$PASS"
    alpn: ["h3"]
    sni: "$FAKE_DOMAIN"
    congestion_control: $CC_ALGO
    udp_relay_mode: native
    skip-cert-verify: true
EOF

echo "✅ 安装完成，节点信息已保存到: $LINK_FILE"
echo "快捷访问: ~/tuic-links.txt"
