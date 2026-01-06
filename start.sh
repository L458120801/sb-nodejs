#!/bin/bash
set -e

# ================== 配置区域 ==================

# [新增] 自定义订阅路径密钥 (密码)
CUSTOM_SUB_SECRET="hello"

# [配置] 手动填写第二个端口 (例如: "10086")
# 留空则仅使用自动获取的端口
MANUAL_SECOND_PORT="25109"

# 固定隧道填写token，不填默认为临时隧道
ARGO_TOKEN=""

# ================== CF 优选域名列表 ==================
CF_DOMAINS=(
    "cf.090227.xyz"
    "cf.877774.xyz"
    "cf.130519.xyz"
    "cf.008500.xyz"
    "store.ubi.com"
    "saas.sin.fan"
)

# ================== 切换到脚本目录 ==================
cd "$(dirname "$0")"
export FILE_PATH="${PWD}/.npm"

rm -rf "$FILE_PATH"
mkdir -p "$FILE_PATH"

# ================== 获取公网 IP ==================
echo "[网络] 获取公网 IP..."
PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb || curl -s --max-time 5 api.ipify.org || echo "")
[ -z "$PUBLIC_IP" ] && echo "[错误] 无法获取公网 IP" && exit 1
echo "[网络] 公网 IP: $PUBLIC_IP"

# ================== CF 优选：随机选择可用域名 ==================
select_random_cf_domain() {
    local available=()
    for domain in "${CF_DOMAINS[@]}"; do
        if curl -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null; then
            available+=("$domain")
        fi
    done
    [ ${#available[@]} -gt 0 ] && echo "${available[$((RANDOM % ${#available[@]}))]}" || echo "${CF_DOMAINS[0]}"
}

echo "[CF优选] 测试中..."
BEST_CF_DOMAIN=$(select_random_cf_domain)
echo "[CF优选] $BEST_CF_DOMAIN"

# ================== 获取端口 (自动+手动) ==================
# 1. 获取自动分配的主端口
[ -n "$SERVER_PORT" ] && PORTS_STRING="$SERVER_PORT" || PORTS_STRING=""

# 2. 如果填写了手动端口，拼接到后面
if [ -n "$MANUAL_SECOND_PORT" ]; then
    if [ -n "$PORTS_STRING" ]; then
        PORTS_STRING="$PORTS_STRING $MANUAL_SECOND_PORT"
    else
        PORTS_STRING="$MANUAL_SECOND_PORT"
    fi
    echo "[端口] 检测到手动配置的第二端口: $MANUAL_SECOND_PORT"
fi

# 3. 解析端口数组
read -ra AVAILABLE_PORTS <<< "$PORTS_STRING"
PORT_COUNT=${#AVAILABLE_PORTS[@]}

[ $PORT_COUNT -eq 0 ] && echo "[错误] 未找到端口 (自动获取失败且未手动指定)" && exit 1
echo "[端口] 最终使用 $PORT_COUNT 个: ${AVAILABLE_PORTS[*]}"

# ================== 端口分配逻辑 ==================
if [ $PORT_COUNT -eq 1 ]; then
    # === 单端口模式 ===
    # 端口1: TUIC (UDP) + HTTP (TCP)
    TUIC_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[0]}
    
    # SS 需要同时占用 TCP/UDP，但 TCP 已被 HTTP 占用，所以无法启动 SS
    SS_PORT=""
    
    SINGLE_PORT_MODE=true
    echo "[警告] 仅检测到 1 个端口。端口已分配给 TUIC(UDP) 和 HTTP(TCP)。"
    echo "[注意] 由于端口冲突，Shadowsocks 将不会启动！请配置第二个端口以启用 SS。"
else
    # === 双端口模式 (推荐) ===
    # 端口1: TUIC (UDP) + HTTP (TCP)
    TUIC_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[0]}
    
    # 端口2: Shadowsocks (TCP + UDP)
    SS_PORT=${AVAILABLE_PORTS[1]}
    
    SINGLE_PORT_MODE=false
fi

ARGO_PORT=8081

# ================== UUID 与 路径逻辑 ==================
UUID_FILE="${FILE_PATH}/uuid.txt"
[ -f "$UUID_FILE" ] && UUID=$(cat "$UUID_FILE") || { UUID=$(cat /proc/sys/kernel/random/uuid); echo "$UUID" > "$UUID_FILE"; }
echo "[UUID] $UUID"

# [逻辑] 决定最终的订阅路径
if [ -n "$CUSTOM_SUB_SECRET" ]; then
    SUB_PATH="$CUSTOM_SUB_SECRET"
    echo "[安全] 使用自定义订阅路径: /$SUB_PATH"
else
    SUB_PATH="$UUID"
    echo "[安全] 使用随机 UUID 路径: /$SUB_PATH"
fi

# ================== 架构检测 & 下载 ==================
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] && BASE_URL="https://arm64.ssss.nyc.mn" || BASE_URL="https://amd64.ssss.nyc.mn"
[[ "$ARCH" == "aarch64" ]] && ARGO_ARCH="arm64" || ARGO_ARCH="amd64"

SB_FILE="${FILE_PATH}/sb"
ARGO_FILE="${FILE_PATH}/cloudflared"

download_file() {
    local url=$1 output=$2
    [ -x "$output" ] && return 0
    echo "[下载] $output..."
    curl -L -sS --max-time 60 -o "$output" "$url" && chmod +x "$output" && echo "[下载] $output 完成" && return 0
    echo "[下载] $output 失败" && return 1
}

download_file "${BASE_URL}/sb" "$SB_FILE"
download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}" "$ARGO_FILE"

# ================== 证书生成 (TUIC需要) ==================
echo "[证书] 生成中..."
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
else
    printf -- "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsoAoGCCqGSM49\nAwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa/\nTsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==\n-----END EC PRIVATE KEY-----\n" > "${FILE_PATH}/private.key"

    printf -- "-----BEGIN CERTIFICATE-----\nMIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw\nMTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH\nA0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgJ54Ga3qEAxdegEWv07Mi8ha\nD5IU8Um3oR/zgRIx7UmRmg4TKkOjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR\nBfGbgrkMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMB\nAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+\neQ6OFb9LbLYL9Zi+AiB+foMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==\n-----END CERTIFICATE-----\n" > "${FILE_PATH}/cert.pem"
fi
echo "[证书] 已就绪"

# ================== ISP ==================
if [ "$CURL_AVAILABLE" = true ]; then
    JSON_DATA=$(curl -s --max-time 2 -H "Referer: https://speed.cloudflare.com/" https://speed.cloudflare.com/meta 2>/dev/null)
    if [ -n "$JSON_DATA" ]; then
        ORG=$(echo "$JSON_DATA" | sed -n 's/.*"asOrganization":"\([^"]*\)".*/\1/p')
        CITY=$(echo "$JSON_DATA" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
        if [ -n "$ORG" ] && [ -n "$CITY" ]; then
            ISP="${ORG}-${CITY}"
        fi
    fi
fi
[ -z "$ISP" ] && ISP="Node"

# ================== 生成订阅 ==================
generate_sub() {
    local argo_domain="$1"
    > "${FILE_PATH}/list.txt"
    
    # TUIC (UDP)
    if [ -n "$TUIC_PORT" ]; then
        echo "tuic://${UUID}:admin@${PUBLIC_IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-${ISP}" >> "${FILE_PATH}/list.txt"
    fi

    # Shadowsocks (TCP + UDP)
    if [ -n "$SS_PORT" ]; then
        # 生成 ss://base64(method:password)@ip:port
        SS_BASE64=$(echo -n "aes-256-gcm:${UUID}" | base64 -w 0 2>/dev/null || echo -n "aes-256-gcm:${UUID}" | openssl base64 | tr -d '\n')
        echo "ss://${SS_BASE64}@${PUBLIC_IP}:${SS_PORT}#SS-${ISP}" >> "${FILE_PATH}/list.txt"
    fi
    
    # Argo VLESS
    [ -n "$argo_domain" ] && echo "vless://${UUID}@${BEST_CF_DOMAIN}:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=%2F${UUID}-vless#Argo-${ISP}" >> "${FILE_PATH}/list.txt"

    cat "${FILE_PATH}/list.txt" > "${FILE_PATH}/sub.txt"
}

# ================== HTTP 服务器脚本 ==================
# 这里的端口使用 Port 1 (HTTP_PORT)
cat > "${FILE_PATH}/server.js" <<JSEOF
const http = require('http');
const fs = require('fs');
const port = process.argv[2] || 8080;
const bind = process.argv[3] || '0.0.0.0';
http.createServer((req, res) => {
    if (req.url.includes('/${SUB_PATH}')) {
        res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
        try { res.end(fs.readFileSync('${FILE_PATH}/sub.txt', 'utf8')); } catch(e) { res.end('error'); }
    } else { 
        res.writeHead(404); 
        res.end('404 Not Found'); 
    }
}).listen(port, bind, () => console.log('HTTP on ' + bind + ':' + port));
JSEOF

echo "[HTTP] 启动订阅服务 (端口 $HTTP_PORT)..."
node "${FILE_PATH}/server.js" $HTTP_PORT 0.0.0.0 &
HTTP_PID=$!
sleep 1
echo "[HTTP] 订阅服务已启动"

# ================== 生成 sing-box 配置 ==================
echo "[CONFIG] 生成配置..."

INBOUNDS=""

# TUIC (UDP) - Port 1
if [ -n "$TUIC_PORT" ]; then
    INBOUNDS="{
        \"type\": \"tuic\",
        \"tag\": \"tuic-in\",
        \"listen\": \"::\",
        \"listen_port\": ${TUIC_PORT},
        \"users\": [{\"uuid\": \"${UUID}\", \"password\": \"admin\"}],
        \"congestion_control\": \"bbr\",
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${FILE_PATH}/cert.pem\",
            \"key_path\": \"${FILE_PATH}/private.key\"
        }
    }"
fi

# Shadowsocks (TCP + UDP) - Port 2
if [ -n "$SS_PORT" ]; then
    [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
    INBOUNDS="${INBOUNDS}{
        \"type\": \"shadowsocks\",
        \"tag\": \"ss-in\",
        \"listen\": \"::\",
        \"listen_port\": ${SS_PORT},
        \"method\": \"aes-256-gcm\",
        \"password\": \"${UUID}\"
    }"
fi

# VLESS for Argo
[ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
INBOUNDS="${INBOUNDS}{
    \"type\": \"vless\",
    \"tag\": \"vless-argo-in\",
    \"listen\": \"127.0.0.1\",
    \"listen_port\": ${ARGO_PORT},
    \"users\": [{\"uuid\": \"${UUID}\"}],
    \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/${UUID}-vless\"
    }
}"

cat > "${FILE_PATH}/config.json" <<CFGEOF
{
    "log": {"level": "warn"},
    "inbounds": [${INBOUNDS}],
    "outbounds": [{"type": "direct", "tag": "direct"}]
}
CFGEOF
echo "[CONFIG] 配置已生成"

# ================== 启动 sing-box ==================
echo "[SING-BOX] 启动中..."
"$SB_FILE" run -c "${FILE_PATH}/config.json" &
SB_PID=$!
sleep 2

if ! kill -0 $SB_PID 2>/dev/null; then
    echo "[SING-BOX] 启动失败"
    "$SB_FILE" run -c "${FILE_PATH}/config.json"
    exit 1
fi
echo "[SING-BOX] 已启动 PID: $SB_PID"

# ================== [修复] Argo 隧道 ==================
ARGO_LOG="${FILE_PATH}/argo.log"
ARGO_DOMAIN=""

echo "[Argo] 启动隧道 (HTTP2模式)..."
"$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://127.0.0.1:${ARGO_PORT} > "$ARGO_LOG" 2>&1 &
ARGO_PID=$!

for i in {1..30}; do
    sleep 1
    ARGO_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | head -1 | sed 's|https://||')
    [ -n "$ARGO_DOMAIN" ] && break
done
[ -n "$ARGO_DOMAIN" ] && echo "[Argo] 域名: $ARGO_DOMAIN" || echo "[Argo] 获取域名失败"

# ================== 生成订阅 ==================
generate_sub "$ARGO_DOMAIN"

# ================== 确定订阅链接 ==================
SUB_URL="http://${PUBLIC_IP}:${HTTP_PORT}/${SUB_PATH}"

# ================== 输出结果 ==================
echo ""
echo "==================================================="
if [ "$SINGLE_PORT_MODE" = true ]; then
    echo "模式: 单端口 (TUIC + Argo)"
    echo "警告: 未配置第二个端口，SS (Shadowsocks) 已禁用。"
    echo ""
    echo "代理节点:"
    echo "  - TUIC (UDP):   ${PUBLIC_IP}:${TUIC_PORT}"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo (WS):    ${ARGO_DOMAIN}"
else
    echo "模式: 双端口 (TUIC + SS + Argo)"
    echo ""
    echo "代理节点:"
    echo "  - TUIC (UDP):   ${PUBLIC_IP}:${TUIC_PORT}"
    echo "  - SS (TCP+UDP): ${PUBLIC_IP}:${SS_PORT}"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo (WS):    ${ARGO_DOMAIN}"
fi
echo ""
echo "订阅链接: $SUB_URL"
echo "注意: 请妥善保管订阅链接，不要泄露给他人"
echo "==================================================="
echo ""

# ================== 保持运行 ==================
wait $SB_PID
