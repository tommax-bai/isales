## 1. dev 端构建准备

- [ ] 1.1 在 `isales-web` 仓库跑 `pnpm install`（或 `npm install`，按 lockfile 决定）；若 lockfile 缺失先 `pnpm install --frozen-lockfile` 失败再 fallback `pnpm install`
- [ ] 1.2 跑 `pnpm run build`，确认 `dist/index.html` + `dist/assets/` 输出；记录 build 总大小（应 < 10 MB）
- [ ] 1.3 `dist/` 完整性 smoke：`grep -l 'iSales' dist/index.html` 应命中（确认 title / favicon / app shell 没空）
- [ ] 1.4 验证 `dist/index.html` 内 `<script>` / `<link>` 引用的 hash 文件全在 `dist/assets/`（防止 build 缺资源）
- [ ] 1.5 提交 `isales-web` 仓库锁文件（如果 install 过程产生改动）；本 change **不**写新前端代码，但 lockfile 更新作为 dependency hygiene 可以同期 commit

## 2. cloud 端 nginx 安装 + 配置

- [ ] 2.1 SSH ECS 跑 `dnf install -y nginx`；`nginx -v` 确认版本 ≥ 1.20
- [ ] 2.2 `mkdir -p /var/www/isales-web/`；目录 owner `nginx:nginx`，permissions `755`
- [ ] 2.3 把 `isales-web/deploy/nginx.conf` 改名为 `isales.conf`，drop 到 `/etc/nginx/conf.d/isales.conf`；按 v1.0 IP-direct 调整：(a) 删除 `server_name <domain>;` 行；(b) `listen 80` 保持；(c) `/api/` 反代 `127.0.0.1:8000` 保持；(d) `/ws/` 反代 `127.0.0.1:8000/ws/` 保持；(e) 增加 `proxy_connect_timeout 5s; proxy_read_timeout 300s`
- [ ] 2.4 删除 `/etc/nginx/conf.d/default.conf` 或注掉默认 server 块（防止 80 端口冲突）
- [ ] 2.5 `nginx -t` 验证配置语法
- [ ] 2.6 SELinux：`chcon -R -t httpd_sys_content_t /var/www/isales-web/`；如果 isales-api 默认监听 unconfined `:8000`，再跑 `setsebool -P httpd_can_network_connect 1` 让 nginx 反代到 `127.0.0.1:8000` 不被 deny
- [ ] 2.7 `systemctl enable --now nginx`；`systemctl is-active nginx` = active；`ss -tln | grep :80` 看到 LISTEN

## 3. dist 部署到 cloud

- [ ] 3.1 dev mac：`scp -i ~/codes/isales-3.pem -r isales-web/dist/* root@121.89.85.150:/var/www/isales-web/`
- [ ] 3.2 cloud：`chown -R nginx:nginx /var/www/isales-web/`；`find /var/www/isales-web/ -type d -exec chmod 755 {} \;`；`find /var/www/isales-web/ -type f -exec chmod 644 {} \;`
- [ ] 3.3 SELinux 重跑 chcon：`chcon -R -t httpd_sys_content_t /var/www/isales-web/`（覆盖 scp 带过来的 context）
- [ ] 3.4 `curl -sI http://127.0.0.1/` from cloud 期望 `HTTP/1.1 200 OK` + `Content-Type: text/html`
- [ ] 3.5 `curl -s http://127.0.0.1/api/health` from cloud 期望 isales-api `/health` JSON（确认 /api 反代真通）

## 4. Aliyun 安全组 + 公网访问

- [ ] 4.1 Aliyun 控制台 ECS 实例 → 安全组 → 入方向，新增规则：协议 `TCP`，端口 `80/80`，授权对象 `0.0.0.0/0`，策略 `允许`，优先级 `1`
- [ ] 4.2 dev mac：`curl -sI http://121.89.85.150/` 期望 200 OK
- [ ] 4.3 浏览器打开 `http://121.89.85.150/`，期望见 isales-web LoginView（不是 nginx 默认页 / 不是空白）
- [ ] 4.4 浏览器 DevTools Network：所有静态资源（CSS / JS / font）从 `121.89.85.150/assets/...` 加载，返回 200；无 403 / 502 / CORS 错

## 5. 端到端 login + 后台基本操作 smoke

- [ ] 5.1 浏览器 LoginView 输 `ISALES_ADMIN_USER` 凭据，点登录；期望跳转 Dashboard
- [ ] 5.2 DevTools Network 看到 `POST /api/auth/login` 返回 token；后续 `GET /api/auth/me` / `GET /api/campaigns` 都带 `Authorization: Bearer ...`
- [ ] 5.3 Dashboard 加载 KPI 卡片不报错（数据可以是 0，重点是 API 调用全 200）
- [ ] 5.4 Campaigns 列表页能加载（v1.0 没数据时显示空状态）；点"新建 campaign"按钮，模态框出，必填项有合理默认
- [ ] 5.5 完整跑 `cloud-edge-grpc-keepalive §5.2` 的 4 步全在 UI 上：(a) 建 campaign / (b) 关联 edge-01 device / (c) 加 lead 手机 13301035545 / (d) start campaign

## 6. 文档 + STATE.md 同步

- [ ] 6.1 修改 `deploy/cloud/STATE.md` § "Installed components"：删除 nginx "deferred" 注脚，改为 "nginx 1.x | active | port 80 SPA + /api & /ws 反代"；新增子节 "isales-web 部署工件"（路径 + 大小 + scp 命令模板）
- [ ] 6.2 修改 `deploy/RUNBOOK-cloud.md` § "首次部署"：增 step "5. nginx + isales-web 部署"（按上述 §2 + §3 步骤）
- [ ] 6.3 修改 `deploy/RUNBOOK-cloud.md` § "常规发版"：增 "更新 isales-web SPA" 子节（`pnpm run build` + `scp dist → /var/www/isales-web/` + `nginx -s reload`）
- [ ] 6.4 修改 `deploy/RUNBOOK-cloud.md` § "故障速查"：增 "如果 80 打不开，:8000 Swagger 是 fallback" 条目
- [ ] 6.5 (meta-repo) 跑 `openspec validate web-admin-deploy --strict` 0 warning

## 7. 收尾 + 归档

- [ ] 7.1 commit 拆分：(a) `isales-web` 仓库（如 lockfile 有动）；(b) meta-repo（spec change + STATE.md + RUNBOOK-cloud.md 更新）
- [ ] 7.2 push 两个仓库 origin/main
- [ ] 7.3 写 `openspec/changes/web-admin-deploy/acceptance.md`：浏览器 smoke screenshot（或文字描述）+ `:8000` Swagger fallback 仍可用 + 完整跑 §5.5 拨号 smoke 的 timeline
- [ ] 7.4 `openspec archive web-admin-deploy`；spec delta 合进 `openspec/specs/deployment-topology/spec.md`
