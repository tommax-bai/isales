## Why

场景（campaign）编辑的「基础」tab 已经能设"音色"和"开场白文案"（`campaign-fixed-greeting` 已上线），但运营填完文案只能靠真拨一通电话才知道这句开场白念出来是什么语气、发音对不对。缺一个"保存/拨号前先听一耳"的反馈环——尤其换音色、调措辞时，盲改成本高。

## What Changes

- 在 web 场景编辑「基础」tab 的"开场白文案"输入框旁新增**「试听」按钮**：填了文案 + 选了音色后点击，浏览器当场播放这句话的合成语音。
- isales-api 新增 `POST /campaigns/tts-preview`：入参 `{text, voice_id}`，用现有 `provider_credential` 凭据现合成 TTS（PCM）→ 封装为浏览器可播的 `audio/wav` → 返回。无状态、不落库、不上 OSS。
- **TTS 真实实现（volcengine V3 SSE）从 isales-engine 下沉到 isales-common**，使 engine 与 api 共用同一份合成实现，避免在 api 侧重复实现一遍 vendor 协议。engine 改为从 isales-common 导入，对外行为不变。
- 不改 engine 的开场白播放路径、不做预生成 / 持久化 / 启动预热——本 change 只交付"试听"这一只读反馈能力。

## Capabilities

### New Capabilities
<!-- 无新增 capability；试听是对既有 web-admin-ui + provider-abc 的扩展 -->

### Modified Capabilities
- `web-admin-ui`: 新增"开场白文案试听"交互要求——管理端 SHALL 允许在保存前对当前文案 + 音色现合成并播放预览。
- `provider-abc`: 放宽"真实实现仅在 isales-engine"的约束——被 engine 与 api 共用的 TTS 真实实现 SHALL 下沉到 isales-common，供两端从共享 `CredentialStore` 构建。

## Impact

- **isales-common**: 新增 `providers/tts_volcengine.py`（自 isales-engine 移入）+ TTS `build_tts` 工厂 + 其依赖的 `_errors`；继续依赖既有 `CredentialStore`。需 bump 版本并更新消费者 pin。
- **isales-engine**: `providers/factory.py` 等改为 `from isales_common.providers import ...`；删除已移出的本地实现文件；行为与单测不变。
- **isales-api**: 新增 `routers/campaigns.py`（或新 router）的 `tts-preview` 端点 + WAV 封装工具；引入对共享 TTS 实现的依赖；沿用现有 `CurrentUser` 鉴权与 `CredentialStore`。对 `text` 长度设上限（建议 ≤200 字）防滥用。
- **isales-web**: `views/Campaigns/Tabs/BasicTab.vue` 加"试听"按钮 + 播放逻辑 + loading/错误态；`api/` 下新增 `ttsPreview` 调用方法。
- **部署**: api + web + common(+engine 重装 pin) 需重新部署；无 DB migration、无新增凭据、无 OSS。
