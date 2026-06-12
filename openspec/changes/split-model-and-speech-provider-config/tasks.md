## 0. 待定决策(apply 前拍板)

- [x] 0.1 ~~新语音 provider_id 命名~~ **已定:LLM 保留 `volcengine` + 语音新增 `volcengine_speech`**(2026-06-11 用户拍板,改动面最小,见 design Open Q1)<!-- decision-only -->`
- [ ] 0.2 语音卡是否同时暴露新旧控制台两套(api_key 新版 / app_key+app_token 旧版),还是只留新版(默认两套都迁、都支持,见 Open Q2)

## 1. isales-common — provider_id 拆分 + 凭据模型

- [ ] 1.1 `providers/factory.py`(或 common 对应枚举源):`KNOWN_ASR_PROVIDERS` / `KNOWN_TTS_PROVIDERS` 由 `{mock,volcengine}` → `{mock,volcengine_speech}`;`KNOWN_LLM_PROVIDERS` 保留 `{mock,volcengine,dashscope}`
- [ ] 1.2 `credentials.py` `ENV_KEY_MAP` / field 约定:`volcengine`(LLM)持 `api_key`(ark)+`endpoint`+`default_model`;`volcengine_speech` 持 `app_key`+`app_token`+`tts_resource_id`(+`api_key` 新版)+`endpoint`;`field_name` 枚举补 `tts_resource_id`
- [ ] 1.3 common 版本 bump(当前 **0.8.11** → 0.8.12;纯枚举/约定,无 schema/alembic)+ 检查 consumer pin `>=0.8.x,<0.9` 是否涵盖
- [ ] 1.4 单测:provider_id 枚举区分 LLM/语音;`CredentialStore` 取 `volcengine.api_key` vs `volcengine_speech.app_token` 互不串

## 2. isales-common — 存量凭据迁移(无 alembic,数据行搬家)

- [ ] 2.1 迁移工具(扩展 `isales-cred-migrate` 或一次性脚本):把现 `volcengine` 的 `app_key`/`app_token`/`tts_resource_id`(及当前承载语音 X-Api-Key 的 `api_key`)四行 → 改 `provider_id='volcengine_speech'`;cipher_text 不动(同一 Fernet key);**dry-run 默认**
- [ ] 2.2 迁移后 `volcengine` 仅留 LLM 字段:`api_key`(**新写 ark key**)+`endpoint`+`default_model`(填有效 ark 模型ID/接入点)
- [ ] 2.3 迁移幂等 + 回滚(provider_id 改回 `volcengine`);迁移前 `pg_dump provider_credential` 备份

## 3. isales-engine — factory 读字段对齐(含修 bug)

- [ ] 3.1 `factory.build_llm("volcengine")` 改读 `store.get("volcengine","api_key")`(ark key),**删掉读 `app_token` 的 bug**;`_DEFAULT_ENDPOINT`/`_DEFAULT_MODEL` 对齐
- [ ] 3.2 `build_asr` / `build_tts` 改读 `volcengine_speech` 的 `api_key`(新版)/`app_key`+`app_token`(旧版)/`tts_resource_id`
- [ ] 3.3 engine `engine_asr_provider`/`engine_tts_provider` 默认/解析指向 `volcengine_speech`
- [ ] 3.4 单测:`build_llm("volcengine")` 用 api_key 不用 app_token;`build_asr`/`build_tts` 走 volcengine_speech 凭据;跑 engine factory 相关测试全绿

## 4. isales-web — 拆「模型配置」+「语音服务配置」两块

- [ ] 4.1 `src/views/Config/ModelProviderConfig.vue` 拆两块:模型配置(火山方舟[ark api_key + endpoint + 模型ID] + DashScope[api_key + endpoint])+ 语音服务配置(豆包语音[app_key + app_token + tts_resource_id]);删「app token 框承载 LLM key」复用逻辑 + 误导注释
- [ ] 4.2 `src/types/llmProviders.ts` + 语音 provider 类型/SSOT:LLM 厂商(volcengine/dashscope)与语音厂商(volcengine_speech)分开定义;字段映射各归各位
- [ ] 4.3 火山方舟 LLM 卡 `default_model` 字段加提示(ark 需带版本模型ID 或接入点 `ep-xxx`,裸 `doubao-pro-32k` 会 404)
- [ ] 4.4 `vitest` + `vue-tsc` 全绿;手测两块卡字段独立保存

## 5. isales-api — provider_id 白名单

- [ ] 5.1 `/provider-credentials` 的 provider_id 校验白名单 += `volcengine_speech`;422 unknown-provider 行为不变
- [ ] 5.2 api 相关测试全绿

## 6. spec 校验

- [ ] 6.1 `specs/provider-credential/spec.md`(MODIFIED 表结构 + LLM/语音分 provider_id scenario)+ `specs/web-admin-ui/spec.md`(MODIFIED 拆两块卡)与实装一致
- [ ] 6.2 `openspec validate split-model-and-speech-provider-config --strict` 通过 + `make spec-validate` 全绿

## 7. 部署 + 迁移 + 真机验收

- [ ] 7.1 按 design Migration Plan:备份 provider_credential → common 上线 → dry-run 迁移核对 → `--apply` 迁移 → engine factory 上线 + 重启 → api 白名单 → web 部署
- [ ] 7.2 写入有效 ark key(`82989d4d-…`)到 `volcengine.api_key`;camp1 main 角色 `model` 改有效 ark 模型ID/接入点
- [ ] 7.3 验证:engine `build_llm("volcengine")` 实测豆包回话(不再 401);ASR/TTS 仍正常(走 volcengine_speech);兜底词不再触发
- [ ] 7.4 真机:mac/QA 拨一通,AI 真用豆包对话(非"喂喂、喂喂"兜底)+ 配合 `fix-goal-achievement-pipeline` 验完整 goal_achieved 链(referee 已验)
- [ ] 7.5 回写 `deploy/cloud/STATE.md`(provider 拆分 + 迁移)+ tasks.md 勾选 + commit-sha

## 8. 收口

- [ ] 8.1 跨仓 commit & push(common/engine/web/api + meta 回写)
- [ ] 8.2 `make test-all`(甄别 pre-existing redis-steal / gate-timeout flake)
- [ ] 8.3 `openspec validate --strict` 后 archive(`/opsx:archive split-model-and-speech-provider-config`)
