🚀 Sing-box 多协议多用户管理脚本 (v5.7)

这是一个基于 Sing-box 核心的高级代理服务脚本，集成了 Hysteria2 / TUIC / ShadowSocks / VLESS (Argo) 多种协议。

✨ v5.7 核心特性：热重载 (Seamless Hot Reload) 新增、删除用户或修改备注时，无需重启服务，连接不会中断。脚本通过 SIGHUP 信号通知核心重载配置，实现毫秒级生效。
🛠️ 功能特性

    多协议共存：

        UDP 主力：Hysteria2 或 TUIC (可一键切换)

        通用兼容：ShadowSocks (AES-256-GCM)

        CDN 救生圈：VLESS + WebSocket + Argo Tunnel (Cloudflare)

    Web 控制面板：

        可视化的用户管理界面。

        支持新增、删除用户，重置 UUID，修改备注。

        所有操作即时生效，无需手动重启。

        一键获取所有协议的订阅链接。

    自动化配置：

        自动申请/自签证书。

        自动下载 Sing-box 和 Cloudflared 核心。

        集成 Node.js 后端，无外部依赖。

⚙️ 快速配置 (start.sh)

在运行脚本之前，您可以修改 start.sh 顶部的配置区域：
变量名	说明	默认值/示例
DEFAULT_PROTOCOL	默认 UDP 协议 (首次启动生效)	"hy2" 或 "tuic"
MANUAL_SECOND_PORT	ShadowSocks 的监听端口	"25109"
CUSTOM_SUB_SECRET	控制面板路径密钥 (密码)	建议修改为复杂的随机字符串
ARGO_TOKEN	(可选) Cloudflare Tunnel Token	留空则使用临时随机隧道
🚀 启动方式
Bash

# 赋予执行权限
chmod +x start.sh

# 启动服务
./start.sh

🎮 控制面板使用指南

服务启动后，脚本会输出控制面板的访问地址。

访问地址格式： http://[你的公网IP]:[端口]/panel/[CUSTOM_SUB_SECRET]
1. 用户管理

    新增用户：点击右上角 + 新增用户，系统会自动生成 UUID，配置立即生效。

    修改备注：直接在表格中修改备注输入框，失去焦点自动保存。

    重置 UUID：点击 重置 按钮可更换用户的 UUID（旧连接将立即失效）。

    删除用户：点击 删除 按钮彻底移除用户。

2. 协议切换

    面板顶部提供了 切换 TUIC 和 切换 Hysteria2 的按钮。

    注意：切换主协议需要重启进程（脚本会自动处理），会造成短暂的连接断开（约 1-3 秒）。

🔗 包含的协议节点

每个用户都会获得以下 4 种节点的订阅链接：

    Hysteria2 / TUIC (取决于当前模式)：

        速度最快，基于 UDP。

        端口：脚本获取的第一个端口。

    ShadowSocks：

        兼容性好，AES-256-GCM 加密。

        端口：MANUAL_SECOND_PORT 设置的端口。

    VLESS (Argo)：

        基于 Cloudflare 隧道，无需公网 IP 也能连。

        救急专用，速度取决于 Cloudflare 线路状况。

免责声明：本脚本仅用于技术研究和服务器性能测试，请勿用于非法用途。
