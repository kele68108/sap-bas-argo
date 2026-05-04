#!/usr/bin/env bash

# ==========================================
# 用户配置区 (请直接修改引号内的变量)
# ==========================================
FILE_PATH="./tmp"
UUID="6948adff-5e1e-4f52-9c9c-11b707390b8b"
ARGO_DOMAIN="4.oxxx.qzz.io"
ARGO_AUTH="eyJhIjoiNTA0NmI1ODdjNmU0YmRhN2FlNTM2ZGZjZGVjM2M1NDkiLCJ0IjoiODE1NjRhMzktOWMxNy00MWZkLWEwZWYtMDQyNjJkODBkNDU2IiwicyI6Ik9EQXlPR0ZsWVdFdE5tVmxaQzAwTXpCbUxUaG1NV010WW1RMU5tSTROR05sTWpneSJ9"
ARGO_PORT=8001
CFIP="sin.cfip.oxxxx.de"
CFPORT=443
NAME="SAP-BAS-ARGO"
# ==========================================

# --- 0. 防呆设计：自动清理旧进程，防止端口冲突 ---
fuser -k -9 8001/tcp 3001/tcp 3002/tcp >/dev/null 2>&1
lsof -ti:8001,3001,3002 | xargs kill -9 >/dev/null 2>&1

# --- 1. 环境准备 ---
if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH"
else
    rm -f "$FILE_PATH"/* 2>/dev/null
fi

WEB_NAME=$(tr -dc a-z </dev/urandom | head -c 6)
BOT_NAME=$(tr -dc a-z </dev/urandom | head -c 6)

WEB_PATH="$FILE_PATH/$WEB_NAME"
BOT_PATH="$FILE_PATH/$BOT_NAME"
SUB_PATH_FILE="$FILE_PATH/sub.txt"
CONFIG_PATH="$FILE_PATH/config.json"

# --- 2. 生成代理配置文件 ---
cat <<EOF > "$CONFIG_PATH"
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "policy": {
    "levels": {
      "0": {"handshake": 3, "connIdle": 60, "uplinkOnly": 2, "downlinkOnly": 5, "bufferSize": 512}
    }
  },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "level": 0}],
        "decryption": "none",
        "fallbacks": [{"dest": 3001}, {"path": "/vless-argo", "dest": 3002}]
      },
      "streamSettings": {"network": "tcp", "security": "none", "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true, "tcpKeepAliveInterval": 15, "tfoQueueLength": 4096}}
    },
    {
      "port": 3001,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {"clients": [{"id": "$UUID", "level": 0}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "none", "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}}
    },
    {
      "port": 3002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {"clients": [{"id": "$UUID", "level": 0}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/vless-argo", "maxEarlyData": 2560, "earlyDataHeaderName": "Sec-WebSocket-Protocol"},
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false}
    }
  ],
  "dns": {"servers": ["https+local://8.8.8.8/dns-query", "8.8.8.8", "https+local://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4"},
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

# --- 3. 下载核心组件 ---
curl -sL -o "$WEB_PATH" "https://github.com/guoziyou/SOCKS5/raw/refs/heads/main/web"
curl -sL -o "$BOT_PATH" "https://github.com/guoziyou/SOCKS5/raw/refs/heads/main/bot"
chmod 755 "$WEB_PATH" "$BOT_PATH" 2>/dev/null

# --- 4. 启动代理核心 (Web) ---
nohup "$WEB_PATH" -c "$CONFIG_PATH" > /dev/null 2>&1 &
sleep 1

# --- 5. 配置并启动 Argo Tunnel (Bot) ---
if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
    if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        RUN_BOT_CMD="tunnel --edge-ip-version 4 --no-autoupdate --protocol http2 run --token $ARGO_AUTH"
    elif [[ "$ARGO_AUTH" == *"TunnelSecret"* ]]; then
        echo "$ARGO_AUTH" > "$FILE_PATH/tunnel.json"
        TUNNEL_ID=$(echo "$ARGO_AUTH" | grep -o '"TunnelID":"[^"]*' | cut -d'"' -f4)
        cat <<EOF > "$FILE_PATH/tunnel.yml"
tunnel: $TUNNEL_ID
credentials-file: $FILE_PATH/tunnel.json
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        RUN_BOT_CMD="tunnel --edge-ip-version 4 --config $FILE_PATH/tunnel.yml run"
    fi

    if [[ -n "$RUN_BOT_CMD" ]]; then
        nohup "$BOT_PATH" $RUN_BOT_CMD > /dev/null 2>&1 &
        sleep 2
    fi
fi

# --- 6. 生成订阅链接 ---
if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
    VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${NAME}"
    VLESS_BASE64=$(echo -n "$VLESS_LINK" | base64 | tr -d '\n')
    
    echo "$VLESS_BASE64" > "$SUB_PATH_FILE"
    
    echo ""
    echo "=================================================="
    echo "Subscription Content (Base64):"
    echo "$VLESS_BASE64"
    echo "=================================================="
    echo "$FILE_PATH/sub.txt saved successfully"
fi

# --- 7. 添加至 ~/.bashrc 实现自启动 ---
SCRIPT_PATH=$(readlink -f "$0")
if [ -f "$SCRIPT_PATH" ]; then
    if ! grep -q "bash $SCRIPT_PATH" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# Auto-run Proxy Script" >> ~/.bashrc
        echo "nohup bash $SCRIPT_PATH >/dev/null 2>&1 &" >> ~/.bashrc
        echo "=================================================="
        echo "已成功将本脚本写入 ~/.bashrc，实现登录/开机自启"
        echo "=================================================="
    fi
fi

# --- 8. 后台自动隐藏清理文件 (90秒后执行) ---
(
    sleep 90
    rm -f "$CONFIG_PATH" "$WEB_PATH" "$BOT_PATH" "$FILE_PATH/tunnel.yml" "$FILE_PATH/tunnel.json" >/dev/null 2>&1
    clear
    echo "App is running"
    echo "Thank you for using this script, enjoy!"
) &
