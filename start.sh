#!/bin/bash
# ================== 配置区域 ==================

# [配置] 默认协议
DEFAULT_PROTOCOL="hy2"

# [配置] ShadowSocks 端口
MANUAL_SECOND_PORT="25109"

# [配置] 控制面板密钥 
CUSTOM_SUB_SECRET="hello"

# Argo Token (可选)
ARGO_TOKEN=""

# ================== 核心循环逻辑 ==================

CONFIG_FILE="saved_config.txt"
USERS_FILE="users.json"

# 脚本自身日志颜色保持
log() {
    echo -e "\033[36m[$(date '+%Y-%m-%d %H:%M:%S')]\033[0m $1"
}

# [修改] 兼容性清理函数 (不依赖 pkill)
cleanup() {
    log "[系统] 正在清理进程..."
    
    # 1. 优先尝试杀死记录的 PID
    [ -n "$SB_PID" ] && kill -9 "$SB_PID" 2>/dev/null
    [ -n "$HTTP_PID" ] && kill -9 "$HTTP_PID" 2>/dev/null
    [ -n "$ARGO_PID" ] && kill -9 "$ARGO_PID" 2>/dev/null
    
    # 2. 兜底清理：使用 ps 查找残留的 sb 进程
    PIDS=$(ps -ef 2>/dev/null | grep "${FILE_PATH}/sb" | grep -v grep | awk '{print $2}' 2>/dev/null)
    if [ -z "$PIDS" ]; then
        PIDS=$(ps 2>/dev/null | grep "${FILE_PATH}/sb" | grep -v grep | awk '{print $1}' 2>/dev/null)
    fi
    
    for pid in $PIDS; do
        if [ "$pid" != "$$" ]; then # 防止误杀自己
            kill -9 "$pid" 2>/dev/null
        fi
    done
    
    rm -f "$FILE_PATH/.restart_flag"
}

trap "cleanup; exit 0" SIGTERM SIGINT

while true; do
    echo ""
    echo "==================================================="
    echo "   🚀 正在启动服务 (v7.5 五列精简版) ..."
    echo "==================================================="
    echo ""

    # ================== 准备工作 ==================
    CF_DOMAINS=("cf.090227.xyz" "cf.877774.xyz" "cf.130519.xyz" "cf.008500.xyz" "store.ubi.com" "saas.sin.fan")
    
    cd "$(dirname "$0")"
    export FILE_PATH="${PWD}/.npm"
    rm -rf "$FILE_PATH"
    mkdir -p "$FILE_PATH"
    
    # 初始化用户文件
    if [ ! -f "$USERS_FILE" ] || [ ! -s "$USERS_FILE" ]; then
        INIT_UUID=$(cat /proc/sys/kernel/random/uuid)
        echo "[{\"uuid\":\"$INIT_UUID\",\"name\":\"默认用户\",\"expiry\":null}]" > "$USERS_FILE"
        log "[初始化] 已创建默认用户文件: $USERS_FILE"
    fi

    if [ -f "$CONFIG_FILE" ]; then PORT1_PROTOCOL=$(cat "$CONFIG_FILE"); else PORT1_PROTOCOL="$DEFAULT_PROTOCOL"; echo "$PORT1_PROTOCOL" > "$CONFIG_FILE"; fi

    log "[网络] 正在获取公网 IP..."
    PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb || curl -s --max-time 5 api.ipify.org || echo "")
    if [ -z "$PUBLIC_IP" ]; then log "[错误] 无法获取 IP，5秒后重试..."; sleep 5; continue; fi
    log "[网络] 公网 IP: $PUBLIC_IP"

    select_random_cf_domain() {
        local available=()
        for domain in "${CF_DOMAINS[@]}"; do if curl -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null; then available+=("$domain"); fi; done
        [ ${#available[@]} -gt 0 ] && echo "${available[$((RANDOM % ${#available[@]}))]}" || echo "${CF_DOMAINS[0]}"
    }
    BEST_CF_DOMAIN=$(select_random_cf_domain)

    # 端口处理
    [ -n "$SERVER_PORT" ] && PORTS_STRING="$SERVER_PORT" || PORTS_STRING=""
    if [ -n "$MANUAL_SECOND_PORT" ]; then if [ -n "$PORTS_STRING" ]; then PORTS_STRING="$PORTS_STRING $MANUAL_SECOND_PORT"; else PORTS_STRING="$MANUAL_SECOND_PORT"; fi; fi
    read -ra AVAILABLE_PORTS <<< "$PORTS_STRING"
    PORT_COUNT=${#AVAILABLE_PORTS[@]}

    if [ $PORT_COUNT -eq 0 ]; then log "[错误] 未找到端口，重试..."; sleep 5; continue; fi

    PRIMARY_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[0]}

    if [ "$PORT1_PROTOCOL" == "tuic" ]; then TUIC_PORT=$PRIMARY_PORT; HY2_PORT=""; PROTOCOL_NAME="TUIC"; else HY2_PORT=$PRIMARY_PORT; TUIC_PORT=""; PROTOCOL_NAME="Hysteria2"; fi
    if [ $PORT_COUNT -eq 1 ]; then SS_PORT=""; else SS_PORT=${AVAILABLE_PORTS[1]}; fi
    ARGO_PORT=8081
    if [ -n "$SS_PORT" ]; then SS_DISPLAY="$SS_PORT"; else SS_DISPLAY="未开启"; fi

    if [ -n "$CUSTOM_SUB_SECRET" ]; then PANEL_KEY="$CUSTOM_SUB_SECRET"; else PANEL_KEY="admin"; fi
    PANEL_URL="http://${PUBLIC_IP}:${HTTP_PORT}/panel/${PANEL_KEY}"

    # 下载核心
    ARCH=$(uname -m)
    [[ "$ARCH" == "aarch64" ]] && BASE_URL="https://arm64.ssss.nyc.mn" || BASE_URL="https://amd64.ssss.nyc.mn"
    [[ "$ARCH" == "aarch64" ]] && ARGO_ARCH="arm64" || ARGO_ARCH="amd64"
    SB_FILE="${FILE_PATH}/sb"; ARGO_FILE="${FILE_PATH}/cloudflared"

    download_file() { if [ ! -x "$2" ]; then curl -L -sS --max-time 60 -o "$2" "$1" && chmod +x "$2"; fi; }
    download_file "${BASE_URL}/sb" "$SB_FILE"
    download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}" "$ARGO_FILE"

    # 证书
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
    else
        printf -- "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsoAoGCCqGSM49\nAwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa/\nTsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==\n-----END EC PRIVATE KEY-----\n" > "${FILE_PATH}/private.key"
        printf -- "-----BEGIN CERTIFICATE-----\nMIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw\nMTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH\nA0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgJ54Ga3qEAxdegEWv07Mi8ha\nD5IU8Um3oR/zgRIx7UmRmg4TKkOjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR\nBfGbgrkMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMB\nAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+\neQ6OFb9LbLYL9Zi+AiB+foMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==\n-----END CERTIFICATE-----\n" > "${FILE_PATH}/cert.pem"
    fi

    # ================== Sing-box 配置生成 ==================
cat > "${FILE_PATH}/gen_config.js" <<JSGEN
const fs = require('fs');
try {
    let users = [];
    try { users = JSON.parse(fs.readFileSync('${USERS_FILE}', 'utf8')); } catch(e) { users = []; }

    // [关键] 过滤掉已过期的用户
    const now = Date.now();
    const activeUsers = users.filter(u => !u.expiry || u.expiry > now);
    const firstUserUUID = (activeUsers.length > 0) ? activeUsers[0].uuid : "00000000-0000-0000-0000-000000000000";

    const tuicPort = '${TUIC_PORT}' ? parseInt('${TUIC_PORT}') : 0;
    const hy2Port = '${HY2_PORT}' ? parseInt('${HY2_PORT}') : 0;
    const ssPort = '${SS_PORT}' ? parseInt('${SS_PORT}') : 0;
    
    const tuicUsers = activeUsers.map(u => ({ uuid: u.uuid, password: "admin" }));
    const hy2Users = activeUsers.map(u => ({ password: u.uuid }));
    const ssUsers = activeUsers.map(u => ({ password: u.uuid }));
    const vlessUsers = activeUsers.map(u => ({ uuid: u.uuid }));

    const inbounds = [];
    if (tuicPort > 0) inbounds.push({
        type: "tuic", tag: "tuic-in", listen: "::", listen_port: tuicPort, users: tuicUsers, congestion_control: "bbr",
        tls: { enabled: true, alpn: ["h3"], certificate_path: "${FILE_PATH}/cert.pem", key_path: "${FILE_PATH}/private.key" }
    });
    if (hy2Port > 0) inbounds.push({
        type: "hysteria2", tag: "hy2-in", listen: "::", listen_port: hy2Port, users: hy2Users, ignore_client_bandwidth: true,
        tls: { enabled: true, alpn: ["h3"], certificate_path: "${FILE_PATH}/cert.pem", key_path: "${FILE_PATH}/private.key" }
    });
    if (ssPort > 0) inbounds.push({
        type: "shadowsocks", tag: "ss-in", listen: "::", listen_port: ssPort, method: "aes-256-gcm", 
        password: firstUserUUID, users: ssUsers 
    });
    inbounds.push({
        type: "vless", tag: "vless-argo-in", listen: "127.0.0.1", listen_port: ${ARGO_PORT}, users: vlessUsers, transport: { type: "ws", path: "/vless-argo" }
    });
    
    console.log(JSON.stringify({ log: { level: "warn", timestamp: true }, inbounds: inbounds, outbounds: [{ type: "direct", tag: "direct" }] }));
} catch(e) { console.error(e); }
JSGEN

    node "${FILE_PATH}/gen_config.js" > "${FILE_PATH}/config.json"

    log "[SING-BOX] 正在启动核心服务..."
    "$SB_FILE" run -c "${FILE_PATH}/config.json" &
    SB_PID=$!

    # ================== Node.js 控制面板 ==================
    if [ -n "$HTTP_PORT" ]; then

# 1. HTML 前端 (v7.5: 5列布局，紧凑优化)
cat > "${FILE_PATH}/panel.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>代理管理面板 Pro</title>
    <style>
        :root { --bg: #121212; --card: #1e1e1e; --primary: #3b82f6; --text: #e5e7eb; --text-gray: #9ca3af; --border: #374151; --danger: #ef4444; --success: #22c55e; }
        body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 20px; box-sizing: border-box; }
        .container { max-width: 1000px; margin: 0 auto; }
        .card { background: var(--card); border-radius: 12px; padding: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.3); margin-bottom: 20px; border: 1px solid var(--border); }
        h2 { margin: 0 0 15px 0; font-size: 1.25rem; border-bottom: 1px solid var(--border); padding-bottom: 10px; display: flex; align-items: center; justify-content: space-between; }
        
        button, input, select { outline: none; transition: 0.2s; }
        .btn { border: none; padding: 6px 12px; border-radius: 6px; cursor: pointer; font-size: 13px; font-weight: 500; color: white; background: var(--border); }
        .btn:hover { filter: brightness(1.1); }
        .btn-primary { background: var(--primary); }
        .btn-danger { background: var(--danger); }
        .btn-success { background: var(--success); }
        .btn-icon { background: transparent; color: var(--text-gray); font-size: 16px; padding: 4px; border: none; cursor: pointer; }
        .btn-icon:hover { color: white; background: rgba(255,255,255,0.1); border-radius: 50%; }

        input[type="text"] { background: #2d2d2d; border: 1px solid var(--border); color: white; padding: 8px; border-radius: 6px; width: 100%; box-sizing: border-box; }
        input[type="text"]:focus { border-color: var(--primary); }

        .user-grid { display: grid; grid-template-columns: 1.5fr 2.5fr 2.5fr 1.5fr 0.8fr 2fr; gap: 10px; align-items: center; padding: 12px 0; border-bottom: 1px solid #2d2d2d; }
        .user-grid.header-row { font-size: 12px; color: var(--text-gray); text-transform: uppercase; border-bottom: 1px solid var(--border); padding-bottom: 8px; font-weight: bold; }
        
        .status-badge { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; padding: 2px 8px; border-radius: 4px; background: rgba(34, 197, 94, 0.1); color: var(--success); white-space: nowrap; }
        .status-badge.expired { background: rgba(239, 68, 68, 0.1); color: var(--danger); }
        
        .uuid-box { font-family: monospace; font-size: 11px; background: #000; padding: 6px; border-radius: 4px; color: #a5f3fc; opacity: 0.9; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .time-box { font-size: 12px; color: #ccc; margin-top: 3px; font-family: monospace; }
        
        /* 模态框 */
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); display: none; justify-content: center; align-items: center; z-index: 1000; backdrop-filter: blur(2px); }
        .modal { background: #252525; border-radius: 16px; width: 90%; max-width: 440px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.5); border: 1px solid var(--border); overflow: hidden; animation: popIn 0.3s ease-out; }
        @keyframes popIn { from { transform: scale(0.95); opacity: 0; } to { transform: scale(1); opacity: 1; } }
        
        .modal-header { padding: 15px 20px; background: #2d2d2d; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); }
        .modal-body { padding: 20px; }
        .modal-footer { padding: 15px 20px; display: flex; justify-content: flex-end; gap: 10px; background: #2d2d2d; border-top: 1px solid var(--border); }

        /* 滚动选择器 - 布局紧凑化优化 */
        .picker-wrapper { display: flex; justify-content: center; height: 180px; position: relative; margin: 10px 0; background: #1a1a1a; border-radius: 8px; overflow: hidden; gap: 2px; }
        
        .picker-mask-top { position: absolute; top:0; left:0; width:100%; height:60px; background: linear-gradient(to bottom, rgba(26,26,26,0.95), rgba(26,26,26,0.5)); z-index: 10; pointer-events: none;}
        .picker-mask-bottom { position: absolute; bottom:0; left:0; width:100%; height:60px; background: linear-gradient(to top, rgba(26,26,26,0.95), rgba(26,26,26,0.5)); z-index: 10; pointer-events: none;}
        .picker-highlight { position: absolute; top: 70px; left: 0; right: 0; height: 40px; background: rgba(59, 130, 246, 0.15); border-top: 1px solid var(--primary); border-bottom: 1px solid var(--primary); pointer-events: none; z-index: 5; }

        /* 列容器：限制宽度，实现紧凑效果 */
        .picker-col-container { flex: 1; max-width: 60px; display: flex; flex-direction: column; align-items: center; z-index: 20; position: relative; }
        
        .picker-btn-up, .picker-btn-down { 
            width: 100%; height: 26px; display: flex; justify-content: center; align-items: center; cursor: pointer; color: #777; background: #222; z-index: 30; user-select: none; transition: 0.1s;
        }
        .picker-btn-up:hover, .picker-btn-down:hover { background: #333; color: #fff; }
        .picker-btn-up svg, .picker-btn-down svg { width: 14px; height: 14px; fill: currentColor; }
        
        .picker-col { width: 100%; height: 128px; overflow-y: scroll; scroll-snap-type: y mandatory; scrollbar-width: none; text-align: center; position: relative; cursor: grab; user-select: none; scroll-behavior: smooth; }
        .picker-col.is-dragging { scroll-behavior: auto; cursor: grabbing; scroll-snap-type: none; } 
        .picker-col::-webkit-scrollbar { display: none; }
        .picker-col ul { list-style: none; padding: 0; margin: 0; padding-top: 44px; padding-bottom: 44px; } 
        .picker-col li { height: 40px; line-height: 40px; scroll-snap-align: center; font-size: 16px; color: #888; transition: 0.2s; }
        
        .col-label { font-size: 10px; color: var(--primary); margin: 5px 0; text-transform: uppercase; text-align: center; white-space: nowrap; }
        .options-row { display: flex; gap: 20px; margin-bottom: 15px; justify-content: center; }
        .checkbox-label { display: flex; align-items: center; gap: 6px; font-size: 14px; cursor: pointer; user-select: none; }
        .checkbox-label input { accent-color: var(--primary); width: 16px; height: 16px; }

        .toast { position: fixed; bottom: 30px; left: 50%; transform: translateX(-50%) translateY(20px); background: #333; border: 1px solid var(--success); color: var(--success); padding: 10px 20px; border-radius: 30px; opacity: 0; pointer-events: none; transition: 0.3s; display: flex; align-items: center; gap: 8px; z-index: 2000; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.5); }
        .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
    </style>
</head>
<body>
    <div class="toast" id="toast"><span>✔</span> 操作成功</div>

    <div class="container">
        <div class="card">
            <h2>🖥️ 系统状态 <span style="font-size:12px; font-weight:normal; color:#666;">v7.5</span></h2>
            <div style="display: flex; gap: 15px; flex-wrap: wrap; font-size: 14px;">
                <div style="background:#2d2d2d; padding:8px 12px; border-radius:6px;">
                    协议: <strong style="color:var(--primary)">${PROTOCOL_NAME}</strong>
                </div>
                <div style="background:#2d2d2d; padding:8px 12px; border-radius:6px;">
                    端口: <strong>${HTTP_PORT}</strong>
                </div>
                <div style="flex:1; display:flex; justify-content:flex-end; gap:10px;">
                    <button class="btn" onclick="switchProto('tuic')">切换 TUIC</button>
                    <button class="btn" onclick="switchProto('hy2')">切换 Hysteria2</button>
                </div>
            </div>
        </div>

        <div class="card">
            <h2>
                👥 用户管理
                <button class="btn btn-primary" style="font-size:12px;" onclick="addUser()">+ 新增用户</button>
            </h2>

            <div class="user-list">
                <div class="user-grid header-row">
                    <div>备注</div>
                    <div>UUID</div>
                    <div>状态 / 过期时间</div>
                    <div style="color:#a5f3fc">剩余时长</div>
                    <div>订阅</div>
                    <div style="text-align:right">操作</div>
                </div>
                <div id="userTableContainer"></div>
            </div>
        </div>
    </div>

    <div class="modal-overlay" id="timeModal">
        <div class="modal">
            <div class="modal-header">
                <span style="font-weight:bold;">⏳ 设置剩余时间</span>
                <button class="btn-icon" onclick="closeModal()">✕</button>
            </div>
            <div class="modal-body">
                <div id="targetUserDisplay" style="text-align:center; color:var(--primary); margin-bottom:15px; font-weight:bold;"></div>
                
                <div class="options-row">
                    <label class="checkbox-label"><input type="checkbox" id="checkForever" onchange="togglePicker()"> 永久有效 (Forever)</label>
                    <label class="checkbox-label"><input type="checkbox" id="checkExpired" onchange="togglePicker()"> 立即过期 (Expired)</label>
                </div>

                <div style="display:flex; justify-content:center; gap:2px;">
                    <div style="flex:1; max-width:60px;"><div class="col-label">年 (0-10)</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">月 (0-12)</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">日 (0-30)</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">时 (0-60)</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">分 (0-60)</div></div>
                </div>
                
                <div class="picker-wrapper" id="pickerContainer">
                    <div class="picker-mask-top"></div>
                    <div class="picker-mask-bottom"></div>
                    <div class="picker-highlight"></div>

                    <svg style="display:none;">
                        <symbol id="icon-minus" viewBox="0 0 24 24"><path d="M19 13H5v-2h14v2z"/></symbol>
                        <symbol id="icon-plus" viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></symbol>
                    </svg>

                    <div class="picker-col-container">
                        <div class="picker-btn-up" onclick="adjustPicker('col-year', -1)"><svg><use href="#icon-minus"></use></svg></div>
                        <div class="picker-col" id="col-year"><ul></ul></div>
                        <div class="picker-btn-down" onclick="adjustPicker('col-year', 1)"><svg><use href="#icon-plus"></use></svg></div>
                    </div>

                    <div class="picker-col-container">
                        <div class="picker-btn-up" onclick="adjustPicker('col-month', -1)"><svg><use href="#icon-minus"></use></svg></div>
                        <div class="picker-col" id="col-month"><ul></ul></div>
                        <div class="picker-btn-down" onclick="adjustPicker('col-month', 1)"><svg><use href="#icon-plus"></use></svg></div>
                    </div>

                    <div class="picker-col-container">
                        <div class="picker-btn-up" onclick="adjustPicker('col-day', -1)"><svg><use href="#icon-minus"></use></svg></div>
                        <div class="picker-col" id="col-day"><ul></ul></div>
                        <div class="picker-btn-down" onclick="adjustPicker('col-day', 1)"><svg><use href="#icon-plus"></use></svg></div>
                    </div>

                    <div class="picker-col-container">
                        <div class="picker-btn-up" onclick="adjustPicker('col-hour', -1)"><svg><use href="#icon-minus"></use></svg></div>
                        <div class="picker-col" id="col-hour"><ul></ul></div>
                        <div class="picker-btn-down" onclick="adjustPicker('col-hour', 1)"><svg><use href="#icon-plus"></use></svg></div>
                    </div>

                    <div class="picker-col-container">
                        <div class="picker-btn-up" onclick="adjustPicker('col-min', -1)"><svg><use href="#icon-minus"></use></svg></div>
                        <div class="picker-col" id="col-min"><ul></ul></div>
                        <div class="picker-btn-down" onclick="adjustPicker('col-min', 1)"><svg><use href="#icon-plus"></use></svg></div>
                    </div>
                </div>
            </div>
            <div class="modal-footer">
                <button class="btn" onclick="closeModal()">取消</button>
                <button class="btn btn-success" onclick="saveTime()">保存更改</button>
            </div>
        </div>
    </div>

    <script>
        let users = [];
        let currentEditIdx = -1;

        function uuidv4() {
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
                const r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                return v.toString(16);
            });
        }

        function showToast(msg) {
            const t = document.getElementById('toast');
            t.innerHTML = '<span>✔</span> ' + (msg || '操作成功');
            t.classList.add('show');
            setTimeout(() => t.classList.remove('show'), 2000);
        }

        async function fetchUsers() {
            const res = await fetch('?action=get_users');
            users = await res.json();
            render();
        }

        function pad(num) { return num.toString().padStart(2, '0'); }

        function formatFullDate(ts) {
            if (!ts) return "永久有效 ∞";
            const d = new Date(ts);
            return \`\${d.getFullYear()}-\${pad(d.getMonth()+1)}-\${pad(d.getDate())} \${pad(d.getHours())}:\${pad(d.getMinutes())}:\${pad(d.getSeconds())}\`;
        }

        function getRemainingStr(ts) {
            if (!ts) return "∞";
            const now = Date.now();
            if (ts < now) return "已过期";
            
            let diff = ts - now;
            const years = Math.floor(diff / (1000 * 60 * 60 * 24 * 365));
            diff -= years * (1000 * 60 * 60 * 24 * 365);
            const days = Math.floor(diff / (1000 * 60 * 60 * 24));
            diff -= days * (1000 * 60 * 60 * 24);
            const hours = Math.floor(diff / (1000 * 60 * 60));
            diff -= hours * (1000 * 60 * 60);
            const mins = Math.floor(diff / (1000 * 60));

            if (years > 0) return \`\${years}年 \${days}天\`;
            if (days > 0) return \`\${days}天 \${hours}小时\`;
            return \`\${hours}小时 \${mins}分\`;
        }

        function render() {
            const container = document.getElementById('userTableContainer');
            container.innerHTML = '';
            const now = Date.now();

            users.forEach((u, idx) => {
                const isExpired = u.expiry && u.expiry < now;
                const row = document.createElement('div');
                row.className = 'user-grid';
                row.style.opacity = isExpired ? '0.6' : '1';

                const statusHtml = isExpired 
                    ? \`<span class="status-badge expired">无效</span> <div class="time-box">\${formatFullDate(u.expiry)}</div>\` 
                    : \`<span class="status-badge">有效</span> <div class="time-box">\${formatFullDate(u.expiry)}</div>\`;
                
                const remainingHtml = \`<div style="color:\${isExpired ? '#ef4444' : '#a5f3fc'}; font-size:13px; font-weight:bold;">\${getRemainingStr(u.expiry)}</div>\`;

                row.innerHTML = \`
                    <div><input type="text" value="\${u.name}" onchange="updateUser(\${idx}, 'name', this.value)" style="padding:4px; font-size:13px;"></div>
                    <div class="uuid-box">\${u.uuid}</div>
                    <div>\${statusHtml}</div>
                    <div>\${remainingHtml}</div>
                    <div>
                        \${!isExpired ? \`<a href="/sub/\${u.uuid}" target="_blank" class="btn btn-primary" style="padding:2px 8px; font-size:11px; text-decoration:none;">订阅</a>\` : '<span style="font-size:11px; color:#666">--</span>'}
                    </div>
                    <div style="text-align:right; display:flex; gap:5px; justify-content:flex-end;">
                        <button class="btn btn-primary" style="padding:4px 8px; font-size:11px;" onclick="openTimeModal(\${idx})">剩余时间</button>
                        <button class="btn btn-danger" style="padding:4px 8px; font-size:11px;" onclick="delUser(\${idx})">删</button>
                    </div>
                \`;
                container.appendChild(row);
            });
        }

        // ============ Picker 逻辑 (5列支持) ============
        const limits = { year: 10, month: 12, day: 30, hour: 60, min: 60 };
        
        function initPickerCol(id, max) {
            const ul = document.querySelector('#' + id + ' ul');
            ul.innerHTML = '';
            for(let i=0; i<=max; i++) {
                const li = document.createElement('li');
                li.innerText = pad(i);
                ul.appendChild(li);
            }
            enableDrag(document.getElementById(id));
        }

        function enableDrag(ele) {
            let isDown = false;
            let startY;
            let scrollTop;

            ele.addEventListener('mousedown', (e) => {
                isDown = true;
                ele.classList.add('is-dragging'); 
                startY = e.pageY - ele.offsetTop;
                scrollTop = ele.scrollTop;
            });
            
            const stopDrag = () => {
                if(!isDown) return;
                isDown = false;
                ele.classList.remove('is-dragging'); 
                snap(ele);
            };

            ele.addEventListener('mouseleave', stopDrag);
            ele.addEventListener('mouseup', stopDrag);
            ele.addEventListener('mousemove', (e) => {
                if (!isDown) return;
                e.preventDefault();
                const y = e.pageY - ele.offsetTop;
                const walk = (y - startY); 
                ele.scrollTop = scrollTop - walk;
            });
            
            let scrollTimeout;
            ele.addEventListener('scroll', () => {
                if(isDown) return; 
                clearTimeout(scrollTimeout);
                scrollTimeout = setTimeout(() => snap(ele), 100);
            });
        }

        function snap(ele) {
            const itemHeight = 40;
            const current = ele.scrollTop;
            const target = Math.round(current / itemHeight) * itemHeight;
            ele.scrollTo({ top: target, behavior: 'smooth' });
        }

        function adjustPicker(id, dir) {
            const ele = document.getElementById(id);
            const itemHeight = 40;
            const currentIdx = Math.round(ele.scrollTop / itemHeight);
            const newIdx = currentIdx + dir;
            if (newIdx >= 0) {
                ele.scrollTo({ top: newIdx * itemHeight, behavior: 'smooth' });
            }
        }

        function getPickerVal(id) {
            const col = document.getElementById(id);
            return Math.round(col.scrollTop / 40);
        }

        function setPickerVal(id, val) {
            const col = document.getElementById(id);
            col.scrollTop = val * 40;
        }

        function togglePicker() {
            const forever = document.getElementById('checkForever').checked;
            const expired = document.getElementById('checkExpired').checked;
            const container = document.getElementById('pickerContainer');
            
            if (forever || expired) {
                container.style.opacity = '0.3';
                container.style.pointerEvents = 'none';
            } else {
                container.style.opacity = '1';
                container.style.pointerEvents = 'auto';
            }
            if(forever && expired) document.getElementById('checkExpired').checked = false; 
        }

        function openTimeModal(idx) {
            currentEditIdx = idx;
            const u = users[idx];
            document.getElementById('targetUserDisplay').innerText = u.name;
            document.getElementById('timeModal').style.display = 'flex';
            
            const now = Date.now();
            let remYear = 0, remMonth = 0, remDay = 0, remHour = 0, remMin = 0;
            
            document.getElementById('checkForever').checked = false;
            document.getElementById('checkExpired').checked = false;

            if (!u.expiry) {
                document.getElementById('checkForever').checked = true;
            } else if (u.expiry < now) {
                document.getElementById('checkExpired').checked = true;
            } else {
                let diff = u.expiry - now;
                const MS_MIN = 60000;
                const MS_HOUR = 3600000;
                const MS_DAY = 86400000;
                const MS_MONTH = 2592000000; 
                const MS_YEAR = 31536000000; // 365天

                remYear = Math.floor(diff / MS_YEAR);
                diff %= MS_YEAR;
                remMonth = Math.floor(diff / MS_MONTH);
                diff %= MS_MONTH;
                remDay = Math.floor(diff / MS_DAY);
                diff %= MS_DAY;
                remHour = Math.floor(diff / MS_HOUR);
                diff %= MS_HOUR;
                remMin = Math.floor(diff / MS_MIN);
            }

            remYear = Math.min(Math.max(0, remYear), limits.year);
            remMonth = Math.min(Math.max(0, remMonth), limits.month);
            remDay = Math.min(Math.max(0, remDay), limits.day);
            remHour = Math.min(Math.max(0, remHour), limits.hour);
            remMin = Math.min(Math.max(0, remMin), limits.min);

            togglePicker();
            
            setTimeout(() => {
                setPickerVal('col-year', remYear);
                setPickerVal('col-month', remMonth);
                setPickerVal('col-day', remDay);
                setPickerVal('col-hour', remHour);
                setPickerVal('col-min', remMin);
            }, 50);
        }

        function closeModal() { document.getElementById('timeModal').style.display = 'none'; }

        function saveTime() {
            if (currentEditIdx === -1) return;
            
            const forever = document.getElementById('checkForever').checked;
            const expired = document.getElementById('checkExpired').checked;
            let newExpiry = null;

            if (expired) {
                newExpiry = Date.now() - 1000; 
            } else if (!forever) {
                const y = getPickerVal('col-year');
                const m = getPickerVal('col-month');
                const d = getPickerVal('col-day');
                const h = getPickerVal('col-hour');
                const min = getPickerVal('col-min');
                
                const now = Date.now();
                // 1年=365天, 1月=30天 (简化计算)
                const addMs = (y * 31536000000) +
                              (m * 2592000000) + 
                              (d * 86400000) + 
                              (h * 3600000) + 
                              (min * 60000);
                newExpiry = now + addMs;
            }
            
            updateUser(currentEditIdx, 'expiry', newExpiry);
            closeModal();
        }

        async function addUser() {
            await fetch(\`?action=manage_user&type=add&name=新用户&uuid=\${uuidv4()}&expiry=\${Date.now() + 30*24*3600*1000}\`);
            fetchUsers();
            showToast("用户已添加");
        }

        async function delUser(idx) {
            if (!confirm('确定删除?')) return;
            await fetch(\`?action=manage_user&type=del&uuid=\${users[idx].uuid}\`);
            fetchUsers();
        }

        async function updateUser(idx, key, val) {
            const u = users[idx];
            let url = \`?action=manage_user&type=update&uuid=\${u.uuid}\`;
            if (key === 'name') url += \`&name=\${encodeURIComponent(val)}\`;
            if (key === 'expiry') url += \`&expiry=\${val === null ? 'null' : val}\`;
            
            await fetch(url);
            fetchUsers();
            if (key === 'expiry') showToast("时间已更新");
        }

        function switchProto(p) {
            if(confirm('需要重启服务，确定切换?')) {
                fetch('?action=switch_proto&proto='+p);
                alert('正在重启...');
                setTimeout(()=>location.reload(), 3000);
            }
        }

        function initPickers() {
            initPickerCol('col-year', limits.year);
            initPickerCol('col-month', limits.month);
            initPickerCol('col-day', limits.day);
            initPickerCol('col-hour', limits.hour);
            initPickerCol('col-min', limits.min);
        }

        initPickers();
        fetchUsers();
    </script>
</body>
</html>
HTMLEOF

# 2. Server.js (逻辑部分)
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

let lastActiveFingerprint = '';

function getUsers() { try { const data = fs.readFileSync(usersFile, 'utf8'); return data ? JSON.parse(data) : []; } catch(e) { return []; } }
function saveUsers(users) { fs.writeFileSync(usersFile, JSON.stringify(users)); }

function updateConfigAndReload() {
    const users = getUsers();
    const now = Date.now();
    const activeUsers = users.filter(u => !u.expiry || u.expiry > now);
    const firstUserUUID = (activeUsers.length > 0) ? activeUsers[0].uuid : "00000000-0000-0000-0000-000000000000";
    
    lastActiveFingerprint = activeUsers.map(u => u.uuid).sort().join('|');

    const tuicUsers = activeUsers.map(u => ({ uuid: u.uuid, password: "admin" }));
    const hy2Users = activeUsers.map(u => ({ password: u.uuid }));
    const ssUsers = activeUsers.map(u => ({ password: u.uuid }));
    const vlessUsers = activeUsers.map(u => ({ uuid: u.uuid }));

    const inbounds = [];
    if (tuicPort > 0) inbounds.push({ type: "tuic", tag: "tuic-in", listen: "::", listen_port: tuicPort, users: tuicUsers, congestion_control: "bbr", tls: { enabled: true, alpn: ["h3"], certificate_path: certPath, key_path: keyPath } });
    if (hy2Port > 0) inbounds.push({ type: "hysteria2", tag: "hy2-in", listen: "::", listen_port: hy2Port, users: hy2Users, ignore_client_bandwidth: true, tls: { enabled: true, alpn: ["h3"], certificate_path: certPath, key_path: keyPath } });
    if (ssPort > 0) inbounds.push({ type: "shadowsocks", tag: "ss-in", listen: "::", listen_port: ssPort, method: "aes-256-gcm", password: firstUserUUID, users: ssUsers });
    inbounds.push({ type: "vless", tag: "vless-argo-in", listen: "127.0.0.1", listen_port: argoPort, users: vlessUsers, transport: { type: "ws", path: "/vless-argo" } });

    const config = { log: { level: "warn", timestamp: true }, inbounds: inbounds, outbounds: [{ type: "direct", tag: "direct" }] };
    
    fs.writeFileSync('${FILE_PATH}/config.json', JSON.stringify(config));
    if (sb_pid) { try { process.kill(sb_pid, 'SIGHUP'); console.log('[System] Config Reloaded'); } catch(e) {} }
}

setInterval(() => {
    const users = getUsers();
    const now = Date.now();
    const activeUsers = users.filter(u => !u.expiry || u.expiry > now);
    const currentFingerprint = activeUsers.map(u => u.uuid).sort().join('|');

    if (currentFingerprint !== lastActiveFingerprint) {
        console.log('[Auto-Expiry] 检测到用户过期，正在刷新节点配置...');
        updateConfigAndReload();
    }
}, 30000);

updateConfigAndReload();

function generateSub(uuid, argoDomain) {
    let content = '';
    const users = getUsers();
    const user = users.find(u => u.uuid === uuid);
    if (!user) return "Error: User not found";
    if (user.expiry && user.expiry < Date.now()) return "Error: Subscription Expired (您的订阅已过期)";

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

    if (isPanel && params.get('action') === 'manage_user') {
        const type = params.get('type');
        let users = getUsers();
        
        if (type === 'add') {
            const expiry = params.get('expiry') === 'null' ? null : parseInt(params.get('expiry'));
            users.push({ name: params.get('name'), uuid: params.get('uuid'), expiry: expiry });
        }
        else if (type === 'del') {
            users = users.filter(u => u.uuid !== params.get('uuid'));
        }
        else if (type === 'update') {
            const u = users.find(u => u.uuid === params.get('uuid'));
            if(u) {
                if(params.has('name')) u.name = params.get('name');
                if(params.has('expiry')) {
                    const e = params.get('expiry');
                    u.expiry = (e === 'null' || e === '') ? null : parseInt(e);
                }
            }
        }
        
        saveUsers(users);
        updateConfigAndReload(); 
        res.end('ok');
        return;
    }

    if (isPanel && params.get('action') === 'get_users') { 
        res.writeHead(200, {'Content-Type': 'application/json'}); 
        res.end(JSON.stringify(getUsers())); 
        return; 
    }
    
    if (isPanel && params.get('action') === 'switch_proto') {
        fs.writeFileSync(configFile, params.get('proto'));
        fs.writeFileSync('${FILE_PATH}/.restart_flag', 'true');
        if (sb_pid) try { process.kill(sb_pid, 'SIGTERM'); } catch(e) {}
        res.end('ok');
        return;
    }

    if (isPanel) { 
        res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'}); 
        try { res.end(fs.readFileSync('${FILE_PATH}/panel.html', 'utf8')); } catch(e) { res.end('Error'); } 
        return; 
    }

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
    log "[Argo] 启动隧道..."
    if [ -n "$ARGO_TOKEN" ]; then
         "$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate run --token "$ARGO_TOKEN" > "$ARGO_LOG" 2>&1 &
    else
         "$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://127.0.0.1:${ARGO_PORT} > "$ARGO_LOG" 2>&1 &
    fi
    ARGO_PID=$!
    
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
        log "♻️ 协议切换，正在重启..."
        rm -f "${FILE_PATH}/.restart_flag"
        sleep 1
        continue 
    else
        log "⚠️ 意外崩溃，5秒后重启..."
        sleep 5
    fi
done
