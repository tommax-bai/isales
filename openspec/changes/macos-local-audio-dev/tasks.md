> **2026-05-18 SUPERSEDED — DO NOT IMPLEMENT.** 取代者
> [`macos-artc-pyobjc-binding`](../macos-artc-pyobjc-binding/tasks.md) 已 active +
> 实施落地。下列 task 列表**不要执行**；保留作思路记录。详见
> [`proposal.md`](./proposal.md) 顶部 SUPERSEDED 块。

## 1. 依赖与脚手架

- [ ] 1.1 在 `isales-telephony/pyproject.toml` `[project.optional-dependencies]` 新增 `dev-mac-audio = ["sounddevice>=0.4.6", "numpy>=1.26"]`；**不**碰 `dependencies` 主列表
- [ ] 1.2 验证 `pip install -e '.[dev,dev-mac-audio]'` 在 mac Apple Silicon 与 Intel mac 均可装上（PortAudio 通过 `brew install portaudio` 提供）
- [ ] 1.3 验证 `pip install -e '.[dev]'`（不带 `dev-mac-audio`）后 `import isales_telephony.audio_bridge` 不触发 sounddevice import；现有 unit-test 全绿
- [ ] 1.4 (meta-repo) 验证 `make spec-validate` 通过 `openspec validate --specs && --changes`（确认 device-hardware / deployment-topology delta 语法 OK）
- [ ] 1.5 (meta-repo) 跑 `openspec validate macos-local-audio-dev --strict` 确认 spec delta 与 design / proposal 一致

## 2. `MacosLocalAudioRtcSession` 实装（核心）

- [ ] 2.1 在 `isales-telephony/isales_telephony/audio_bridge/` 新建 `macos_local_audio_session.py`；定义 `class MacosLocalAudioRtcSession(RtcSession)`，从 `isales_common.audio.rtc` import ABC
- [ ] 2.2 实施 `__init__(self, *, input_device=None, output_device=None)`：参数透传 sounddevice 的 device 选择；sounddevice 用 lazy import，未装时 ImportError 给明确提示 "pip install -e '.[dev-mac-audio]' first"
- [ ] 2.3 实施 `async def join(self, channel, token, uid)`：开 `sd.InputStream(samplerate=16000, channels=1, dtype='int16', blocksize=320, device=input_device, callback=_capture_cb)` 和 `sd.OutputStream(...)`；channel / token / uid 仅打印日志，不验证；启动 WARN log 提示戴耳机
- [ ] 2.4 实施 `_capture_cb`：把 PortAudio 给的 numpy int16 16k mono 20ms 帧（320 samples）转 `PcmFrame` 入 asyncio Queue（threadsafe via `loop.call_soon_threadsafe`）
- [ ] 2.5 实施 `def audio_frames(self) -> AsyncIterator[PcmFrame]`：drainer task 从 Queue 出帧 yield；leave 时 yield 终止
- [ ] 2.6 实施 `async def push_audio(self, pcm, *, timestamp_ms)`：把 PCM bytes 转 numpy int16 写入 `OutputStream`；OutputStream 写入接口非 async — 走 `loop.run_in_executor` 包一层避免阻塞 event loop
- [ ] 2.7 实施 `def is_joined(self) -> bool` 与 `async def leave(self)`：stop / close 两个 stream + 终止 drainer；二次 leave 幂等
- [ ] 2.8 单元测试 `tests/audio_bridge/test_macos_local_audio_session.py`：mock sounddevice（不真开设备），验证 join/leave 幂等 / audio_frames 形状 / push_audio 不阻塞 event loop / lazy import / channel-token-uid 不验证 / 多次 join fail-fast
- [ ] 2.9 集成 smoke（手工跑 + 记一个 README 注脚，不进 CI）：在 mac 上戴耳机真开 stream，对着 mic 说话 5 秒，println 显示 audio_frames yield 数量与时长一致；push_audio 把测试 sine 波放出来听得到

## 3. session 工厂选择 + CLI flag 接入

- [ ] 3.1 修改 `isales-telephony/isales_telephony/audio_bridge/__init__.py::get_default_rtc_session_class()` 签名加 `dev_no_modem: bool = False` 参数；`dev_no_modem and sys.platform == "darwin"` → 返回 `MacosLocalAudioRtcSession`；其他保留既有 `sys.platform` 默认逻辑（不传 flag 完全向后兼容）
- [ ] 3.2 modify `isales-telephony/isales_telephony/edge/main.py`：argparse 增加顶层 flag `--dev-no-modem` / `--dev-channel <name>` / `--dev-uid <id>` / `--dev-peer-uid <id>` / `--dev-input-device <name|idx>` / `--dev-output-device <name|idx>` / subcommand `--list-audio-devices`
- [ ] 3.3 实施 `--list-audio-devices` subcommand：调 `sounddevice.query_devices()` 打印一张 device 表（idx / name / max_input_channels / max_output_channels / default_samplerate），退出
- [ ] 3.4 在 `main.py` 启动序列中：`--dev-no-modem` 且 `sys.platform != "darwin"` → fail-fast，print 错误 "dev-no-modem mode is macOS-only; use Windows real ARTC path on this platform"
- [ ] 3.5 单元测试 `tests/edge/test_main_cli.py`：argparse flag 解析正确 / 平台守护 / --list-audio-devices 走 sounddevice mock 路径

## 4. `EdgeOrchestrator` dev-no-modem 分支

- [ ] 4.1 修改 `isales-telephony/isales_telephony/edge/orchestrator.py`：`EdgeOrchestrator.__init__` 增加 `dev_no_modem: bool = False` + dev params kwargs
- [ ] 4.2 `EdgeOrchestrator.start()` 检测 dev mode：跳过 `SerialATClient` 实例化 / 跳过 USB watcher 起动 / 跳过任何 AT 命令；仍正常起 cloud-edge grpc_client + AudioBridge
- [ ] 4.3 dev mode 下，收到 cloud-side `Cloud2Edge.dial` 时（或 dev params 指定 self-initiated mode），直接构造 `CallSession(channel=dev_channel, uid=dev_uid, state="connected", peer_uid=dev_peer_uid or "engine")` 并按既有"on connected"路径走 `AudioBridge.join(...)` → capture/playback pumps
- [ ] 4.4 dev mode teardown：注册 SIGINT / SIGTERM handler，触发时给 cloud-edge grpc 发 `Edge2Cloud.remote_hangup{call_id, hangup_cause="dev_terminate"}` → `AudioBridge.leave()` → 退出进程
- [ ] 4.5 单元测试 `tests/edge/test_orchestrator_dev_mode.py`：dev mode 下不实例化 SerialATClient / 不发 AT 命令；dial → AudioBridge.join 路径触发；SIGINT → remote_hangup 发出 + leave 调用
- [ ] 4.6 回归测试：跑全套既有 `tests/edge/test_orchestrator.py` 确认非-dev-mode 路径零回归

## 5. `dev-recipes.md` 文档

- [ ] 5.1 创建 `isales-telephony/deploy/edge/macos/dev-recipes.md`，开篇第一段明确"本文档描述 macOS dev-no-modem 形态，仅用于策略 / 工程闭环演练；不进入 v1.0 商用形态；商用是 Windows + 真 GSM modem + 真 ARTC，看 `deploy/edge/windows/STATE.md`"
- [ ] 5.2 写"前置依赖"节：`brew install portaudio` + `pip install -e '.[dev,dev-mac-audio]'` + 验证 `isales-telephony-edge --list-audio-devices` 能打印 device 表
- [ ] 5.3 写"强制戴耳机"节：解释 mic 收 speaker TTS 会回灌 / barge-in 误触 / ASR 失真；推荐有线耳机 > 蓝牙耳机（蓝牙延迟会影响 barge-in 调参）
- [ ] 5.4 写"一行启动"节：cloud-side engine 怎么起（指向真 cloud `121.89.85.150` 还是 dev 本机），edge 一行命令 `isales-telephony-edge --cloud-endpoint <ip:port> --edge-token-file <jwt> --dev-no-modem --dev-channel demo-001 --dev-uid mac-dev-01`
- [ ] 5.5 写"barge-in 演练 step-by-step"节：先静音 speaker 跑一次（基线）→ 戴耳机跑一次 → 故意打断 AI 说话 → 看 engine log 里 barge-in event 时间戳 / VAD active duration / TTS cancel 路径
- [ ] 5.6 写"与商用契约的边界"节：声明本 recipe 测出的延迟 / barge-in / VAD 行为 MUST NOT 直接外推到 Windows + 真 RTC + 真 modem；引用 deployment-topology spec 中对应 Scenario

## 6. 收尾与归档准备

- [ ] 6.1 跑 `make test-all`（meta-repo）确认 7 个 sub-repo + isales-web 测试全绿 / 受影响的 isales-telephony 测试全部通过
- [ ] 6.2 跑 `openspec validate macos-local-audio-dev --strict` 全部 0 warning
- [ ] 6.3 commit 拆分：(a) isales-telephony PR：`MacosLocalAudioRtcSession` + 工厂 + CLI + orchestrator + tests + recipe 文档；(b) meta-repo commit：tasks.md 进度回写 + spec delta lock-in
- [ ] 6.4 PR review 通过后 push 两个仓库 origin/main；meta-repo tasks.md 内联 `<!-- commit-sha PR# -->` 注释标完成度
- [ ] 6.5 archive 准备：写 `openspec/changes/macos-local-audio-dev/acceptance.md`（手工 smoke 结果摘要 + 已知 trade-offs 列表 + dev-recipes.md 链接），跑 `openspec archive macos-local-audio-dev`，spec delta 合进 `openspec/specs/device-hardware/spec.md` 与 `openspec/specs/deployment-topology/spec.md`
- [ ] 6.6 archive 后更新 memory：在 `project_a2_progress.md` 或新建 `project_macos_dev_path.md` 记录 dev 工作流；MEMORY.md index 同步
