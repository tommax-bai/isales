## Context

`campaign-fixed-greeting` 已让运营在场景编辑「基础」tab 设"音色"(`voice_id`)与"开场白文案"(`campaign.greeting`)，全链路上线 ECS。但合成语音目前**只在真拨电话时由 engine 现合成**（`tts-cache-and-gated-filler` 的进程内 lazy 缓存，无预生成、无持久化）。运营改完文案要听效果必须真打一通，反馈环很重。

现状 ground-truth（已核实）：
- TTS ABC 在 `isales-common/isales_common/providers/tts.py`；**真实实现 `VolcengineTTSProvider`（V3 SSE，304 行）在 `isales-engine`**，仅依赖 stdlib + `httpx` + 该 ABC + engine 本地的 `providers/_errors`。
- 凭据走 `provider_credential` 表 + `isales_common.credentials.CredentialStore`；**isales-api 已在 `provider_credentials.py` 使用 `CredentialStore`**（能 decrypt 凭据）。
- TTS 输出为裸 PCM 16-bit LE mono（默认 16k），浏览器 `<audio>` 不能直接播。

## Goals / Non-Goals

**Goals:**
- 运营在保存/拨号前能对"当前文案 + 当前音色"现合成并在浏览器试听。
- api 与 engine 共用同一份 TTS 真实实现，不在 api 侧重复实现 vendor 协议。

**Non-Goals:**
- 不做预生成 / 持久化 / OSS / 启动预热（沿用 engine 的 lazy 内存缓存现状，不动）。
- 不改 engine 开场白播放路径与既有 TTS 行为。
- 不引入新凭据、不加 DB migration、不做音色管理改造。

## Decisions

### 决策 1：TTS 真实实现下沉到 isales-common（而非 api 复制 / 调 engine RPC）

把 `tts_volcengine.py` + TTS `build_tts` 工厂分支 + 依赖的 `_errors` 从 isales-engine 移到 `isales-common/isales_common/providers/`，engine 改为 `from isales_common.providers ... import`。

- **为什么**：api 要合成就得拿到 provider。三条路——(a) 下沉 common 共用；(b) api 复制一份 vendor V3 SSE 客户端；(c) engine 暴露合成 RPC，api 远程调。(b) 直接违反 CLAUDE.md「不重复实现 / 不堆多层」——V3 SSE 有 5 个已知 gotcha（见 `[[reference_artc_sdk]]`），复制必然漂移。(c) 把试听延迟耦合到 engine 在线 + 多一层 RPC 面，且 engine 是控制面，不该承载 web 同步请求。(a) 因为该实现几乎不耦合 engine（唯一耦合是 `_errors`），下沉成本最低且最干净，凭据本就在 common 的 `CredentialStore`。
- **spec 影响**：`provider-abc` 现规定"真实实现仅在 isales-engine"，需 MODIFY 放宽为"被多服务共用的真实实现下沉 common"。

### 决策 2：api 端点合成后封 WAV header 返回 audio/wav

`POST /campaigns/tts-preview` body `{text, voice_id}` → `build_tts("volcengine", store=...)` → `async for chunk in synthesize_stream(text, voice_id)` 累积 PCM → 前置 44 字节 WAV header（PCM/16-bit/mono/sample_rate 与 provider 输出一致）→ `Response(content=wav, media_type="audio/wav")`。

- **为什么 WAV 而非 PCM/mp3**：裸 PCM 浏览器不能播；WAV 只需 44 字节定长头、零额外依赖、零转码延迟；mp3/opus 要引编码器，不值当。
- **无状态**：不读写 campaign 行，`text`/`voice_id` 取前端当前（可能未保存）表单值，所以**不需要 campaign_id**。试听用的是"草稿态"，符合"保存前先听"。
- **一次性返回 vs 流式**：试听文案短（≤200 字），整段合成完再返回足够（百毫秒级），不引入分块流式播放复杂度。

### 决策 3：text 长度上限 + 鉴权

端点对 `text` 设 ≤200 字上限（开场白实际 ~25 字，留足余量），超限 422；`voice_id` 必填非空。沿用现有 `CurrentUser` 依赖鉴权，防未登录滥用 vendor 配额。

### 决策 4：前端按钮 disabled 条件 + 播放

按钮在 `greeting` 为空或 `voice_id` 为空时 disabled。点击 → loading → `fetch` 拿 blob → `new Audio(URL.createObjectURL(blob)).play()`，播完/出错 `revokeObjectURL`。失败弹 `ElMessage.error`。同一时间只播一个，再次点击先停上一个。

## Risks / Trade-offs

- **下沉 provider 触及 engine 热路径** → 仅移动文件 + 改 import，保持类名/签名/行为不变；以 engine 现有 TTS 单测（`test_tts_cache` 等）+ `make test-all` 守住无回归。`_errors` 若被 engine 其他模块共用，则一并下沉 common 并在 engine 留 re-export shim（仅过渡，注明移除条件）。
- **试听消耗 vendor TTS 配额** → text 上限 + 登录鉴权；试听是人工点击、低频，量级远小于真实通话。
- **采样率/声道与 WAV 头不一致会播成噪音** → header 的 sample_rate/channels/bits 从 provider 实际输出参数取，不写死；加一条端到端断言（合成 25 字 → wav 时长 > 0）。
- **isales-common bump 未同步 pin** → 按 CLAUDE.md 跨仓约定，bump common 版本并更新 engine/api 的 pin，部署时重装。

## Migration Plan

无 DB migration。部署顺序：isales-common 发版 → engine/api 更新 pin 重装 → 部署 api(新端点) + web(试听按钮)。回滚：web 去掉按钮即隐藏入口；api 删端点；common provider 下沉是纯文件位置变更，engine 可回退 import。
