## 1. engine 解锁实时合成选取路径

<!-- engine 4d4a632 (branch fix/inbound-stereo-downmix-20260601): filler_manager.py _pick_phrase 选取改 p.text.strip() -->
- [x] 1.1 改 `isales-engine/isales_engine/realtime/filler_manager.py` `_pick_phrase`：`ready` 过滤从 `generation_status == READY and p.audio_url` 改为 `p.text.strip()`（仅要求文本非空）
<!-- 同 commit: module docstring + _pick_phrase 注释 + _stream_audio docstring 全改；删除 unused GenerationStatus import -->
- [x] 1.2 同文件更新 `_pick_phrase` / `_stream_audio` docstring 与注释：说明 v1.0 走实时 TTS + 进程缓存，`audio_url` / `generation_status` 为 stage-6 OSS 字段，并写明「stage-6 worker+OSS 就绪时以独立 change 恢复 audio_url 优先分支」的恢复条件
<!-- FillerPhraseSpec 保留 audio_url/generation_status 字段供 stage-6；确认 _pick_phrase 不再读取，runtime_config.py 填充无需改 -->
- [x] 1.3 检查 `FillerPhraseSpec` 是否仍需 `audio_url` / `generation_status` 字段（保留供 stage-6，但确认 v1.0 选取不再读取）；`runtime_config.py` 填充逻辑无需改

## 2. engine 单测同步

<!-- test_filler_skip_when_no_ready_phrase → 拆成 skip_when_text_empty + plays_pending_phrase_via_realtime_synth -->
- [x] 2.1 改 `tests/test_filler_manager.py`：把「无 audio_url / generation_status=pending 即 skip」的断言改为「文本非空即可选并实时合成」；保留「文本全空则 skip」「合成异常则 skip 不中断」两条兜底断言
<!-- test_run_loop.py fixture 用 ready+audio_url 但 text 非空，新行为下仍有效，无需改 -->
- [x] 2.2 检查 `tests/test_run_loop.py` 中 filler 相关用例（如有 audio_url 前置 fixture）同步更新
<!-- pytest -k filler: 8 passed; test_run_loop.py: 6 passed -->
- [x] 2.3 跑 `.venv/bin/python -m pytest -q -k filler` 全绿

## 3. web 详情页补 filler 控件

<!-- web 5ad886b (main): CampaignDetail.vue 基本信息卡 greeting 下方加 filler 开关+延迟，复用 BasicTab hint 文案 -->
- [x] 3.1 `isales-web/src/views/Campaigns/CampaignDetail.vue` 增加 `filler_enabled` el-switch + `filler_delay_ms` el-input-number（`v-if="filler_enabled"`），复用 `BasicTab.vue:53-75` 控件与 hint 文案、`CampaignBase` 既有字段、既有 PATCH `/campaigns/{id}` 通路
<!-- form reactive + onRefresh 加载 + onSave payload 三处都补了 filler_enabled/filler_delay_ms -->
- [x] 3.2 确认详情页加载/保存包含这两个字段（CampaignDetail 的 form 绑定 + payload）；与 greeting 详情页范式（commit a2573be）一致
<!-- npm run typecheck EXIT=0; eslint CampaignDetail.vue EXIT=0 -->
- [x] 3.3 web 构建/类型检查通过（`npm run build` 或 `vue-tsc`）

## 4. 验证与部署

<!-- 单测 plays_pending_phrase_via_realtime_synth 已证 unblock；真机 e2e（开 dev campaign filler_enabled + 真拨确认日志出 filler event）待跑，需真实 edge+话机；DB 预检被 prod-read 权限拦下 -->
- [ ] 4.1 在 dev campaign 上开 `filler_enabled=true`，跑 mac dev-no-modem e2e（或慢模型场景），确认日志出现 `filler` event 而非 `filler_skip_no_ready_phrase`
<!-- engine: scp filler_manager.py 单文件(远端==pre-change baseline diff净) + restart clean; 部署文件含 p.text.strip()、GenerationStatus 全清。web: npm run build + scp dist + nginx reload, SPA 200。STATE.md 同步更新 -->
- [x] 4.2 engine SCP 覆盖 ECS + restart（参 `[[feedback_ecs_deploy_scp]]`）；web 发布
<!-- openspec validate --strict 通过 -->
- [x] 4.3 `openspec validate filler-realtime-unblock-and-detail-toggle --strict` 通过

## 5. 回写与归档准备

<!-- engine 4d4a632 / web 5ad886b / meta fcd9e7d 已回写各 task 行 -->
- [x] 5.1 在本 tasks.md 用 HTML 注释回写各 task 的 PR#/commit/偏离说明
<!-- 等 4.1 真机 e2e 通过后 archive -->
- [ ] 5.2 全 task 完成后准备 archive（合并 filler + web-admin-ui spec delta）
