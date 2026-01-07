#!/bin/bash
# ================== 配置区域 ==================

# [配置] 默认协议 (仅当没有保存的配置时生效)
DEFAULT_PROTOCOL="hy2"

# [配置] 手动填写第二个端口 (例如: "10086")
MANUAL_SECOND_PORT="25109"

# [配置] 固定 UUID (留空则每次重启生成新的)
FIXED_UUID=""

# [配置] 自定义订阅路径密钥 (面板密码)
CUSTOM_SUB_SECRET="hello"

# 固定隧道填写token
ARGO_TOKEN=""

# ================== 核心循环逻辑 ==================

CONFIG_FILE="saved_config.txt"

# 定义清理函数 (优化点3: 增加引号和非空判断，增强稳定性)
cleanup() {
    echo "[系统] 正在清理进程..."
    [ -n "$SB_PID" ] && kill "$SB_PID" 2>/dev/null
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
    [ -n "$ARGO_PID" ] && kill "$ARGO_PID" 2>/dev/null
    rm -f "$FILE_PATH/.restart_flag"
}

trap "cleanup; exit 0" SIGTERM SIGINT

while true; do
    echo "==================================================="
    echo "   🚀 正在启动服务 (v4.4) ..."
    echo "==================================================="

    # ================== 变量与目录准备 ==================
    CF_DOMAINS=("cf.090227.xyz" "cf.877774.xyz" "cf.130519.xyz" "cf.008500.xyz" "store.ubi.com" "saas.sin.fan")
    
    cd "$(dirname "$0")"
    export FILE_PATH="${PWD}/.npm"
    rm -rf "$FILE_PATH"
    mkdir -p "$FILE_PATH"

    # ================== 读取/保存 协议配置 ==================
    if [ -f "$CONFIG_FILE" ]; then
        PORT1_PROTOCOL=$(cat "$CONFIG_FILE")
        echo "[配置] 读取到保存的协议: $PORT1_PROTOCOL"
    else
        PORT1_PROTOCOL="$DEFAULT_PROTOCOL"
        echo "$PORT1_PROTOCOL" > "$CONFIG_FILE"
        echo "[配置] 使用默认协议: $PORT1_PROTOCOL"
    fi

    # ================== 获取公网 IP ==================
    echo "[网络] 获取公网 IP..."
    PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb || curl -s --max-time 5 api.ipify.org || echo "")
    if [ -z "$PUBLIC_IP" ]; then
        echo "[错误] 无法获取 IP，5秒后重试..."
        sleep 5
        continue
    fi
    echo "[网络] 公网 IP: $PUBLIC_IP"

    # ================== CF 优选 (保持原版逻辑) ==================
    select_random_cf_domain() {
        local available=()
        for domain in "${CF_DOMAINS[@]}"; do
            if curl -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null; then
                available+=("$domain")
            fi
        done
        [ ${#available[@]} -gt 0 ] && echo "${available[$((RANDOM % ${#available[@]}))]}" || echo "${CF_DOMAINS[0]}"
    }
    BEST_CF_DOMAIN=$(select_random_cf_domain)

    # ================== 获取端口 ==================
    [ -n "$SERVER_PORT" ] && PORTS_STRING="$SERVER_PORT" || PORTS_STRING=""
    if [ -n "$MANUAL_SECOND_PORT" ]; then
        if [ -n "$PORTS_STRING" ]; then
            PORTS_STRING="$PORTS_STRING $MANUAL_SECOND_PORT"
        else
            PORTS_STRING="$MANUAL_SECOND_PORT"
        fi
    fi
    read -ra AVAILABLE_PORTS <<< "$PORTS_STRING"
    PORT_COUNT=${#AVAILABLE_PORTS[@]}

    if [ $PORT_COUNT -eq 0 ]; then
        echo "[错误] 未找到端口，5秒后重试..."
        sleep 5
        continue
    fi

    PRIMARY_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[0]}

    if [ "$PORT1_PROTOCOL" == "tuic" ]; then
        TUIC_PORT=$PRIMARY_PORT
        HY2_PORT=""
        PROTOCOL_NAME="TUIC"
    else
        HY2_PORT=$PRIMARY_PORT
        TUIC_PORT=""
        PROTOCOL_NAME="Hysteria2"
    fi

    if [ $PORT_COUNT -eq 1 ]; then
        SS_PORT=""
        SINGLE_PORT_MODE=true
    else
        SS_PORT=${AVAILABLE_PORTS[1]}
        SINGLE_PORT_MODE=false
    fi
    ARGO_PORT=8081

    # SS 端口显示文本
    if [ -n "$SS_PORT" ]; then
        SS_DISPLAY="$SS_PORT"
    else
        SS_DISPLAY="未开启"
    fi

    # ================== UUID 逻辑 (优化点4: 严格遵守不读取缓存) ==================
    UUID_FILE="uuid.txt"
    if [ -n "$FIXED_UUID" ]; then
        UUID="$FIXED_UUID"
        echo "$UUID" > "$UUID_FILE"
    else
        # 严格执行：每次循环(重启)都生成新UUID
        UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "$UUID" > "$UUID_FILE"
        echo "[UUID] 新生成: $UUID"
    fi
    
    if [ -n "$CUSTOM_SUB_SECRET" ]; then
        SUB_PATH="$CUSTOM_SUB_SECRET"
    else
        SUB_PATH="$UUID"
    fi

    # [新增] 提前计算订阅链接，供面板显示
    SUB_URL="http://${PUBLIC_IP}:${HTTP_PORT}/${SUB_PATH}"
    PANEL_URL="http://${PUBLIC_IP}:${HTTP_PORT}/panel/${SUB_PATH}"

    # ================== 下载核心 ==================
    ARCH=$(uname -m)
    [[ "$ARCH" == "aarch64" ]] && BASE_URL="https://arm64.ssss.nyc.mn" || BASE_URL="https://amd64.ssss.nyc.mn"
    [[ "$ARCH" == "aarch64" ]] && ARGO_ARCH="arm64" || ARGO_ARCH="amd64"
    
    SB_FILE="${FILE_PATH}/sb"
    ARGO_FILE="${FILE_PATH}/cloudflared"

    download_file() {
        if [ -x "$2" ]; then return 0; fi
        curl -L -sS --max-time 60 -o "$2" "$1" && chmod +x "$2"
    }
    
    download_file "${BASE_URL}/sb" "$SB_FILE"
    download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}" "$ARGO_FILE"

    # ================== 证书 ==================
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
    else
        printf -- "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsoAoGCCqGSM49\nAwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa/\nTsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==\n-----END EC PRIVATE KEY-----\n" > "${FILE_PATH}/private.key"
        printf -- "-----BEGIN CERTIFICATE-----\nMIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw\nMTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH\nA0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgJ54Ga3qEAxdegEWv07Mi8ha\nD5IU8Um3oR/zgRIx7UmRmg4TKkOjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR\nBfGbgrkMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMB\nAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+\neQ6OFb9LbLYL9Zi+AiB+foMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==\n-----END CERTIFICATE-----\n" > "${FILE_PATH}/cert.pem"
    fi

    # ================== 初始化订阅文件 ==================
    > "${FILE_PATH}/list.txt"
    if [ -n "$TUIC_PORT" ]; then
        echo "tuic://${UUID}:admin@${PUBLIC_IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-Node" >> "${FILE_PATH}/list.txt"
    fi
    if [ -n "$HY2_PORT" ]; then
        echo "hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&insecure=1#Hy2-Node" >> "${FILE_PATH}/list.txt"
    fi
    if [ -n "$SS_PORT" ]; then
        SS_BASE64=$(echo -n "aes-256-gcm:${UUID}" | base64 -w 0 2>/dev/null || echo -n "aes-256-gcm:${UUID}" | openssl base64 | tr -d '\n')
        echo "ss://${SS_BASE64}@${PUBLIC_IP}:${SS_PORT}#SS-Node" >> "${FILE_PATH}/list.txt"
    fi
    cat "${FILE_PATH}/list.txt" > "${FILE_PATH}/sub.txt"

    # ================== 启动 Sing-box ==================
    INBOUNDS=""
    if [ -n "$TUIC_PORT" ]; then
        INBOUNDS="{ \"type\": \"tuic\", \"tag\": \"tuic-in\", \"listen\": \"::\", \"listen_port\": ${TUIC_PORT}, \"users\": [{\"uuid\": \"${UUID}\", \"password\": \"admin\"}], \"congestion_control\": \"bbr\", \"tls\": { \"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\" } }"
    fi
    if [ -n "$HY2_PORT" ]; then
        [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
        INBOUNDS="${INBOUNDS}{ \"type\": \"hysteria2\", \"tag\": \"hy2-in\", \"listen\": \"::\", \"listen_port\": ${HY2_PORT}, \"users\": [{\"password\": \"${UUID}\"}], \"ignore_client_bandwidth\": true, \"tls\": { \"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\" } }"
    fi
    if [ -n "$SS_PORT" ]; then
        [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
        INBOUNDS="${INBOUNDS}{ \"type\": \"shadowsocks\", \"tag\": \"ss-in\", \"listen\": \"::\", \"listen_port\": ${SS_PORT}, \"method\": \"aes-256-gcm\", \"password\": \"${UUID}\" }"
    fi
    [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
    INBOUNDS="${INBOUNDS}{ \"type\": \"vless\", \"tag\": \"vless-argo-in\", \"listen\": \"127.0.0.1\", \"listen_port\": ${ARGO_PORT}, \"users\": [{\"uuid\": \"${UUID}\"}], \"transport\": { \"type\": \"ws\", \"path\": \"/${UUID}-vless\" } }"

cat > "${FILE_PATH}/config.json" <<CFGEOF
{ "log": {"level": "warn"}, "inbounds": [${INBOUNDS}], "outbounds": [{"type": "direct", "tag": "direct"}] }
CFGEOF

    echo "[SING-BOX] 启动中..."
    "$SB_FILE" run -c "${FILE_PATH}/config.json" &
    SB_PID=$!

    # ================== Node.js 控制面板 (增加订阅显示) ==================
    if [ -n "$HTTP_PORT" ]; then
cat > "${FILE_PATH}/server.js" <<JSEOF
const http = require('http');
const fs = require('fs');
const port = process.argv[2] || 8080;
const bind = process.argv[3] || '0.0.0.0';
const sb_pid = process.argv[4];
const configFile = '${CONFIG_FILE}';

// HTML 模板
const html = \`
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Server Control Panel</title>
    <style>
        body { background: #1a1b1e; color: #fff; font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .card { background: #25262b; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.4); text-align: center; max-width: 400px; width: 90%; }
        h1 { color: #4dabf7; margin-bottom: 0.5rem; }
        .status { margin: 1rem 0; padding: 1rem; background: #2c2e33; border-radius: 8px; text-align: left; font-size: 0.9rem; }
        .status span { display: block; margin: 5px 0; }
        .btn { display: block; width: 100%; padding: 12px; margin: 10px 0; border: none; border-radius: 6px; font-size: 1rem; cursor: pointer; transition: 0.2s; color: #fff; }
        .btn-blue { background: #1971c2; } .btn-blue:hover { background: #1864ab; }
        .btn-green { background: #2f9e44; } .btn-green:hover { background: #2b8a3e; }
        .btn-red { background: #e03131; } .btn-red:hover { background: #c92a2a; }
        .tag { font-weight: bold; color: #fab005; }
        .sub-box { margin-top: 15px; border-top: 1px solid #444; padding-top: 10px; }
        .sub-input { width: 100%; box-sizing: border-box; background: #1a1b1e; border: 1px solid #555; color: #ccc; padding: 8px; border-radius: 4px; margin-top: 5px; outline: none; font-size: 0.8rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>🚀 控制面板</h1>
        <div class="status">
            <span>当前协议: <b class="tag">${PROTOCOL_NAME}</b></span>
            <span>运行 UUID: ${UUID}</span>
            <span>SS 端口: ${SS_DISPLAY}</span>
            <div class="sub-box">
                <span style="color:#aaa; font-size:0.85rem;">订阅链接 (点击复制):</span>
                <input type="text" class="sub-input" value="${SUB_URL}" readonly onclick="this.select(); document.execCommand('copy'); alert('已复制到剪贴板!')">
            </div>
        </div>
        <button class="btn btn-blue" onclick="switchProto('tuic')">🔄 切换为 TUIC (UDP)</button>
        <button class="btn btn-green" onclick="switchProto('hy2')">⚡ 切换为 Hysteria2 (UDP)</button>
        <hr style="border-color: #444; margin: 1.5rem 0;">
        <button class="btn btn-red" onclick="restart()">🔥 立即重启服务 (Restart)</button>
    </div>
    <script>
        function switchProto(proto) {
            if(!confirm('确定要切换协议并重启吗？连接将中断几秒。')) return;
            fetch('?action=switch&proto=' + proto).then(res => res.text()).then(txt => document.body.innerHTML = '<h2 style="color:#fff">'+txt+'</h2>');
        }
        function restart() {
            if(!confirm('确定要重启吗？UUID 可能会刷新。')) return;
            fetch('?action=restart').then(res => res.text()).then(txt => document.body.innerHTML = '<h2 style="color:#fff">'+txt+'</h2>');
        }
    </script>
</body>
</html>
\`;

http.createServer((req, res) => {
    // 验证路径密钥
    if (!req.url.includes('${SUB_PATH}')) {
        res.writeHead(404);
        res.end('404 Not Found');
        return;
    }

    // === 控制面板 API ===
    if (req.url.includes('/panel')) {
        const urlParams = new URL(req.url, 'http://localhost').searchParams;
        const action = urlParams.get('action');

        if (action === 'switch') {
            const proto = urlParams.get('proto');
            if (proto === 'tuic' || proto === 'hy2') {
                fs.writeFileSync(configFile, proto);
                res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
                res.end('正在切换协议并重启... (Switching to ' + proto + '...)');
                fs.writeFileSync('${FILE_PATH}/.restart_flag', 'true');
                if (sb_pid) try { process.kill(sb_pid, 'SIGTERM'); } catch(e) {}
            }
            return;
        }

        if (action === 'restart') {
            res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
            res.end('正在执行重启... (Restarting...)');
            fs.writeFileSync('${FILE_PATH}/.restart_flag', 'true');
            if (sb_pid) try { process.kill(sb_pid, 'SIGTERM'); } catch(e) {}
            return;
        }

        res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
        res.end(html);
        return;
    }

    // === 订阅链接 ===
    if (req.url.includes('/${SUB_PATH}')) {
        res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
        try { res.end(fs.readFileSync('${FILE_PATH}/sub.txt', 'utf8')); } catch(e) { res.end('error'); }
        return;
    }

    res.writeHead(404);
    res.end('404');

}).listen(port, bind, () => console.log('HTTP on ' + bind + ':' + port));
JSEOF
        node "${FILE_PATH}/server.js" $HTTP_PORT 0.0.0.0 $SB_PID &
        HTTP_PID=$!
    fi

    # ================== 启动 Argo (保持原版逻辑) ==================
    ARGO_LOG="${FILE_PATH}/argo.log"
    echo "[Argo] 启动隧道..."
    "$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://127.0.0.1:${ARGO_PORT} > "$ARGO_LOG" 2>&1 &
    ARGO_PID=$!
    
    (
        sleep 5
        ARGO_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | head -1 | sed 's|https://||')
        if [ -n "$ARGO_DOMAIN" ]; then
             echo "vless://${UUID}@${BEST_CF_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=%2F${UUID}-vless#Argo-Node" >> "${FILE_PATH}/list.txt"
             cat "${FILE_PATH}/list.txt" > "${FILE_PATH}/sub.txt"
             echo "[Argo] 域名: $ARGO_DOMAIN"
        fi
    ) &

    # ================== 输出信息 ==================
    echo ""
    echo "==================================================="
    echo "模式: 双端口 ($PROTOCOL_NAME + SS + Argo)"
    echo "UUID: $UUID"
    echo ""
    echo "订阅链接: $SUB_URL"
    echo "控制面板: $PANEL_URL"
    echo "==================================================="
    echo ""

    wait "$SB_PID" # 优化点3: 增加引号
    
    # 优化点3: 增加非空判断和引号
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
    [ -n "$ARGO_PID" ] && kill "$ARGO_PID" 2>/dev/null
    
    if [ -f "${FILE_PATH}/.restart_flag" ]; then
        echo "♻️ 重载配置中..."
        rm -f "${FILE_PATH}/.restart_flag"
        sleep 1
        continue 
    else
        echo "⚠️ 意外崩溃，5秒后重启..."
        sleep 5
    fi
done
