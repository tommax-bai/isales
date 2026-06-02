## 1. 代码改动（isales-engine）

- [ ] 1.1 改 `isales_engine/state_machine.py::transition_to` 内部逻辑：移除 `raise IllegalTransition`，改为非常规 transition 时 `logger.warning("state_transition_unusual current=<X> new=<Y> reason=<R>")` + 追加 transcript `state_warning` 事件，**继续完成 state 赋值**
- [ ] 1.2 transcript 事件名从 `state_error` 改 `state_warning`（语义降级反映 advisory 性质）
- [ ] 1.3 `IllegalTransition` 异常类定义保留（不删除 class，避免 import 错误）；`transition_to` 不再抛它
- [ ] 1.4 `force=True` 参数定义保留（不删 signature），内部逻辑等价于"无论 force 取值都执行 transition"——backward-compat 保证 22 处现有调用方不需要改动
- [ ] 1.5 grep `isales_engine/` 确认 22 处 `transition_to` 调用代码一行未改 + 5 处 `session.state` 读取一行未改
- [ ] 1.6 在 `state_machine.py` 顶部 docstring 注明"transition guard 是 advisory；非常规 transition 写 state_warning 不阻塞业务；详细 rationale 见 spec call-state-machine § 非法 transition 改 advisory 警告"

## 2. 测试改动

- [ ] 2.1 `tests/test_state_machine.py` (188 行) 找出所有测 `pytest.raises(IllegalTransition)` 的 testcase
- [ ] 2.2 把这些 testcase 改写为：验证调用 `transition_to(illegal_state)` 后 **state 真的变了** + transcript 含 `state_warning` 事件 + logger.warning 被 emit（用 `caplog`）
- [ ] 2.3 加新 testcase `test_transition_to_unusual_writes_warning_and_continues`：覆盖 § 非法 transition 改 advisory 警告 / Scenario 非常规 transition 不抛异常
- [ ] 2.4 加新 testcase `test_state_warning_event_payload`：覆盖 transcript 事件 payload 正确（type / attempted / from_state / to_state）
- [ ] 2.5 加新 testcase `test_force_true_backward_compat`：覆盖 force=True 调用方式仍能工作（等价于不传 force）
- [ ] 2.6 `tests/test_event_pubsub.py` grep `IllegalTransition` / `state_error`，如有引用则同步改为 `state_warning`
- [ ] 2.7 跑 `cd ~/codes/isales-engine && .venv/bin/python -m pytest tests/test_state_machine.py tests/test_event_pubsub.py -v` 确认全绿

## 3. spec 同步（archive 时合并到 openspec/specs/）

- [ ] 3.1 验证 `openspec/changes/call-state-machine-soften-guard/specs/call-state-machine/spec.md` 含 MODIFIED § 状态集合 + ADDED 3 个新 Requirement（§ 非法 transition 改 advisory 警告 / § state_error 事件名迁移到 state_warning / § IllegalTransition 类保留但不再抛出）
- [ ] 3.2 `openspec validate call-state-machine-soften-guard --strict` 通过

## 4. 部署 + 验证

- [ ] 4.1 commit isales-engine feature branch + push origin
- [ ] 4.2 scp 改后的 `state_machine.py` 到 ECS `/opt/isales/current/isales-engine/isales_engine/state_machine.py`
- [ ] 4.3 `systemctl restart isales-engine` + 看 `isales_engine_started` log + `is-active`
- [ ] 4.4 跑 mac dev-no-modem 真 mic smoke：戴耳机 + 听完开场白 + 说"喂你好"+ 停 2 秒；验证之前会 crash 的 `INTERRUPTED → ACTIVATING (reason=silence_threshold)` 现在走 ACTIVATING 路径完成 silence_activation 兜底语 + transcript 出现 `state_warning` 事件（非 `state_error`）
- [ ] 4.5 ssh ECS 拉 `journalctl -u isales-engine | grep state_transition_unusual` 确认 warning log 可见 + 可 grep
- [ ] 4.6 SQL 查 call_record transcript 含 `state_warning` 事件结构正确（type / attempted / from_state / to_state 4 字段齐）

## 5. 联合验收（Windows 真拨号验完后做）

- [ ] 5.1 Windows 真拨号 13301035545 e2e 验证 barge-in 场景 state 转换正常，不再 crash
- [ ] 5.2 多通话压力跑（连续 ≥10 通），统计 `state_warning` 事件出现频率（若 >10% 通话出现则下次 sprint 需 review LEGAL_TRANSITIONS 表 + 业务流程）

## 6. archive

- [ ] 6.1 跑 `openspec validate call-state-machine-soften-guard --strict` 最终确认
- [ ] 6.2 跑 `/opsx:archive call-state-machine-soften-guard` 合并 spec delta 到 `openspec/specs/call-state-machine/spec.md` + 移动 change 目录到 `openspec/changes/archive/YYYY-MM-DD-call-state-machine-soften-guard/`
- [ ] 6.3 archive commit + push meta-repo

## 7. followup（不在本 change scope，记录在此用于下次 change 起源）

- [ ] 7.1 followup change `call-state-machine-cleanup-dead-code`：grep + 删除 4 处 `except IllegalTransition` handler dead code
- [ ] 7.2 followup change `call-state-machine-event-driven`（可选）：如果累计 N 个月 `state_warning` 事件高频出现（>10% 通话），考虑进一步重构成 event-driven / 多 flag 模型；如果未出现，本 change 软化 guard 已足够，无需进一步动作
