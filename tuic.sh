#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

WORK_DIR="/etc/tuic"
mkdir -p "$WORK_DIR"

MASQ_DOMAIN="www.bing.com"
TUIC_BIN="$WORK_DIR/tuic-server"
SERVER_JSON="$WORK_DIR/server.json"
CERT_PEM="$WORK_DIR/tuic-cert.pem"
KEY_PEM="$WORK_DIR/tuic-key.pem"
USER_FILE="$WORK_DIR/tuic_user.txt"
LINK_FILE="$WORK_DIR/tuic-link.txt"

# -------------------------------
# 依赖检测与安装
# -------------------------------
install_deps() {
    local deps=("curl" "jq" "openssl" "lsof" "netstat" "ss")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -eq 0 ]; then
        echo "✅ 所有依赖已安装"
        return
    fi
    echo "⚠️ 缺少依赖: ${missing[*]}，正在安装..."
    if [ -f /etc/debian_version ]; then
        apt update -y
        apt install -y curl jq openssl lsof net-tools iproute2
    elif [ -f /etc/alpine-release ]; then
        apk update
        apk add curl jq openssl lsof net-tools iproute2
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl jq openssl lsof net-tools iproute
    else
        echo "❌ 未知系统，请手动安装依赖: curl jq openssl lsof net-tools iproute2"
        exit 1
    fi
}
install_deps

# -------------------------------
# 端口检测与分配
# -------------------------------
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:\\[]${port}\\]?$"
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -qE "[:\\[]${port}\\]?$"
        return $?
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" -sTCP:LISTEN -n 2>/dev/null | grep -q ":$port"
        return $?
    else
        return 1
    fi
}

find_free_port() {
    for ((port=10000; port<=50000; port++)); do
        if ! is_port_in_use "$port"; then
            echo "$port"
            return
        fi
    done
    echo "❌ 未找到可用端口" >&2
    exit 1
}

PORT="$(find_free_port)"
echo "🎯 已自动分配端口：$PORT"

# -------------------------------
# 核心功能函数
# -------------------------------
generate_certificate() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=$MASQ_DOMAIN" -days 825 -nodes >/dev/null 2>&1
}

download_tuic() {
    local tag filename url version
    tag="$(curl -fsSL https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r .tag_name)"
    version="${tag#tuic-server-}"
    filename="tuic-server-${version}-x86_64-unknown-linux-musl"
    url="https://github.com/tuic-protocol/tuic/releases/download/${tag}/${filename}"
    curl -fsSL -o "$TUIC_BIN" "$url"
    chmod +x "$TUIC_BIN"
}

generate_user() {
    local uuid pass
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    pass="$(openssl rand -hex 16)"
    printf '%s\n%s\n' "$uuid" "$pass" > "$USER_FILE"
}

generate_config() {
    local uuid pass
    uuid="$(sed -n '1p' "$USER_FILE")"
    pass="$(sed -n '2p' "$USER_FILE")"
    cat > "$SERVER_JSON" <<EOF
{
  "server": "0.0.0.0:$PORT",
  "users": {
    "$uuid": "$pass"
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
    local uuid pass enc_pass enc_sni ip country link
    uuid="$(sed -n '1p' "$USER_FILE")"
    pass="$(sed -n '2p' "$USER_FILE")"
    enc_pass="$(printf '%s' "$pass" | jq -s -R -r @uri)"
    enc_sni="$(printf '%s' "$MASQ_DOMAIN" | jq -s -R -r @uri)"
    : > "$LINK_FILE"
    echo "📡 TUIC 节点链接如下："
    for ip in "$(curl -fsSL ipv4.icanhazip.com)" "$(curl -fsSL ipv6.icanhazip.com)"; do
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ":" ]] && ip="[$ip]"
        country="$(curl -fsSL "http://ip-api.com/line/$ip?fields=countryCode" || echo "XX")"
        link="tuic://$uuid:$enc_pass@$ip:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-${country}"
        echo "$link" | tee -a "$LINK_FILE"
    done
}

export_clients() {
    local uuid pass ip
    uuid="$(sed -n '1p' "$USER_FILE")"
    pass="$(sed -n '2p' "$USER_FILE")"
    ip="$(curl -fsSL ipv4.icanhazip.com || curl -fsSL ipv6.icanhazip.com || echo 127.0.0.1)"
    [[ "$ip" =~ ":" ]] && ip="[$ip]"
    cat > "$WORK_DIR/v2rayn-tuic.json" <<EOF
{
  "protocol": "tuic",
  "tag": "TUIC-bbr",
  "settings": {
    "server": "$ip",
    "server_port": $PORT,
    "uuid": "$uuid",
    "password": "$pass",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "sni": "$MASQ_DOMAIN",
    "udp_relay_mode": "native",
    "disable_sni": false,
    "reduce_rtt": true
  }
}
EOF
}

install_service() {
    if command -v openrc-run >/dev/null 2>&1; then
        cat > /etc/init.d/tuic <<'EOF'
#!/sbin/openrc-run
command="/etc/tuic/tuic-server"
command_args="-c /etc/tuic/server.json"
pidfile="/run/tuic.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/tuic
        rc-update add tuic default
        rc-service tuic restart || rc-service tuic start
    elif pidof systemd >/dev/null 2>&1; then
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
        systemctl restart tuic || systemctl start tuic
    else
        echo "🚀 未检测到 OpenRC 或 systemd，前台运行 TUIC..."
        exec "$TUIC_BIN" -c "$SERVER_JSON"
    fi
    echo "✅ TUIC 服务已启动，以下是你的节点链接："
    cat "$LINK_FILE"
}

modify_port() {
    local new_port
    while true; do
        read -p "请输入新端口号（10000–50000）: " new_port
        if [[ ! "$new_port" =~ ^[0-9]+$ ]] || ((new_port < 10000 || new_port > 50000)); then
            echo "❌ 端口号必须是10000到50000之间的数字，请重新输入。"
            continue
        fi
        if is_port_in_use "$new_port"; then
            echo "❌ 端口 $new_port 已被占用，请选择其他端口。"
            continue
        fi
        break
    done

    # 更新配置文件中的端口
    jq ".server = "0.0.0.0:$new_port"" "$SERVER_JSON" > "$SERVER_JSON.tmp" && mv "$SERVER_JSON.tmp" "$SERVER_JSON"

    # 更新端口变量
    PORT="$new_port"

    # 重新生成链接
    generate_links

    # 重启服务
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart tuic
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tuic restart
    else
        echo "⚠️ 无法自动重启服务，请手动重启。"
    fi

    echo "✅ 端口修改成功，新端口：$PORT"
}
