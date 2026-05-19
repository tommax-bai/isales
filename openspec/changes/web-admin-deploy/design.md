## Context

iSales v1.0 cloud-side 当前部署 = 5 个 systemd 服务（isales-engine / -api /
-scheduler / -worker + database / redis）+ 5 个 git-checkout sub-repo 在
`/opt/isales/releases/<ts>/`。isales-api 在 :8000 直接 bind 0.0.0.0 + admin
REST + Swagger。

`isales-web` 仓库自 stage 7 起就在写、stage 8 polish 期 9-tab Campaign / Lead /
Voice 全 ship 了（git log: `41c5e67 PR #4+#5 prep-stage8-cleanup`），但 cloud
deploy 一直挂在 STATE.md "nginx deferred" 这条注脚下没动。

2026-05-19 实拨 13301035545 smoke 时，问题暴露：要走 4 步 REST 调用 +
17 个 required campaign field，没有 UI 几乎不可操作。所以这条 deferred 决策
该解锁了。

约束：
- v1.0 仍 **IP-direct**（121.89.85.150）；**不**引入域名 / Let's Encrypt
  / ICP 备案
- 不能改任何已 archive change 的契约
- 不能动 isales-api / engine 的端口 / bind / auth surface
- `isales-web` 当前代码 / dist 已就绪，本 change 优先**不**碰前端代码

## Goals / Non-Goals

**Goals**

- 浏览器打开 `http://121.89.85.150/` 出 isales-web Login → 登 → 进 Dashboard
- 后续所有 admin 操作（campaign / lead / device / call 历史）在 UI 上点
- cloud-edge-grpc-keepalive §5.2 拨号 smoke 用 UI 完成全流程
- STATE.md / RUNBOOK-cloud.md 同步落地，跨次 dev session 不再撞墙

**Non-Goals**

- 不做域名 / TLS 终结 / HTTPS 证书（v1.x 路径）
- 不做新前端 view / 新 UI 流程
- 不做 RBAC / 多 admin（用既有 `ISALES_ADMIN_USER` 单用户）
- 不接 CDN / OSS / Aliyun 加速
- 不做 isales-api CORS / 跨域改动（nginx 在前面，前端 → nginx → API 同源）
- 不引入 nginx 高级特性（rate limit / WAF / gzip 进阶配置）—— 默认配置够 v1.0

## Decisions

### Decision 1：用 nginx 作 SPA 静态服务 + /api & /ws 反代，而不是 FastAPI StaticFiles

**选**：cloud ECS 安装独立 nginx，listen 80，root `/var/www/isales-web/`，
SPA fallback `try_files $uri $uri/ /index.html`，`/api/` 反代到 `127.0.0.1:8000/`，
`/ws/` 反代到 `127.0.0.1:8000/ws/`。配置直接来自 `isales-web/deploy/nginx.conf`，
v1.0 IP-direct 模式去掉 `server_name <domain>` 这一行。

**否决方案 A：FastAPI StaticFiles mount** —— isales-api `app.mount("/", StaticFiles(directory="...", html=True))` 让 :8000 同时服务 SPA + API。
否决理由：FastAPI 路由匹配 priority 会让 `/auth/login` / `/campaigns` 等
API 端点和 SPA 静态文件 fallback 互相干扰；mount path 调整需要 SPA 重 build；
mixing concerns 跟 v1.0 "单一职责" 原则相违。

**否决方案 B：OSS / CDN** —— Aliyun OSS 桶服务 SPA + 单独域名。
否决理由：增加新组件（OSS + DNS + CDN）+ 跨域配置复杂；v1.0 不需要 CDN
加速效果；C2 阶段再考虑。

**Why nginx**：
- isales-web 本身已经在 `deploy/nginx.conf` 写好这个 pattern，零配置改写
- `/api` 反代让 SPA 和 API 同源，**避免 CORS 配置**（这是关键 ROI）
- WebSocket 反代 in-place 让 Monitor / live-status 类页面零额外配置就能跑
- v1.x 升级到 TLS / 域名时 nginx 就是 TLS 终结点，**复用同一个 nginx 进程
  不重做架构**
- Aliyun Cloud Linux 3 默认仓库就有，`dnf install` 一行

### Decision 2：dist 部署路径 `/var/www/isales-web/`，owner `nginx:nginx`，权限 644 / 755

**选**：build artifact 落 `/var/www/isales-web/{index.html,assets/}`，nginx 走 root 直接 serve。

**否决**：放 `/opt/isales/current/isales-web/dist/`（跟 sub-repos 同级路径）—
看似一致，但 root 是 isales user 写、nginx user 读，权限 / SELinux 互斥概率高；
分开 `/var/www/` 是 Linux 静态站标准实践。

### Decision 3：v1.0 不开 HTTPS / TLS，纯 HTTP listen 80

**选**：明确不做 HTTPS，listen 80 only；nginx.conf 不含 `listen 443 ssl`。

**否决**：上 Let's Encrypt + 自签证书 / Aliyun 免费证书。
否决理由：v1.0 决策线 IP-direct，没有 domain；浏览器对 raw IP 的 HTTPS 证书
全报警告，得不偿失；C2 / v1.x 时同步引入域名 + 备案 + TLS 一起做。

**Trade-off**：v1.0 admin 走 HTTP，**JWT token 在线明文**。Mitigation：
仅在 dev / QA / 小规模内部使用阶段；公网开放面 = 单 admin 账号 + JWT 30 天
TTL；C2 多租户前必上 TLS。

### Decision 4：Aliyun 安全组 inbound 80/TCP 开 `0.0.0.0/0` 公网

**选**：跟 :8000 / :50051 同样的 v1.0 IP-direct 公网开放策略。

**否决**：白名单到 mac dev 出口 IP（更安全），但每次 dev 换网络（4G / 公司 /
咖啡馆）都要改安全组，操作成本高。

**Why**：v1.0 internal-dev 阶段；C2 多租户 + 客户登录前补 IP 白名单 / WAF。

### Decision 5：SPA build 在 dev mac 上做，scp dist 到 cloud

**选**：`cd ~/codes/isales-web && pnpm install && pnpm run build` 在 dev mac
跑出 dist/，然后 `scp -r dist/* root@ECS:/var/www/isales-web/`。

**否决**：cloud 上跑 Node + build —— 需要装 Node.js / pnpm / `node_modules`
开销巨大（~300 MB+）+ build 工具链应该留在 dev side，不污染 cloud 运行时。

### Decision 6：STATE.md 反转 "nginx deferred"，本 change 同 commit 内更新

**选**：本 change 落地的同时（同 commit 或同 PR 内）改 STATE.md，把
"nginx | deferred" 那一行去掉，新增 "nginx 1.x | active | port 80 SPA + /api & /ws 反代"。

**Why**：按 CLAUDE.md "STATE.md is canonical when RUNBOOK / OpenSpec / memory
disagree on cloud-vs-edge deployment state" 约束，本 change 反转 STATE.md
既有决策必须同步落 STATE。

### Decision 7：保留 :8000 公网开放作 Swagger fallback

**选**：不收紧 :8000 inbound 规则；nginx 上 80 后 :8000 仍直连可达，作为
Swagger 调试 / nginx 配错的 fallback 通道。

**否决**：把 :8000 收成 127.0.0.1-only —— 更安全但 fallback / 调试都没了，
v1.0 dev 阶段不值得。

**Why**：v1.0 IP-direct 阶段稳定性 > 公网攻击面收紧。C2 阶段统一收紧。

## Risks / Trade-offs

- **[Risk] nginx 默认 SELinux context 阻挡 `/var/www/isales-web/` 读** ——
  Aliyun Cloud Linux 3 默认 SELinux enforcing。Mitigation：部署脚本里跑
  `chcon -R -t httpd_sys_content_t /var/www/isales-web/` 或 `setsebool -P httpd_can_network_connect 1`。RUNBOOK 把这一步明示。

- **[Risk] nginx upstream `:8000` 拒连或超时** —— isales-api 重启 / 配置错时
  nginx 502 ；用户看到的是空白页。Mitigation：nginx.conf 加 `proxy_connect_timeout 5s` + 自定义 502 错误页指引"刷新 / 看 systemctl"。

- **[Risk] WebSocket 反代 idle-timeout** —— Monitor / live-status 这种长链接，
  nginx 默认 `proxy_read_timeout` 60s 会断。原 isales-web/deploy/nginx.conf
  已含 `proxy_read_timeout` 调大。保持。

- **[Trade-off] HTTP 明文 admin** —— 见 Decision 3 trade-off。

- **[Trade-off] dist 部署是 manual scp**（无 CI/CD），易过期。Mitigation：
  RUNBOOK 写"常规发版"中"前端发版"子节，标明每次 isales-web push 后跑
  build + scp 命令。C2 阶段补 CI。

## Migration Plan

无 schema migration。纯部署。

回滚策略：
- 停 nginx: `systemctl stop nginx && systemctl disable nginx`
- 删 dist: `rm -rf /var/www/isales-web/`
- 关安全组 80 端口
- STATE.md 回到 "nginx deferred"

回滚耗时 ≈ 2 分钟。

部署顺序：
1. dev mac：`pnpm run build` 重建 dist
2. cloud ECS：`dnf install nginx`
3. drop nginx.conf 配置到 `/etc/nginx/conf.d/isales.conf`
4. `mkdir -p /var/www/isales-web/`
5. `scp dist/* root@ECS:/var/www/isales-web/`
6. SELinux chcon
7. `nginx -t` 验证
8. Aliyun 控制台 inbound 80/TCP 0.0.0.0/0 允许
9. `systemctl enable --now nginx`
10. 浏览器 smoke

## Open Questions

无（架构上很标准）。
