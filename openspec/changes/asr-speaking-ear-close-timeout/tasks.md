## 1. isales-engine：asr_volcengine close_timeout

- [x] 1.1 `providers/asr_volcengine.py`：`__init__` 加构造参数 `ws_close_timeout_s: float = 0.2`，存 `self._ws_close_timeout_s`
- [x] 1.2 `_stream_one_connection`：`websockets_module.connect(self._url, additional_headers=headers, close_timeout=self._ws_close_timeout_s)`
- [x] 1.3 注释更新：说明短 close_timeout 是为了让 EOS-promote 后重连不被库默认 10s 阻塞，保证 SPEAKING 期间 ASR 有耳朵（引 call 138 实证）

## 2. isales-engine：测试

- [x] 2.1 `tests/test_providers.py` 或 asr 测试：构造默认 `_ws_close_timeout_s == 0.2` <!-- + override 0.5 -->
- [x] 2.2 mock `websockets.connect`（monkeypatch）断言收到 `close_timeout=0.2` <!-- test_asr_ws_close_timeout_default_and_passed_to_connect: inject fake websockets module, assert captured close_timeout==0.2 -->
- [x] 2.3 全量 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q` 无回归；ruff + mypy 改的文件 <!-- 315 passed; test file ruff clean; asr_volcengine 既有 7 pre-existing ruff/mypy 未新增 -->>

## 3. 部署 + commit

- [ ] 3.1 scp `asr_volcengine.py` → ECS `/opt/isales/current/isales-engine/...` + `systemctl restart isales-engine` + log clean（`isales_engine_started`）
- [ ] 3.2 commit + push isales-engine（branch fix/inbound-stereo-downmix-20260601）
- [ ] 3.3 更新 deploy/cloud/STATE.md（ASR close_timeout 0.2 + SPEAKING 期间重连）

## 4. 真机验证（mac dev-no-modem 受控通话）

- [ ] 4.1 跑真通话：量 `reconnect_after_clean_exit` 相对上一条 ASR 文本的间隔——确认从 ~10s 降到 ~200ms
- [ ] 4.2 AI 说话**中途**插话：确认 SPEAKING 期间出现 `volcengine_asr_NONEMPTY_TEXT` partial（证明 ASR 在听）
- [ ] 4.3 确认 `_partial_monitor` 触发 `interruption` + cancel `current_speaking_task`（barge-in 真生效）；记录是否被 VAD-corroboration gate 挡（若挡 → 归 VAD 重评估 followup）
- [ ] 4.4 对照基线（call 138：~9.7s 失聪窗口、SPEAKING 期间零 partial）确认改善

## 5. 验证 + archive

- [ ] 5.1 `openspec validate asr-speaking-ear-close-timeout --strict` 通过
- [ ] 5.2 `/opsx:archive asr-speaking-ear-close-timeout`
- [ ] 5.3 archive commit + push meta-repo

## Followups（本 change 明确不做，需另起 change + 真机 RMS 测量）

- VAD-cancel 重启用（`_vad_monitor` 2026-06-03 因 ambient-noise 误触禁用）
- `voice_rms_threshold=1200` 重调 + `_partial_monitor` VAD-corroboration gate 重评估（旧 self-loopback/AEC 依据已作废）
