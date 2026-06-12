## 0. 待定决策(apply 前拍板)

- [x] 0.1 ~~新语音 provider_id 命名~~ **已定:LLM 保留 `volcengine` + 语音新增 `volcengine_speech`**(2026-06-11 用户拍板,改动面最小,见 design Open Q1)<!-- decision-only -->`
- [x] 0.2 ~~语音卡是否同时暴露新旧控制台两套~~ **已定:两套都迁、都支持(behavior-preserving)** — 语音卡暴露 `api_key`(新版 X-Api-Key) + `app_key`+`app_token`(旧版) + `tts_resource_id`;engine `build_volcengine_tts` / `VolcengineASRProvider` 已 prefer api_key、fallback app_key+app_token(2026-06-12 取 design Open Q2 默认值)<!-- decision-only -->`

## 1. isales-common — provider_id 拆分 + 凭据模型

- [x] 1.1 `providers/factory.py`(或 common 对应枚举源):`KNOWN_ASR_PROVIDERS` / `KNOWN_TTS_PROVIDERS` 由 `{mock,volcengine}` → `{mock,volcengine_speech}`;`KNOWN_LLM_PROVIDERS` 保留 `{mock,volcengine,dashscope}` <!-- engine 2457991: KNOWN_* 在 engine factory.py(common 无独立枚举源) -->
- [x] 1.2 `credentials.py` `ENV_KEY_MAP` / field 约定:`volcengine`(LLM)持 `api_key`(ark)+`endpoint`+`default_model`;`volcengine_speech` 持 `app_key`+`app_token`+`tts_resource_id`(+`api_key` 新版)+`endpoint`;`field_name` 枚举补 `tts_resource_id` <!-- common d0bf1f9: ENV_KEY_MAP 拆分(在 cli/cred_migrate.py) + 新增 ISALES_VOLCENGINE_SPEECH_API_KEY;field_name 枚举补在 api ALLOWED_FIELD_NAMES(见 5.1) -->
- [x] 1.3 common 版本 bump(当前 **0.8.11** → 0.8.12;纯枚举/约定,无 schema/alembic)+ 检查 consumer pin `>=0.8.x,<0.9` 是否涵盖 <!-- common d0bf1f9: 0.8.12;engine/api pin >=0.8.11,<0.9 + worker/scheduler >=0.8,<0.9 均涵盖,无需改 pin -->
- [x] 1.4 单测:provider_id 枚举区分 LLM/语音;`CredentialStore` 取 `volcengine.api_key` vs `volcengine_speech.app_token` 互不串 <!-- common d0bf1f9: TestLLMSpeechProviderIsolation + TestKeyMap/TestSpeechFields -->

## 2. isales-common — 存量凭据迁移(无 alembic,数据行搬家)

- [x] 2.1 迁移工具(扩展 `isales-cred-migrate` 或一次性脚本):把现 `volcengine` 的 `app_key`/`app_token`/`tts_resource_id`(及当前承载语音 X-Api-Key 的 `api_key`)四行 → 改 `provider_id='volcengine_speech'`;cipher_text 不动(同一 Fernet key);**dry-run 默认** <!-- common d0bf1f9: `isales-cred-migrate split-speech` 子命令,SPEECH_FIELDS 覆盖 api_key/app_key/app_token/{tts,asr}_resource_id/{asr,tts}_endpoint -->
- [x] 2.2 迁移后 `volcengine` 仅留 LLM 字段:`api_key`(**新写 ark key**)+`endpoint`+`default_model`(填有效 ark 模型ID/接入点) <!-- common d0bf1f9: split-speech 把语音字段搬走后 volcengine 仅留 endpoint/default_model;ark api_key 是新值,在部署步骤 7.2 写入(工具已就绪,真值待 prod) -->
- [x] 2.3 迁移幂等 + 回滚(provider_id 改回 `volcengine`);迁移前 `pg_dump provider_credential` 备份 <!-- common d0bf1f9: 幂等(找不到源行 no-op)+ --rollback;pg_dump 在部署步骤 7.1 -->

## 3. isales-engine — factory 读字段对齐(含修 bug)

- [x] 3.1 `factory.build_llm("volcengine")` 改读 `store.get("volcengine","api_key")`(ark key),**删掉读 `app_token` 的 bug**;`_DEFAULT_ENDPOINT`/`_DEFAULT_MODEL` 对齐 <!-- engine 2457991 -->
- [x] 3.2 `build_asr` / `build_tts` 改读 `volcengine_speech` 的 `api_key`(新版)/`app_key`+`app_token`(旧版)/`tts_resource_id` <!-- engine 2457991 + common d0bf1f9(build_volcengine_tts 读 volcengine_speech) -->
- [x] 3.3 engine `engine_asr_provider`/`engine_tts_provider` 默认/解析指向 `volcengine_speech` <!-- engine 2457991: KNOWN_ASR/TTS 仅认 volcengine_speech;settings 默认仍 mock(dev);meta: deploy/cloud/env/engine.env(.example) ASR/TTS_PROVIDER=volcengine_speech -->
- [x] 3.4 单测:`build_llm("volcengine")` 用 api_key 不用 app_token;`build_asr`/`build_tts` 走 volcengine_speech 凭据;跑 engine factory 相关测试全绿 <!-- engine 2457991: test_providers + test_provider_errors + test_tts_volcengine 全绿 -->

## 4. isales-web — 拆「模型配置」+「语音服务配置」两块

- [x] 4.1 `src/views/Config/ModelProviderConfig.vue` 拆两块:模型配置(火山方舟[ark api_key + endpoint + 模型ID] + DashScope[api_key + endpoint])+ 语音服务配置(豆包语音[app_key + app_token + tts_resource_id]);删「app token 框承载 LLM key」复用逻辑 + 误导注释 <!-- web abae626: field-driven 两 section,语音卡含新版 api_key + 旧版 app_key/app_token + tts_resource_id -->
- [x] 4.2 `src/types/llmProviders.ts` + 语音 provider 类型/SSOT:LLM 厂商(volcengine/dashscope)与语音厂商(volcengine_speech)分开定义;字段映射各归各位 <!-- web abae626: 新增 speechProviders.ts(语音 SSOT);llmProviders.ts label 标注 volcengine=Ark LLM -->
- [x] 4.3 火山方舟 LLM 卡 `default_model` 字段加提示(ark 需带版本模型ID 或接入点 `ep-xxx`,裸 `doubao-pro-32k` 会 404) <!-- web abae626: default_model field.hint -->
- [x] 4.4 `vitest` + `vue-tsc` 全绿;手测两块卡字段独立保存 <!-- web abae626: vue-tsc clean + vitest 90/90;手测两块卡独立保存 deferred 到部署后 SPA 点验 -->

## 5. isales-api — provider_id 白名单

- [x] 5.1 `/provider-credentials` 的 provider_id 校验白名单 += `volcengine_speech`;422 unknown-provider 行为不变 <!-- api 2eac78f: ALLOWED_PROVIDER_IDS += volcengine_speech;ALLOWED_FIELD_NAMES += tts_resource_id/asr_resource_id -->
- [x] 5.2 api 相关测试全绿 <!-- api 2eac78f: test_provider_credentials 12/12(test_campaign_start_pause 2 失败是 pre-existing redis-steal,与本 change 无关) -->

## 6. spec 校验

- [x] 6.1 `specs/provider-credential/spec.md`(MODIFIED 表结构 + LLM/语音分 provider_id scenario)+ `specs/web-admin-ui/spec.md`(MODIFIED 拆两块卡)与实装一致 <!-- 已核对: provider-credential(LLM=volcengine/dashscope, 语音=volcengine_speech, build_llm 读 api_key) + web-admin-ui(两块卡)与实装一致 -->
- [x] 6.2 `openspec validate split-model-and-speech-provider-config --strict` 通过 + `make spec-validate` 全绿 <!-- valid;make spec-validate: --specs 22/22 + --changes 9/9 + dingrtc 版本一致 -->

## 7. 部署 + 迁移 + 真机验收

- [x] 7.1 按 design Migration Plan:备份 provider_credential → common 上线 → dry-run 迁移核对 → `--apply` 迁移 → engine factory 上线 + 重启 → api 白名单 → web 部署 <!-- 2026-06-12 全栈部署:pg_dump `provider_credential-split-20260612-101555.sql` → scp common(cred_migrate+tts_volcengine) → dry-run 核对 4 行 → split-speech --apply(4 行 → volcengine_speech) → import-env 写 ark key → scp engine factory.py + api router + 翻 engine.env ASR/TTS=volcengine_speech → 重启 engine+api → web build+rsync+nginx reload(index-CJ3BqlMB.js)。详见 deploy/cloud/STATE.md 2026-06-12 10:30 条 -->
- [x] 7.2 写入有效 ark key(`82989d4d-…`)到 `volcengine.api_key`;~~camp1 main 角色 `model` 改有效 ark 模型ID/接入点~~ <!-- ark key 82989d4d-…2c49 已写入 volcengine.api_key(import-env --apply)。camp1 main model **用户决定自己在「模型配置」UI 处理**(2026-06-12):火山方舟账号当前无可用豆包模型(GET /models 全 Shutdown / doubao-seed-1-6 ModelNotOpen / doubao-pro-32k NotFound),需用户开通模型/建 ep-xxx 接入点 -->
- [~] 7.3 验证:engine `build_llm("volcengine")` ~~实测豆包回话~~(**不再 401** ✓);ASR/TTS 仍正常(走 volcengine_speech)✓;~~兜底词不再触发~~ <!-- ark key 鉴权实测通过(curl ark 返回 model NotFound 而非 auth-failed,401 根因已除);build_llm("volcengine") 构建 OK key_prefix=8298;build_asr/tts 从 volcengine_speech 构建成功(engine startup credentials_loaded count=6 无 NotImplementedError)。**豆包回话/兜底词清除 待 camp1 main 模型开通**(账号侧,见 7.2);⚠️ LLMRegistry fail-open 只接 build 错误不接 runtime 404 → valid-key/bad-model 仍 404→兜底 -->
- [ ] 7.4 真机:mac/QA 拨一通,AI 真用豆包对话(非"喂喂、喂喂"兜底)+ 配合 `fix-goal-achievement-pipeline` 验完整 goal_achieved 链(referee 已验) <!-- DEFERRED:需用户先开通豆包模型(7.2)+ 真机拨测;account-blocked + 需真人电话 -->
- [x] 7.5 回写 `deploy/cloud/STATE.md`(provider 拆分 + 迁移)+ tasks.md 勾选 + commit-sha <!-- STATE.md 2026-06-12 10:30 条 + 本 tasks.md + meta commit -->

## 8. 收口

- [x] 8.1 跨仓 commit & push(common/engine/web/api + meta 回写) <!-- common d0bf1f9 / engine 2457991 / api 2eac78f / web abae626 / meta 068e646 全 push origin main -->
- [x] 8.2 `make test-all`(甄别 pre-existing redis-steal / gate-timeout flake) <!-- common 189 / telephony 345 / worker 57 / web 90 全绿;engine 1(gate-timeout)+ api 2 + scheduler 3 = pre-existing redis-steal/gate flake,均与本 change 无关(stash 验证 + scheduler/telephony/worker 未触碰)。ultracode 对抗审计 0 confirmed / 3 dismissed -->
- [x] 8.3 `openspec validate --strict` 后 archive(`/opsx:archive split-model-and-speech-provider-config`) <!-- 见下方 archive -->`
