# singbox-nodejs-panel

一键启动脚本，集成 Web 控制面板、双端口多协议与 Argo 隧道。

**双端口模式 (推荐):**
* **主端口 (Port 1):** Hysteria2 / TUIC (可在面板一键切换) + HTTP 订阅服务 + Web 控制面板
* **副端口 (Port 2):** Shadowsocks (TCP+UDP)
* **备用链路:** Cloudflare Argo 隧道 (自动启用，防止断联)

**单端口模式:**
* 若只检测到一个端口，将启用 Hy2/TUIC + Argo + 面板 (Shadowsocks 自动禁用)

**访问地址:**
* **订阅链接:** `http://IP:主端口/密钥`
* **控制面板:** `http://IP:主端口/panel/密钥`

**脚本特性:**
* 支持 Web 页面远程重启 (无需登录服务器后台)
* 支持在线切换 Hysteria2 / TUIC 协议
* 每次重启自动轮换 UUID (也可在脚本中固定)
* Argo 隧道智能兜底，直连挂了走隧道

**配置说明:**
修改脚本顶部的 `MANUAL_SECOND_PORT` 变量即可启用双端口模式。
