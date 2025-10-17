#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

WORK_DIR="/etc/tuic"
mkdir -p "$WORK_DIR"

MASQ_DOMAINS=("www.microsoft.com" "www.cloudflare.com" "www.bing.com" "www.apple.com" "www.amazon.com")
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}
TUIC_BIN="$WORK_DIR/tuic-server"
SERVER_JSON="$WORK_DIR/server.json"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-link.txt"
PORT="28888"

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
  "congestion_control": "bbr",
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

    for ip in $(curl -s ipv4.icanhazip.com; curl -s ipv6.icanhazip.com); do
        [[ "$ip" =~ ":" ]] && ip="[$ip]"
        COUNTRY=$(curl -s "http://ip-api.com/line/$ip?fields=countryCode" || echo "XX")
        [[ "$COUNTRY" == "XX" ]] && echo "⚠️ 无法识别 IP 所属国家，已使用默认标识"
        LINK="tuic://$UUID:$ENC_PASS@$ip:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=bbr#TUIC-${COUNTRY}"
        echo "$LINK" | tee -a "$LINK_FILE"
    done
}

export_clients() {
    UUID=$(sed -n '1p' "$USER_FILE")
    PASS=$(sed -n '2p' "$USER_FILE")
    IP=$(curl -s ipv4.icanhazip.com || curl -s ipv6.icanhazip.com)
    [[ "$IP" =~ ":" ]] && IP="[$IP]"
    cat > "$WORK_DIR/v2rayn-tuic.json" <<EOF
{
  "protocol": "tuic",
  "tag": "TUIC-bbr",
  "settings": {
    "server": "$IP",
    "server_port": $PORT,
    "uuid": "$UUID",
    "password": "$PASS",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "sni": "$MASQ_DOMAIN",
    "udp_relay_mode": "native",
    "disable_sni": false,
    "reduce_rtt": true
  }
}
EOF

    cat > "$WORK_DIR/clash-tuic.yaml" <<EOF
proxies:
  - name: "TUIC-bbr"
    type: tuic
    server: $IP
    port: $PORT
    uuid: "$UUID"
    password: "$PASS"
    alpn: ["h3"]
    sni: "$MASQ_DOMAIN"
    congestion_control: bbr
    udp_relay_mode: native
    skip-cert-verify: true
    disable_sni: false
    reduce_rtt: true
EOF
}

install_service() {
    if ss -ulpn | grep -q ":$PORT"; then
        echo "⚠️ 端口 $PORT 已被占用，请修改端口或停止冲突进程"
        exit 1
    fi

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

    echo "✅ TUIC 服务已启动，以下是你的节点链接："
    cat "$LINK_FILE"
}

# 主流程
generate_certificate
download_tuic
generate_user
generate_config
generate_links
export_clients
install_service
