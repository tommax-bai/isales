## 1. 引擎实装（isales-engine）

<!-- engine WIP 把裸 sleep(filler_delay_s) 改为 remaining = filler_delay_s - (now - processing_start)，remaining<=0 即刻播 -->
- [x] 1.1 `run_loop.py` `_play_streaming._maybe_filler`：把裸 `await asyncio.sleep(filler_delay_s)` 改为按 `processing_start` 计算剩余预算 `remaining = filler_delay_s - (time.monotonic() - processing_start)`；`remaining > 0` 才 sleep，随后判 `first_audio_ms is None` 再 `filler.start()`。`remaining <= 0` 时不 sleep、直接判并即刻播。
<!-- 验证：仅 main 回合 call site (filler=filler, processing_start 来自 PROCESSING 进入) 受影响；wrap-up + restructure 均 filler=None -->
- [x] 1.2 复核 `processing_start` 在三个 `_play_streaming` 调用点都是 PROCESSING 进入时刻：主回合（`filler=filler`，`processing_start` 经 `_run_gated_turn` 透传自 PROCESSING 进入）、wrap-up（`filler=None`，不受影响）、restructure（`processing_start=time.monotonic()` 且 `filler=None`，不受影响）。确认仅主回合 `filler` 非 None，行为变化只落在主回合。
- [x] 1.3 确认快轮次取消路径不变：首音频先于剩余预算就绪 → `filler_task.cancel()` + `filler.stop()` 仍生效（未触碰该段）。

## 2. 测试（isales-engine）

<!-- tests in isales-engine/tests/test_play_streaming.py：模拟 processing_start 处于过去=门控已耗时 -->
- [x] 2.1 单测 `test_gate_elapsed_counts_against_filler_budget`：门控耗 0.40s < 预算 0.50s → 剩余 0.10s 等满、首音频 0.25s 仍未出 → 播垫词（旧锚点下 0.25s 会取消 → start_called==0，本测据此甄别）。
- [x] 2.2 单测 `test_filler_immediate_when_gate_already_spent_budget`：门控耗 1.0s ≥ 预算 0.5s（`remaining <= 0`）→ 进入即刻播，不再额外等满。
- [x] 2.3 单测 `test_fast_turn_no_filler_even_with_some_gate_elapsed`：门控耗 0.10s、剩余预算内首音频就绪 → 取消、不播。
- [x] 2.4 `filler_enabled=false`：由既有 `filler=None` 用例覆盖（`_play_streaming` 不入 `if filler is not None` 分支）；run_loop 构建守卫在 `run_loop.py:683`。无需新增。
<!-- 全 engine 套件：1 failed 415 passed；唯一失败 test_gating.py::test_gate_fails_open_to_main_on_referee_timeout 经 git stash 验证在 clean HEAD 同样失败=pre-existing，与本 change 无关（referee gate timeout，非 filler） -->
- [x] 2.5 `test_play_streaming.py` 11/11 绿；`-k "filler or play_streaming or run_loop or run_session"` 38/38 绿；全 engine 套件 415 passed，唯一 failure 为 pre-existing 的 referee-gate-timeout 测试（clean HEAD 亦失败，与本 change 无关）。

## 3. 部署 + 验收

<!-- deployed: 部署前 sha 验 ECS==local HEAD(4b6e53dc)=in-sync 不 clobber；备份 run_loop.py.bak-20260612-153250；scp 后 ECS sha=720dd750=edited；graceful_shutdown active=0 不丢通话；新 PID 961287 isales_engine_started + credentials_loaded count=6，无 traceback -->
- [x] 3.1 scp `run_loop.py` 覆盖 ECS engine + `systemctl restart isales-engine`（沿用 scp-deploy 约定），核对服务起来无异常日志。
<!-- DEFERRED: prod 两 campaign 均 filler_enabled=false（camp1 filler_delay_ms=2500 但 enabled=false / camp2 空）→ 无 live 路径走垫词。代码已单测+服务级验。随后续开启垫词的 campaign 真机顺带验 -->
- [~] 3.2 真机/服务级验收：**DEFERRED** —— prod 无 `filler_enabled=true` campaign，无 live 垫词路径可拨测。服务级已验（engine 带新代码 clean 重启、单测覆盖新计时三路径）。待后续某 campaign 开启垫词时真机顺带验"垫词触发贴近客户说完话起 `filler_delay_ms`"。
- [x] 3.3 `openspec validate engine-filler-delay-client-anchor --strict` 通过。

## 4. 收尾

<!-- engine c921d7a (isales-engine, pushed main); meta commit 见下 -->
- [x] 4.1 tasks.md 用 HTML 注释回写 commit/PR# + 偏离说明；engine（`c921d7a`）+ meta-repo 提交并 `git push`。
- [ ] 4.2 `openspec archive engine-filler-delay-client-anchor`（合并 filler spec delta），确认目录移入 `changes/archive/`。**等用户确认**（真机验收 deferred，是否先 archive 由用户定）。
