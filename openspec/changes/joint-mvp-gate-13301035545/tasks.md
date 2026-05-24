## 1. Pre-flight spot-check (动手前必做)

- [ ] 1.1 Windows dev box: `py -3.12 -c "import aliyun_artc_pywrap; print(dir(aliyun_artc_pywrap))"` 列出 6 个公开符号
- [ ] 1.2 Windows dev box: COM12 AT `pyserial`/`AT\r\n → OK`；COM 号动态认 description 不认数字 (per `project_d1_hardware_rig` memory)
- [ ] 1.3 Windows dev box: `AT+CPCMREG=1` gate + COM11 byte stream 可读 (5 秒 silence read)
- [ ] 1.4 Windows dev box: `scripts/cloud_edge_smoke.py --endpoint 121.89.85.150:50051 --token-file .edge-token-test.jwt --timeout 15` → `==> CONNECTED + Heartbeat OK`
- [ ] 1.5 Windows dev box: SIM7600G-H 联通卡余额查询 `AT+CUSD=1,"#999#"` ≥ 1 元 (避免拨打失败)
<!-- 2026-05-24 ECS 4 服务全 active；journalctl --since "5 minutes ago" 0 error -->
- [x] 1.6 ECS: `systemctl is-active isales-{api,engine,worker,scheduler}` 全 active；journalctl --since "5 minutes ago" 无 error
<!-- 2026-05-24 provider_credential 3 rows: dashscope.api_key + volcengine.app_key + volcengine.app_token (user 在 §5 完成后又手填了 dashscope 测试 key) -->
- [x] 1.7 ECS: `psql -d isales -c "SELECT provider_id, field_name FROM provider_credential"` 含 volcengine.app_key + volcengine.app_token (per impl-provider-credential-db-ssot)
<!-- 2026-05-24 grep engine.env 含 ISALES_RTC_APP_ID + ISALES_RTC_APP_KEY 已设 -->
- [x] 1.8 ECS: `engine.env` 含 `ISALES_RTC_APP_ID=o6dpsan9` + `ISALES_RTC_APP_KEY=c4f5feb...` (per cloud STATE.md)
- [ ] 1.9 临时 `isales-cred-test-llm` 脚本 (dev box): 用 ECS 凭据调一次豆包 `chat()` 真返回内容 (验 LLM 网络通路 + 凭据有效)

## 2. isales-engine RTC token CLI (smoke 用)

<!-- 设计修订 2026-05-24: proto 现状 DialCommand.rtc_token 已就位 (生产 dial 走该字段，engine 用既有 RtcTokenIssuer.sign_for_call 签 token)；不加新 RPC；§9.4/§9.5 smoke 走 ECS CLI 包装。详见 design.md D1 修订版 -->
<!-- 2026-05-24 isales_engine/cli/mint_rtc_token.py 包装 RtcTokenIssuer.sign + ENV_APP_ID/ENV_APP_KEY 校验 + JSON stdout (stderr 走日志) -->
- [x] 2.1 新建 `isales-engine/isales_engine/cli/mint_rtc_token.py` + pyproject `[project.scripts] isales-engine-mint-rtc-token = isales_engine.cli.mint_rtc_token:main`；CLI args: `--channel <name> --user-id <uid> [--ttl 600] [--json]`；内部读 `ISALES_RTC_APP_ID` + `ISALES_RTC_APP_KEY` env → 调 `RtcTokenIssuer.sign()` → 默认 stdout 输出 `{app_id, channel, user_id, nonce, token, expires_at}` JSON
<!-- 2026-05-24 tests/test_cli_mint_rtc_token.py 7 cases (env missing×2 / happy path / TTL default / arg validation×3) 全 passed -->
- [x] 2.2 pytest: `isales-engine/tests/test_cli_mint_rtc_token.py` — env 缺失抛 SystemExit + 提示信息；正常 flow 输出合法 JSON + token 长度 64 (sha256 hex) + expires_at = now + ttl
<!-- 2026-05-24 git bundle scp + git fetch + merge → engine HEAD a200e26；pip install -e refreshed entry point -->
- [x] 2.3 deploy 到 ECS (本机 pip install -e 即可，无需 git bundle scp，因 isales-engine 已在 ECS clone；本 CLI 是新 entry point 需 pip install -e refresh)
<!-- 2026-05-24 ECS CLI 真跑出 JSON token: app_id=o6dpsan9 / channel=smoke-test / user_id=u1 / nonce=AK-NisxoaW0bIktcSf5 / token=a3606f8585...cb91f (sha256 hex 64) / expires_at=1779608254 -->
- [x] 2.4 验证 ECS CLI: `ssh root@121.89.85.150 'sudo -u isales -H -E env $(cat /etc/isales/env/engine.env | grep -v ^# | xargs) /opt/isales/current/venv/bin/isales-engine-mint-rtc-token --channel smoke --user-id u1 --ttl 60 --json'` 输出合法 JSON

## 3. pybind §9.4 真 RTC join smoke

<!-- 2026-05-24 isales-telephony/scripts/pybind_rtc_join_smoke.py 写好 (改用 ssh ECS isales-engine-mint-rtc-token CLI 拿 token 而非 cloud-edge RPC，per design D1 修订)；CLI args: --channel --user-id --duration --ttl --ssh-host --ssh-key；通过判: on_join_channel_result code=0 + 5s 内 + 无 error events -->
- [x] 3.1 新建 `isales-telephony/scripts/pybind_rtc_join_smoke.py`：CLI `--channel smoke-channel-9-4 --duration 5`；内部 ① 走 ssh ECS isales-engine-mint-rtc-token CLI 拿 token；② `EngineHandle.create()`；③ `engine.join_channel(token, channel)`；④ 等 `on_join_channel_result` 回调；⑤ idle `duration` 秒；⑥ `engine.leave_channel()` + `destroy()`；通过条件: code=0 + 无 disconnect event
<!-- 2026-05-24 BLOCKED on pybind binding gap (discovered during real run): Windows pybind 暴露 join_channel(token, channel, uid, name) 4 args，ARTC SDK native 需 5-arg 含 JoinChannelConfig 才接受 join；rc=16974081 native reject。新 change `windows-artc-pybind11-join-config` propose 扩 binding (SetClientRole / PublishLocalAudioStream / JoinChannelConfig type / 5-arg JoinChannel) + 重 build .pyd 后再跑本 §3.2。本次同时确认: extras MUST 是 JSON 含 app_id (空串触发 native silent abort exit 5)；on_join callback 真签名 (result, channel, user_id, elapsed_ms) 4 args。脚本 commit isales-telephony 189f669 -->
- [ ] 3.2 运行该脚本，**验 `on_join_channel_result(code=0)` 出现 5s 内**；不通过查 ARTC vendor SDK 版本 + token 签发逻辑
- [ ] 3.3 把通过证据 (timestamp + channel + duration + result code) 加进 `isales-telephony/deploy/edge/windows/STATE.md § "pybind §9.4 smoke 通过"`

## 4. pybind §9.5 真 PCM push/pull smoke

<!-- 2026-05-24 isales-engine/scripts/ecs_pcm_loopback_listen.py 写好 (用 AliyunRtcSession.production + RtcTokenIssuer.sign 本地签 token + push silence + audio_frames 计数；exit 0 = 收到 ≥1 inbound frame) -->
- [x] 4.1 新建 `isales-engine/scripts/ecs_pcm_loopback_listen.py`：ARTC Linux Python wrapper join `smoke-channel-9-5` → 注册 `on_audio_frame` 回调累计 inbound bytes + 反推 silence PCM；CLI `--channel smoke-channel-9-5 --duration 10`
<!-- 2026-05-24 isales-telephony/scripts/pybind_pcm_loopback_smoke.py 写好 (复用 §3 mint_token_via_ssh + EngineHandle 同 channel join + push silence loop + on_audio_frame 计数 → JSON stats)；vendor pybind 暴露 push_audio_frame 方法名待 hardware 上验证 -->
- [x] 4.2 新建 `isales-telephony/scripts/pybind_pcm_loopback_smoke.py`：edge 端 join 同 channel + push 5s silence (8kHz mono 16-bit) + 等接收 ≥ 1 inbound frame；通过条件: 5s 内至少收到 1 inbound frame
- [ ] 4.3 启动顺序: ECS 端先跑 listen → Windows 端再跑 push (相隔 ≤ 30s)；运行 + 验通过
- [ ] 4.4 把通过证据 (inbound frame count + bytes received) 加进两份 STATE.md

## 5. edge daemon 五件套真启动

- [ ] 5.1 review `isales-telephony/isales_telephony/main_windows.py` 现状 — startup 钩子是否按 D4 design 顺序 (env → token → gRPC → modem AT → SerialPcm → ARTC .pyd → tray active → asyncio task group)；缺失部分补齐
- [ ] 5.2 测 daemon 启动: `py -3.12 -m isales_telephony.main_windows`；预期 tray icon 1 秒内显示，10 秒内绿色 (cloud-edge 连 + modem registered)；log 含 `modem_registered` / `grpc_connected` / `artc_loaded` 三条 INFO line
- [ ] 5.3 启动失败 troubleshoot: ① PYTHONPATH 含 pybind .pyd 目录；② vendor DLL 在 .pyd 同目录或 PATH；③ `.edge-token-test.jwt` 路径正确；④ COM12/COM11 description 匹配 (memory `project_d1_hardware_rig`)
- [ ] 5.4 把通过证据 (tray screenshot + log excerpt) 加进 windows STATE.md § "edge daemon 五件套真启动"

## 6. PG seed + UI prompt 配置

- [ ] 6.1 ECS psql 直接 INSERT 1 campaign (`name='MVP test', concurrency=1, time_windows='[{"start":"00:00","end":"23:59","days":[1,2,3,4,5,6,7]}]'`, 其他必填字段查 data-model spec 设合理 default)
- [ ] 6.2 psql 验证: `SELECT id, name, concurrency, time_windows FROM campaign WHERE name='MVP test'` 返回 1 行
- [ ] 6.3 UI 走 `/operations/campaigns` 进入「MVP test」详情 → 用 PromptTierEditor 加 1 个 role tier (model=doubao-pro-32k / temperature=0.7 / prompt 内容 "您好，这里是 iSales 测试，我能帮您什么吗?") + enable
- [ ] 6.4 ECS psql: 验 `role_config` + `prompt_version` 两表各 1 行 (campaign_id = MVP test.id, kind=role, current_prompt_version_id 非空)
- [ ] 6.5 UI 加 1 个 lead: `LeadEditDialog` 选 campaign=MVP test + phone=+8613301035545 + name="MVP test"
- [ ] 6.6 ECS psql 验 `SELECT id, campaign_id, phone, status, next_call_at FROM lead WHERE phone='+8613301035545'` → status=new + next_call_at IS NULL (符合 retry-followup spec `next_call_at IS NULL` 视为立即可呼)

## 7. 真拨号闭环

<!-- 2026-05-24 isales-telephony/scripts/joint_mvp_dial.py 写好 (6 step: preflight / start daemon subprocess / wait daemon log 3 needles / curl campaign start with ISALES_ADMIN_TOKEN env / poll call_record by lead_id with ssh+psql / 人耳 input yes/no → emit STATE.md evidence markdown)；--dry-run 跳后 3 step -->
- [x] 7.1 新建 `isales-telephony/scripts/joint_mvp_dial.py` CLI: `--phone +8613301035545 --campaign-id <id> --lead-id <id> --timeout 60 [--dry-run]`；内部步骤: ① pre-flight (call task 1.* 5 step)；② 启 edge daemon (后台 process)；③ 等 daemon log `modem_registered` + `grpc_connected` + `artc_loaded`；④ ECS curl `POST /api/campaigns/{id}/start` 用 ISALES_ADMIN_TOKEN env；⑤ ssh+psql 轮询 call_record by lead_id；⑥ 验 transcript[0] 含 AI 开场白文本 → 人耳 input yes/no；⑦ emit STATE.md evidence markdown
- [ ] 7.2 真跑该脚本，**接听自己手机听 AI 开场白**。若听到 → 标 §7 通过；听不到 → debug
- [ ] 7.3 debug 路径: ① modem 接通但无声 → COM11 SerialPcm 路由错；② 接通有杂音 → PCM codec mismatch (8kHz/16bit/mono confirm)；③ 接通后立挂断 → engine 异常，查 journalctl；④ 完全没拨出 → AT command 失败 / 余额 / 信号
- [ ] 7.4 拨通成功后: psql 查 call_record 行 — 记 id / duration / status / hangup_cause；transcript[0] 文本 (AI 开场白)
- [ ] 7.5 录音 (可选): user 手机录或直接电话录音；存到 dev box 本地 (gitignored)

## 8. STATE.md + acceptance

- [ ] 8.1 `isales-telephony/deploy/edge/windows/STATE.md` 加 § "MVP gate 证据" 块：call_record.id / 拨号号码 / 时长 / transcript[0] / "AI 开场白是否听到 yes/no" (必须 yes 才进下一步)
- [ ] 8.2 `deploy/cloud/STATE.md` 加 § "MVP gate 证据" 块 (同上信息)
- [ ] 8.3 grep 确认无 mock 残留: ECS engine.env `ISALES_ENGINE_LLM_PROVIDER=volcengine` (非 mock)；`ISALES_ENGINE_ASR_PROVIDER=volcengine`；`ISALES_ENGINE_TTS_PROVIDER=volcengine`
- [ ] 8.4 `openspec validate joint-mvp-gate-13301035545 --strict` 通过
- [ ] 8.5 `openspec validate --specs && --changes` 全绿
- [ ] 8.6 写 `acceptance.md` (verified local + verified cloud + 真拨通号码 / transcript[0] / 是否听到 yes/no + 关联 archived A2 §12 + D1 §9)
- [ ] 8.7 commit + push 各 sub-repo (proto / engine / telephony) + meta-repo
- [ ] 8.8 `openspec archive joint-mvp-gate-13301035545 --yes` (**hard gate: AI 开场白必须真听到才能 archive**)
