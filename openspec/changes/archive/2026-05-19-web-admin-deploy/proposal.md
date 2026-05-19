## Why

`isales-web` 仓库**早已建好且 build 通过**：Vue 3 + Element Plus + Pinia + Axios，
11 个 view（Login / Dashboard / Campaigns / Leads / Devices / Calls / Monitor /
Callbacks / Holidays / SimCards / VoiceModels / HandoffTasks），`dist/` 已构建，
`deploy/nginx.conf` 也写好（SPA fallback + `/api` 反代 :8000 + `/ws` 反代 :8000）。

但 cloud-side 一直**没部署**：

- `deploy/cloud/STATE.md` 第 24 行明示 "nginx deferred — `install.sh` § nginx step
  is optional in v1.0 mode; engine gRPC bind 0.0.0.0:50051 directly, isales-api
  listens 0.0.0.0:8000 directly. isales-web not yet deployed"
- ECS `which nginx` → not installed
- ECS `/opt/isales/current/` 只有 5 个 sub-repos，无 isales-web
- 任何 admin 操作（建 campaign / lead / start dispatch）目前只能走 Swagger
  `:8000/docs` 手工点

2026-05-19 跑 archived `macos-artc-pyobjc-binding §3.9` 真云 smoke + 当前 active
`cloud-edge-grpc-keepalive §5.2`（拨真手机 13301035545）时实证：

- 拨号前要先在 cloud 建 campaign + 关联 device + 加 lead + start，至少 4 个
  REST 调用
- 走 Swagger 一个一个点效率低、易出错（17 个 required campaign 字段）
- dev / QA / boss-console 后续都需要一个能用的 admin UI

成本评估：
- 代码端工作量约 0（dist 已 build）
- cloud 端 = `dnf install nginx` + scp dist + drop nginx.conf + systemctl enable
  + Aliyun 安全组开 80 端口，预计 20 分钟内可上线
- 这反转 STATE.md 的 "nginx deferred" 决策；该决策当初是"v1.0 IP-direct，不要
  domain / 不要 TLS / 不要 nginx"，但 nginx 即使没 TLS / 没 domain 也能纯做
  SPA 服务 + API 反代，**不**绑定 domain 决策

## What Changes

### Cloud-side（核心）

- **安装 nginx** 到 ECS（`dnf install nginx`），systemctl enable
- **部署 `isales-web/dist/`** 到 `/var/www/isales-web/`（owner `nginx:nginx`）
- **drop nginx.conf** 到 `/etc/nginx/conf.d/isales.conf`（基于
  `isales-web/deploy/nginx.conf`，根据 v1.0 IP-direct 微调：去掉 server_name 域名、
  保留 `listen 80`、保留 SPA fallback + /api 反代 + /ws 反代）
- **Aliyun 安全组** inbound 开 **80/TCP** 给 `0.0.0.0/0`（先放公网，C2 多租户
  阶段再收紧）
- isales-api / isales-engine / 其它服务**不动**（仍 bind 0.0.0.0:8000 / :50051 直接）

### Web 端（轻量）

- `isales-web` 当前 `.env.example` 已就绪（`VITE_API_BASE=/api` 走相对路径），
  本 change **不**改前端代码
- 验证一次 `pnpm install && pnpm run build`（或 `npm run build`，按 lockfile）
  在当前 mac dev 机能 reproducibly 构建 dist
- 如果 build 失败，先 fix（独立小修，可能 0 改动）

### 部署文档

- `deploy/cloud/STATE.md` § "Installed components": 删除"nginx deferred" 注脚，
  改为"nginx 1.x 已装 + 服务 isales-web"；记 80/TCP 端口；新增 § "isales-web 部署
  工件" 说明 `/var/www/isales-web/` 路径与 `/etc/nginx/conf.d/isales.conf`
- `deploy/RUNBOOK-cloud.md` § "首次部署": 增 "5. nginx + isales-web 部署"步骤
- `deploy/RUNBOOK-cloud.md` § "常规发版": 增 "更新 isales-web SPA" 子节（`scp
  dist/ → /var/www/isales-web/` + `nginx -s reload`）

### 验收

- 浏览器打开 `http://121.89.85.150/` 见到 `LoginView`（不是 nginx 默认页）
- `POST /api/auth/login` 通过 nginx 反代到 isales-api `:8000` 拿 token
- 完整跑通 5.2 拨号 smoke 的 4 步（建 campaign → 关联 device → 加 lead → start）
  全在 web UI 上点完，cloud engine 收 dial → edge 收 DialCommand → 拨真手机

### 不包括（明确 Non-Goals）

- **不**做 v1.x 域名 + Let's Encrypt + ICP 备案（仍 IP-direct）
- **不**改 isales-api / 其它服务的 bind / 监听（nginx 只反代，不替代）
- **不**做 isales-web 新 view / 新 UI 改动
- **不**做 RBAC / 多 admin user（admin 仍单用户 env-pinned，由 v2 stage 处理）
- **不**做 CDN / OSS 加速（v1.0 直接 nginx 出，足够 dev / QA）

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `deployment-topology`：新增 "云端 admin web SPA 部署形态" Requirement，记
  nginx 作为 v1.0 必装组件 + SPA 落地路径 + /api & /ws 反代契约；**不**修改
  现有 Requirement 主体，纯追加。

## Impact

**受影响代码：**
- `isales-web` 仓库本身：**0 代码改动**（已就绪），仅 `pnpm run build` 重建 dist
- `isales` meta-repo: `deploy/cloud/STATE.md` + `deploy/RUNBOOK-cloud.md` 各
  一节扩充

**不受影响：**
- `isales-common` / `isales-api` / `isales-engine` / `isales-scheduler` /
  `isales-worker` / `isales-telephony` 任何代码
- 已 archive 的 `arch-cloud-edge-split` / `macos-artc-pyobjc-binding` 任何契约
- active `cloud-edge-grpc-keepalive` / `windows-artc-pybind11` 任何代码或部署

**APIs / 协议：** 全部不变。nginx 仅做透明反代 + 静态服务。

**依赖：** 引入 nginx 1.x（Aliyun Cloud Linux 3 默认仓库 `dnf install nginx`，
约 5 MB）

**风险：**

- nginx 配置错可能挡掉 :8000 直连 admin（但 :8000 还在 0.0.0.0 监听，
  Swagger fallback 仍可访问）。Mitigation：保留 :8000 公网开放作 fallback；
  RUNBOOK-cloud.md 在 § "故障速查" 加"如果 80 打不开，直接 :8000 走 Swagger"
- 公网 80 端口比 :8000 暴露面更大、易受扫探。Mitigation：v1.0 仍只单 admin
  + JWT auth + 后续 fail2ban / WAF 在 C2 阶段补；Aliyun console 也可加 IP
  白名单
- 反转 STATE.md 既有决策需要 commit 同步更新 STATE.md（按 CLAUDE.md "Both
  STATE.md files are canonical" 规则强制要求）。本 change 在 tasks.md 里
  显式 tick 这条
