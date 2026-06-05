## 1. isales-common：下沉 TTS 真实实现

- [x] 1.1 移动 `isales-engine/isales_engine/providers/tts_volcengine.py` → `isales-common/isales_common/providers/tts_volcengine.py`，保持类名 `VolcengineTTSProvider` / 方法签名 / V3 SSE 行为不变 <!-- 移入 common; 加 sample_rate property 供 api WAV 头读取; uid "isales-engine"→"isales" -->
- [x] 1.2 处理 `_errors` 依赖：将 `tts_volcengine.py` 依赖的错误类型移到 `isales-common/isales_common/providers/_errors.py`；engine 侧 `providers/_errors.py` 若被其他模块共用，则 re-export from common（过渡 shim，注释注明"待所有引用切到 common 后移除"）<!-- map_http_error/map_transport_error/as_provider_invalid_response + helpers 下沉 common _errors.py (异常类本就在 common); engine _errors.py 改为 re-export shim, 带 removal trigger; asr_volcengine/llm_openai_compatible 不动 -->
- [x] 1.3 把 `build_tts` 的 volcengine 分支（含新版 `api_key` / legacy `app_key+app_token` 双路 + `resource_id`）下沉到 isales-common <!-- 新增 build_volcengine_tts(store) in common tts_volcengine.py; 缺凭据抛 ProviderInvalidRequest(原 engine 抛 NotImplementedError, 偏离记录见 § 决策); engine factory.build_tts volcengine 分支改为 return build_volcengine_tts(s) -->
- [x] 1.4 bump isales-common 版本号（pyproject）<!-- 0.5.2 → 0.6.0; 加 httpx>=0.27 到 dependencies (provider 用 httpx, common 原无此依赖) -->
- [x] 1.5 isales-common 跑 lint / type-check / 单测全绿 <!-- ruff All checks passed; pytest 170 passed (含新 tests/test_tts_volcengine.py 12 个: provider SSE/error/reuse + build_volcengine_tts 4 例) -->

## 2. isales-engine：import 改向，行为不变

- [x] 2.1 `providers/factory.py` 等改为 `from isales_common...` import；删除已移出的本地实现文件 <!-- factory build_tts 用 build_volcengine_tts; rm isales-engine .../providers/tts_volcengine.py; test_tts_volcengine.py 拆分(provider 测试搬 common, engine 留 factory routing 2 例) -->
- [x] 2.2 更新 isales-engine 对 isales-common 的版本 pin <!-- engine + api 同步 >=0.6.0,<0.7 (原 <0.6) -->
- [x] 2.3 跑 TTS/factory/errors 相关测试确认无回归 <!-- test_tts_volcengine + test_provider_errors + test_tts_cache 31 passed; test_provider_errors.py:166 缺凭据断言 NotImplementedError→ProviderInvalidRequest -->
- [x] 2.4 跑 engine 全 pytest 确认无新增失败 <!-- 314 passed, 0 fail (旧 "5 pre-existing TTS volcengine fails" 也消失) -->

## 3. isales-api：试听合成端点

- [x] 3.1 新增 WAV 封装工具 <!-- isales_api/common/wav.py: pcm16_to_wav(pcm, *, sample_rate, channels=1) 用 stdlib wave 模块写 RIFF/WAVE 头, 不手搓 44 字节 -->
- [x] 3.2 在 `routers/campaigns.py` 加 `POST /campaigns/tts-preview` <!-- 路由放在 /{campaign_id} 动态路由前; schema TtsPreviewRequest(text 1..200, voice_id 1..128) 加在 schemas.py; CurrentUser 鉴权 (同其它 campaign 路由) -->
- [x] 3.3 端点逻辑：CredentialStore.from_db(session) → build_volcengine_tts(store) → 累积 PCM → pcm16_to_wav(sample_rate=provider.sample_rate) → Response(media_type="audio/wav") <!-- sample_rate 取 provider.sample_rate property, 不写死 -->
- [x] 3.4 错误处理：凭据缺失→400 tts_credential_not_configured; vendor ProviderError→502; 空音频→502; 超长/缺参→422(pydantic 在 handler 前拦, 不调 vendor) <!-- -->
- [x] 3.5 加单测 tests/test_tts_preview.py: wav RIFF/WAVE 头+时长>0(fake provider); 超长 422 且 vendor 0 调用(spy); 空 voice_id 422; 空 text 422; 缺凭据 400 <!-- 5 passed; 401 未认证由共享 CurrentUser dep 结构保证(test_auth 通测) -->
- [x] 3.6 isales-api 跑测试套；更新 common pin <!-- 5 新测试全过; 全套 108 passed + 2 failed(test_campaign_start_pause Redis 队列被 macOS legacy launchd BLPOP 偷消息, 已知 flake feedback_legacy_macos_deploy_steals_redis, 非本改动); api pin >=0.6.0,<0.7 -->

<!-- 偏离说明: build_volcengine_tts 缺凭据抛 ProviderInvalidRequest(原 engine build_tts 抛 NotImplementedError)。api 端点 catch 它→400; engine 侧 test_provider_errors.py 同步改断言。LLM/ASR 仍走 _require_field 的 NotImplementedError 不变。 -->

## 4. isales-web：试听按钮 + 播放

- [x] 4.1 `api/campaigns.ts` 加 `ttsPreview(text, voiceId)`：POST `/campaigns/tts-preview`，`responseType: "blob"`，返回 Blob <!-- -->
- [x] 4.2 `BasicTab.vue`：开场白框下加"试听"按钮，`:disabled="!greetingFilled || !form.voice_id"`，`:loading="previewing"` <!-- voice 未选时旁注"选好音色后可试听" -->
- [x] 4.3 点击逻辑：先把 form.voice_id(VoiceModel DB id) 用已加载 voices 列表解析成 vendor speaker 串再调 api(api 保持无状态 voice_id:str); blob→new Audio(createObjectURL).play(); onended revokeObjectURL; 再次点击先 stopPreview; 失败 ElMessage.error; onBeforeUnmount 停播 <!-- -->
- [x] 4.4 视觉：el-button size=small + .preview-row/.preview-hint，沿用既有 .hint 灰字风格 <!-- -->
- [x] 4.5 跑 lint + build <!-- eslint EXIT 0; vite build 4.69s 成功, CampaignEdit chunk 36.19kB 含改动 -->

## 4B. isales-engine：campaign voice_id 接线（本 session 追加，用户要求并入）

<!-- 实施中发现: engine runtime_config.py 原硬编码 voice_id="default", 从不消费
     campaign.voice_id → 真实通话一律 default 音色, 与试听不一致。用户选择并入本 change 修。 -->

- [x] 4B.1 `runtime_config.py` import `VoiceModel`；用 `campaign.voice_id`(int FK) `await db.get(VoiceModel, id)` 解析出 `VoiceModel.voice_id`(vendor speaker)，return 时 `voice_id=voice_speaker` 替代硬编码 "default" <!-- NULL / VoiceModel 不存在 → 回落 "default"(provider 映射默认 speaker), 不抛错 -->
- [x] 4B.2 engine ruff + 全 pytest 无回归 <!-- ruff All checks passed; 314 passed (campaign.voice_id NULL 时 guard 跳过查询, 现有 mock 测试不受影响) -->
- [x] 4B.3 spec delta：ai-pipeline 加 ADDED "引擎按 campaign 选定音色合成" <!-- voice-resolution 单测无现成 DB harness, 由 §6 真拨号验收覆盖 -->

## 5. 部署 ECS

- [ ] 5.1 isales-common 发版后，engine/api 重装更新 pin（按 `[[feedback_ecs_deploy_scp]]` 走 scp 覆盖 + restart，不走 git pull）
- [ ] 5.2 SCP 新 `runtime`/provider 文件到 ECS engine + api；`systemctl restart isales-engine isales-api`，journalctl 验证无 import error、`credentials_loaded` 正常
- [ ] 5.3 构建 isales-web 产物 scp 到 `/var/www/isales-web/`（含 `BasicTab` 试听按钮）；浏览器硬刷确认按钮出现
- [ ] 5.4 更新 `deploy/cloud/STATE.md`（若服务版本/pin 变化）

## 6. 联合验收

- [ ] 6.1 线上 web 进任一场景编辑「基础」tab，填开场白 + 选音色，点"试听"，浏览器应播放该句合成语音
- [ ] 6.2 改音色后再试听，音色应随之变化；清空文案后按钮应 disabled
- [ ] 6.3 改文案为 >200 字应被前端/后端拦下并给出可读提示
- [ ] 6.4 ECS api log grep 试听端点一次合成，确认走共享 common provider（无 import error、无重复 vendor 客户端）

## 7. Archive 准备

- [x] 7.1 跑 `openspec validate campaign-greeting-tts-preview --strict` 全绿 <!-- valid -->
- [x] 7.2 各 sub-repo commit：common 2a127c5 (main) / engine c109c61 (fix/inbound-stereo-downmix-20260601 分支) / api 7cf71a1 (main) / web 8b5b1ff (main) <!-- push 见下; engine 在 feature 分支(非 protected), 随该上下文走 -->
- [x] 7.3 meta-repo commit 本 change 4 artifact + tasks 进度回写 + push <!-- meta d7c621c; 全 5 仓已 push origin (common/api/web/meta → main, engine → fix/inbound-stereo-downmix-20260601) -->

<!-- 7.4 /opsx:archive 留到 §5 部署 + §6 验收完成后 -->
- [ ] 7.4 跑 `/opsx:archive campaign-greeting-tts-preview`，合并 spec delta（web-admin-ui + provider-abc）到 `openspec/specs/`，移动到 archive/
- [ ] 7.4 跑 `/opsx:archive campaign-greeting-tts-preview`，合并 spec delta（web-admin-ui + provider-abc）到 `openspec/specs/`，移动到 `openspec/changes/archive/YYYY-MM-DD-campaign-greeting-tts-preview/`
