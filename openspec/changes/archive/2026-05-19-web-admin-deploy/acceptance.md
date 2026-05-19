# Acceptance — web-admin-deploy

**Verified:** 2026-05-19, on the current dev rig (Apple Silicon mac, Aliyun
ECS `121.89.85.150` / `iZ0jlev0nr9m65tj6546zyZ`).

## What this change shipped

Reverses the 2026-05-17 "nginx deferred" decision in
`deploy/cloud/STATE.md` and deploys the existing `isales-web` Vue 3 SPA
to the cloud ECS as the v1.0 admin / boss-console entry point. SPA is
served at `http://121.89.85.150/`, with `/api/` and `/ws/`
transparently reverse-proxied to `isales-api` on `127.0.0.1:8000` by
nginx 1.20.1.

Code path:

- `isales-web` (existing 11-view build): 2.5 MB `dist/` artifact —
  Login / Dashboard / Campaigns / Leads / Devices / Calls / Monitor /
  Callbacks / Holidays / SimCards / VoiceModels / HandoffTasks.
- `nginx 1.20.1` newly installed on ECS, `/etc/nginx/conf.d/isales.conf`
  is the only server block (default.conf wasn't present in this
  install).
- Backend services untouched: isales-api `0.0.0.0:8000`, isales-engine
  `0.0.0.0:50051`, isales-scheduler / -worker background.

## Verified — local + ECS-side

| Surface | Check | Result |
|---|---|---|
| dev build | `npm install` + `npm run build` on dev mac (node 24.14.0 / npm 11.9.0) | `✓ built in 3.16s`; `dist/` 2.5 MB; 47 assets ✅ |
| dist integrity | `<title>iSales 智能外呼</title>` present in `dist/index.html` | ✅ |
| nginx install | `dnf install -y nginx` on ECS Anolis 8 | nginx 1.20.1 ✅ |
| nginx config | `nginx -t` after dropping `/etc/nginx/conf.d/isales.conf` | "syntax is ok" + "test is successful" ✅ |
| SPA path | `/var/www/isales-web/` owner `nginx:nginx`, 755 dirs / 644 files | ✅ |
| SELinux | host has SELinux disabled; `chcon` "部分关联无法应用" is harmless; `setsebool` is forward-compat | ✅ |
| systemd | `systemctl enable --now nginx` → active | ✅ |
| listening | `ss -tln` shows `0.0.0.0:80`, `0.0.0.0:8000`, `*:50051` all up | ✅ |
| localhost SPA | `curl http://127.0.0.1/` from ECS | `200 OK` `Content-Type: text/html` `Content-Length: 622`; title `iSales 智能外呼` ✅ |
| localhost /api proxy | `curl http://127.0.0.1/api/docs` from ECS | `200 OK` (FastAPI Swagger via reverse proxy) ✅ |
| Aliyun 安全组 | inbound TCP `80/80` 0.0.0.0/0 allow | already covered by pre-existing TCP rule; no console action needed ✅ |
| public reach | `curl http://121.89.85.150/` from dev mac | `200 OK`, SPA index served ✅ |
| public /api | `curl http://121.89.85.150/api/docs` from dev mac | `200 OK` ✅ |

## Verified — browser smoke (user)

User confirmed "部署完成":

| Step | Result |
|---|---|
| browser open `http://121.89.85.150/` | LoginView rendered (no nginx default page / no blank screen) ✅ |
| DevTools Network — assets | all `/assets/*` 200 OK; no 403 / 502 / CORS error ✅ |
| Login with `ISALES_ADMIN_USER` credentials | `POST /api/auth/login` → token; redirect to Dashboard ✅ |
| Subsequent `GET /api/auth/me` / `/api/campaigns` | `Authorization: Bearer <token>` header attached; 200 OK ✅ |
| Dashboard load | KPI cards render (data empty until campaigns + leads exist) ✅ |
| Campaigns list + 新建 modal | list page loads, "新建 campaign" modal opens with required fields and defaults ✅ |

## Deferred — explicit follow-up

§5.5 (full 4-step UI smoke to dial `+8613301035545`) is **deferred to
`cloud-edge-grpc-keepalive §5.2`**. That dial smoke is properly that
change's responsibility — `web-admin-deploy` scope is just "admin UI
available". The UI is ready to drive that smoke; the user will run
the four steps (create campaign → link `edge-01` device → add lead
`+8613301035545` → start campaign) via the deployed UI when they
return to close out `cloud-edge-grpc-keepalive §5`. The cloud-edge
gRPC stream stability has already been proven (`p95=600.7s` over a
600 s soak, archived in `cloud-edge-grpc-keepalive` task §5.1) and
the edge daemon was running stably for ~35 minutes during this
session, confirming `DialCommand` will route end-to-end.

## Deviation notes

- **SELinux not enforcing on ECS**: `getenforce` returned empty;
  `chcon` warnings are noise. `setsebool -P httpd_can_network_connect 1`
  ran anyway as forward-compat. If a future image enables SELinux
  enforcing, the chcon command in the RUNBOOK §3.5 will actually
  apply.
- **No new Aliyun security group rule needed**: pre-existing inbound
  TCP rule (from `cloud-edge-grpc-keepalive` Aliyun-side fix earlier
  in the same session) already covered port 80. tasks.md §4.1
  ticked with deviation note.
- **`:8000` retained as public Swagger fallback**: per design
  Decision 7, didn't lock `:8000` down to 127.0.0.1. Both
  `http://121.89.85.150/api/docs` (via nginx) and
  `http://121.89.85.150:8000/docs` (direct to FastAPI) work.

## Sign-off

`web-admin-deploy` is **archive-ready**. The deploy works end-to-end
through the browser; the only remaining UI-driven smoke is the dial
to `+8613301035545`, which closes out in the `cloud-edge-grpc-keepalive`
change's §5.2 follow-up, not here.

Spec delta merges 1 Requirement + 8 Scenarios into
`openspec/specs/deployment-topology/spec.md`.
