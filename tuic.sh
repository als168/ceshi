#!/bin/sh
# TUIC v5 一键安装脚本 (Alpine Linux, 自动检测二进制 + URL 编码订阅链接)
# 修改版：改进了二进制文件验证逻辑，增加了更多下载源，增加了自动端口检测功能，并显示主菜单
set -e

# ===== 显示欢迎信息 =====
welcome() {
    echo "---------------------------------------"
    echo " TUIC v5 Alpine Linux 安装脚本 (修改版)"
    echo "---------------------------------------"
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

# ===== 安装依赖 =====
install_deps() {
    echo "正在安装必要的软件包..."
    apk add --no-cache wget curl openssl openrc lsof coreutils jq file >/dev/null
}

# ===== 检测是否已有 TUIC =====
check_existing_tuic() {
    if [ -x "$TUIC_BIN" ]; then
        echo "检测到已存在 TUIC 二进制，跳过下载步骤"
    else
        echo "未检测到 TUIC，开始下载..."
        download_tuic
    fi
}

# ===== 下载 TUIC =====
download_tuic() {
    # 获取最新 tag
    echo "正在获取最新版本信息..."
    TAG=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest | jq -r .tag_name)
    if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
        echo "无法获取最新版本信息，使用默认版本 1.0.0"
        TAG="tuic-server-1.0.0"
        VERSION="1.0.0"
    else
        VERSION=${TAG#tuic-server-} # 去掉前缀，只保留版本号
    fi
    echo "检测到最新版本: $VERSION"

    # 拼接文件名和下载地址 (x86_64 架构)
    FILENAME="tuic-server-${VERSION}-x86_64-unknown-linux-musl"
    # 增加更多下载源
    URLS="
    https://ghproxy.com/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
    https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
    https://mirror.ghproxy.com/https://github.com/tuic-protocol/tuic/releases/download/$TAG/$FILENAME
    "
    SUCCESS=0
    for url in $URLS; do
        echo "尝试下载: $url"
        if wget --timeout=30 --tries=3 --show-progress -O $TEMP_BIN "$url"; then
            # 检查文件大小，如果太小可能是错误页面
            FILE_SIZE=$(stat -c %s $TEMP_BIN)
            if [ $FILE_SIZE -lt 100000 ]; then
                echo "警告: 下载的文件过小 ($FILE_SIZE 字节)，可能不是有效的二进制文件，尝试下一个源"
                continue
            fi
            # 检查文件类型
            FILE_TYPE=$(file $TEMP_BIN)
            echo "文件类型: $FILE_TYPE"
            # 更宽松的文件类型检查
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
    local end_port=${2:-50000}   # 默认结束端口
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

# ===== 证书处理 =====
generate_certificate() {
    read -p "请输入用于自签证书的伪装域名 (默认 www.bing.com): " FAKE_DOMAIN
    [ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.bing.com"
    echo "正在生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $CERT_DIR/key.pem -out $CERT_DIR/cert.pem -days 365 \
        -subj "/CN=$FAKE_DOMAIN"
    CERT_PATH="$CERT_DIR/cert.pem"
    KEY_PATH="$CERT_DIR/key.pem"
}

# ===== 检测 IP 类型 =====
detect_ip_type() {
    local ipv4=""
    local ipv6=""
    
    if [ -x "$(command -v wget)" ]; then
        ipv4=$(wget -qO- ipv4.icanhazip.com 2>/dev/null)
        ipv6=$(wget -qO- ipv6.icanhazip.com 2>/dev/null)
    elif [ -x "$(command -v curl)" ]; then
        ipv4=$(curl -s ipv4.icanhazip.com 2>/dev/null)
        ipv6=$(curl -s ipv6.icanhazip.com 2>/dev/null)
    fi
    
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

# ===== 生成订阅链接 =====
generate_links() {
    local enc_pass enc_sni ipv4 ipv6 country4 country6 link4 link6
    
    enc_pass=$(printf '%s' "$PASS" | jq -s -R -r @uri) # URL 编码密码
    enc_sni=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri) # URL 编码 SNI
    
    ipv4=$(cat $CERT_DIR/ipv4.txt)
    ipv6=$(cat $CERT_DIR/ipv6.txt)
    
    LINKS_FILE="$CERT_DIR/links.txt"
    : > "$LINKS_FILE"
    
    if [ -n "$ipv4" ]; then
        country4=$(curl -s "http://ip-api.com/line/$ipv4?fields=countryCode" || echo "XX")
        link4="tuic://$UUID:$enc_pass@$ipv4:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country4"
        echo "$link4" >> "$LINKS_FILE"
    fi
    
    if [ -n "$ipv6" ]; then
        country6=$(curl -s "http://ip-api.com/line/$ipv6?fields=countryCode" || echo "XX")
        link6="tuic://$UUID:$enc_pass@[$ipv6]:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country6"
        echo "$link6" >> "$LINKS_FILE"
    fi
    
    echo "------------------------------------------------------------------------"
    echo " TUIC 安装和配置完成！"
    echo "------------------------------------------------------------------------"
    echo "服务器地址: $ipv4 $ipv6"
    echo "端口: $PORT"
    echo "UUID: $UUID"
    echo "密码: $PASS"
    echo "SNI: $FAKE_DOMAIN"
    echo "证书路径: $CERT_PATH"
    echo "私钥路径: $KEY_PATH"
    echo "IP 类型: $IP_TYPE"
    echo "------------------------------------------------------------------------"
    echo "TUIC 订阅链接:"
    [ -n "$link4" ] && echo "$link4"
    [ -n "$link6" ] && echo "$link6"
    echo "------------------------------------------------------------------------"
}

# ===== 显示节点信息 =====
show_info() {
    local ipv4 ipv6 country4 country6 link4 link6
    
    ipv4=$(cat $CERT_DIR/ipv4.txt)
    ipv6=$(cat $CERT_DIR/ipv6.txt)
    
    LINKS_FILE="$CERT_DIR/links.txt"
    
    echo "---------------------------------------"
    echo "📄 节点链接:"
    [ -f "$LINKS_FILE" ] && cat "$LINKS_FILE" || echo "尚未生成链接"
    echo "🔑 UUID: $UUID"
    echo "🔑 密码: $PASS"
    echo "🎭 SNI: $FAKE_DOMAIN"
    echo "🔌 端口: $PORT"
    echo "📁 配置文件: $CONFIG_FILE"
    echo "IP 类型: $IP_TYPE"
    echo "---------------------------------------"
}

# ===== 生成 UUID 和密码 =====
generate_user() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -base64 16)
}

# ===== 生成配置文件 =====
generate_config() {
    local uuid pass enc_pass enc_sni
    uuid="$UUID"
    pass="$PASS"
    enc_pass=$(printf '%s' "$pass" | jq -s -R -r @uri)
    enc_sni=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)
    
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "[::]:$PORT",
    "users": {
        "$uuid": "$pass"
    },
    "certificate": "$CERT_PATH",
    "private_key": "$KEY_PATH",
    "alpn": ["h3"],
    "congestion_control": "bbr"
}
EOF
    echo "配置文件已生成: $CONFIG_FILE"
}

# ===== 修改端口 =====
modify_port() {
    local new_port
    read -p "请输入新端口号（10000–50000）: " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 10000 && new_port <= 50000 )); then
        if is_port_available "$new_port"; then
            echo "🎯 新端口已设置为：$new_port"
            PORT="$new_port"
            generate_config
            generate_links
            echo "✅ 配置已更新"
            rc-service tuic restart || echo "⚠️ 请手动重启 TUIC"
        else
            echo "❌ 端口 $new_port 已被占用，请选择其他端口"
        fi
    else
        echo "❌ 无效端口，请输入 10000–50000 范围内的数字"
    fi
}

# ===== 卸载 TUIC =====
uninstall_tuic() {
    local backup_dir
    backup_dir="/etc/tuic-backup-$(date +%s)"
    mkdir -p "$backup_dir"
    cp -r "$CERT_DIR" "$backup_dir" 2>/dev/null || true

    rc-service tuic stop || true
    rc-update del tuic default || true
    rm -f /etc/init.d/tuic
    rm -f "$TUIC_BIN"
    rm -rf "$CERT_DIR"
    echo "✅ TUIC 已卸载，配置备份于 $backup_dir"
}

# ===== 一键安装 TUIC =====
do_install() {
    install_deps
    check_existing_tuic
    generate_user
    generate_config
    detect_ip_type
    generate_links
    install_service
    show_info
    copy_to_clipboard
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

    # 检查是否启动成功
    sleep 2
    if ! pgrep -x tuic-server >/dev/null 2>&1; then
        echo "⚠️ TUIC 启动失败，可能端口被占用，尝试更换端口..."
        PORT=$(find_available_port)
        generate_config
        generate_links
        echo "✅ 已自动切换到新端口：$PORT"
    else
        echo "✅ TUIC 服务已启动"
    fi
}

# ===== 复制到剪贴板 =====
copy_to_clipboard() {
    local link4 link6
    
    LINKS_FILE="$CERT_DIR/links.txt"
    
    if command -v xclip >/dev/null 2>&1; then
        if [ -f "$LINKS_FILE" ]; then
            head -n 1 "$LINKS_FILE" | xclip -selection clipboard
            echo "📋 IPv4 节点链接已复制到剪贴板 (xclip)"
        else
            echo "❌ 未检测到有效的节点链接"
        fi
    elif command -v pbcopy >/dev/null 2>&1; then
        if [ -f "$LINKS_FILE" ]; then
            head -n 1 "$LINKS_FILE" | pbcopy
            echo "📋 IPv4 节点链接已复制到剪贴板 (pbcopy)"
        else
            echo "❌ 未检测到有效的节点链接"
        fi
    else
        echo "⚠️ 未检测到剪贴板工具 (xclip/pbcopy)，请手动复制以下链接:"
        [ -f "$LINKS_FILE" ] && cat "$LINKS_FILE" || echo "尚未生成链接"
    fi
}

# ===== 初始化变量 =====
TUIC_BIN="/usr/local/bin/tuic"
TEMP_BIN="/tmp/tuic_temp"
CERT_DIR="/etc/tuic"
mkdir -p $CERT_DIR

# ===== 检测 IP 类型 =====
detect_ip_type() {
    local ipv4=""
    local ipv6=""
    
    if [ -x "$(command -v wget)" ]; then
        ipv4=$(wget -qO- ipv4.icanhazip.com 2>/dev/null)
        ipv6=$(wget -qO- ipv6.icanhazip.com 2>/dev/null)
    elif [ -x "$(command -v curl)" ]; then
        ipv4=$(curl -s ipv4.icanhazip.com 2>/dev/null)
        ipv6=$(curl -s ipv6.icanhazip.com 2>/dev/null)
    fi
    
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

# ===== 生成订阅链接 =====
generate_links() {
    local enc_pass enc_sni ipv4 ipv6 country4 country6 link4 link6
    
    enc_pass=$(printf '%s' "$PASS" | jq -s -R -r @uri) # URL 编码密码
    enc_sni=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri) # URL 编码 SNI
    
    ipv4=$(cat $CERT_DIR/ipv4.txt)
    ipv6=$(cat $CERT_DIR/ipv6.txt)
    
    LINKS_FILE="$CERT_DIR/links.txt"
    : > "$LINKS_FILE"
    
    if [ -n "$ipv4" ]; then
        country4=$(curl -s "http://ip-api.com/line/$ipv4?fields=countryCode" || echo "XX")
        link4="tuic://$UUID:$enc_pass@$ipv4:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country4"
        echo "$link4" >> "$LINKS_FILE"
    fi
    
    if [ -n "$ipv6" ]; then
        country6=$(curl -s "http://ip-api.com/line/$ipv6?fields=countryCode" || echo "XX")
        link6="tuic://$UUID:$enc_pass@[$ipv6]:$PORT?sni=$enc_sni&alpn=h3&congestion_control=bbr#TUIC-$country6"
        echo "$link6" >> "$LINKS_FILE"
    fi
    
    echo "------------------------------------------------------------------------"
    echo " TUIC 安装和配置完成！"
    echo "------------------------------------------------------------------------"
    echo "服务器地址: $ipv4 $ipv6"
    echo "端口: $PORT"
    echo "UUID: $UUID"
    echo "密码: $PASS"
    echo "SNI: $FAKE_DOMAIN"
    echo "证书路径: $CERT_PATH"
    echo "私钥路径: $KEY_PATH"
    echo "IP 类型: $IP_TYPE"
    echo "------------------------------------------------------------------------"
    echo "TUIC 订阅链接:"
    [ -f "$LINKS_FILE" ] && cat "$LINKS_FILE" || echo "尚未生成链接"
    echo "------------------------------------------------------------------------"
}

# ===== 显示欢迎信息并进入主菜单 =====
welcome
main_menu
