#!/bin/bash
# ================== 配置区域 ==================

# [配置] 默认协议 (仅当没有保存的配置时生效)
DEFAULT_PROTOCOL="hy2"

# [配置] 手动填写第二个端口 (例如: "10086")
MANUAL_SECOND_PORT="10086"

# [配置] 控制面板固定路径/密钥 (写死)
CUSTOM_SUB_SECRET="hello"

# 固定隧道填写token
ARGO_TOKEN=""

# ================== 核心循环逻辑 ==================

CONFIG_FILE="saved_config.txt"
USERS_FILE="users.json"

# 强力清理函数
cleanup() {
    echo "[系统] 正在清理进程..."
    [ -n "$SB_PID" ] && kill -9 "$SB_PID" 2>/dev/null
    [ -n "$HTTP_PID" ] && kill -9 "$HTTP_PID" 2>/dev/null
    [ -n "$ARGO_PID" ] && kill -9 "$ARGO_PID" 2>/dev/null
    pkill -9 -f "sb run -c" 2>/dev/null
    rm -f "$FILE_PATH/.restart_flag"
}

trap "cleanup; exit 0" SIGTERM SIGINT

while true; do
    echo "==================================================="
    echo "   🚀 正在启动服务 (v5.7) ..."
    echo "==================================================="

    # ================== 变量与目录准备 ==================
    CF_DOMAINS=("cf.090227.xyz" "cf.877774.xyz" "cf.130519.xyz" "cf.008500.xyz" "store.ubi.com" "saas.sin.fan")
    
    cd "$(dirname "$0")"
    export FILE_PATH="${PWD}/.npm"
    rm -rf "$FILE_PATH"
    mkdir -p "$FILE_PATH"
    
    # 确保用户数据文件存在
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        INIT_UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "[{\"uuid\":\"$INIT_UUID\",\"name\":\"默认用户\"}]" > "$USERS_FILE"
        echo "[初始化] 已创建默认用户文件: $USERS_FILE"
    fi

    # ================== 读取/保存 协议配置 ==================
    if [ -f "$CONFIG_FILE" ]; then
        PORT1_PROTOCOL=$(cat "$CONFIG_FILE")
    else
        PORT1_PROTOCOL="$DEFAULT_PROTOCOL"
        echo "$PORT1_PROTOCOL" > "$CONFIG_FILE"
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

    # ================== CF 优选 ==================
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

    if [ -n "$SS_PORT" ]; then SS_DISPLAY="$SS_PORT"; else SS_DISPLAY="未开启"; fi

    # ================== 面板路径处理 ==================
    if [ -n "$CUSTOM_SUB_SECRET" ]; then
        PANEL_KEY="$CUSTOM_SUB_SECRET"
    else
        PANEL_KEY="admin"
    fi
    PANEL_URL="http://${PUBLIC_IP}:${HTTP_PORT}/panel/${PANEL_KEY}"

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

    # ================== 初次配置生成 ==================
cat > "${FILE_PATH}/gen_config.js" <<JSGEN
const fs = require('fs');
try {
    let users = [];
    try { users = JSON.parse(fs.readFileSync('${USERS_FILE}', 'utf8')); } catch(e) { users = []; }

    const firstUserUUID = (users && users.length > 0 && users[0].uuid) ? users[0].uuid : "00000000-0000-0000-0000-000000000000";
    const tuicPort = '${TUIC_PORT}' ? parseInt('${TUIC_PORT}') : 0;
    const hy2Port = '${HY2_PORT}' ? parseInt('${HY2_PORT}') : 0;
    const ssPort = '${SS_PORT}' ? parseInt('${SS_PORT}') : 0;
    
    const tuicUsers = users.map(u => ({ uuid: u.uuid, password: "admin" }));
    const hy2Users = users.map(u => ({ password: u.uuid }));
    const ssUsers = users.map(u => ({ password: u.uuid }));
    const vlessUsers = users.map(u => ({ uuid: u.uuid }));

    const inbounds = [];
    if (tuicPort > 0) {
        inbounds.push({
            type: "tuic", tag: "tuic-in", listen: "::", listen_port: tuicPort, users: tuicUsers, congestion_control: "bbr",
            tls: { enabled: true, alpn: ["h3"], certificate_path: "${FILE_PATH}/cert.pem", key_path: "${FILE_PATH}/private.key" }
        });
    }
    if (hy2Port > 0) {
        inbounds.push({
            type: "hysteria2", tag: "hy2-in", listen: "::", listen_port: hy2Port, users: hy2Users, ignore_client_bandwidth: true,
            tls: { enabled: true, alpn: ["h3"], certificate_path: "${FILE_PATH}/cert.pem", key_path: "${FILE_PATH}/private.key" }
        });
    }
    if (ssPort > 0) {
        inbounds.push({
            type: "shadowsocks", tag: "ss-in", listen: "::", listen_port: ssPort, method: "aes-256-gcm", 
            password: firstUserUUID, users: ssUsers 
        });
    }
    inbounds.push({
        type: "vless", tag: "vless-argo-in", listen: "127.0.0.1", listen_port: ${ARGO_PORT}, users: vlessUsers, transport: { type: "ws", path: "/vless-argo" }
    });

    console.log(JSON.stringify({ log: { level: "warn" }, inbounds: inbounds, outbounds: [{ type: "direct", tag: "direct" }] }));
} catch(e) { console.error(e); }
JSGEN

    node "${FILE_PATH}/gen_config.js" > "${FILE_PATH}/config.json"

    echo "[SING-BOX] 启动中..."
    "$SB_FILE" run -c "${FILE_PATH}/config.json" &
    SB_PID=$!

    # ================== Node.js 控制面板 (热重载版) ==================
    if [ -n "$HTTP_PORT" ]; then

# 1. 生成 HTML (纯前端逻辑)
cat > "${FILE_PATH}/panel.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Server Manager</title>
    <style>
        body { background: #1a1b1e; color: #e9ecef; font-family: sans-serif; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; }
        .card { background: #25262b; padding: 20px; border-radius: 12px; box-shadow: 0 4px 24px rgba(0,0,0,0.2); margin-bottom: 20px; }
        h2 { margin-top: 0; color: #4dabf7; display: flex; justify-content: space-between; align-items: center; }
        .btn { border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 14px; color: #fff; text-decoration: none; display: inline-block;}
        .btn-primary { background: #1971c2; } .btn-primary:hover { background: #1864ab; }
        .btn-success { background: #2f9e44; } .btn-success:hover { background: #2b8a3e; }
        .btn-danger { background: #e03131; } .btn-danger:hover { background: #c92a2a; }
        .btn-sm { padding: 4px 8px; font-size: 12px; margin-left: 5px; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #373a40; }
        th { color: #909296; font-size: 12px; text-transform: uppercase; }
        input[type="text"] { background: #1a1b1e; border: 1px solid #373a40; color: #fff; padding: 6px; border-radius: 4px; width: 100%; box-sizing: border-box; }
        .action-cell { display: flex; gap: 5px; }
        .protocol-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; background: #373a40; font-size: 12px; margin-right: 5px; }
        .toast { position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%); background: #2f9e44; color: white; padding: 10px 20px; border-radius: 50px; opacity: 0; transition: 0.3s; pointer-events: none; }
        .toast.show { opacity: 1; bottom: 40px; }
    </style>
</head>
<body>
    <div class="toast" id="toast">✅ 操作生效 (Changes Applied)</div>
    <div class="container">
        <div class="card">
            <h2>
                <span>🚀 服务管理</span>
                <span style="font-size:12px; color:#aaa; font-weight:normal;">Hot Reload Active</span>
            </h2>
            <div style="margin-bottom: 15px;">
                <span class="protocol-badge">当前协议: ${PROTOCOL_NAME}</span>
                <span class="protocol-badge">SS端口: ${SS_DISPLAY}</span>
            </div>
            <div style="display:flex; gap:10px;">
                <button class="btn btn-primary" style="flex:1" onclick="switchProto('tuic')">切换 TUIC (需重启)</button>
                <button class="btn btn-primary" style="flex:1" onclick="switchProto('hy2')">切换 Hysteria2 (需重启)</button>
            </div>
        </div>

        <div class="card">
            <h2>
                <span>👥 用户订阅管理</span>
                <button class="btn btn-primary btn-sm" onclick="addUser()">+ 新增用户</button>
            </h2>
            <table>
                <thead><tr><th width="20%">备注</th><th width="45%">UUID</th><th width="15%">订阅链接</th><th width="20%">操作</th></tr></thead>
                <tbody id="userTable"></tbody>
            </table>
        </div>
    </div>

    <script>
        function generateUUID() {
            var d = new Date().getTime();
            var d2 = ((typeof performance !== 'undefined') && performance.now && (performance.now()*1000)) || 0;
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16;
                if(d > 0){ r = (d + r)%16 | 0; d = Math.floor(d/16); } else { r = (d2 + r)%16 | 0; d2 = Math.floor(d2/16); }
                return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
            });
        }

        let users = [];
        
        function showToast() { 
            const t = document.getElementById('toast'); t.classList.add('show'); 
            setTimeout(() => t.classList.remove('show'), 2000); 
        }

        function loadUsers() {
            fetch('?action=get_users').then(r=>r.json()).then(d => { users = d; render(); });
        }

        function render() {
            const tbody = document.getElementById('userTable');
            tbody.innerHTML = \`\`; 
            if (users.length === 0) tbody.innerHTML = '<tr><td colspan="4" style="text-align:center; color:#777;">暂无用户</td></tr>';
            users.forEach((u, idx) => {
                const tr = document.createElement('tr');
                tr.innerHTML = \`
                    <td><input type="text" value="\${u.name}" onchange="updateRemark(\${idx}, this.value)"></td>
                    <td><div style="display:flex; gap:5px;"><input type="text" value="\${u.uuid}" readonly style="font-family:monospace; font-size:12px;"></div></td>
                    <td><a href="/sub/\${u.uuid}" target="_blank" class="btn btn-primary btn-sm">打开</a></td>
                    <td class="action-cell">
                        <button class="btn btn-primary btn-sm" onclick="regenUUID(\${idx})">重置</button>
                        <button class="btn btn-danger btn-sm" onclick="delUser(\${idx})">删除</button>
                    </td>
                \`;
                tbody.appendChild(tr);
            });
        }

        function refresh() { loadUsers(); showToast(); }

        function addUser() {
            fetch('?action=manage_user&type=add&name=新用户&uuid=' + generateUUID()).then(() => refresh());
        }

        function delUser(idx) {
            if(!confirm('确定删除吗？')) return;
            fetch('?action=manage_user&type=del&uuid=' + users[idx].uuid).then(() => refresh());
        }

        function regenUUID(idx) {
            fetch('?action=manage_user&type=reset&old_uuid=' + users[idx].uuid + '&new_uuid=' + generateUUID()).then(() => refresh());
        }

        function updateRemark(idx, newName) {
            fetch('?action=manage_user&type=remark&uuid=' + users[idx].uuid + '&name=' + encodeURIComponent(newName)).then(() => showToast());
        }
        
        function switchProto(proto) {
             if(!confirm('切换协议需要重启服务，确定吗？')) return;
             fetch('?action=switch_proto&proto=' + proto).then(() => {
                 alert('正在切换并重启...'); setTimeout(() => location.reload(), 2000);
             });
        }

        loadUsers();
    </script>
</body>
</html>
HTMLEOF

# 2. 生成 Server.js (核心：集成配置生成与热重载)
cat > "${FILE_PATH}/server.js" <<JSEOF
const http = require('http');
const fs = require('fs');
const port = process.argv[2] || 8080;
const bind = process.argv[3] || '0.0.0.0';
const sb_pid = process.argv[4];
const configFile = '${CONFIG_FILE}';
const usersFile = '${USERS_FILE}';
const panelKey = '${PANEL_KEY}';
const publicIp = '${PUBLIC_IP}';
const tuicPort = '${TUIC_PORT}' ? parseInt('${TUIC_PORT}') : 0;
const hy2Port = '${HY2_PORT}' ? parseInt('${HY2_PORT}') : 0;
const ssPort = '${SS_PORT}' ? parseInt('${SS_PORT}') : 0;
const argoPort = ${ARGO_PORT};
const bestCf = '${BEST_CF_DOMAIN}';
const certPath = '${FILE_PATH}/cert.pem';
const keyPath = '${FILE_PATH}/private.key';

function getUsers() {
    try { const data = fs.readFileSync(usersFile, 'utf8'); return data ? JSON.parse(data) : []; } catch(e) { return []; }
}
function saveUsers(users) { fs.writeFileSync(usersFile, JSON.stringify(users)); }

// === 核心：Node.js 内置配置生成器 (用于热重载) ===
function updateConfigAndReload() {
    const users = getUsers();
    const firstUserUUID = (users && users.length > 0 && users[0].uuid) ? users[0].uuid : "00000000-0000-0000-0000-000000000000";
    
    const tuicUsers = users.map(u => ({ uuid: u.uuid, password: "admin" }));
    const hy2Users = users.map(u => ({ password: u.uuid }));
    const ssUsers = users.map(u => ({ password: u.uuid }));
    const vlessUsers = users.map(u => ({ uuid: u.uuid }));

    const inbounds = [];
    if (tuicPort > 0) inbounds.push({ type: "tuic", tag: "tuic-in", listen: "::", listen_port: tuicPort, users: tuicUsers, congestion_control: "bbr", tls: { enabled: true, alpn: ["h3"], certificate_path: certPath, key_path: keyPath } });
    if (hy2Port > 0) inbounds.push({ type: "hysteria2", tag: "hy2-in", listen: "::", listen_port: hy2Port, users: hy2Users, ignore_client_bandwidth: true, tls: { enabled: true, alpn: ["h3"], certificate_path: certPath, key_path: keyPath } });
    if (ssPort > 0) inbounds.push({ type: "shadowsocks", tag: "ss-in", listen: "::", listen_port: ssPort, method: "aes-256-gcm", password: firstUserUUID, users: ssUsers });
    inbounds.push({ type: "vless", tag: "vless-argo-in", listen: "127.0.0.1", listen_port: argoPort, users: vlessUsers, transport: { type: "ws", path: "/vless-argo" } });

    const config = { log: { level: "warn" }, inbounds: inbounds, outbounds: [{ type: "direct", tag: "direct" }] };
    
    // 写入配置并发送信号
    fs.writeFileSync('${FILE_PATH}/config.json', JSON.stringify(config));
    if (sb_pid) {
        try { 
            process.kill(sb_pid, 'SIGHUP'); 
            console.log('[Node] Hot Reload: SIGHUP sent to Sing-box');
        } catch(e) { console.error('[Node] Failed to reload Sing-box:', e); }
    }
}

function generateSub(uuid, argoDomain) {
    let content = '';
    const users = getUsers();
    const user = users.find(u => u.uuid === uuid);
    if (!user) return "Error: User not found";
    const remarks = user.name;

    if (tuicPort) content += \`tuic://\${uuid}:admin@\${publicIp}:\${tuicPort}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-\${encodeURIComponent(remarks)}\\n\`;
    if (hy2Port) content += \`hysteria2://\${uuid}@\${publicIp}:\${hy2Port}/?sni=www.bing.com&insecure=1#Hy2-\${encodeURIComponent(remarks)}\\n\`;
    if (ssPort) { let ssBase64 = Buffer.from(\`aes-256-gcm:\${uuid}\`).toString('base64'); content += \`ss://\${ssBase64}@\${publicIp}:\${ssPort}#SS-\${encodeURIComponent(remarks)}\\n\`; }
    if (argoDomain) content += \`vless://\${uuid}@\${bestCf}:443?encryption=none&security=tls&sni=\${argoDomain}&type=ws&host=\${argoDomain}&path=%2Fvless-argo#Argo-\${encodeURIComponent(remarks)}\\n\`;
    return content;
}

http.createServer((req, res) => {
    const isPanel = req.url.startsWith('/panel/${PANEL_KEY}');
    const isSub = req.url.startsWith('/sub/');
    const url = new URL(req.url, 'http://localhost');
    const params = url.searchParams;

    // === 用户管理 API (热重载) ===
    if (isPanel && params.get('action') === 'manage_user') {
        const type = params.get('type');
        let users = getUsers();
        if (type === 'add') users.push({ name: params.get('name'), uuid: params.get('uuid') });
        else if (type === 'del') users = users.filter(u => u.uuid !== params.get('uuid'));
        else if (type === 'reset') { const u = users.find(u => u.uuid === params.get('old_uuid')); if(u) u.uuid = params.get('new_uuid'); }
        else if (type === 'remark') { const u = users.find(u => u.uuid === params.get('uuid')); if(u) u.name = params.get('name'); }
        
        saveUsers(users);
        updateConfigAndReload(); // 关键调用
        res.end('ok');
        return;
    }

    if (isPanel && params.get('action') === 'get_users') { res.writeHead(200, {'Content-Type': 'application/json'}); res.end(JSON.stringify(getUsers())); return; }
    
    // 切换协议 (仍需重启脚本)
    if (isPanel && params.get('action') === 'switch_proto') {
        fs.writeFileSync(configFile, params.get('proto'));
        fs.writeFileSync('${FILE_PATH}/.restart_flag', 'true');
        if (sb_pid) try { process.kill(sb_pid, 'SIGTERM'); } catch(e) {}
        res.end('ok');
        return;
    }

    if (isPanel) { res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'}); try { res.end(fs.readFileSync('${FILE_PATH}/panel.html', 'utf8')); } catch(e) { res.end('Error'); } return; }

    if (isSub) {
        const uuid = req.url.split('/sub/')[1];
        const userExists = getUsers().some(u => u.uuid === uuid);
        if (userExists) {
            let argoDomain = '';
            try { const log = fs.readFileSync('${FILE_PATH}/argo.log', 'utf8'); const match = log.match(/https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com/); if (match) argoDomain = match[0].replace('https://', ''); } catch(e) {}
            res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
            res.end(generateSub(uuid, argoDomain));
        } else { res.writeHead(404); res.end('User not found'); }
        return;
    }
    res.writeHead(404); res.end('404');
}).listen(port, bind, () => console.log('HTTP on ' + bind + ':' + port));
JSEOF
        node "${FILE_PATH}/server.js" $HTTP_PORT 0.0.0.0 $SB_PID &
        HTTP_PID=$!
    fi

    # ================== 启动 Argo ==================
    ARGO_LOG="${FILE_PATH}/argo.log"
    echo "[Argo] 启动隧道..."
    if [ -n "$ARGO_TOKEN" ]; then
         "$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate run --token "$ARGO_TOKEN" > "$ARGO_LOG" 2>&1 &
    else
         "$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://127.0.0.1:${ARGO_PORT} > "$ARGO_LOG" 2>&1 &
    fi
    ARGO_PID=$!
    
    # ================== 输出信息 ==================
    echo ""
    echo "==================================================="
    echo "模式: 多用户管理 ($PROTOCOL_NAME + Argo)"
    echo "控制面板地址: $PANEL_URL"
    echo "==================================================="
    echo ""

    wait "$SB_PID"
    
    [ -n "$HTTP_PID" ] && kill -9 "$HTTP_PID" 2>/dev/null
    [ -n "$ARGO_PID" ] && kill -9 "$ARGO_PID" 2>/dev/null
    
    if [ -f "${FILE_PATH}/.restart_flag" ]; then
        echo "♻️ 协议切换，正在重启..."
        rm -f "${FILE_PATH}/.restart_flag"
        sleep 1
        continue 
    else
        echo "⚠️ 意外崩溃，5秒后重启..."
        sleep 5
    fi
done
