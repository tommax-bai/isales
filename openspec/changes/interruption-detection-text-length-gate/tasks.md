## 1. isales-engine - InterruptionConfig 加 min_text_length 字段

- [ ] 1.1 修改 `isales-engine/isales_engine/realtime/interruption_detector.py`: `InterruptionConfig` dataclass 加 `min_text_length: int = 2` 字段; 删 prototype hardcoded `_MIN_TEXT_LENGTH_PROTOTYPE` 常量, 改读 `config.min_text_length`
- [ ] 1.2 修改同文件 `evaluate_partial` 函数: text length gate 用 `config.min_text_length` 取代 hardcoded 2; gate 顺序保持 whitelist → text_length → duration → triggered
- [ ] 1.3 更新模块 docstring (顶部): 把"double-condition"改"triple-condition", 新增 `min_text_length` 说明; 新增"verdict reason='text_too_short'"枚举值

## 2. isales-engine - run_loop.py vad_monitor deprecate cancel

- [ ] 2.1 修改 `isales-engine/isales_engine/run_loop.py::_vad_monitor`: 删 `speaking_task.cancel()` 调用 + 删 transcript event `source="vad"` 写入; 加注释指向本 change name 说明原因
- [ ] 2.2 保留 `session.vad_voice_active_ms` mirror 逻辑 (partial_monitor corroboration 550902d 防自环机制仍需要)
- [ ] 2.3 加 logger.info 记录 deprecate 路径触发 (debug ops 验证 vad_monitor 仍在跑但不再 cancel)

## 3. isales-engine - runtime_config 读 PG min_text_length

- [ ] 3.1 修改 `isales-engine/isales_engine/runtime_config.py::build_runtime_config`: 读 `campaign.interruption_min_text_length` 字段 (int, fallback default 2 若 None / 列不存在)
- [ ] 3.2 验证 `InterruptionConfig(...)` 构造时把读到的值传进 `min_text_length=` 参数

## 4. isales-engine - 单测

- [ ] 4.1 `tests/test_interruption_detector.py` 新加 `test_evaluate_partial_text_too_short` testcase: text="对", 期望 verdict="ignored", reason="text_too_short"
- [ ] 4.2 同文件新加 `test_evaluate_partial_text_meets_min_length_passes` testcase: text="等等", min_duration_ms 已满足, 期望 verdict="triggered", reason="exceeds"
- [ ] 4.3 同文件新加 `test_evaluate_partial_text_length_per_config_override` testcase: config min_text_length=1, text="对" 期望 verdict="triggered" (验证 per-campaign override 生效)
- [ ] 4.4 `tests/test_realtime_interruption.py` 调整 `_vad_monitor` 不再触发 cancel 的断言 (若现有 testcase 断言"vad triggers cancel speaking_task" 需改成"vad mirrors voice_active_ms only")
- [ ] 4.5 运行 `cd ../isales-engine && .venv/bin/python -m pytest -q tests/test_interruption_detector.py tests/test_realtime_interruption.py` 全绿

## 5. isales-common - PG migration

- [ ] 5.1 在 `isales-common/alembic/versions/` 加 migration 文件 `add_campaign_interruption_min_text_length.py`: 给 `campaign` 表加 `interruption_min_text_length` 列 (Integer, NOT NULL, server_default='2')
- [ ] 5.2 修改 `isales-common/isales_common/models/campaign.py`: `Campaign` SQLAlchemy 模型加 `interruption_min_text_length: Mapped[int]` 列定义 (default=2)
- [ ] 5.3 修改 `isales-common/isales_common/schemas/campaign.py`: Pydantic Campaign schema 加 `interruption_min_text_length: int = 2` 字段
- [ ] 5.4 bump `isales-common/pyproject.toml` version + 在 isales-engine pin 升级
- [ ] 5.5 跑 isales-common pytest 全绿; isales-engine pip install -e ../isales-common 后 import 验证

## 6. ECS 部署

- [ ] 6.1 ssh ECS 跑 alembic upgrade head 应用 PG migration (campaign 表加 interruption_min_text_length 列, dev campaign id=1 自动用 default 2)
- [ ] 6.2 scp `isales-engine/isales_engine/realtime/interruption_detector.py` + `run_loop.py` + `runtime_config.py` 到 ECS `/opt/isales/current/isales-engine/isales_engine/...`
- [ ] 6.3 scp isales-common 新版本 wheel 到 ECS 并在 engine venv 内 pip install --upgrade
- [ ] 6.4 `systemctl restart isales-engine` ECS 端
- [ ] 6.5 grep `systemctl status isales-engine` + `journalctl -u isales-engine -n 50` 确认无 import 错 / config 错

## 7. mac dev-no-modem smoke 验证

- [ ] 7.1 mac 端 cd `~/codes/isales-telephony` 启动 dev-no-modem edge (按 [[project_macos_dev_path]] 命令)
- [ ] 7.2 触发 1 个真 mic 多轮通话 (用户主动说 "你好" → AI 回应; 用户再说 "等等我想问个问题" 期望触发打断)
- [ ] 7.3 验证 call_record transcript:
  - AI 长回应 segment `interrupted=false` (无误打断)
  - 真用户说 2+ 字 ("等等") 触发 partial-source interruption (有有效打断)
  - **MUST NOT** 出现 `source="vad"` interruption event
- [ ] 7.4 验证 engine log: 出现 `partial_monitor_skip_text_too_short` 信息 (噪音/单字片段过滤生效); 出现 `vad_monitor_skip_deprecate` 信息 (vad_monitor 仍在跑但不 cancel)

## 8. Windows 真拨号 e2e 验证 (留依赖)

- [ ] 8.1 等 Windows binding 就绪 (依赖 `engine-rtc-dingrtc-migration` § 7 完成)
- [ ] 8.2 Windows 端发起真拨号 → GSM modem 听筒接电话 → AI 销售话术 → 真人用户主动打断 ("等等我想问个问题")
- [ ] 8.3 验证 transcript: AI segment `interrupted=false` 直到真用户 2+ 字打断 partial-source 触发

## 9. 收尾

- [ ] 9.1 删除 `isales-engine/isales_engine/realtime/interruption_detector.py` 顶部 PROTOTYPE 注释段 (task 1.1 已经把 prototype hardcoded 改成 config-driven)
- [ ] 9.2 删除 `isales-engine/isales_engine/run_loop.py` 内 prototype `continue` patch 段 (task 2.1 已经正式删 cancel 路径)
- [ ] 9.3 `openspec validate interruption-detection-text-length-gate --strict` 通过
- [ ] 9.4 git commit + push to origin/main (engine + common + meta 三仓)
- [ ] 9.5 准备 archive 阶段 (实施完整 + smoke + Windows 真拨号 e2e 验证后)
