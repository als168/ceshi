#!/bin/sh
# TUIC v5 一键安装脚本 (Alpine Linux, 自动检测二进制 + URL 编码订阅链接)
# 修改版：改进了二进制文件验证逻辑，增加了更多下载源，修复了菜单显示问题
set -e

# ===== 全局变量 =====
TUIC_BIN="/usr/local/bin/tuic"
TEMP_BIN="/tmp/tuic_temp"
CERT_DIR="/etc/tuic"
CONFIG_FILE="$CERT_DIR/config.json"
PORT=""
UUID=""
PASS=""
FAKE_DOMAIN="www.bing.com"
CERT_PATH=""
KEY_PATH=""
IP_TYPE=""

# ===== 欢迎信息 =====
welcome() {
    echo "---------------------------------------"
    echo " TUIC v5 Alpine Linux 安装脚本 (修改版)"
    echo "---------------------------------------"
}

# ===== 安装依赖 =====
install_deps() {
    echo "正在安装必要的软件包..."
    apk add --no-cache wget curl openssl openrc lsof coreutils jq file >/dev/null
}

# ===== 检测IP类型 =====
detect_ip_type() {
    local ipv4=""
    local ipv6=""
    
    ipv4=$(wget -qO- ipv4.icanhazip.com 2>/dev/null || curl -s ipv4.icanhazip.com 2>/dev/null)
    ipv6=$(wget -qO- ipv6.icanhazip.com 2>/dev/null || curl -s ipv6.icanhazip.com 2>/dev/null)
    
    echo "$ipv4" > $CERT_DIR/ipv4.txt
    echo "$ipv6" > $CERT_DIR/ipv6.txt
    
    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        echo "❌ 无法获取服务器 IP 地址"
        exit 1
    fi
    
    if [ -z "$ipv4" ]; then
        IP_TYPE="IPv6"
    elif [ -z "$ipv6" ]; then
        IP_TYPE="IPv4"
    else
        IP_TYPE="IPv4 & IPv6"
    fi
}

# ===== 端口检测函数 =====
is_port_available() {
    local port=$1
    if lsof -i :$port >/dev/null 2>&1 || netstat -tuln | grep -q ":$port"; then
        return 1 # 端口被占用
    else
        return 0 # 端口可用
    fi
}

find_available_port() {
    local start_port=${1:-28543} # 默认起始端口
    local end_port=${2:-30000}   # 默认结束端口
    local port
    
    for ((port=start_port; port<=end_port; port++)); do
        if is_port_available $port; then
            echo $port
            return 0
        fi
    done
    
    echo "❌ 在 $start_port-$end_port 范围内未找到可用端口" >&2
    exit 1
}

# ===== 下载TUIC =====
download_tuic() {
    echo "正在获取最新版本信息..."
    TAG=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r .tag_name)
    if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
        echo "无法获取最新版本信息，使用默认版本 1.0.0"
        TAG="tuic-server-1.0.0"
        VERSION="1.0.0"
    else
        VERSION=${TAG#tuic-server-}
    fi
    echo "检测到最新版本: $VERSION"

    FILENAME="tuic-server-${VERSION}-x86_64-unknown-linux-musl"
    URLS="
    https://ghproxy.com/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
    https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
    https://mirror.ghproxy.com/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
    "
    
    SUCCESS=0
    for url in $URLS; do
        echo "尝试下载: $url"
        if wget --timeout=30 --tries=3 --show-progress -O $TEMP_BIN "$url"; then
            FILE_SIZE=$(stat -c %s $TEMP_BIN)
            if [ $FILE_SIZE -lt 100000 ]; then
                echo "警告: 下载的文件过小 ($FILE_SIZE 字节)，可能不是有效的二进制文件，尝试下一个源"
                continue
            fi
            
            FILE_TYPE=$(file $TEMP_BIN)
            echo "文件类型: $FILE_TYPE"
            
            if echo "$FILE_TYPE" | grep -q "ELF"; then
                echo "✓ 文件类型检查通过"
                mv $TEMP_BIN $TUIC_BIN
                chmod +x $TUIC_BIN
                SUCCESS=1
                break
            else
                echo "警告: 下载的文件不是 ELF 格式，尝试下一个源"
            fi
        fi
    done
    
    if [ $SUCCESS -eq 0 ]; then
        echo "❌ 所有下载源均失败，请检查网络环境或手动下载。"
        echo "手动下载指南:"
        echo "1. 访问 https://github.com/tuic-protocol/tuic/releases/latest"
        echo "2. 下载 tuic-server-*-x86_64-unknown-linux-musl 文件"
        echo "3. 将文件上传到服务器并重命名为 $TUIC_BIN"
        echo "4. 执行: chmod +x $TUIC_BIN"
        exit 1
    fi
    echo "✓ TUIC 二进制文件下载成功"
}

# ===== 证书处理 =====
generate_certificate() {
    echo "正在生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout $CERT_DIR/key.pem -out $CERT_DIR/cert.pem \
        -days 365 -subj "/CN=$FAKE_DOMAIN"
    CERT_PATH="$CERT_DIR/cert.pem"
    KEY_PATH="$CERT_DIR/key.pem"
}

# ===== 生成用户信息 =====
generate_user() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -base64 16)
    echo "✓ 用户信息已生成"
}

# ===== 写配置文件 =====
generate_config() {
    cat > $CONFIG_FILE <<EOF
{
    "server": "[::]:$PORT",
    "users": {
        "$UUID": "$PASS"
    },
    "certificate": "$CERT_PATH",
    "private_key": "$KEY_PATH",
    "alpn": ["h3"],
    "congestion_control": "bbr"
}
EOF
    echo "✓ 配置文件已生成: $CONFIG_FILE"
}

# ===== 安装服务 =====
install_service() {
    SERVICE_FILE="/etc/init.d/tuic"
    cat > $SERVICE_FILE <<'EOF'
#!/sbin/openrc-run
description="TUIC v5 Service"
command="/usr/local/bin/tuic"
command_args="--config /etc/tuic/config.json"
command_background="yes"
pidfile="/run/tuic.pid"
depend() {
    need net
}
EOF
    chmod +x $SERVICE_FILE
    rc-update add tuic default
    rc-service tuic restart
    echo "✓ TUIC 服务已安装并启动"
}

# ===== 生成订阅链接 =====
generate_links() {
    local enc_pass enc_sni ipv4 ipv6 country4 country6
    
    enc_pass=$(printf '%s' "$PASS" | jq -s -R -r @uri)
    enc_sni=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)
    
    ipv4=$(cat $CERT_DIR/ipv4.txt 2>/dev/null)
    ipv6=$(cat $CERT_DIR/ipv6.txt 2>/dev/null)
    
    echo "------------------------------------------------------------------------"
    echo " TUIC 安装和配置完成！"
    echo "------------------------------------------------------------------------"
    echo "服务器地址:"
    [ -n "$ipv4" ] && echo "IPv4: $ipv4"
    [ -n "$ipv6" ] && echo "IPv6: $ipv6"
    echo "端口: $PORT"
    echo "UUID: $UUID"
    echo "密码: $PASS"
    echo "SNI: $FAKE_DOMAIN"
    echo "IP 类型: $IP_TYPE"
    echo "------------------------------------------------------------------------"
    echo "TUIC 订阅链接:"
    
    if [ -n "$ipv4" ]; then
        country4=$(curl -s "http://ip-api.com/line/$ipv4?fields=countryCode" || echo "XX")
        echo "tuic://$UUID:$enc_pass@$ipv4:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country4"
    fi
    
    if [ -n "$ipv6" ]; then
        country6=$(curl -s "http://ip-api.com/line/$ipv6?fields=countryCode" || echo "XX")
        echo "tuic://$UUID:$enc_pass@[$ipv6]:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country6"
    fi
    
    echo "------------------------------------------------------------------------"
}

# ===== 显示节点信息 =====
show_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ TUIC 尚未安装，请先安装"
        return
    fi
    
    local enc_pass enc_sni ipv4 ipv6 country4 country6
    
    enc_pass=$(printf '%s' "$PASS" | jq -s -R -r @uri)
    enc_sni=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)
    
    ipv4=$(cat $CERT_DIR/ipv4.txt 2>/dev/null)
    ipv6=$(cat $CERT_DIR/ipv6.txt 2>/dev/null)
    
    echo "---------------------------------------"
    echo "📄 节点信息:"
    echo "---------------------------------------"
    echo "服务器地址:"
    [ -n "$ipv4" ] && echo "IPv4: $ipv4"
    [ -n "$ipv6" ] && echo "IPv6: $ipv6"
    echo "端口: $PORT"
    echo "UUID: $UUID"
    echo "密码: $PASS"
    echo "SNI: $FAKE_DOMAIN"
    echo "IP 类型: $IP_TYPE"
    echo "---------------------------------------"
    echo "📡 TUIC 订阅链接:"
    
    if [ -n "$ipv4" ]; then
        country4=$(curl -s "http://ip-api.com/line/$ipv4?fields=countryCode" || echo "XX")
        echo "tuic://$UUID:$enc_pass@$ipv4:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country4"
    fi
    
    if [ -n "$ipv6" ]; then
        country6=$(curl -s "http://ip-api.com/line/$ipv6?fields=countryCode" || echo "XX")
        echo "tuic://$UUID:$enc_pass@[$ipv6]:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country6"
    fi
    
    echo "---------------------------------------"
}

# ===== 修改端口 =====
modify_port() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ TUIC 尚未安装，请先安装"
        return
    fi
    
    local new_port
    read -p "请输入新端口号（10000–50000）: " new_port
    
    if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 10000 && new_port <= 50000 )); then
        if is_port_available "$new_port"; then
            PORT="$new_port"
            generate_config
            rc-service tuic restart
            echo "✓ 端口已修改为 $PORT，服务已重启"
            show_info
        else
            echo "❌ 端口 $new_port 已被占用，请选择其他端口"
        fi
    else
        echo "❌ 无效端口，请输入 10000–50000 范围内的数字"
    fi
}

# ===== 卸载 TUIC =====
uninstall_tuic() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ TUIC 尚未安装，无需卸载"
        return
    fi
    
    local backup_dir
    backup_dir="/etc/tuic-backup-$(date +%s)"
    mkdir -p "$backup_dir"
    cp -r "$CERT_DIR" "$backup_dir" 2>/dev/null || true

    rc-service tuic stop || true
    rc-update del tuic default || true
    rm -f /etc/init.d/tuic
    rm -f "$TUIC_BIN"
    rm -rf "$CERT_DIR"
    echo "✓ TUIC 已卸载，配置备份于 $backup_dir"
}

# ===== 一键安装 =====
do_install() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "⚠️ TUIC 已经安装，如需重新安装请先卸载"
        return
    fi
    
    echo "正在安装 TUIC 服务..."
    install_deps
    mkdir -p "$CERT_DIR"
    
    if [ ! -x "$TUIC_BIN" ]; then
        download_tuic
    fi
    
    detect_ip_type
    generate_certificate
    generate_user
    
    echo "正在检测可用端口..."
    DEFAULT_PORT=28543
    if is_port_available $DEFAULT_PORT; then
        PORT=$DEFAULT_PORT
        echo "✓ 默认端口 $DEFAULT_PORT 可用"
    else
        echo "默认端口 $DEFAULT_PORT 已被占用，正在寻找可用端口..."
        PORT=$(find_available_port $DEFAULT_PORT)
        echo "✓ 已自动分配端口: $PORT"
    fi
    
    generate_config
    install_service
    generate_links
}

# ===== 主菜单 =====
main_menu() {
    while true; do
        echo "---------------------------------------"
        echo " TUIC 一键部署脚本（终极增强版）"
        echo "---------------------------------------"
        echo "1) 安装 TUIC 服务"
        echo "2) 查看节点信息"
        echo "3) 修改端口"
        echo "4) 卸载 TUIC"
        echo "5) 退出"
        read -p "请输入选项 [1-5]: " CHOICE

        case "$CHOICE" in
            1) do_install ;;
            2) show_info ;;
            3) modify_port ;;
            4) uninstall_tuic ;;
            5) echo "👋 再见"; exit 0 ;;
            *) echo "❌ 无效选项";;
        esac
    done
}

# ===== 脚本入口 =====
welcome
main_menu
