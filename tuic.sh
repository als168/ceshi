#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

WORK_DIR="/etc/tuic"
mkdir -p "$WORK_DIR"

TUIC_BIN="$WORK_DIR/tuic-server"
SERVER_JSON="$WORK_DIR/server.json"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-link.txt"

MASQ_DOMAINS=(
  "www.microsoft.com"
  "www.cloudflare.com"
  "www.bing.com"
  "www.apple.com"
  "www.amazon.com"
  "www.google.com"
  "www.youtube.com"
  "www.facebook.com"
  "www.yahoo.com"
  "www.wikipedia.org"
)

read -p "请输入监听端口（默认 28888）: " INPUT_PORT
PORT="${INPUT_PORT:-28888}"
CONGESTION="bbr"
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}
echo "🎭 已随机选择伪装域名：$MASQ_DOMAIN"

generate_certificate() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days 825 -nodes >/dev/null 2>&1
}

download_tuic() {
    TAG=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r .tag_name)
    VERSION=${TAG#tuic-server-}
    FILENAME="tuic-server-${VERSION}-x86_64-unknown-linux-musl"
    URL="https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME"
    curl -L --max-time 30 -o "$TUIC_BIN" "$URL"
    chmod +x "$TUIC_BIN"
}

generate_user() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 16)
    echo "$UUID" > "$USER_FILE"
    echo "$PASS" >> "$USER_FILE"
}

generate_config() {
    UUID=$(sed -n '1p' "$USER_FILE")
    PASS=$(sed -n '2p' "$USER_FILE")
    cat > "$SERVER_JSON" <<EOF
{
  "server": "0.0.0.0:$PORT",
  "users": {
    "$UUID": "$PASS"
  },
  "certificate": "$CERT_PEM",
  "private_key": "$KEY_PEM",
  "congestion_control": "$CONGESTION",
  "alpn": ["h3"],
  "log_level": "info"
}
EOF
}

generate_links() {
    UUID=$(sed -n '1p' "$USER_FILE")
    PASS=$(sed -n '2p' "$USER_FILE")
    ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
    ENC_SNI=$(printf '%s' "$MASQ_DOMAIN" | jq -s -R -r @uri)
    > "$LINK_FILE"

    echo "📡 TUIC 节点链接如下："

    detect_country() {
        local ip="$1"
        curl -s --max-time 5 "http://ip-api.com/line/$ip?fields=countryCode" || echo "XX"
    }

    IPV4=$(curl -s --max-time 5 ipv4.icanhazip.com || echo "")
    IPV6=$(curl -s --max-time 5 ipv6.icanhazip.com || echo "")

    if [[ -n "$IPV4" ]]; then
        COUNTRY=$(detect_country "$IPV4")
        LINK="tuic://$UUID:$ENC_PASS@$IPV4:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CONGESTION#TUIC-IPv4-${COUNTRY}"
        echo "$LINK" | tee -a "$LINK_FILE"
    fi

    if [[ -n "$IPV6" ]]; then
        COUNTRY=$(detect_country "$IPV6")
        LINK="tuic://$UUID:$ENC_PASS@[$IPV6]:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=$CONGESTION#TUIC-IPv6-${COUNTRY}"
        echo "$LINK" | tee -a "$LINK_FILE"
    fi

    if [[ -z "$IPV4" && -z "$IPV6" ]]; then
        echo "⚠️ 无法检测到公网 IP，请检查 VPS 网络连接"
    fi
}

install_service() {
    if pidof systemd >/dev/null; then
        cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$TUIC_BIN -c $SERVER_JSON
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reexec
        systemctl daemon-reload
        systemctl enable tuic
        systemctl start tuic
    elif command -v openrc-run >/dev/null; then
        cat > /etc/init.d/tuic <<EOF
#!/sbin/openrc-run
command="$TUIC_BIN"
command_args="-c $SERVER_JSON"
pidfile="/run/tuic.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/tuic
        rc-update add tuic default
        rc-service tuic start
    else
        echo "🚀 TUIC 正在前台运行..."
        exec "$TUIC_BIN" -c "$SERVER_JSON"
    fi
}

# 主流程
generate_certificate
download_tuic
generate_user
generate_config
generate_links
install_service
