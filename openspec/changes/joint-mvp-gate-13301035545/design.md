## Context

整个 iSales 平台代码已就位:

- ECS `121.89.85.150` 4 服务 active (api / engine / scheduler / worker)
  + alembic head b2c3d4e5f6a7 + provider 凭据 DB SSOT 通过
- cloud-edge gRPC 控制面 smoke verified (2026-05-17)
- Windows dev box `C:\Users\tianx\codes\isales-telephony` 有 SIM7600G-H
  modem 插 USB (信号满格联通)：COM12 AT / COM11 audio (动态认 description
  不认 number — 见 memory `project_d1_hardware_rig`)
- ARTC pybind binding `.pyd` build 通过 (`aliyun_artc_pywrap.
  cp312-win_amd64.pyd` 258KB + 5 vendor DLL + 6 公开符号)

但 **没有任何一次端到端拨号闭环**:

- pybind §9.4 真 RTC join 没跑 (缺 client token 签发链路 + 实测回调)
- pybind §9.5 真 PCM push/pull 没测 (无 channel 两端同时活)
- `main_windows.py` 框架就位但**进程从未启动过**——五件套
  (COM12 AT + COM11 SerialPcm + ARTC .pyd + cloud-edge gRPC + JWT token)
  没有一次性串通跑过
- A2 §12.2 "拨自己手机听 AI 开场白" 等同未通过

constraint:
- dev 自己只有这一台 Windows，一根 SIM7600G-H，一张联通卡，一个手机
  号 (13301035545) — 不能并行 fan-out，单实例闭环验证
- ECS 的 RTC AppKey 不能漂到 edge (cloud-only 设计)；edge 用 token 是
  ECS engine 用 AppKey 签发的短期 token
- ARTC Linux SDK 装在 ECS `/opt/isales/vendor/aliyun-artc-linux-python/`
  (per memory `reference_vendor_sdk_paths`)
- 拨号触发链是 scheduler poll DB → push Redis `engine:dial` queue →
  engine consume → RtcTelephonyClient.dial → DialCommand via gRPC → edge
  接收 → modem 实拨 + ARTC 接听
- v1.0 部署 posture: IP-direct (`121.89.85.150`)，无 TLS / 无域名
  (per `deploy/cloud/STATE.md`)

## Goals / Non-Goals

**Goals:**
- pybind §9.4 真 RTC join 通过 — Windows edge 用 ARTC Python wrapper 真
  join 一个测试 RTC 房间，看到 `on_join_channel_result(code=0)` 回调
- pybind §9.5 真 PCM 双向通过 — edge push silence PCM → ECS engine pull
  到；engine push silence → edge pull 到。延迟测量留下次（本 change 只
  验通路，不卡 P95 ≤ 50 ms gate；过了更好，不过也算通）
- `main_windows.py` daemon 真启动跑通五件套——tray 看到 modem online +
  COM 通道 active + gRPC connected + 凭据载入完成
- ECS 上 `mint_rtc_token` 路径就位 — edge 通过 cloud-edge gRPC 拿到 RTC
  client token (AppKey 不漂边缘)
- 一键拨号脚本 `joint_mvp_dial.py` 跑通: scheduler push lead → engine
  接 ARTC → edge 接同房间 → SIM7600G-H 实拨 13301035545 → 接通 → AI 念
  开场白 → 听到 → 挂断 → call_record + transcript 落库
- STATE.md (两份) 记录 MVP gate 通过证据 — call_record.id + transcript[0]
  + duration_s + "is AI opener heard yes/no"

**Non-Goals:**
- **不**测 P50/P95 latency (A2 §12.3 留下次)
- **不**做故障注入 (A2 §12.4 留下次)
- **不**100 seats 压测 (A2 §12.5 留下次)
- **不**做 PyInstaller frozen-exe 打包 (pybind §9.3 留下次，需干净 Win
  PC)
- **不**做多租户/多 edge_device 表 (C2 范围)
- **不**碰 ARTC AppKey 存放位置 (engine.env 不变，cloud-only 设计)
- **不**改 AI provider 实装 (volcengine 已实装并装载凭据；本 change
  仅验证整链路用 volcengine 真接)

## Decisions

### D1: RTC client token 签发 — 生产走 DialCommand，smoke 走 ECS CLI

**生产 dial 流程**: proto 现状已就位 — `cloud_edge_pb2.DialCommand.rtc_token`
字段 (line 134)。engine 在 push DialCommand 之前用既有 `RtcTokenIssuer.
sign_for_call(call_id)` 签 token，随 DialCommand 一起下发；edge 端
ARTC.JoinChannel 直接用。本 change 不改 proto，不需要新 RPC。

**§9.4 / §9.5 smoke 需要 token 但没有 dial 流程触发**: 用一个 ECS-side
CLI `isales-engine-mint-rtc-token --channel X --user-id Y --ttl 600`
包装既有 `RtcTokenIssuer.sign()`，输出 JSON token。smoke 脚本通过 ssh
跑 CLI 拿 token，AppKey 不离 ECS。比加 proto RPC 简单一个数量级。

**Alternatives:**
- ① 加 cloud-edge unary RPC `MintRtcToken` — **原 proposal 方向，拒绝**。
  proto + grpc_pb2 + handler + client 重生成的代价 vs 一个 ECS CLI 包装：
  CLI 完胜。生产路径 DialCommand 已携带 token，新 RPC 没有除 smoke 之外
  的真用户。
- ② edge 通过 isales-api HTTPS endpoint 拿 token — 多一条网络路径 + JWT
  鉴权 wiring；同样仅 smoke 用，不值得。
- ③ 把 AppKey 复制到 edge — 拒绝。AppKey 是 cloud secret，禁止越线。

### D2: pybind §9.4 smoke 用 isolated channel，不复用 dial 流程

§9.4 测的是 "pybind 真能 join 一个 RTC 房间" — 与拨号链路解耦更易调
试。`scripts/pybind_rtc_join_smoke.py` 直接调:

```python
token = mint_token_via_grpc(channel="smoke-channel-9-4")
engine = EngineHandle.create()
engine.join_channel(token, "smoke-channel-9-4")
# wait on_join_channel_result(code=0)
# wait 5s
engine.leave_channel()
engine.destroy()
```

通过条件: callback `code=0` + 5s 内无 disconnect 事件 + clean leave。

**Alternatives:**
- 用 dial 流程同步测 §9.4 — 拒绝。两层耦合，调试不清。

### D3: pybind §9.5 smoke ECS engine 侧用 ARTC Linux Python wrapper 直 join 同房间

§9.5 测 PCM 双向通过，ECS engine 端需要也 join 同一 channel。设计:

- edge 端 `pybind_pcm_loopback_smoke.py`: join channel "smoke-channel-9-5"
  → push 5s silence (8kHz mono 16-bit) → 等 ECS 端发回的 PCM → leave
- ECS 端临时脚本 `scripts/ecs_pcm_loopback_listen.py` (新): 用 ARTC
  Linux Python wrapper join 同房间 → on_audio_frame 回调累计 + 反 push
  → leave

启动顺序: ECS 端脚本先跑监听 → edge 端再跑 push。

通过条件: edge 端在 5s 内收到至少一个 inbound PCM frame (silence or
echo)。延迟测量本 change 不卡 — 收到一帧就算通。

**Alternatives:**
- ECS engine 进程本身就监听 — 耦合主进程。临时脚本更干净。

### D4: edge daemon 启动序列

`main_windows.py` 入口已有，需要确认串联以下顺序:

1. 读 `%APPDATA%\isales\env\telephony.env` (或 dev box 用
   `isales-telephony/.env-dev`)
2. 加载 `.edge-token-test.jwt` (per STATE.md, edge-01, TTL 365d)
3. 启 cloud-edge gRPC client → 等 CONNECTED + token verified
4. 启 modem-controller AT loop (COM12) → 等 modem registered
5. 启 SerialPcm loop (COM11) → idle
6. 加载 ARTC pybind .pyd (无 RTC join，等 DialCommand 到来再 join)
7. Tray icon green = 一切 active
8. asyncio task group 监听 DialCommand → 触发 RTC join + 拨号

`joint_mvp_dial.py` CLI 启 daemon 前先 health-check 然后 sleep 直到
所有 step 通过 (timeout 60s)。

### D5: PG seed 一行 SQL，不写 CLI

Seed 数据极小 (1 campaign + 1 lead)；写 CLI overkill。直接给 RUNBOOK
一段 SQL 模板，运维 (或 dev) psql 一行执行:

```sql
INSERT INTO campaign (name, concurrency, default_replies, time_windows,
  retry_intervals, retry_max_count, follow_up_interval_days,
  follow_up_max_count, voice_id, ...其他必填字段)
VALUES ('MVP test', 1, '[]', '[{"start":"00:00","end":"23:59","days":[1,2,3,4,5,6,7]}]',
  '[]', 0, 0, 0, NULL, ...);

INSERT INTO lead (campaign_id, phone, name, source, status, ...)
VALUES (<campaign-id>, '+8613301035545', 'MVP test', 'mvp-gate',
  'new', ...);
```

加 role_config + prompt_version 用 `/api/role-configs` + `/api/prompt-versions`
通过 UI / curl 创建 (因为这些有 Pydantic 验证 + 关系约束，UI/API 比 SQL
更稳)。

**Alternatives:**
- 写 `isales-seed-mvp` CLI — overkill for 一次性 seed。

### D6: STATE.md 通过证据格式

两份 STATE.md (cloud + windows-edge) 各加一段「MVP gate 证据」:

```markdown
## MVP gate 证据 (joint-mvp-gate-13301035545, <date>)

- call_record.id: <int>
- 拨号号码: +86 13301035545
- 时长: <duration_s>
- transcript[0] (AI 开场白): "<text>"
- AI 开场白是否听到: yes/no (人耳)
- 录音文件 (可选): <path | null>
- pybind §9.4 join code=0: yes
- pybind §9.5 PCM 双向收到 frame: yes
```

通过条件硬约束: "AI 开场白是否听到: yes" 必须为 yes 才算 MVP gate 通过。
不通过 = STATE.md 不写证据 + tasks.md `8.X` 不 tick + change 不归档。

## Risks / Trade-offs

- **[Risk] ARTC vendor SDK 版本 mismatch** — Windows pybind 是 ARTC
  Windows SDK 7.x build；ECS 是 ARTC Linux Python wrapper 7.10.2。两端
  版本不一致可能导致 frame format / codec 不通。**Mitigation**: §9.5
  smoke 先验通路；若收不到 frame 立即对版本 + 报阿里工单。
- **[Risk] SIM7600G-H 拨打能力 / 联通卡可拨打** — 上次 modem 用是用
  `AT+CCID` 自检；真拨打 `ATD+8613...;` 未实测。**Mitigation**: 先脱
  离 ARTC 单独跑 `ATD` 命令验 modem + 卡能拨 (`AT response: CONNECT`
  或 `NO CARRIER` 等)；通过再加 ARTC。
- **[Risk] 接通后 PCM 路由不顺 / 没声音** — SIM7600G-H 的 PCM 在 COM11
  Class=Ports 不是 USB Audio Class，需要 `AT+CPCMREG=1` gate +
  `pyserial` byte stream 处理 (见 windows STATE.md 注释)。本 change
  实测时若 PCM 通路出错，debug 走 windows STATE.md § Hardware rig。
- **[Risk] AI 开场白 LLM 调失败 / 超时** — engine startup 装载凭据 OK
  但运行时调豆包 LLM 可能 rate limit / 余额不足。**Mitigation**: 拨
  号前 dry-run 测一次 LLM `chat()` 通过 (用 `isales-cred-test-llm` 临
  时脚本)；本 change 加该脚本。
- **[Trade-off] 不测 latency / 不压测** — 拨通 ≠ 商业可用，但能不能
  拨通是先决条件。Latency / 压测 / 故障注入留下次 change，分而治之。
- **[Risk] 拨打骚扰自己** — 13301035545 是 dev 自己手机，可控。但实
  测多次拨号会被骚扰，dev 同意。
- **[Risk] 真拨打费用** — 联通 SIM 卡需要有余额。**Mitigation**: 拨
  打前 `AT+CUSD=1,"#999#"` 查余额；不足充值。

## Migration Plan

1. **Pre-flight on Windows dev box** (动手前 spot-check, per memory
   `feedback_check_hardware_first`):
   - COM12 `AT\r\n` → `OK`
   - COM11 PCM byte stream gated by `AT+CPCMREG=1`
   - `aliyun_artc_pywrap` import 通
   - cloud-edge gRPC smoke (`scripts/cloud_edge_smoke.py`) → CONNECTED
   - SIM 余额够拨

2. **MintRtcToken endpoint 上线** (cloud-edge gRPC + isales-api 侧):
   - cloud-edge proto 加 `MintRtcToken` RPC
   - engine 实装签发 (用 `ISALES_RTC_APP_KEY` + ARTC Python token gen)
   - edge gRPC client 加 `mint_rtc_token(channel_id)` 客户端
   - 部署到 ECS

3. **pybind §9.4 smoke**:
   - 跑 `scripts/pybind_rtc_join_smoke.py --channel smoke-channel-9-4`
   - 期望: `on_join_channel_result(code=0)` 5s 内出现 + clean leave

4. **pybind §9.5 smoke**:
   - ECS 启 `scripts/ecs_pcm_loopback_listen.py --channel smoke-channel-9-5`
   - Windows 跑 `scripts/pybind_pcm_loopback_smoke.py --channel smoke-channel-9-5`
   - 期望: 双向至少 1 inbound frame

5. **PG seed**: psql 一行 INSERT campaign + lead；UI 加 role_config +
   prompt_version

6. **edge daemon up**: `python isales_telephony.main_windows`；tray 看
   到 green + log 含 `modem_registered` + `grpc_connected` + `artc_loaded`

7. **真拨号闭环** `scripts/joint_mvp_dial.py --phone +8613301035545
   --campaign-id <id>`:
   - 启 daemon → 等连云 → 触发 scheduler → 接 RTC → modem 拨
   - 听 13301035545 是否响铃
   - 接听后听 AI 开场白
   - 验 call_record + transcript

8. **STATE.md** (两份) 写证据 + tasks.md 钉对应 task 通过

9. **Archive** — 听到 AI 开场白才能 archive；没听到 = 不通过 = 留 change
   active 继续 debug。

## Open Questions

1. **MintRtcToken RPC 放在 cloud-edge proto 哪一层？** 当前 cloud-edge
   proto 是单向 stream (engine → edge DialCommand / edge → engine
   Heartbeat & HardwareAlert)。MintRtcToken 是 edge initiate 的请求 —
   要么加一个独立 unary RPC，要么用 EdgeMessage 加 `MintRtcTokenRequest`
   variant + 等 engine 回 `MintRtcTokenResponse` over stream。**默认决
   策**: 加独立 unary RPC `MintRtcToken(MintRtcTokenRequest) returns
   (MintRtcTokenResponse)`，更清晰 + 不污染 bidi stream。RESOLVED in
   apply phase.
2. **role_config prompt 多长才合适?** "您好，这里是 iSales 测试" 够不
   够？还是更长 ("您好，我是 iSales 客服小张，了解到您最近...")？**默
   认决策**: 起步用最短 1 句，听见即过 — 拨通后再加长。
3. **录音存哪？** call_record.recording_url 当前未实装。**默认决策**:
   本 change 不存录音；MVP gate 只依赖人耳 + transcript[0] 文本。录音
   留 worker 后续 change。
4. **ECS 端 PCM loopback 监听脚本属于哪个仓?** Linux 用 ARTC Python
   wrapper，写在 `isales-engine/scripts/` 还是 `isales-common/scripts/`?
   **默认决策**: 放 `isales-engine/scripts/` (与 engine 现有 ARTC 代
   码同仓，引用方便)。
