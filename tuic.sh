#!/bin/bash
# TUIC 一键部署脚本（融合增强版）
# 支持：自动安装、配置导出、节点生成、服务管理（systemd/OpenRC/前台）

set -euo pipefail
IFS=$'\n\t'

WORK_DIR="/etc/tuic"
mkdir -p "$WORK_DIR"

MASQ_DOMAINS=("www.microsoft.com" "www.cloudflare.com" "www.bing.com" "www.apple.com" "www.amazon.com")
MASQ_DOMAIN=${MASQ_DOMAINS[$RANDOM % ${#MASQ_DOMAINS[@]}]}
TUIC_BIN="$WORK_DIR/tuic-server"
SERVER_TOML="$WORK_DIR/server.toml"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-link.txt"
PID_FILE="$WORK_DIR/tuic.pid"
PORT="28888"

# --------------------- 核心函数 ---------------------
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
    cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:$PORT"
[users]
$UUID = "$PASS"
[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]
[quic]
congestion_control = "bbr"
EOF
}

generate_link() {
    UUID=$(sed -n '1p' "$USER_FILE")
    PASS=$(sed -n '2p' "$USER_FILE")
    IP=$(curl -s https://api.ipify.org)
    COUNTRY=$(curl -s "http://ip-api.com/line/$IP?fields=countryCode" || echo "XX")
    ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
    ENC_SNI=$(printf '%s' "$MASQ_DOMAIN" | jq -s -R -r @uri)
    LINK="tuic://$UUID:$ENC_PASS@$IP:$PORT?sni=$ENC_SNI&alpn=h3&congestion_control=bbr#TUIC-${COUNTRY}"
    echo "$LINK" > "$LINK_FILE"
}

install_service_systemd() {
    cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=$TUIC_BIN -c $SERVER_TOML
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable tuic
    systemctl start tuic
}

install_service_openrc() {
    cat > /etc/init.d/tuic <<EOF
#!/sbin/openrc-run
command="$TUIC_BIN"
command_args="-c $SERVER_TOML"
pidfile="/run/tuic.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/tuic
    rc-update add tuic default
    rc-service tuic start
}

run_foreground() {
    echo "🚀 TUIC 正在前台运行..."
    exec "$TUIC_BIN" -c "$SERVER_TOML"
}

modify_port() {
    read -p "请输入新端口号: " NEW_PORT
    PORT="$NEW_PORT"
    generate_config
    systemctl restart tuic 2>/dev/null || rc-service tuic restart 2>/dev/null || echo "请手动重启 TUIC"
    echo "✅ 端口已修改为 $PORT"
}

uninstall_tuic() {
    systemctl stop tuic 2>/dev/null || rc-service tuic stop 2>/dev/null || true
    systemctl disable tuic 2>/dev/null || rc-update del tuic default 2>/dev/null || true
    rm -rf "$WORK_DIR" /etc/systemd/system/tuic.service /etc/init.d/tuic
    echo "✅ TUIC 已卸载"
}

show_info() {
    echo "📄 节点链接:"
    cat "$LINK_FILE"
    echo "📁 配置路径: $SERVER_TOML"
    echo "🔑 UUID: $(sed -n '1p' "$USER_FILE")"
    echo "🔑 密码: $(sed -n '2p' "$USER_FILE")"
}

# --------------------- 主菜单 ---------------------
main_menu() {
    echo "---------------------------------------"
    echo " TUIC 一键部署脚本（融合增强版）"
    echo "---------------------------------------"
    echo "请选择操作:"
    echo "1) 安装 TUIC 服务"
    echo "2) 修改端口"
    echo "3) 查看节点信息"
    echo "4) 卸载 TUIC"
    echo "5) 退出"
    read -p "请输入选项 [1-5]: " CHOICE

    case "$CHOICE" in
        1)
            generate_certificate
            download_tuic
            generate_user
            generate_config
            generate_link
            echo "请选择运行方式:"
            echo "1) systemd 后台服务"
            echo "2) OpenRC 后台服务"
            echo "3) 前台运行（适合 Pterodactyl）"
            read -p "请输入选项 [1-3]: " MODE
            case "$MODE" in
                1) install_service_systemd ;;
                2) install_service_openrc ;;
                3) run_foreground ;;
                *) echo "❌ 无效选项"; exit 1 ;;
            esac
            ;;
        2) modify_port ;;
        3) show_info ;;
        4) uninstall_tuic ;;
        5) echo "👋 再见"; exit 0 ;;
        *) echo "❌ 无效选项"; exit 1 ;;
    esac
}

main_menu
