<!-- All telephony-side work landed in isales-telephony commit 4c7d3d1. -->

## 1. Recorder 滚动保留

- [x] 1.1 在 `isales_telephony/modem_controller/recorder.py` 新增 `Recorder.prune(keep: int)`：列出 `RECORDINGS_DIR` 下 `*.wav`，按 mtime 降序，删除第 `keep` 个之后的旧文件；`keep<=0` 时为 no-op（禁用录音由调用方在 begin_call 前判断）
  <!-- 4c7d3d1 recorder.py: prune() sorts *.wav by mtime desc, unlinks wavs[keep:]; keep<=0 returns early (must NOT wipe dir). -->
- [x] 1.2 更新 `recorder.py` 模块 docstring 与 `RedisRecordingQueue` docstring：去掉"挂断后 push worker 上传 OSS"的现行描述，改注"v1.0 纯本地滚动保留；`RedisRecordingQueue` 为 v1.x OSS 路径预留，本路不调用"
  <!-- 4c7d3d1 module docstring → edge-local rolling model; RedisRecordingQueue docstring marked v1.x-reserved with removal trigger. -->
- [x] 1.3 为 `prune` 写单测：写 N+2 个 wav（错开 mtime）→ `prune(keep=N)` → 断言只剩最近 N 个、删的是最旧的
  <!-- 4c7d3d1 tests/test_modem_recorder.py: keeps_only_newest_n / deletes_strictly_oldest_by_mtime / noop_under_limit / keep_zero_is_noop_does_not_wipe. os.utime stamps deterministic mtimes. -->

## 2. 配置

- [x] 2.1 modem-controller 配置新增 `RECORDINGS_DIR`（录音落盘目录）与 `MAX_RECORDINGS`（默认 10，0=禁用录音）；接入现有 config / settings 加载路径
  <!-- 4c7d3d1 偏离：env 走 edge daemon 入口而非 modem-controller daemon —— 云-边拆分后真实音频路径在 edge AudioBridge，modem-controller main.py 不 wire 音频。env 名加 ISALES_EDGE_ 前缀对齐仓库约定：ISALES_EDGE_RECORDINGS_DIR / ISALES_EDGE_MAX_RECORDINGS(默认10,0=禁用) / ISALES_EDGE_RECORDING_MIN_FREE_GB(默认1)。helper _build_recorder() in edge/main.py，main_windows.py 复用。 -->
- [x] 2.2 edge env 模板 + isales-telephony README「Environment」段补 `RECORDINGS_DIR` / `MAX_RECORDINGS`；跑 `make deploy-check` 确认 env-template ↔ README 一致
  <!-- 4c7d3d1 deploy/edge/windows/env.example.txt 补 3 个 opt-in 变量(含 LOCAL-only/无云上传/机器坏即丢 警示)。README 偏离：未动 isales-telephony/README.md —— deploy-check 只比对 modem-controller.env.example ↔ README，录音是 edge-daemon 变量不在该对内；加进 README 反而会造新失配。deploy-check 现存失败(ISALES_ALLOW_MOCK_AT/ISALES_MODEM_DRIVER)经 stash 验证为预存、与本 change 无关。 -->

## 3. 接线通话生命周期

- [x] 3.1 定位 modem-controller 主流程中通话建立 / 双向音频流转 / 挂断三处 hook 点（用户上行 PCM 与 AI 下行 PCM 各在何处可取到 16k）
  <!-- 4c7d3d1 真实路径不在 modem-controller 而在 edge：AudioBridge(audio_bridge/bridge.py) 一通一实例，_upstream_loop 的 resampled=用户 16k、_downstream_loop 的 frame.pcm=AI 16k(降采前)；生命周期在 EdgeOrchestrator._handle_connected(建)/_CallContext.teardown(拆)。 -->
- [x] 3.2 通话建立：实例化 / 复用 `Recorder(RECORDINGS_DIR, min_free_gb=...)`，`MAX_RECORDINGS>0` 时调 `begin_call(call_id)`；捕获 `DiskFullError` → 记结构化 warning（free / 阈值）并跳过本通录音，通话继续
  <!-- 4c7d3d1 orchestrator._handle_connected: 单实例 Recorder 经 ctor 注入；begin_call 在建 bridge 前，DiskFullError → logger.warning(recording_skipped_disk_full) + 不录(record_recorder=None)，通话继续。 -->
- [x] 3.3 音频 loop：用户上行帧调 `append_user(call_id, pcm_16k)`，AI 下行帧调 `append_ai(call_id, pcm_16k)`
  <!-- 4c7d3d1 AudioBridge: upstream loop append_user(resampled/16k)；downstream loop append_ai(frame.pcm/16k，降采前以对齐)。begin/finalize/prune 由 orchestrator，append 由 bridge(PCM 只在此)。 -->
- [x] 3.4 挂断收尾：调 `finalize(call_id)` 写 stereo wav，随后 `prune(keep=MAX_RECORDINGS)`；确保异常不阻断正常挂断流程
  <!-- 4c7d3d1 _CallContext.teardown: bridge.leave() 停泵后(无更多 append) finalize+prune，两步各裹 contextlib.suppress(Exception) 不阻断挂断。teardown 是所有挂断路径汇聚点。 -->

## 4. 验证

- [x] 4.1 单测 / 集成：模拟一通话（注入 user+ai PCM）→ 挂断 → 断言 `RECORDINGS_DIR` 下生成 stereo wav（2 声道、16k、左=user 右=ai），且超过 N 通后只剩最近 N 个
  <!-- 4c7d3d1 tests/test_audio_bridge.py::test_bridge_records_both_channels_to_stereo_wav(2ch/16k/左右双通道有能量)。超 N 通滚动覆盖在 test_modem_recorder.py::test_prune_keeps_only_newest_n。 -->
- [x] 4.2 `MAX_RECORDINGS=0` 路径：断言不创建任何 wav 文件
  <!-- 4c7d3d1 test_main_cli.py::test_build_recorder_disabled_when_max_zero / _disabled_when_dir_unset → (None,0)；test_audio_bridge.py::test_bridge_without_recorder_writes_nothing → 目录无 wav。 -->
- [x] 4.3 `cd ../isales-telephony && .venv/bin/python -m pytest -q -k record` 全绿
  <!-- 4c7d3d1 -k record 8→在新测试上扩展；全量 .venv pytest -q = 343 passed, 4 skipped, 零回归。 -->
- [x] 4.4 `openspec validate edge-local-call-recording --strict` 通过
  <!-- valid. -->

## 5. 收尾

- [x] 5.1 在本 tasks.md 用 HTML 注释回写每个 task 的 PR# / commit / 偏离说明
  <!-- 本次回写；sub-repo commit = isales-telephony 4c7d3d1。 -->
- [ ] 5.2 commit + push isales-telephony 与 meta-repo（遵守 push 规则，main 直推 OK）
