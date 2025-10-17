#!/bin/sh
set -e

TUIC_BIN="/usr/local/bin/tuic"
CERT_DIR="/etc/tuic"
CONFIG_FILE="$CERT_DIR/config.json"
SERVICE_FILE="/etc/init.d/tuic"

# ===== 管理菜单 =====
if [ -x "$TUIC_BIN" ]; then
  echo "---------------------------------------"
  echo " 检测到已安装 TUIC v5"
  echo "---------------------------------------"
  echo "请选择操作:"
  echo "1) 修改端口"
  echo "2) 卸载 TUIC"
  echo "3) 退出"
  read -p "请输入选项 [1-3]: " choice

  case "$choice" in
    1)
      read -p "请输入新的端口号: " NEW_PORT
      if [ -z "$NEW_PORT" ]; then
        echo "❌ 端口不能为空"
        exit 1
      fi
      sed -i "s/\"server\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" "$CONFIG_FILE"
      echo "端口已修改为 $NEW_PORT"
      rc-service tuic restart
      echo "✅ TUIC 已重启"
      exit 0
      ;;
    2)
      echo "正在卸载 TUIC..."
      rc-service tuic stop || true
      rc-update del tuic default || true
      rm -f "$TUIC_BIN" "$SERVICE_FILE"
      rm -rf "$CERT_DIR"
      echo "✅ TUIC 已卸载完成"
      exit 0
      ;;
    3)
      echo "已退出"
      exit 0
      ;;
    *)
      echo "无效选项"
      exit 1
      ;;
  esac
fi

# ===== 如果未安装，执行安装流程 =====
echo "---------------------------------------"
echo " TUIC v5 Alpine Linux 安装脚本 "
echo "---------------------------------------"

apk add --no-cache wget curl openssl openrc lsof coreutils jq file >/dev/null
apk add --no-cache aria2 >/dev/null || true

# 下载 TUIC 二进制（省略，保持你之前的逻辑）
# ...（此处保留完整安装逻辑，包括证书生成、UUID、配置文件、OpenRC 服务等）

# ===== 获取 IPv4/IPv6 =====
IPV4=$(wget -qO- -T 5 ipv4.icanhazip.com)
IPV6=$(wget -qO- -T 5 ipv6.icanhazip.com)
[ -n "$IPV6" ] && IP6_URI="[$IPV6]"

# ===== 输出订阅链接 =====
ENC_PASS=$(printf '%s' "$PASS" | jq -s -R -r @uri)
ENC_SNI=$(printf '%s' "$FAKE_DOMAIN" | jq -s -R -r @uri)

echo "------------------------------------------------------------------------"
[ -n "$IPV4" ] && echo "tuic://$UUID:$ENC_PASS@$IPV4:$PORT?sni=$ENC_SNI&alpn=h3#TUIC节点-IPv4"
[ -n "$IPV6" ] && echo "tuic://$UUID:$ENC_PASS@$IP6_URI:$PORT?sni=$ENC_SNI&alpn=h3#TUIC节点-IPv6"
echo "------------------------------------------------------------------------"
