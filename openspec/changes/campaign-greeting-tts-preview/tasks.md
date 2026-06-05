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

## 4C. 音色改为直填 speaker 字符串（用户决策：不用 ListSpeakers/不入库，文本框直填）

<!-- 用户最终决策：音色列表实时拉/AK-SK 路线放弃；音色控件改文本框直填 vendor
     speaker 串, campaign 直存该串。返工 §4(下拉) + §4B(FK 解析)。 -->

- [x] 4C.1 isales-common: `Campaign.voice_id` `BigInteger` FK → `String(128)`(model) + CampaignBase/Update schema `int|None`→`str|None`(max 128) <!-- model + 2 schema 改; ForeignKey import 仍被 prompt_version FK 用, 不删 -->
- [x] 4C.2 alembic migration `f6a7b8c9d0e1_campaign_voice_id_to_string`: drop FK `fk_campaign_voice_id_voice_model`(naming_convention) + alter type→VARCHAR(128) `USING NULL`; downgrade 反向 <!-- 本地 dev PG upgrade+downgrade+upgrade roundtrip 全过; head=f6a7b8c9d0e1 -->
- [x] 4C.3 isales-engine: runtime_config 简化为 `voice_speaker = campaign.voice_id or "default"`, 删 VoiceModel import + db.get 查询(返工 §4B) <!-- ruff 过; 314 passed -->
- [x] 4C.4 isales-api: CampaignNestedUpdate.voice_id `int|None`→`str|None`(max 128); tts-preview 端点不变(本就收 voice_id:str) <!-- 15 passed -->
- [x] 4C.5 isales-web: BasicTab + CampaignDetail 音色 `el-select`→`el-input`(占位示例 speaker 串); 试听直接发 form.voice_id 串(删 VoiceModel id→speaker 解析 + voices 加载); types CampaignBase.voice_id number→string <!-- vue-tsc + build 绿; voiceApi/VoiceModel import 清理 -->
- [x] 4C.6 data-model spec delta: ADDED "campaign.voice_id 持有 vendor speaker 字符串"; ai-pipeline delta 改为 speaker 串直用 <!-- -->

<!-- 注: voice_model 表 + /voice-models CRUD + VoiceModelList 页 + voiceApi 暂保留不动(其它地方可能引用), 本 change 只是 campaign 不再 FK 它。 -->

## 5. 部署 ECS

- [x] 5.1 common 是 editable 安装(/opt/isales/current/isales-common)，scp 覆盖代码即生效，无需重装；httpx 0.28.1 已在共享 venv，新依赖满足 <!-- 单一共享 venv /opt/isales/current/venv; pip Editable project location 指向 current -->
- [x] 5.2 SCP common(tts_volcengine.py 新 + _errors.py) + engine(_errors shim + factory + runtime_config) + api(campaigns + schemas + common/wav.py) 到 ECS；rm 旧 engine tts_volcengine.py + 清 pyc；`systemctl restart isales-api isales-engine` <!-- 两服务 active; engine credentials_loaded count=5 + isales_engine_started 无 import error; common 共享 provider import OK -->
- [x] 5.3 web dist scp 到 `/var/www/isales-web/`；确认 CampaignEdit-BaXYFyyZ.js 含"选好「音色」后可试听" <!-- index.html 已覆盖指向新 bundle; 旧 BkidOE76 orphan 无害 -->
- [x] 5.4 更新 `deploy/cloud/STATE.md`（tts-preview 端点 + provider 下沉）<!-- -->

## 6. 联合验收

- [x] 6.4 ECS 真调 endpoint(铸 admin JWT): POST /campaigns/tts-preview "您好，我是智联招聘的小雨" + zh_female_xiaohe_uranus_bigtts → **HTTP 200 + content-type audio/wav + 76412 bytes + 首字节 RIFF**，真 vendor 合成走共享 common provider，无 import error <!-- 服务端全链路实证 -->
- [ ] 6.1 线上 web 进任一场景编辑「基础」tab，填开场白 + 选音色，点"试听"，浏览器应播放该句合成语音 <!-- 留用户在浏览器点; 服务端已实证返回真 WAV -->
- [ ] 6.2 改音色后再试听，音色应随之变化；清空文案后按钮应 disabled <!-- 留用户 -->
- [ ] 6.3 改文案为 >200 字应被前端/后端拦下并给出可读提示 <!-- 留用户; api 单测已覆盖 422 -->
- [ ] 6.5 真拨号验证 engine voice 接线(§4B): campaign 设非 default 音色，真拨听到的应是该音色(与试听一致) <!-- 留 §6 真拨号; 无 DB 单测 harness -->

<!-- 6.1-6.3 + 6.5 需真人浏览器/真拨号, 留用户; 6.4 服务端 smoke 已绿覆盖 api→common provider→vendor→WAV 全链 -->

<!-- 全 5 仓部署 commit: common 2a127c5 / engine c109c61+1eb78b6 / api 7cf71a1 / web 8b5b1ff / meta c5375c2 -->

- [ ] 6.6 `git -C ~/codes/isales-web push` 后续若动 dist 清理 orphan bundle（可选清理 BkidOE76）<!-- 低优先, 不影响功能 -->

## 7. Archive 准备

- [x] 7.1 跑 `openspec validate campaign-greeting-tts-preview --strict` 全绿 <!-- valid -->
- [x] 7.2 各 sub-repo commit：common 2a127c5 (main) / engine c109c61 (fix/inbound-stereo-downmix-20260601 分支) / api 7cf71a1 (main) / web 8b5b1ff (main) <!-- push 见下; engine 在 feature 分支(非 protected), 随该上下文走 -->
- [x] 7.3 meta-repo commit 本 change 4 artifact + tasks 进度回写 + push <!-- meta d7c621c; 全 5 仓已 push origin (common/api/web/meta → main, engine → fix/inbound-stereo-downmix-20260601) -->

<!-- 7.4 /opsx:archive 留到 §5 部署 + §6 验收完成后 -->
- [ ] 7.4 跑 `/opsx:archive campaign-greeting-tts-preview`，合并 spec delta（web-admin-ui + provider-abc）到 `openspec/specs/`，移动到 archive/
- [ ] 7.4 跑 `/opsx:archive campaign-greeting-tts-preview`，合并 spec delta（web-admin-ui + provider-abc）到 `openspec/specs/`，移动到 `openspec/changes/archive/YYYY-MM-DD-campaign-greeting-tts-preview/`
