#!/bin/bash
# ================== 配置区域 ==================

# [配置] 默认协议
DEFAULT_PROTOCOL="hy2"

# [配置] ShadowSocks 端口
MANUAL_SECOND_PORT="24890"

# [配置] 控制面板密钥 
CUSTOM_SUB_SECRET="hello"

# [默认] Argo Token (初始值,后续由面板控制)
ARGO_TOKEN=""

# ================== 核心循环逻辑 ==================

CONFIG_FILE="saved_config.txt"
USERS_FILE="users.json"
ARGO_CONFIG_FILE="argo_config.json"

log() {
    echo -e "\033[36m[$(date '+%Y-%m-%d %H:%M:%S')]\033[0m $1"
}

# [系统] 进程清理
cleanup() {
    log "[系统] 正在清理进程..."
    [ -n "$SB_PID" ] && kill -9 "$SB_PID" 2>/dev/null
    [ -n "$HTTP_PID" ] && kill -9 "$HTTP_PID" 2>/dev/null
    [ -n "$ARGO_PID" ] && kill -9 "$ARGO_PID" 2>/dev/null
    
    PIDS=$(ps -ef 2>/dev/null | grep "${FILE_PATH}/sb" | grep -v grep | awk '{print $2}' 2>/dev/null)
    if [ -z "$PIDS" ]; then
        PIDS=$(ps 2>/dev/null | grep "${FILE_PATH}/sb" | grep -v grep | awk '{print $1}' 2>/dev/null)
    fi
    for pid in $PIDS; do if [ "$pid" != "$$" ]; then kill -9 "$pid" 2>/dev/null; fi; done
    rm -f "$FILE_PATH/.restart_flag"
}

trap "cleanup; exit 0" SIGTERM SIGINT

while true; do
    echo ""
    echo "==================================================="
    echo "   🚀 正在启动服务 (v8.3 Latency MS)"
    echo "==================================================="
    echo ""

    # ================== 准备工作 ==================
    CF_DOMAINS=(  
        "cdn.2020111.xyz"  
        "cloudflare.czkcdn.cn"  
        "cloudflare.182682.xyz"  
        "cdn.9889888.xyz"  
        "cf.cdn.saas.fis.ink"  
        "cfyx.tencentapp.cn"  
        "www.cnae.top"  
        "cf.090227.xyz"  
        "cf.877774.xyz"  
        "cf.130519.xyz"  
        "cf.008500.xyz"  
        "saas.sin.fan"  
    )
    
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

    # 初始化 Argo 配置文件
    if [ ! -f "$ARGO_CONFIG_FILE" ]; then
        if [ -n "$ARGO_TOKEN" ]; then
            echo "{\"mode\":\"fixed\",\"token\":\"$ARGO_TOKEN\",\"domain\":\"\"}" > "$ARGO_CONFIG_FILE"
        else
            echo "{\"mode\":\"random\",\"token\":\"\",\"domain\":\"\"}" > "$ARGO_CONFIG_FILE"
        fi
    fi

    if [ -f "$CONFIG_FILE" ]; then PORT1_PROTOCOL=$(cat "$CONFIG_FILE"); else PORT1_PROTOCOL="$DEFAULT_PROTOCOL"; echo "$PORT1_PROTOCOL" > "$CONFIG_FILE"; fi

    log "[网络] 正在获取公网 IP..."
    PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb || curl -s --max-time 5 api.ipify.org || echo "")
    if [ -z "$PUBLIC_IP" ]; then log "[错误] 无法获取 IP,5秒后重试..."; sleep 5; continue; fi
    log "[网络] 公网 IP: $PUBLIC_IP"

    # [核心升级] 5次平均测速 + 毫秒级 Top 3 输出
    select_best_cf_domain() {
        local res_file="${FILE_PATH}/cf_latency.res"
        : > "$res_file"
        
        # 并发测试所有域名
        for domain in "${CF_DOMAINS[@]}"; do
            (
                total_time=0
                success_count=0
                
                # [修改] 连续测速 5 次
                for i in {1..5}; do
                    # connect-timeout 1.2s
                    t=$(curl -s -w "%{time_connect}" -o /dev/null --connect-timeout 1.2 "https://$domain" 2>/dev/null)
                    
                    if [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$t" != "0.000000" ]; then
                        total_time=$(awk "BEGIN {print $total_time + $t}")
                        success_count=$((success_count + 1))
                    fi
                    
                    # 间隔 0.5 秒
                    sleep 0.5
                done
                
                # 至少成功1次才计算
                if [ "$success_count" -gt 0 ]; then
                    avg_time=$(awk "BEGIN {print $total_time / $success_count}")
                    echo "$avg_time $domain" >> "$res_file"
                fi
            ) &
        done
        wait
        
        # [修改] 输出 Top 3 到 stderr，格式转换为 ms
        if [ -s "$res_file" ]; then
            echo -e "\n🏆 优选测速 Top 3 (平均延迟):" >&2
            # 使用 awk 将秒转换为毫秒并格式化输出
            sort -n "$res_file" | head -n 3 | awk '{printf "   [%s----%.2fms]\n", $2, $1*1000}' >&2
            echo "" >&2
        fi
        
        # 排序取第一名返回给变量
        local best=$(sort -n "$res_file" 2>/dev/null | head -n 1 | awk '{print $2}')
        rm -f "$res_file"
        
        if [ -n "$best" ]; then echo "$best"; else echo "${CF_DOMAINS[0]}"; fi
    }
    
    log "[网络] 正在进行高精度测速 (Sample: 5x, Interval: 0.5s)..."
    BEST_CF_DOMAIN=$(select_best_cf_domain)
    log "[网络] 最终选择: $BEST_CF_DOMAIN"

    # 端口处理
    [ -n "$SERVER_PORT" ] && PORTS_STRING="$SERVER_PORT" || PORTS_STRING=""
    if [ -n "$MANUAL_SECOND_PORT" ]; then if [ -n "$PORTS_STRING" ]; then PORTS_STRING="$PORTS_STRING $MANUAL_SECOND_PORT"; else PORTS_STRING="$MANUAL_SECOND_PORT"; fi; fi
    read -ra AVAILABLE_PORTS <<< "$PORTS_STRING"
    PORT_COUNT=${#AVAILABLE_PORTS[@]}

    if [ $PORT_COUNT -eq 0 ]; then log "[错误] 未找到端口,重试..."; sleep 5; continue; fi

    PRIMARY_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[0]}

    if [ "$PORT1_PROTOCOL" == "tuic" ]; then TUIC_PORT=$PRIMARY_PORT; HY2_PORT=""; PROTOCOL_NAME="TUIC"; else HY2_PORT=$PRIMARY_PORT; TUIC_PORT=""; PROTOCOL_NAME="Hysteria2"; fi
    if [ $PORT_COUNT -eq 1 ]; then SS_PORT=""; else SS_PORT=${AVAILABLE_PORTS[1]}; fi
    ARGO_PORT=8081

    if [ -n "$CUSTOM_SUB_SECRET" ]; then PANEL_KEY="$CUSTOM_SUB_SECRET"; else PANEL_KEY="admin"; fi
    PANEL_URL="http://${PUBLIC_IP}:${HTTP_PORT}/panel/${PANEL_KEY}"

    # 下载核心（使用官方 Releases）
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        SB_ARCH="arm64"
        ARGO_ARCH="arm64"
    else
        SB_ARCH="amd64"
        ARGO_ARCH="amd64"
    fi

    SB_FILE="${FILE_PATH}/sb"
    ARGO_FILE="${FILE_PATH}/cloudflared"

    download_file() {
        if [ ! -x "$2" ]; then
            curl -L -sS --max-time 60 -o "$2" "$1" && chmod +x "$2"
        fi
    }

    download_singbox() {
        # 已存在就不重复下
        [ -x "$SB_FILE" ] && return 0

        # 通过 releases/latest 重定向拿到最新版本号（例如 1.12.22）
        latest_url=$(curl -Ls -o /dev/null -w "%{url_effective}" "https://github.com/SagerNet/sing-box/releases/latest")
        ver="${latest_url##*/v}"

        tgz="${FILE_PATH}/sing-box.tgz"
        dir="${FILE_PATH}/sing-box-${ver}-linux-${SB_ARCH}"

        curl -L -sS --max-time 180 -o "$tgz"           "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz" || return 1

        tar -xzf "$tgz" -C "$FILE_PATH" || return 1

        mv "${dir}/sing-box" "$SB_FILE" || return 1
        chmod +x "$SB_FILE"

        # 可选：若解压包里带 libcronet.so，就放到同目录，避免某些功能缺库
        if [ -f "${dir}/libcronet.so" ]; then
            mv "${dir}/libcronet.so" "${FILE_PATH}/libcronet.so"
        fi

        rm -f "$tgz"
        return 0
    }

    download_singbox || { log "[错误] sing-box 下载/解压失败"; sleep 5; continue; }

    # cloudflared 仍用官方 latest
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

# 1. HTML 前端
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
        input[type="text"]:disabled { background: #1a1a1a; color: #555; cursor: not-allowed; }

        .user-grid { display: grid; grid-template-columns: 1.5fr 2.5fr 2.5fr 1.5fr 0.8fr 2fr; gap: 10px; align-items: center; padding: 12px 0; border-bottom: 1px solid #2d2d2d; }
        .user-grid.header-row { font-size: 12px; color: var(--text-gray); text-transform: uppercase; border-bottom: 1px solid var(--border); padding-bottom: 8px; font-weight: bold; }
        
        .status-badge { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; padding: 2px 8px; border-radius: 4px; background: rgba(34, 197, 94, 0.1); color: var(--success); white-space: nowrap; }
        .status-badge.expired { background: rgba(239, 68, 68, 0.1); color: var(--danger); }
        
        .uuid-box { font-family: monospace; font-size: 11px; background: #000; padding: 6px; border-radius: 4px; color: #a5f3fc; opacity: 0.9; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .time-box { font-size: 12px; color: #ccc; margin-top: 3px; font-family: monospace; }
        
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); display: none; justify-content: center; align-items: center; z-index: 1000; backdrop-filter: blur(2px); }
        .modal { background: #252525; border-radius: 16px; width: 90%; max-width: 440px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.5); border: 1px solid var(--border); overflow: hidden; animation: popIn 0.3s ease-out; }
        @keyframes popIn { from { transform: scale(0.95); opacity: 0; } to { transform: scale(1); opacity: 1; } }
        .modal-header { padding: 15px 20px; background: #2d2d2d; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); }
        .modal-body { padding: 20px; }
        .modal-footer { padding: 15px 20px; display: flex; justify-content: flex-end; gap: 10px; background: #2d2d2d; border-top: 1px solid var(--border); }

        .picker-wrapper { display: flex; justify-content: center; height: 180px; position: relative; margin: 10px 0; background: #1a1a1a; border-radius: 8px; overflow: hidden; gap: 2px; }
        .picker-mask-top { position: absolute; top:0; left:0; width:100%; height:60px; background: linear-gradient(to bottom, rgba(26,26,26,0.95), rgba(26,26,26,0.5)); z-index: 10; pointer-events: none;}
        .picker-mask-bottom { position: absolute; bottom:0; left:0; width:100%; height:60px; background: linear-gradient(to top, rgba(26,26,26,0.95), rgba(26,26,26,0.5)); z-index: 10; pointer-events: none;}
        .picker-highlight { position: absolute; top: 70px; left: 0; right: 0; height: 40px; background: rgba(59, 130, 246, 0.15); border-top: 1px solid var(--primary); border-bottom: 1px solid var(--primary); pointer-events: none; z-index: 5; }
        .picker-col-container { flex: 1; max-width: 60px; display: flex; flex-direction: column; align-items: center; z-index: 20; position: relative; }
        .picker-btn-up, .picker-btn-down { width: 100%; height: 26px; display: flex; justify-content: center; align-items: center; cursor: pointer; color: #777; background: #222; z-index: 30; user-select: none; transition: 0.1s; }
        .picker-btn-up:hover, .picker-btn-down:hover { background: #333; color: #fff; }
        .picker-btn-up svg, .picker-btn-down svg { width: 14px; height: 14px; fill: currentColor; }
        .picker-col { width: 100%; height: 128px; overflow-y: scroll; scroll-snap-type: y mandatory; scrollbar-width: none; text-align: center; position: relative; cursor: grab; user-select: none; scroll-behavior: smooth; }
        .picker-col.is-dragging { scroll-behavior: auto; cursor: grabbing; scroll-snap-type: none; } 
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
        <!-- 顶部系统状态 -->
        <div class="card">
            <h2>🖥️ 系统状态 <span style="font-size:12px; font-weight:normal; color:#666;">v8.3</span></h2>
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

        <!-- Argo 配置卡片 -->
        <div class="card">
            <h2>☁️ Argo 隧道配置</h2>
            <div class="options-row" style="justify-content: flex-start; gap: 20px;">
                <label class="checkbox-label"><input type="radio" name="argoMode" value="random" onchange="toggleArgoInputs()"> 随机域名 (免费)</label>
                <label class="checkbox-label"><input type="radio" name="argoMode" value="fixed" onchange="toggleArgoInputs()"> 固定域名 (需Token)</label>
            </div>
            <div style="margin-top:15px; display:grid; gap:10px;">
                <input type="text" id="argoToken" placeholder="Argo Token (eyAh......)" disabled>
                <input type="text" id="argoDomain" placeholder="固定域名 (例: sub.example.com)" disabled>
            </div>
            <button class="btn btn-primary" style="margin-top:15px; width:100%" onclick="saveArgoConfig()">保存并重启服务</button>
            <div style="font-size:12px; color:#666; margin-top:10px;">* 切换模式或修改配置后,服务将自动重启以生效。</div>
        </div>

        <!-- 用户管理卡片 -->
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

    <!-- 时间选择模态框 -->
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
                    <div style="flex:1; max-width:60px;"><div class="col-label">年</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">月</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">日</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">时</div></div>
                    <div style="flex:1; max-width:60px;"><div class="col-label">分</div></div>
                </div>
                
                <div class="picker-wrapper" id="pickerContainer">
                    <div class="picker-mask-top"></div><div class="picker-mask-bottom"></div><div class="picker-highlight"></div>
                    <svg style="display:none;"><symbol id="icon-minus" viewBox="0 0 24 24"><path d="M19 13H5v-2h14v2z"/></symbol><symbol id="icon-plus" viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></symbol></svg>
                    <div class="picker-col-container"><div class="picker-btn-up" onclick="adjustPicker('col-year', -1)"><svg><use href="#icon-minus"></use></svg></div><div class="picker-col" id="col-year"><ul></ul></div><div class="picker-btn-down" onclick="adjustPicker('col-year', 1)"><svg><use href="#icon-plus"></use></svg></div></div>
                    <div class="picker-col-container"><div class="picker-btn-up" onclick="adjustPicker('col-month', -1)"><svg><use href="#icon-minus"></use></svg></div><div class="picker-col" id="col-month"><ul></ul></div><div class="picker-btn-down" onclick="adjustPicker('col-month', 1)"><svg><use href="#icon-plus"></use></svg></div></div>
                    <div class="picker-col-container"><div class="picker-btn-up" onclick="adjustPicker('col-day', -1)"><svg><use href="#icon-minus"></use></svg></div><div class="picker-col" id="col-day"><ul></ul></div><div class="picker-btn-down" onclick="adjustPicker('col-day', 1)"><svg><use href="#icon-plus"></use></svg></div></div>
                    <div class="picker-col-container"><div class="picker-btn-up" onclick="adjustPicker('col-hour', -1)"><svg><use href="#icon-minus"></use></svg></div><div class="picker-col" id="col-hour"><ul></ul></div><div class="picker-btn-down" onclick="adjustPicker('col-hour', 1)"><svg><use href="#icon-plus"></use></svg></div></div>
                    <div class="picker-col-container"><div class="picker-btn-up" onclick="adjustPicker('col-min', -1)"><svg><use href="#icon-minus"></use></svg></div><div class="picker-col" id="col-min"><ul></ul></div><div class="picker-btn-down" onclick="adjustPicker('col-min', 1)"><svg><use href="#icon-plus"></use></svg></div></div>
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
        const limits = { year: 10, month: 12, day: 30, hour: 60, min: 60 };

        function uuidv4() { return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8); return v.toString(16); }); }
        function showToast(msg) { const t = document.getElementById('toast'); t.innerHTML = '<span>✔</span> ' + (msg || '操作成功'); t.classList.add('show'); setTimeout(() => t.classList.remove('show'), 2000); }
        function pad(num) { return num.toString().padStart(2, '0'); }

        async function fetchUsers() {
            const res = await fetch('?action=get_users');
            users = await res.json();
            render();
        }

        async function fetchArgoConfig() {
            try {
                const res = await fetch('?action=get_argo');
                const config = await res.json();
                
                if (config.mode === 'fixed') {
                    document.querySelector('input[name="argoMode"][value="fixed"]').checked = true;
                } else {
                    document.querySelector('input[name="argoMode"][value="random"]').checked = true;
                }
                
                document.getElementById('argoToken').value = config.token || '';
                document.getElementById('argoDomain').value = config.domain || '';
                toggleArgoInputs();
            } catch(e) { console.error("Load Argo config failed", e); }
        }

        function toggleArgoInputs() {
            const isFixed = document.querySelector('input[name="argoMode"][value="fixed"]').checked;
            document.getElementById('argoToken').disabled = !isFixed;
            document.getElementById('argoDomain').disabled = !isFixed;
            
            if(!isFixed) {
                document.getElementById('argoToken').style.opacity = '0.5';
                document.getElementById('argoDomain').style.opacity = '0.5';
            } else {
                document.getElementById('argoToken').style.opacity = '1';
                document.getElementById('argoDomain').style.opacity = '1';
            }
        }

        async function saveArgoConfig() {
            const mode = document.querySelector('input[name="argoMode"]:checked').value;
            const token = document.getElementById('argoToken').value.trim();
            const domain = document.getElementById('argoDomain').value.trim();

            if (mode === 'fixed' && !token) { alert('请填写 Argo Token'); return; }

            if(confirm('保存配置将重启服务,是否继续?')) {
                await fetch('?action=save_argo&mode='+mode+'&token='+encodeURIComponent(token)+'&domain='+encodeURIComponent(domain));
                alert('正在重启...');
                setTimeout(()=>location.reload(), 3000);
            }
        }

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
            const years = Math.floor(diff / (1000 * 60 * 60 * 24 * 365)); diff -= years * 31536000000;
            const days = Math.floor(diff / (1000 * 60 * 60 * 24)); diff -= days * 86400000;
            const hours = Math.floor(diff / (1000 * 60 * 60)); diff -= hours * 3600000;
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
                    <div>\${!isExpired ? \`<a href="/sub/\${u.uuid}" target="_blank" class="btn btn-primary" style="padding:2px 8px; font-size:11px; text-decoration:none;">订阅</a>\` : '<span style="font-size:11px; color:#666">--</span>'}</div>
                    <div style="text-align:right; display:flex; gap:5px; justify-content:flex-end;">
                        <button class="btn btn-primary" style="padding:4px 8px; font-size:11px;" onclick="openTimeModal(\${idx})">时间</button>
                        <button class="btn btn-danger" style="padding:4px 8px; font-size:11px;" onclick="delUser(\${idx})">删</button>
                    </div>\`;
                container.appendChild(row);
            });
        }

        /* 滚动选择器逻辑 */
        function initPickerCol(id, max) {
            const ul = document.querySelector('#' + id + ' ul'); ul.innerHTML = '';
            for(let i=0; i<=max; i++) { const li = document.createElement('li'); li.innerText = pad(i); ul.appendChild(li); }
            enableDrag(document.getElementById(id));
        }
        function enableDrag(ele) {
            let isDown = false, startY, scrollTop;
            ele.addEventListener('mousedown', (e) => { isDown = true; ele.classList.add('is-dragging'); startY = e.pageY - ele.offsetTop; scrollTop = ele.scrollTop; });
            const stop = () => { if(!isDown) return; isDown = false; ele.classList.remove('is-dragging'); snap(ele); };
            ele.addEventListener('mouseleave', stop); ele.addEventListener('mouseup', stop);
            ele.addEventListener('mousemove', (e) => { if (!isDown) return; e.preventDefault(); const y = e.pageY - ele.offsetTop; ele.scrollTop = scrollTop - (y - startY); });
            let t; ele.addEventListener('scroll', () => { if(isDown) return; clearTimeout(t); t = setTimeout(() => snap(ele), 100); });
        }
        function snap(ele) { const h = 40; ele.scrollTo({ top: Math.round(ele.scrollTop / h) * h, behavior: 'smooth' }); }
        function adjustPicker(id, dir) { const ele = document.getElementById(id), h = 40; const n = Math.round(ele.scrollTop / h) + dir; if (n >= 0) ele.scrollTo({ top: n * h, behavior: 'smooth' }); }
        function getPickerVal(id) { return Math.round(document.getElementById(id).scrollTop / 40); }
        function setPickerVal(id, val) { document.getElementById(id).scrollTop = val * 40; }
        function togglePicker() {
            const dis = document.getElementById('checkForever').checked || document.getElementById('checkExpired').checked;
            document.getElementById('pickerContainer').style.opacity = dis ? '0.3' : '1';
            document.getElementById('pickerContainer').style.pointerEvents = dis ? 'none' : 'auto';
            if(document.getElementById('checkForever').checked && document.getElementById('checkExpired').checked) document.getElementById('checkExpired').checked = false; 
        }

        function openTimeModal(idx) {
            currentEditIdx = idx; const u = users[idx];
            document.getElementById('targetUserDisplay').innerText = u.name;
            document.getElementById('timeModal').style.display = 'flex';
            document.getElementById('checkForever').checked = !u.expiry;
            document.getElementById('checkExpired').checked = u.expiry && u.expiry < Date.now();
            let y=0,m=0,d=0,h=0,min=0;
            if(u.expiry && u.expiry > Date.now()) {
                let diff = u.expiry - Date.now();
                y = Math.floor(diff/31536000000); diff%=31536000000;
                m = Math.floor(diff/2592000000); diff%=2592000000;
                d = Math.floor(diff/86400000); diff%=86400000;
                h = Math.floor(diff/3600000); diff%=3600000;
                min = Math.floor(diff/60000);
            }
            togglePicker();
            setTimeout(() => { setPickerVal('col-year',Math.min(y,10)); setPickerVal('col-month',Math.min(m,12)); setPickerVal('col-day',Math.min(d,30)); setPickerVal('col-hour',Math.min(h,60)); setPickerVal('col-min',Math.min(min,60)); }, 50);
        }
        function closeModal() { document.getElementById('timeModal').style.display = 'none'; }
        function saveTime() {
            if (currentEditIdx === -1) return;
            const forever = document.getElementById('checkForever').checked;
            const expired = document.getElementById('checkExpired').checked;
            let newExpiry = null;
            if (expired) newExpiry = Date.now() - 1000;
            else if (!forever) {
                newExpiry = Date.now() + (getPickerVal('col-year')*31536000000) + (getPickerVal('col-month')*2592000000) + (getPickerVal('col-day')*86400000) + (getPickerVal('col-hour')*3600000) + (getPickerVal('col-min')*60000);
            }
            updateUser(currentEditIdx, 'expiry', newExpiry);
            closeModal();
        }

        async function addUser() { await fetch(\`?action=manage_user&type=add&name=新用户&uuid=\${uuidv4()}&expiry=\${Date.now() + 2592000000}\`); fetchUsers(); showToast("用户已添加"); }
        async function delUser(idx) { if (!confirm('确定删除?')) return; await fetch(\`?action=manage_user&type=del&uuid=\${users[idx].uuid}\`); fetchUsers(); }
        async function updateUser(idx, key, val) {
            let url = \`?action=manage_user&type=update&uuid=\${users[idx].uuid}\`;
            if (key === 'name') url += \`&name=\${encodeURIComponent(val)}\`;
            if (key === 'expiry') url += \`&expiry=\${val === null ? 'null' : val}\`;
            await fetch(url); fetchUsers(); if(key === 'expiry') showToast("时间已更新");
        }
        function switchProto(p) { if(confirm('需要重启服务,确定切换?')) { fetch('?action=switch_proto&proto='+p); alert('正在重启...'); setTimeout(()=>location.reload(), 3000); } }

        initPickerCol('col-year', 10); initPickerCol('col-month', 12); initPickerCol('col-day', 30); initPickerCol('col-hour', 60); initPickerCol('col-min', 60);
        fetchUsers();
        fetchArgoConfig();
    </script>
</body>
</html>
HTMLEOF

# 2. Server.js (后端逻辑: 生成订阅)
cat > "${FILE_PATH}/server.js" <<JSEOF
const http = require('http');
const fs = require('fs');
const port = process.argv[2] || 8080;
const bind = process.argv[3] || '0.0.0.0';
const sb_pid = process.argv[4];
const configFile = '${CONFIG_FILE}';
const usersFile = '${USERS_FILE}';
const argoConfigFile = '${ARGO_CONFIG_FILE}';
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

function getArgoConfig() { try { const data = fs.readFileSync(argoConfigFile, 'utf8'); return data ? JSON.parse(data) : {mode:'random'}; } catch(e) { return {mode:'random'}; } }

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
    if (currentFingerprint !== lastActiveFingerprint) updateConfigAndReload();
}, 30000);
updateConfigAndReload();

function generateSub(uuid) {
    let content = '';
    const users = getUsers();
    const user = users.find(u => u.uuid === uuid);
    if (!user) return "Error: User not found";
    if (user.expiry && user.expiry < Date.now()) return "Error: Subscription Expired (您的订阅已过期)";

    // 获取 Argo 域名
    let argoDomain = '';
    const argoConfig = getArgoConfig();
    if (argoConfig.mode === 'fixed' && argoConfig.domain) {
        argoDomain = argoConfig.domain;
    } else {
        try { const log = fs.readFileSync('${FILE_PATH}/argo.log', 'utf8'); const match = log.match(/https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com/); if (match) argoDomain = match[0].replace('https://', ''); } catch(e) {}
    }

    const remarks = user.name;
    if (tuicPort) content += \`tuic://\${uuid}:admin@\${publicIp}:\${tuicPort}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-\${encodeURIComponent(remarks)}\\n\`;
    if (hy2Port) content += \`hysteria2://\${uuid}@\${publicIp}:\${hy2Port}/?sni=www.bing.com&insecure=1#Hy2-\${encodeURIComponent(remarks)}\\n\`;
    if (ssPort) { let ssBase64 = Buffer.from(\`aes-256-gcm:\${uuid}\`).toString('base64'); content += \`ss://\${ssBase64}@\${publicIp}:\${ssPort}#SS-\${encodeURIComponent(remarks)}\\n\`; }
    
    // [强制优选] 使用 bestCf 进行物理连接，argoDomain 仅用于 Host/SNI
    if (argoDomain) {
        content += \`vless://\${uuid}@\${bestCf}:443?encryption=none&security=tls&sni=\${argoDomain}&type=ws&host=\${argoDomain}&path=%2Fvless-argo#Argo-\${encodeURIComponent(remarks)}\\n\`;
    }
    return content;
}

http.createServer((req, res) => {
    const isPanel = req.url.startsWith('/panel/${PANEL_KEY}');
    const isSub = req.url.startsWith('/sub/');
    const url = new URL(req.url, 'http://localhost');
    const params = url.searchParams;

    if (isPanel) {
        if (params.get('action') === 'manage_user') {
            const type = params.get('type');
            let users = getUsers();
            if (type === 'add') users.push({ name: params.get('name'), uuid: params.get('uuid'), expiry: params.get('expiry') === 'null' ? null : parseInt(params.get('expiry')) });
            else if (type === 'del') users = users.filter(u => u.uuid !== params.get('uuid'));
            else if (type === 'update') {
                const u = users.find(u => u.uuid === params.get('uuid'));
                if(u) {
                    if(params.has('name')) u.name = params.get('name');
                    if(params.has('expiry')) u.expiry = (params.get('expiry') === 'null' || params.get('expiry') === '') ? null : parseInt(params.get('expiry'));
                }
            }
            saveUsers(users); updateConfigAndReload(); res.end('ok'); return;
        }
        if (params.get('action') === 'get_users') { res.writeHead(200, {'Content-Type': 'application/json'}); res.end(JSON.stringify(getUsers())); return; }
        
        if (params.get('action') === 'get_argo') { res.writeHead(200, {'Content-Type': 'application/json'}); res.end(JSON.stringify(getArgoConfig())); return; }
        if (params.get('action') === 'save_argo') {
            const newConfig = { mode: params.get('mode'), token: params.get('token'), domain: params.get('domain') };
            fs.writeFileSync(argoConfigFile, JSON.stringify(newConfig));
            fs.writeFileSync('${FILE_PATH}/.restart_flag', 'true');
            if (sb_pid) try { process.kill(sb_pid, 'SIGTERM'); } catch(e) {}
            res.end('ok'); return;
        }

        if (params.get('action') === 'switch_proto') {
            fs.writeFileSync(configFile, params.get('proto'));
            fs.writeFileSync('${FILE_PATH}/.restart_flag', 'true');
            if (sb_pid) try { process.kill(sb_pid, 'SIGTERM'); } catch(e) {}
            res.end('ok'); return;
        }

        res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'}); 
        try { res.end(fs.readFileSync('${FILE_PATH}/panel.html', 'utf8')); } catch(e) { res.end('Error'); } 
        return; 
    }

    if (isSub) {
        const uuid = req.url.split('/sub/')[1];
        const userExists = getUsers().some(u => u.uuid === uuid);
        if (userExists) {
            res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
            res.end(generateSub(uuid));
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
    if [ -f "$ARGO_CONFIG_FILE" ]; then
        eval $(node -e "try { const c = require('${PWD}/${ARGO_CONFIG_FILE}'); console.log('RUN_MODE='+c.mode); console.log('RUN_TOKEN='+c.token); } catch(e) {}")
    fi

    log "[Argo] 正在启动隧道 (模式: ${RUN_MODE:-random})..."
    
    if [ "$RUN_MODE" == "fixed" ] && [ -n "$RUN_TOKEN" ]; then
        "$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate run --token "$RUN_TOKEN" > "$ARGO_LOG" 2>&1 &
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
        log "♻️ 配置变更,正在重启服务..."
        rm -f "${FILE_PATH}/.restart_flag"
        sleep 1
        continue 
    else
        log "⚠️ 意外崩溃,5秒后重启..."
        sleep 5
    fi
done
