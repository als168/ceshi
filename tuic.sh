#!/bin/bash
set -e

# 确保脚本用 bash 执行
if [ -z "$BASH_VERSION" ]; then
  echo "❌ 请使用 bash 来运行此脚本，例如："
  echo "   bash tuic.sh"
  exit 1
fi

CERT_DIR="/etc/tuic"
WORK_DIR="$CERT_DIR"
CONFIG_FILE="$WORK_DIR/config.json"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-links.txt"

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
      systemctl restart tuic || true
      echo "✅ 端口已修改为 $NEW_PORT"
      exit 0
      ;;
    2)
      echo "正在卸载 TUIC..."
      systemctl stop tuic || true
      systemctl disable tuic || true
      rm -rf "$WORK_DIR" /etc/systemd/system/tuic.service
      systemctl daemon-reload
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

# ---------------- 拥塞控制算法检测 ----------------
detect_cc_algo() {
    if sysctl net.ipv4.tcp_available_congestion_control >/dev/null 2>&1; then
        SUPPORTED=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    else
        SUPPORTED="cubic reno"
    fi

    if echo "$SUPPORTED" | grep -qw "bbr2"; then
        CC_ALGO="bbr2"
    elif echo "$SUPPORTED" | grep -qw "bbr"; then
        CC_ALGO="bbr"
    else
        CC_ALGO="cubic"
    fi
}
detect_cc_algo

# ---------------- 生成配置 ----------------
PORT=28543
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
IPV4=$(curl -s ipv4.icanhazip.com || true)
IPV6=$(curl -s ipv6.icanhazip.com || true)

ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
ENC_SNI=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)

> "$LINK_FILE"

if [ -n "$IPV6" ]; then
  COUNTRY6=$(curl -s "http://ip-api.com/line/${IPV6}?fields=countryCode" || echo "XX")
  LINK6="tuic://$UUID:$ENC_PASS@[$IPV6]:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CC_ALGO#TUIC-${COUNTRY6}-IPv6-$CC_ALGO"
  echo "$LINK6" >> "$LINK_FILE"
  echo "IPv6 节点: $LINK6"
fi

if [ -n "$IPV4" ]; then
  COUNTRY4=$(curl -s "http://ip-api.com/line/${IPV4}?fields=countryCode" || echo "XX")
  LINK4="tuic://$UUID:$ENC_PASS@$IPV4:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CC_ALGO#TUIC-${COUNTRY4}-IPv4-$CC_ALGO"
  echo "$LINK4" >> "$LINK_FILE"
  echo "IPv4 节点: $LINK4"
fi

ln -sf "$LINK_FILE" /root/tuic-links.txt

# ---------------- v2rayN 配置 ----------------
cat > "$WORK_DIR/v2rayn-tuic.json" <<EOF
{
  "protocol": "tuic",
  "tag": "TUIC-$CC_ALGO",
  "settings": {
    "server": "${IPV6:-$IPV4}",
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
  - name: "TUIC-${CC_ALGO}"
    type: tuic
    server: ${IPV6:-$IPV4}
    port: $PORT
    uuid: "$UUID"
    password: "$PASS"
    alpn: ["h3"]
    sni: "$FAKE_DOMAIN"
    congestion_control: $CC_ALGO
    udp_relay_mode: native
    skip-cert-verify: true
EOF

# ---------------- systemd 服务 ----------------
cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC Server
After=network
