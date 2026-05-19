## ADDED Requirements

### Requirement: 云端 admin web SPA 部署形态（v1.0 IP-direct + nginx）

iSales cloud-side SHALL 部署 `isales-web` Vue 3 SPA 作为统一 admin / boss
console 入口；nginx 作为 SPA 静态服务 + `isales-api` HTTP / WebSocket
反向代理。本 Requirement 与既有 "v1.0 IP-direct" 部署形态并列，**不**改动
isales-api / isales-engine / 其它后端服务的 bind / 监听 / 协议；nginx
仅充当透明 reverse proxy + 静态文件 server。

本 Requirement 反转 `deploy/cloud/STATE.md` 2026-05-17 起的 "nginx deferred"
注脚——nginx 在 v1.0 IP-direct 形态下**作为必装组件**部署。

#### Scenario: nginx 1.x 安装 + listen 80

- **WHEN** cloud-side 首次部署或常规发版
- **THEN** ECS SHALL 装 nginx 1.20+（Aliyun Cloud Linux 3 默认仓库 `dnf
  install nginx`），systemctl enable 常驻
- **THEN** nginx SHALL `listen 80`；**MUST NOT** 在 v1.0 IP-direct 形态启用
  `listen 443 ssl`（HTTPS / TLS 留 v1.x 域名 + 备案路径）
- **WHEN** Aliyun 安全组未开放 80/TCP inbound
- **THEN** 部署 SHALL 在控制台新增规则：协议 TCP，端口 80/80，授权对象
  `0.0.0.0/0`，策略允许（C2 多租户阶段再收紧到白名单 / WAF）

#### Scenario: SPA 静态部署路径 + 权限

- **WHEN** `isales-web/dist/` build artifact 部署到 cloud
- **THEN** SHALL 落到 `/var/www/isales-web/`；目录 owner `nginx:nginx`，
  目录 755 / 文件 644
- **THEN** SHALL 跑 `chcon -R -t httpd_sys_content_t /var/www/isales-web/`
  设置 SELinux context（Aliyun Cloud Linux 3 默认 enforcing）
- **MUST NOT** 把 dist 落 `/opt/isales/current/isales-web/`（与
  sub-repos 路径混淆，权限模型冲突）

#### Scenario: nginx 反代契约 (/api → :8000, /ws → :8000/ws)

- **WHEN** 浏览器请求 `http://121.89.85.150/api/<path>`
- **THEN** nginx SHALL `proxy_pass http://127.0.0.1:8000/<path>`，透传
  `Host` / `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto`
- **WHEN** 浏览器升级 `ws://121.89.85.150/ws/<path>`
- **THEN** nginx SHALL 反代到 `http://127.0.0.1:8000/ws/<path>`，带
  `Upgrade: websocket` + `Connection: upgrade` 头；`proxy_read_timeout`
  SHALL ≥ 300 秒（Monitor / live-status 类长连接不被默认 60s 杀）
- nginx 配置 SHALL 设 `proxy_connect_timeout 5s`（API 重启 / 故障时 5 秒
  内 fast-fail，不挂浏览器请求）

#### Scenario: SPA fallback for HTML5 history 路由

- **WHEN** 浏览器请求 `http://121.89.85.150/<view>`（如 `/campaigns/3/edit`）
- **THEN** nginx SHALL `try_files $uri $uri/ /index.html`，让 Vue Router
  HTML5 history 模式所有路由都 serve index.html；浏览器 JS 接管路由

#### Scenario: 同源 — 避免 CORS

- **WHEN** 浏览器从 nginx 拿 SPA 并调 `/api/<path>`
- **THEN** Origin = `http://121.89.85.150`，Target = 同源（nginx 反代），
  SHALL **不需要** isales-api 配置 CORS Allow-Origin
- 即：本部署形态下 isales-api **MUST NOT** 引入 `fastapi.middleware.cors`
  / 任何跨域中间件（v1.0 单源场景，CORS 反而是攻击面）

#### Scenario: isales-api / engine 仍 0.0.0.0:8000 / :50051 公开监听

- **WHEN** nginx 上线后
- **THEN** isales-api **仍** bind `0.0.0.0:8000`（不收紧到 127.0.0.1）；
  isales-engine **仍** bind `0.0.0.0:50051`
- **Why**: (a) :50051 是 edge gRPC 入口，必须公网可达；(b) :8000 保留公网作
  Swagger / nginx 配错的 fallback 通道；(c) v1.0 IP-direct 阶段统一 IP 公开
  策略，C2 阶段一次性收紧

#### Scenario: 部署文档同步更新

- **WHEN** 本 Requirement 实装
- **THEN** `deploy/cloud/STATE.md` SHALL 在同一 commit 内删除 "nginx
  deferred" 注脚，改记 "nginx 1.x active port 80"，新增子节 "isales-web 部署
  工件" 含 `/var/www/isales-web/` 路径 + scp 命令模板
- **THEN** `deploy/RUNBOOK-cloud.md` SHALL 在 "首次部署" + "常规发版" +
  "故障速查" 三节分别增加 nginx + SPA 相关内容
- **MUST**：本 Requirement 实装后任何后续 dev session 启动时跑 `STATE.md §
  Bootstrap` 4 命令 SHALL 看到 nginx active + :80 LISTEN，**否则**视为
  部署 drift

#### Scenario: v1.0 不引入 HTTPS / 域名

- **WHEN** v1.0 任何 admin / dev / QA 操作
- **THEN** 浏览器 SHALL 走 `http://121.89.85.150/`，**不**做 TLS 终结
- JWT token 在网络上 SHALL 是**明文**（v1.0 已知 trade-off）；
  Mitigation：本 Requirement 不引入 HTTPS，但 v1.x 路径已锁——同一个 nginx
  容器加 `listen 443 ssl` + Let's Encrypt 证书 + 备案域名即可升级，不动
  服务架构

#### Scenario: 回滚路径

- **WHEN** nginx / SPA 部署后发现严重问题需要回滚
- **THEN** 步骤 SHALL 是：(a) `systemctl stop nginx && systemctl disable
  nginx`；(b) `rm -rf /var/www/isales-web/`；(c) Aliyun console 关 80
  inbound；(d) `STATE.md` 同 commit 改回 "nginx deferred"
- 回滚耗时 SHALL ≤ 5 分钟；isales-api / engine / 其它服务 SHALL 完全不
  受影响
