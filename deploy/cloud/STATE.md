# cloud deployment — current state snapshot

**Last updated**: 2026-05-24 09:32 CST — **impl-provider-credential-db-ssot
deployed**; provider 凭据从 env 切到 DB SSOT (provider_credential 表 Fernet
加密)；engine startup 装载 `credentials_loaded count=2 providers=['volcengine']`
✓；env 4 个文件加 `ISALES_FERNET_KEY` 同值 + engine.env 删 VOLCENGINE 真值；
alembic head a1b2c3d4e5f6 → b2c3d4e5f6a7。

Prior: 2026-05-23 18:50 — **web-admin-campaign-workflow deployed**;
campaign 进入客户面 4-entry top-nav，per-campaign 配置端点 (`/api/role-configs`
/ `/api/prompt-versions` / `/api/filler-sets` + `/api/campaigns/{id}/progress`)
mount 完成 + JWT 鉴权返回 401 ✓；scheduler 取数补 `next_call_at IS NULL`。
**无 alembic 迁移** (4 张配置表已存在)。SPA 重 build 至 75 files / 2.9 MB
含 `CampaignWorkspace` / `CampaignDetail` / `ModelProviderConfig` 新 chunk。
浏览器 UI 烟测仍欠 (从 curl 层确认 200 / 401 行为)。

Prior: 2026-05-20 web-admin-ui-redesign 落地。

This file is a **point-in-time snapshot** of what's actually deployed to the
iSales cloud, distinct from `deploy/RUNBOOK-cloud.md` which describes *how*
to deploy from scratch. Update this file whenever cloud topology changes.

> **Fresh Claude Code session resuming work — READ THIS FIRST**. The OpenSpec
> tasks.md checkboxes for A2 `arch-cloud-edge-split` lag the actual deploy
> state. This file is canonical; CLAUDE.md (root) makes it the arbiter when
> RUNBOOK / OpenSpec disagree. See § "Bootstrap a new dev session" at the
> bottom for the 4-command grep recipe to verify each layer before asserting
> any state.

## v1.0 deployment posture (project decision)

| Decision | v1.0 | Future (v1.x+) |
|---|---|---|
| Public endpoint | **IP-direct** `121.89.85.150` — edge connects straight to the ECS public IP | optional domain + ICP 备案 + Let's Encrypt (deferred until commercial scale or compliance pressure) |
| TLS posture | **TBD when first edge ships** — plain gRPC over IP is the cheapest option for a customer-VPN / pilot deploy; nip.io-style sslip plus Let's Encrypt is the lowest-friction TLS path that does not require a registered domain; self-signed pinned at edge is also viable. Pick when first edge actually deploys. | full PKI tied to domain |
| ICP 备案 | **not required** — no public domain in v1.0 | required if/when domain is registered |
| nginx | **active (2026-05-19, `web-admin-deploy`)** — nginx 1.20.1 listening `:80` serving `isales-web` SPA from `/var/www/isales-web/` + reverse-proxying `/api/` → `127.0.0.1:8000` + `/ws/` → `127.0.0.1:8000/ws/`. engine gRPC still binds `0.0.0.0:50051` directly (un-fronted); isales-api still binds `0.0.0.0:8000` directly (retained as Swagger fallback). | nginx terminates TLS + serves all SPA + reverse-proxies the four cloud services (full domain + 备案 path) |

`deploy/RUNBOOK-cloud.md` §2.2 ("域名与 TLS") describes the **future** path,
not the v1.0 default. §2.1 ("v1.0 IP 直连") is the current canonical recipe.

Decision rationale: v1.0 ship target is single-customer pilot installs where
the edge runs on the customer's own Windows PC and dials the ECS over the
public internet (or a customer-provided VPN). Domain registration + ICP 备案
alone takes 2-4 weeks in China and is not on the critical path for proving
the AI sales-call flow works. Re-add the domain step when (a) multiple
customer deployments need a stable endpoint label or (b) compliance / brand
requirements come in.

## ECS

| Field | Value |
|---|---|
| Public IP | `121.89.85.150` |
| Hostname | `iZ0jlev0nr9m65tj6546zyZ` |
| Region | Aliyun (region inferred from console; verify before any region-specific work) |
| OS | **Alibaba Cloud Linux 3.2104 U13 (OpenAnolis Edition)** — RHEL 8-compatible, `dnf`/`yum`-based |
| Arch | x86_64 |
| CPU / RAM | 8C 8G (provisioned; A2 spec called for 4C16G — fine for PoC) |
| Disk | 40 GiB system disk, ~33 GiB free pre-deploy → ~32 GiB free post-deploy (deploy added < 1 GiB) |
| Swap | none (default) |
| SSH | port 22, public key auth only (key bound via Aliyun console "SSH 密钥对") |
| Login user | `root` |

### SSH access from a dev machine

The `.pem` private key must be on your machine. The SSH command shape:

```
ssh -i <path-to>/isales.pem root@121.89.85.150
```

| dev rig | path | notes |
|---|---|---|
| Windows (primary) | `C:\Users\tianx\codes\isales.pem` | Original key, used during install |
| macOS (dev) | `~/codes/isales-3.pem` | **2026-05-19**: rotated keypair; this is the only `.pem` currently bound to the ECS instance |

On a new machine: copy the **current** `.pem` from a secure location
(password manager attachment, USB drive, another dev machine's
`~/.ssh/`), `chmod 600` it on macOS/Linux, then test:

```
ssh -i ~/codes/isales-3.pem root@121.89.85.150 'hostname'
# expect: iZ0jlev0nr9m65tj6546zyZ
```

Current bound keypair fingerprint (verify you have the right `.pem`):

```
2048 SHA256:Xz3C4DtqUBvdENUZk5Biw+GYKw3gGmjt1UwEzL9yOHQ (RSA)
```

> **2026-05-19 rotation note.** Prior fingerprint
> `SHA256:ESKEddFU95g0ytlCZyTYEg3T4SHYNe7oBVPHpWQI5k0` was the install-time
> keypair; it has since been replaced via Aliyun console. A stale
> `isales.pem` (e.g. older `~/Downloads/isales.pem`) WILL fail with
> `Permission denied (publickey)` — `ssh-keygen -lf <path>` to verify
> before troubleshooting host bindings.

ECS host key fingerprints (for first-time `Are you sure you want to
continue connecting (yes/no/[fingerprint])?` accept):

```
ED25519 SHA256:3aQzOCsr17BHqpH9o/4cQI0oJ2g9e6MO8A+j2dFBVmo
ED25519 MD5:20:b5:69:4f:15:1e:c8:3c:c7:5e:1b:29:e3:e3:0e:0a
```

If `Permission denied (publickey)`: the key is either wrong (stale
rotation — see above), not bound to this ECS in the Aliyun console, or
has wrong file permissions on a Unix host. Aliyun console → ECS
instance → "更多 > 密钥对 > 绑定/解绑密钥对".

Claude Code permission rule (`.claude/settings.local.json` at repo root)
already allows `Bash(ssh -i C:/Users/tianx/codes/isales.pem*)` and
`Bash(scp -i C:/Users/tianx/codes/isales.pem*)` so an agent can drive
the ECS without per-command auto-mode prompts.

## Installed components on the ECS

All on the same single instance — no managed RDS / Redis, no separate
nodes. Single-host posture acceptable for v1.0 PoC (no HA).

### Data plane (persistent, provisioned earlier)

| Service | Version | systemd unit | Listen | Auth |
|---|---|---|---|---|
| PostgreSQL | 13.23 | `postgresql.service` | `127.0.0.1:5432`, `[::1]:5432` | scram-sha-256, user `isales` |
| Redis | 6.2.20 | `redis.service` | `127.0.0.1:6379`, `[::1]:6379` | `requirepass` |
| sshd | (system) | `sshd.service` | `0.0.0.0:22` | pubkey-only |

PostgreSQL data dir: `/var/lib/pgsql/data/`. Redis config: `/etc/redis.conf`.

PG `isales` role + `isales` database exist; password matches the
`ISALES_DATABASE_URL` in `deploy/cloud/env/*.env`. pg_hba grants
`host isales isales 127.0.0.1/32 scram-sha-256` (only local TCP, no remote
PG access).

### Language runtime + git (added 2026-05-17 via dnf)

| Package | Version | Source |
|---|---|---|
| python3.11 | 3.11.13-7.0.1.al8 | `alinux3-updates` repo |
| python3.11-devel | 3.11.13-7.0.1.al8 | `alinux3-updates` repo |
| git | 2.43.7 | base |
| gcc / make | (already present) | base |

Python 3.6.8 is also on the box as `/usr/bin/python3` (RHEL 8 system Python).
**Cloud services require Python 3.11+** — every iSales repo's
`pyproject.toml::requires-python = ">=3.11"` and isales-engine uses 3.11-only
features (`asyncio.TaskGroup` / `except*` / `asyncio.timeout`) in 7 core
modules; pip would hard-refuse to install on 3.6. Do **NOT** try to run any
iSales service from the system Python.

### Application services (deployed 2026-05-17 22:30-23:25 CST)

Pulled from `https://github.com/tommax-bai/isales-{common,api,engine,
scheduler,worker}.git` at `main` HEAD into
`/opt/isales/releases/20260517-222944/` (current release).
`/opt/isales/current → /opt/isales/releases/20260517-222944/` symlink.
Single shared venv at `/opt/isales/current/venv/` runs Python 3.11.13;
all 5 isales packages installed editable (`pip install -e`).

| Service | systemd unit | Listen | Notes |
|---|---|---|---|
| isales-engine | `isales-engine.service` enabled+active | `0.0.0.0:50051` (cloud-edge gRPC, plaintext per v1.0 IP-direct) | HS256 JWT bearer in initial metadata; secret in `engine.env::ISALES_JWT_SECRET`. Log line `cloud_edge_grpc_server_started` confirms boot. |
| isales-api | `isales-api.service` enabled+active | `0.0.0.0:8000` (FastAPI + Uvicorn + WebSocket) | Web admin / boss console backend; see `api.env`. Both public direct (Swagger fallback) AND fronted by nginx `/api/` reverse proxy. |
| isales-scheduler | `isales-scheduler.service` enabled+active | (no socket — pure background) | Lead dispatcher; idle until campaign + leads inserted. |
| isales-worker | `isales-worker.service` enabled+active | (no socket — pure background) | Post-call summary / webhook fan-out. |
| nginx | `nginx.service` enabled+active (2026-05-19, `web-admin-deploy`) | `0.0.0.0:80` (HTTP only, v1.0 IP-direct, no TLS) | Serves `isales-web` SPA from `/var/www/isales-web/` + reverse-proxies `/api/` → `127.0.0.1:8000/` + `/ws/` → `127.0.0.1:8000/ws/`. Config drop-in: `/etc/nginx/conf.d/isales.conf` (from `isales-web/deploy/nginx.conf`, `server_name` stripped). |
| isales-web (SPA) | static files under nginx | served at `http://121.89.85.150/` | Vue 3 + Element Plus admin / boss console. Built artifact path `/var/www/isales-web/{index.html,assets/}` (47 files, 2.5 MB). Re-deploy: `pnpm run build` on dev mac → `scp dist/ → ECS:/var/www/isales-web/` → `nginx -s reload`. |

Service env files at `/etc/isales/env/{api,engine,scheduler,worker}.env`
(root:isales 0640), mirrored from this repo's `deploy/cloud/env/*.env`. Each
systemd unit has a `*.service.d/env.conf` drop-in pointing at its env file.

Database schema: alembic head `b2c3d4e5f6a7` (advanced from `a1b2c3d4e5f6`
on 2026-05-24 by `impl-provider-credential-db-ssot §1.6` — 新建
`provider_credential` 表，存 Fernet urlsafe-base64 cipher，UNIQUE
`(provider_id, field_name)` + idx `provider_id`)。21 tables in `public`
(19 initial + 2026-05-20 `appointment` + 2026-05-24 `provider_credential`)。
Verify with:

```bash
ssh ... 'cd /opt/isales/current/isales-common && set -a && source /etc/isales/env/api.env && set +a && \
    sudo -u isales -H -E env ISALES_DATABASE_URL="$ISALES_DATABASE_URL" \
    /opt/isales/current/venv/bin/alembic current'
```

**Not deployed in v1.0**: Prometheus / Grafana monitoring stack —
per the "v1.0 deployment posture" decision. Re-add when production
observability scope opens.

> **2026-05-19 (`web-admin-deploy`)**: nginx + isales-web were
> previously listed here as "not deployed in v1.0"; that decision is
> now reversed. Both are active under v1.0 IP-direct + HTTP-only
> posture (no TLS, no domain). v1.x adds TLS termination + 备案
> domain on the same nginx instance.

> **2026-05-20 (`web-admin-ui-redesign`)**: SPA redesigned — sticky
> top-nav (`[线索 ｜ 外呼 ｜ 预约]` + 3 config circles) replaces
> sidebar; 10 operational views demoted under `/operations/*` with
> client-side 301 from old top-level paths (preserves bookmarks).
> Backend gained `/api/appointments` (6 endpoints + state-machine).
> Deploy steps actually executed:
>
> 1. backup `/var/www/isales-web/` → `/var/www/isales-web.bak-20260520-112349/`
> 2. `git pull` on isales-common / isales-api / isales-engine /
>    isales-scheduler / isales-worker (engine stashed a stale
>    cloud-edge-grpc-keepalive hotfix under
>    `stash@{0}: On main: pre-deploy-202605-keepalive-hotfix` — main
>    branch already contains the equivalent code, drop the stash next
>    cleanup pass)
> 3. `pip install -e` rerun for all 5 packages; `pip check` clean
> 4. `alembic upgrade head` advanced `580b817550c8 → a1b2c3d4e5f6`;
>    `\d appointment` shows 10 cols / 4 indexes / 2 FKs as expected
> 5. `systemctl restart isales-api`; startup log shows
>    `Application startup complete` + `Uvicorn running on http://0.0.0.0:8000`
> 6. `rsync -avz --delete dist/ → /var/www/isales-web/` (had to
>    `dnf install -y rsync` first — not pre-installed on AL3); 71
>    asset files; `chown -R nginx:nginx` + `755/644` perms
> 7. Public smoke from dev mac:
>    - `GET http://121.89.85.150/` 200 (SPA index)
>    - `GET http://121.89.85.150/api/docs` 200
>    - `GET http://121.89.85.150/api/appointments` 401 (JWT enforced)
>    - `GET http://121.89.85.150/dashboard` 200 (SPA fallback; client
>      router redirects to `/operations/dashboard`)
>    - `GET http://121.89.85.150/operations` 200
>
> Known follow-up: full in-browser smoke (login → 6 entries → leads →
> call → create-appointment → appointments flow → 3 config views) still
> owed; cite when `web-admin-ui-redesign §6.7` ticks. Until then, the
> infrastructure and HTTP layers are confirmed but UX validation is
> from curl only.

> **2026-05-23 (`web-admin-campaign-workflow`)**: campaign 进入客户面 4-entry
> top-nav (`[场景 ｜ 线索 ｜ 外呼 ｜ 预约]` + 1 模型厂商 config 圆按钮)，
> per-campaign 外呼策略 (4-tier prompt / 垫词 / 时段 / 选用音色) 真持久化到
> 后端。Deploy 步骤实际执行：
>
> 1. backup `/var/www/isales-web/` → `/var/www/isales-web.bak-20260523-pre-campaign-workflow/`
> 2. **Workaround**: ECS → github.com:443 持续 TCP 超时（Aliyun CN egress
>    阻断），git pull 全部失败 → 改用本地 `git bundle create` + `scp` →
>    ECS `git fetch /tmp/<repo>.bundle main:bundle/main` + `merge --ff-only`。
>    Applied: common `99c47b2`, api `9416669`, scheduler `241481e`。
>    [架构建议] install.sh / 部署文档应加 fallback 路径（bundle 或 China
>    git mirror），以及一段 egress 连通性 diagnostic。
> 3. `pip install -e isales-common` 刷新版本（0.3.0 → 0.3.2）；consumer
>    pin 范围 `>=0.3.0,<0.4` 未变，editable 安装无需再装。
> 4. **No alembic migration** — `role_config` / `prompt_version` /
>    `filler_set` / `filler_phrase` 已存在于初始 schema，仅 HTTP 端点新增。
> 5. `systemctl restart isales-api isales-scheduler`; 两者 active；
>    `journalctl --since "30 seconds ago"` grep error/fail/traceback → 0 命中。
> 6. local `npm install` 补 `lucide-vue-next`（node_modules 漏装）→
>    `npm run build` clean (13.5s，含 CampaignWorkspace 4kB / CampaignDetail
>    19.5kB / ModelProviderConfig 6.2kB)；75 asset files / 2.9 MB；
>    `scp dist/*` + `chown -R nginx:nginx` + `nginx -s reload`。
> 7. HTTP smoke（curl from ECS 127.0.0.1）：
>    - `GET /` 200 (SPA index)
>    - `GET /campaigns` 200 (SPA fallback; client router → CampaignWorkspace)
>    - `GET /operations/campaigns` 200 (运营面 view 保留)
>    - `GET /api/role-configs` 401 (新 router 已 mount + JWT 强制)
>    - `GET /api/prompt-versions` 401 (同)
>    - `GET /api/filler-sets` 401 (同)
>    - `GET /api/campaigns` 401 / `GET /api/docs` 200
>
> Known follow-up: full in-browser smoke (建场景 → 配 prompt/时段/音色 →
> 保存刷新仍在 → 添加线索下拉 → 启动场景 → 验证 `next_call_at` 初始化 →
> 停止 → 旧 `/operations/*` 重定向仍工作) 仍欠；HTTP layer / 后端日志确认
> 后端 + 鉴权层 OK，UX 验证需浏览器。复用 `web-admin-ui-redesign` 同期
> deferred UX smoke。

> **2026-05-24 (`impl-provider-credential-db-ssot`)**: provider 凭据从
> env 切到 DB SSOT (`provider_credential` 表 + Fernet 加密 + admin CRUD)。
> Deploy 步骤实际执行：
>
> 1. 本地 `git bundle create` 5 仓 (common/api/engine/worker/scheduler)
>    → scp → ECS git fetch + merge --ff-only。HEAD: common 6edbd8c /
>    api b14d834 / engine 0f6023b / worker 134c371 / scheduler 78c4c54。
> 2. `pip install -e isales-common` (0.3.2 → 0.4.0) + 4 service 重装
>    pyproject metadata (>=0.4.0,<0.5 pin)；`pip check` clean。
> 3. backup `/etc/isales/env/engine.env` → `/tmp/engine.env.pre-cred-migrate`
>    (chmod 644 给 isales 用户读)。
> 4. **alembic upgrade head** advanced `a1b2c3d4e5f6 → b2c3d4e5f6a7`；
>    `\d provider_credential` 显示 5 cols (id/provider_id/field_name/
>    cipher_text/updated_by/timestamps) + UNIQUE(provider_id, field_name)
>    + idx ix_provider_credential_provider_id。
> 5. `isales-cred-migrate import-env --env-file /tmp/engine.env.pre-cred-migrate
>    --apply` 灌入 2 行 (volcengine.app_key + volcengine.app_token)，
>    masked plan 显 `api-********5338` / `8298********2c49` 与原值前后
>    4 字对齐 ✓。
> 6. scp 4 个新 env (含 ISALES_FERNET_KEY=Yt-e_Tg... 同值，engine.env
>    无 VOLCENGINE_APP_KEY/APP_TOKEN，加 ISALES_CREDENTIALS_REQUIRED=true)
>    → `install -m 0640 -o root -g isales` 覆盖 `/etc/isales/env/`。
> 7. `systemctl restart isales-api isales-engine isales-scheduler
>    isales-worker`；4 服务 active；`journalctl -u isales-engine` 显
>    `credentials_loaded count=2 providers=['volcengine']` ✓；60s 日志
>    grep error/fail/traceback 0 命中。
> 8. HTTP smoke：`/api/provider-credentials = 401` (新 router 鉴权 OK) /
>    `/api/campaigns = 401` / `/api/docs = 200`。
> 9. `cd isales-web && node scripts/check_api_reachability.mjs`：
>    全量 47 endpoints OK，0 DEAD。新 endpoint `POST /provider-credentials`,
>    `GET /provider-credentials/{id}`, `DELETE`, `reload-hint` 全 401 ✓。
> 10. Cleanup `/tmp/engine.env.pre-cred-migrate`。
>
> Known follow-up: full in-browser smoke (UI「模型厂商」改 key + 保存 +
> mask preview 验证) 仍欠；HTTP layer / engine startup 装载日志确认
> 后端链路 OK。

### Why PG 13 not PG 16

`alinux3-updates` repo only carries `postgresql-13.23-2.0.1.al8`.
Installing PG 16 would require adding the PostgreSQL Global Development
Group (PGDG) repo against RHEL 8, which works but introduces one more
maintained dependency. v1.0 schema is plain SQLAlchemy migrations
compatible across PG 13–16, so PG 13 was chosen as the simplest stable
path. To upgrade later: `pg_dumpall` → install PG 16 from PGDG → `psql
< dump.sql` → cutover.

### Why AL3 not Ubuntu 22.04

The ECS was already provisioned with AL3 by the user before the iSales
deployment work began. Reprovisioning to Ubuntu was deemed not worth
the cost (PG/Redis on AL3 are first-class supported). Implication:
`deploy/cloud/scripts/install.sh` (originally written for Ubuntu apt)
was **not** run end-to-end here; instead a manual port of its phases
ran from a Claude Code SSH session 2026-05-17. The script needs an
`apt → dnf` adaptation pass before it's runnable here. Package mappings:

| Ubuntu apt | AL3 dnf |
|---|---|
| `postgresql postgresql-contrib` | `postgresql-server postgresql-contrib` (already installed) |
| `redis-server` | `redis` (already installed) |
| `python3.12 python3.12-venv` | `python3.11 python3.11-devel` from `alinux3-updates` (Python 3.12 not in repo; build-from-source possible but not warranted) |
| `nginx` | `nginx` (in `epel`) — not used in v1.0 |

## Cloud-edge gRPC end-to-end smoke (verified 2026-05-17 23:25 CST)

Reproducible verification, run from Windows dev box → ECS:

```powershell
# 1. Mint a one-hour test JWT on ECS (uses ISALES_JWT_SECRET from api.env):
ssh -i C:/Users/tianx/codes/isales.pem root@121.89.85.150 `
    'set -a; source /etc/isales/env/api.env; set +a; \
     /opt/isales/current/venv/bin/isales-edge-token-mint \
        --device-id edge-test --ttl 1h' > $env:TEMP\smoke.jwt

# 2. Run the smoke from local dev .venv (3.14 works fine; grpcio is the only need):
.venv\Scripts\python.exe scripts\cloud_edge_smoke.py `
    --endpoint 121.89.85.150:50051 --token-file $env:TEMP\smoke.jwt --timeout 15
```

Expected output (under 5 s):

```
==> connecting to 121.89.85.150:50051 ...
==> CONNECTED
==> sending Heartbeat (critical=True) ...
==> Heartbeat sent OK
==> idle 3s to observe any inbound frames ...
==> total inbound frames: 0
==> stopping client ...
==> done
```

The `cloud_edge_stream_error` WARN line on teardown is a normal close-
sequence artifact (engine sends EOS, grpc.aio raises on the client side as
the iterator empties) — not a bug. 0 inbound frames is also normal: engine
doesn't push proactive frames in idle state.

This proves:
- TCP reach across Aliyun security group (50051/tcp + 8000/tcp open from
  external — verified in earlier provisioning; no security group changes
  needed for v1.0 IP-direct)
- gRPC bidi stream up
- engine token verify (alg HS256, sub=edge-01, aud=cloud-edge)
- engine accepts non-critical Heartbeat from edge

Edge-side smoke script: `isales-telephony/scripts/cloud_edge_smoke.py`
(committed 2026-05-17, commit `cbd2d02`). It uses the production
`CloudEdgeGrpcClient` so it exercises the same code path D1 §9.1 ("tray
goes green on activation") would.

### Known trap — mac → ECS 50051 idle-stream cut (2026-05-19)

While running the §3.9 real-cloud smoke for archived
`macos-artc-pyobjc-binding` (`archive/2026-05-19-macos-artc-pyobjc-binding/
acceptance.md`), the bidi stream was observed to be **cut by an
intermediate Aliyun network layer ~1 ms after `call.initial_metadata()`
returns**. Pattern:

- TCP three-way handshake: 100 % succeeds (`nc -zv` instant OK)
- HTTP/2 setup: `call.initial_metadata()` returns
- Next `async for response in call:` iteration: `UNAVAILABLE: Socket
  closed`
- Engine localhost smoke (`127.0.0.1:50051` from the ECS itself):
  3 / 3 reliable — so engine code is fine
- Adding `grpc.keepalive_time_ms=30000` etc. channel options on client
  alone **did not** mitigate; the cut is upstream of the keepalive
  ping cadence

The current diagnosis is an Aliyun-side stateful idle-cleanup (ECS
security group / SLB if interposed / connection-tracking GC). Fix is
tracked in OpenSpec change `cloud-edge-grpc-keepalive`:

1. **Code side** (both sub-repos, this change): symmetric HTTP/2
   keepalive options on `grpc_client.py` and `grpc_server.py` +
   `cloud_edge_stream_connected` / `cloud_edge_stream_opened` INFO
   logs so ops can correlate.
2. **Aliyun console side** (this RUNBOOK): re-confirm the inbound
   50051 security group rule has no idle-cleanup; if an SLB is
   introduced in front, require seven-layer HTTP/2 + idle-timeout
   ≥ 60 min. See `deploy/RUNBOOK-cloud.md` § "50051 TCP idle-timeout
   配置".
3. **Acceptance gate**: `scripts/cloud_edge_smoke.py --soak 600
   --report-file <path>` from a real dev rig MUST report stream
   lifetime p95 ≥ 300 s.

Update this section after the soak gate clears; cite the
`cloud-edge-grpc-keepalive` archive commit for closure.

## Secrets

### Cloud service env files

Real values live in `deploy/cloud/env/{api,engine,scheduler,worker}.env`
of THIS repo (private), committed per the 2026-05-17 decision. See
`deploy/cloud/env/README.md` for the rotation procedure and migration
path when secrets need to leave git. Key values currently in env files:

| Key | Value (audit hint, full value in env file) | Source |
|---|---|---|
| `ISALES_RTC_APP_ID` | `o6dpsan9` | Aliyun RTC console |
| `ISALES_RTC_APP_KEY` | `c4f5feb...` (32 hex) | Aliyun RTC console; cloud-only |
| `ISALES_JWT_SECRET` | `7426829e...` (64 hex) | random; identical across api/engine env files |
| `ISALES_DATABASE_URL` | `postgresql+asyncpg://isales:***REMOVED***@127.0.0.1:5432/isales` | local PG, password matches `pg_hba` config |
| `ISALES_ENGINE_CLOUD_EDGE_GRPC_BIND` | `0.0.0.0:50051` | v1.0 IP-direct (was `127.0.0.1:50051` until 2026-05-17, see commit `8a0a6ab`) |

The 4 files are mirrored to `/etc/isales/env/*.env` on the ECS
(root:isales 0640), and each systemd unit's drop-in
`/etc/systemd/system/isales-*.service.d/env.conf` sets
`EnvironmentFile=/etc/isales/env/<svc>.env`.

### GitHub PAT on ECS (for `git pull` / OTA upgrade path)

Classic PAT, owner `tommax-bai`. Lives at `/opt/isales/.git-credentials`
(isales:isales 0600). git config `credential.helper=store` is set in
`/opt/isales/.gitconfig` (isales home is `/opt/isales`, NOT `/home/isales`
— `useradd -d /opt/isales`). Verified by `sudo -u isales -H git ls-remote
isales-common.git` returning the HEAD SHA.

This unblocks in-place `git pull` for release updates from ECS without
needing to scp from the dev box. (Note: PAT classic = full `repo` scope.
A future tightening would re-issue as fine-grained PAT with Contents:Read
on the 5 repos only.)

Token expiration: 90 days from creation (default; verify before TTL
elapses via GitHub Settings → Developer Settings → Personal access
tokens). When expiring:

```bash
# Replace TOKEN on the next line and run:
printf 'https://tommax-bai:<NEW>@github.com\n' | \
    ssh -i C:/Users/tianx/codes/isales.pem root@121.89.85.150 \
    'tee /opt/isales/.git-credentials > /dev/null && \
     chown isales:isales /opt/isales/.git-credentials && \
     chmod 0600 /opt/isales/.git-credentials'
# Sanity:
ssh ... 'sudo -u isales -H git ls-remote https://github.com/tommax-bai/isales-common.git refs/heads/main'
```

### EDGE_DEVICE_TOKEN for current dev rig

`device_id=edge-01`, TTL 365d (expires ~2027-05-17), minted via:

```bash
ssh ... 'set -a; source /etc/isales/env/api.env; set +a; \
    /opt/isales/current/venv/bin/isales-edge-token-mint \
        --device-id edge-01 --ttl 365d'
```

For local testing, full token sits at the Windows dev box repo path
`isales-telephony/.edge-token-test.jwt` (gitignored by `*.jwt` rule
in `isales-telephony/.gitignore`). For each new edge / device, mint a
fresh token with its own `--device-id`.

## ARTC SDK vendor — where the binaries live

The ARTC SDK is proprietary and **gitignored** in every repo it touches.
Three platform variants, three locations:

| Platform | Used by | Location |
|---|---|---|
| Linux Python wrapper | cloud engine | **ECS**: `/opt/isales/vendor/aliyun-artc-linux-python/` (symlink → `AliRTCSDK_Linux-7.10.2/`). Tarball + extracted dir both kept under `/opt/isales/vendor/`. Not on local Windows dev machine — pulled straight from alicdn to ECS. |
| Windows C++ SDK | edge (Windows client) | (in repo) `isales-telephony/deploy/edge/windows/vendor/aliyun-artc-windows/`. Gitignored. See `deploy/edge/windows/STATE.md` for the dev rig state. |
| macOS framework | edge (Mac mini QA only) | Not downloaded — A2 走 mock，未真实用到 |

Linux Python tarball (137 MiB, sha256 `09564bad835f2296140bc6c9f2d8d4a88e7e940de07cbb0a470b3cd8d5db0e98`)
download direct from alicdn CDN, no auth required:

```
https://alivc-demo-cms.alicdn.com/versionProduct/sdk/linux/AliRTCSDK_Linux-7.10.0-20260109.tar.gz
```

Note the filename says `7.10.0` but the tarball's top-level dir is
`AliRTCSDK_Linux-7.10.2/` — Aliyun marketing tag inconsistent. The 7.10.2
inside is what we use.

The Python wrapper is ctypes-style FFI (4 `.py` files + a `Release/lib/`
with `libAliRtcLinuxEngine.so` (50 MiB), `libonnxruntime.so.1.16.3`
(17 MiB), `AliRtcCoreService` elf). **Not bound to a Python ABI** —
AL3's stock Python 3.6.8 imports all four modules without issue;
`ldd libAliRtcLinuxEngine.so` resolves cleanly against AL3 glibc 2.32.
But the engine itself runs on Python **3.11.13**, not 3.6.8, for the
reasons documented above.

At runtime, callers MUST set `LD_LIBRARY_PATH` to include
`/opt/isales/vendor/aliyun-artc-linux-python/Python/Release/lib` and
pass `AliRtcCoreService` absolute path to `CreateAliRTCEngine(...)`.
(engine.env already has `LD_LIBRARY_PATH=/opt/isales/current/vendor/...`
plus `PYTHONPATH=/opt/isales/current/vendor/.../python` set; the
`/opt/isales/current/vendor/` symlink target is the deploy time vendor
location — verify after each release activation.)

For CI / OSS distribution: A2 task 1.3 plans an OSS private bucket
mirror; not provisioned yet — but given the alicdn URL is unauthenticated,
the OSS mirror is no longer strictly needed (CI can pull direct).
The Windows SDK URL is pinned in
`isales-telephony/deploy/edge/windows/vendor/README.md`.

## OSS / object storage

**Not provisioned in v1.0.** The decision is to use ECS local
filesystem for v1.0 storage needs (recording uploads, opener prerender
PCM). v1.0 worker code doesn't yet exercise `ISALES_OSS_*` envvars, so
this is a no-op decision today; if/when recording upload lands, switch
to either OSS or a larger ECS disk.

## Active OpenSpec changes touching the cloud (status 2026-05-17)

| Change | Status | Cloud impact |
|---|---|---|
| `arch-cloud-edge-split` (A2) | 52/64 tasks (checkboxes); reality: all deploy phases done except §12 e2e MVP gate | This whole snapshot IS A2's data plane |
| `windows-artc-pybind11` | 39/51 tasks; §9.1 + §9.2 ticked 2026-05-17 commit `ed8732e` | Edge-side only |
| `windows-client-core` (D1) | **ARCHIVED 2026-05-17** to `openspec/changes/archive/2026-05-17-windows-client-core/` | Edge-side only |
| `impl-real-at` (A1) | **ARCHIVED 2026-05-17** | Edge-side only |

## Deviations from spec to record at archive time

When A2 is archived, the following deviations must land as `design.md`
notes in the archived `openspec/changes/archive/...` directory:

1. **AL3 vs Ubuntu 22.04** — install.sh not actually adapted to dnf; manual
   port used 2026-05-17 (Steps A-G in the conversation log; reproducible).
2. **Python 3.11 vs 3.12** — install.sh `step_venv` hardcoded `python3.12`
   which AL3 doesn't provide; switched to `python3.11` (still satisfies
   `requires-python = ">=3.11"`).
3. **PG 13 vs PG 16** — schema-compatible; cite "alinux3-updates default" reason.
4. **8C8G vs 4C16G** — half RAM; load-test to confirm; bump if needed.
5. **PG + Redis on the ECS vs managed RDS/Tair** — no HA; cite v1.0 PoC scope.
6. **No OSS** — local filesystem; cite "worker doesn't read OSS_* yet".
7. **No nginx + no domain + no TLS** — v1.0 IP-direct; cite STATE.md
   posture decision.
8. **No isales-web** — admin console deferred; cite same scope decision.
9. **install.sh `ISALES_DOMAIN` hard-require + nginx step** — bypassed by
   running phases manually; the script proper should grow a `--ip-direct`
   mode flag.
10. **Secrets in private repo git** — non-default policy; cite "single
    collaborator + internal PoC" with the README's migration path.

## Next deployment steps (what's still pending)

In rough order. **This list is authoritative for cloud-side punch-list
status — A2 OpenSpec `tasks.md` checkboxes are signed-in progress, not
ground truth.**

1. ~~Mirror `deploy/cloud/env/*.env` to `/etc/isales/env/` on the ECS.~~
   **DONE 2026-05-17**.
2. ~~Adapt `deploy/cloud/scripts/install.sh` for AL3 dnf.~~ **WORKED
   AROUND 2026-05-17** via manual phase-by-phase run; proper script
   adaptation still owed for next clean deploy. Reasonable timing: when
   first OTA upgrade is needed or when standing up a second ECS.
3. ~~Upload ARTC SDK Linux Python tarball.~~ **DONE 2026-05-17**.
4. ~~Clone 5 sibling repos + venvs + alembic + systemd + engine
   `0.0.0.0:50051` bind + security group.~~ **DONE 2026-05-17**.
5. ~~nginx + Let's Encrypt + domain.~~ **DEFERRED to v1.x**.
6. **End-to-end MVP**: scheduler dispatches a fake lead → engine joins
   ARTC channel → edge (Windows) joins same channel → audio flows → AI
   says opener → hang up. **A2 §12 / D1 §9 joint MVP gate.** Sub-gates:
   - ✅ Cloud-edge gRPC control plane (smoke 2026-05-17, see § above)
   - ❌ **pybind §9.4** real ARTC RTC join on Windows edge (needs RTC
     client token signed with AppKey)
   - ❌ **pybind §9.5** real PCM push/pull end-to-end P95 ≤ 50 ms
   - ❌ **AI provider stack ready** — grep `engine.env` for which
     ASR/LLM/TTS provider is wired; if mock, swap to 豆包 / real provider
   - ❌ **PG seed data** — `campaign` + `lead` rows pointing at test
     phone number (e.g. dev's own `13301035545`)
   - ❌ **isales-telephony-edge full daemon on dev box** — pyserial COM12
     (AT) + COM11 (audio SerialPcm) + ARTC pybind + cloud-edge gRPC
     client all wired through `main_windows.py` or `edge/main.py`
7. **isales-web admin console deploy** — deferred until UX needs require it.

## Bootstrap a new dev session — verify before asserting state

A fresh Claude Code session should run these 4 commands (each ~10 s)
before reporting any cloud-side status. Each verifies one layer against
authoritative sources, replacing the "trust the OpenSpec checkbox"
failure mode (see [[feedback-ground-truth-before-pending]] memory).

```powershell
# 1. ECS reachable + 4 services up + ports listen
ssh -i C:/Users/tianx/codes/isales.pem -o ConnectTimeout=8 root@121.89.85.150 `
    'systemctl is-active isales-api isales-engine isales-scheduler isales-worker postgresql redis; \
     echo "---"; ss -tln | grep -E ":50051|:8000"'
# expect: 6 "active" lines + "0.0.0.0:50051" + "0.0.0.0:8000" listeners

# 2. alembic at head + 19 tables
ssh -i C:/Users/tianx/codes/isales.pem root@121.89.85.150 `
    'cd /opt/isales/current/isales-common && set -a && source /etc/isales/env/api.env && set +a && \
     sudo -u isales -H -E env ISALES_DATABASE_URL="$ISALES_DATABASE_URL" \
        /opt/isales/current/venv/bin/alembic current; \
     echo "---"; cd /tmp && sudo -u postgres psql -d isales -tAc \
        "SELECT count(*) FROM pg_tables WHERE schemaname = '\''public'\'';"'
# expect: "580b817550c8 (head)" + "20" (19 tables + alembic_version)

# 3. cloud-edge gRPC reachable from local box
Test-NetConnection -ComputerName 121.89.85.150 -Port 50051 -WarningAction SilentlyContinue | `
    Select-Object ComputerName,RemotePort,TcpTestSucceeded
# expect: TcpTestSucceeded True

# 4. cloud-edge end-to-end smoke (mint fresh token + run smoke)
ssh -i C:/Users/tianx/codes/isales.pem root@121.89.85.150 `
    'set -a; source /etc/isales/env/api.env; set +a; \
     /opt/isales/current/venv/bin/isales-edge-token-mint --device-id edge-test --ttl 1h' `
    > "$env:TEMP\smoke.jwt"
cd C:\Users\tianx\codes\isales-telephony
.\.venv\Scripts\python.exe scripts\cloud_edge_smoke.py `
    --endpoint 121.89.85.150:50051 --token-file "$env:TEMP\smoke.jwt" --timeout 15
# expect: "==> CONNECTED" + "==> Heartbeat sent OK" + "==> done"
```

If ANY of the 4 fails, that is the ground truth — report it and dig in.
**Never** infer cloud state from OpenSpec tasks.md checkbox alone (see
[[feedback-ground-truth-before-pending]] for past regressions and
prevention rules).

## Related state files

- `deploy/edge/windows/STATE.md` — Windows dev rig (Python 3.12, CMake,
  VS BuildTools, ARTC Windows SDK, pybind .pyd, SIM7600G-H modem)
- `archive/2026-05-17-windows-client-core/acceptance.md` — D1 archived
  acceptance log; § "Out-of-scope deferred items" lists §9 joint MVP gates
- `archive/2026-05-17-impl-real-at/acceptance.md` — A1 archived; §3.4
  hangup_cause samples deferred to D1 §9.3 (now joint MVP)
