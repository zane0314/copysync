# Web Clipboard

私人跨设备网页剪贴板 MVP。一个 Python 标准库服务，SQLite 存元数据，本地目录存文件。

## 本地运行

```sh
cd copy-example
export WEBCLIP_PASSWORD='change-me'
export WEBCLIP_SESSION_SECRET='change-me-too'
export WEBCLIP_COOKIE_SECURE=0
python3 app.py
```

打开 `http://127.0.0.1:15080`。

程序会自动读取当前目录的 `.env`；同名环境变量已存在时，以外部环境变量为准。

正式入口应放在 HTTPS 后面，并保持 `WEBCLIP_COOKIE_SECURE=1`。

首次启动时 `WEBCLIP_PASSWORD` 会被写入 SQLite 为 PBKDF2-SHA256 哈希。后续可在网页里修改密码；修改后其他已登录设备会自动失效。

## VPS 配置

建议：

- `copy.example.com`：DNS Only，指向 VPS，反代 `/go` 或同一个服务。
- `copy-direct.example.com`：DNS Only，指向 VPS。
- `copy-cf.example.com`：Cloudflare 代理，指向同一个 VPS 后端。
- 两个业务入口使用各自的 Host-only Cookie，避免会话 Cookie 泄漏给其他 `example.com` 子域名。
- `WEBCLIP_GO_ONLY_HOSTS=copy.example.com` 会让总入口根路径直接显示线路选择页。
- 三个入口共用同一个后端进程、SQLite 和文件目录，内容列表完全一致。
- Cloudflare 入口不要缓存动态内容；应用和 nginx 都返回 `Cache-Control: no-store`。
- 应用默认只监听 `127.0.0.1`，公网只暴露 nginx 的 80/443。
- 单文件默认 100MB，单次请求总上传默认 110MB。

Cloudflare 面板建议：

- `copy.example.com`：灰云 DNS Only。
- `copy-direct.example.com`：灰云 DNS Only。
- `copy-cf.example.com`：橙云 Proxied。
- SSL/TLS 使用 Full strict，源站证书必须有效。
- Cache Rules 对 `copy-cf.example.com/*` 设置 Bypass cache。
- 100MB 上传要在 `copy-cf` 实测；如果 Cloudflare 侧失败，使用 `copy-direct` 直连上传。

Nginx 反代核心配置：

```nginx
client_max_body_size 110m;

location / {
    proxy_pass http://127.0.0.1:15080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

完整 nginx 模板在 `deploy/nginx-web-clipboard.conf`。

systemd 服务核心参数：

```ini
[Service]
WorkingDirectory=/opt/copy-example
EnvironmentFile=/opt/copy-example/.env
ExecStart=/usr/bin/python3 /opt/copy-example/app.py
Restart=always
User=webclip
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/copy-example/data
```

定时清理可以用 cron 或 systemd timer 调这个命令：

```sh
cd /opt/copy-example
WEBCLIP_DATA_DIR=/opt/copy-example/data WEBCLIP_SESSION_SECRET='same-secret' python3 app.py --cleanup
```

清理会删除过期临时内容、超过 1 小时的 `.part` 文件、数据库里已丢失文件的记录，并清掉孤立文件。

## 已实现

- 强密码登录，30 天会话。
- 密码以 PBKDF2-SHA256 哈希存储在 SQLite。
- 修改密码会清除旧会话。
- 文本保存。
- 多文件上传，单文件默认 100MB。
- 单次上传请求默认最多 110MB。
- 内容列表、复制文本、下载文件、删除。
- 图片预览。
- 拖拽上传。
- 搜索内容名称和文本。
- 按全部、文本、文件、图片、已钉住筛选。
- 未钉住内容可一键延长 24 小时。
- 默认 4 小时过期。
- 图钉后不过期，取消图钉后重新按 4 小时计时。
- 清空临时内容会保留图钉。
- 彻底清空全部会删除图钉。
- 删除已钉住项目会二次确认。
- 支持独立清理命令：`python3 app.py --cleanup`。
- 钉住容量上限 5GB，临时容量上限 2GB，磁盘 80% 停止上传。
- `/go` 入口页检测 `copy-direct` 和 `copy-cf` 后让用户手动选择。
- `/probe` 提供跨域线路检测，入口页每条线路最多测 3 次、2 秒超时、取中位数。
- 安全响应头：`nosniff`、`DENY frame`、`same-origin referrer`、基础 CSP。
- SVG 不内联预览，HTML/SVG 等文件默认附件下载。
- nginx 模板含 HTTPS 跳转、HSTS、登录限速、API 基础限速。

## 暂不做

注册、找回密码、多用户权限、对象存储、网盘、分片上传、断点续传、永久历史。
