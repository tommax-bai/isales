## Why

通话录音目前停留在"零件备齐、没装上线"状态：`modem_controller/recorder.py` 的 `Recorder` 类已能把每通话录成 stereo WAV（左=用户上行 / 右=AI 下行），但从未接入 modem-controller 主流程，worker 侧的 OSS 上传 consumer 也完全没写，端到端录不出文件。现有 `transcript/spec.md`「录音存储」requirement 要求 worker 异步上传 OSS + 回写 `recording_url` + 前端用 `ts` 回放——这套云端归档链路在 v1.0 还没有任何一端落地，且对当前的边缘调试 / 质检诉求是过度设计。

v1.0 只需要一个最小可用的录音：在 edge 端把通话录下来、本地能听。先把"能录、能听"跑通，云端归档（OSS + admin 回放）作为 v1.x 再补。

## What Changes

- edge 端（modem-controller）在通话生命周期内启动 / 写入 / 收尾录音：起呼 `begin_call` → 音频 loop `append_user` / `append_ai` → 挂断 `finalize`。
- 新增**纯本地滚动保留**：每次 `finalize` 后按文件 mtime 删旧，只保留最近 N 个录音（默认 N=10，按**文件个数**滚动，不设总大小上限）。
- **不传 OSS、不回写数据库、admin 后台看不到**：录音是 edge 本地文件，机器坏即丢，仅供本机调试 / 质检自留。
- edge env 新增 `RECORDINGS_DIR`（录音落盘目录）、`MAX_RECORDINGS`（默认 10）；磁盘下限沿用现有 `DiskFullError` 兜底。
- `RedisRecordingQueue` 类保留不删（标注未来 OSS 路径复用），但本 change 不调用它；worker 不新增任何 consumer。
- **BREAKING（spec 层）**：`transcript/spec.md`「录音存储」requirement 的行为从"OSS 归档 + recording_url + ts 回放"改为"edge 本地 stereo WAV + 滚动保留最近 N 个"；OSS 上传与前端 ts 回放标为 v1.x 范围外。

## Capabilities

### New Capabilities
<!-- none — 录音行为归属现有 transcript capability -->

### Modified Capabilities
- `transcript`:「录音存储」requirement 改为 edge 本地滚动保留模型（去掉 OSS 上传 / recording_url 写入 / ts 回放，标为 v1.x 范围外）。

## Impact

- **代码**：只动 `isales-telephony` 一个仓——
  - `isales_telephony/modem_controller/recorder.py`：新增 `prune(keep=N)`（按 mtime 删到最近 N 个），更新 docstring（去掉 OSS 描述）。
  - `isales_telephony/modem_controller/` 主流程：接线 `Recorder` 到通话生命周期（begin / append / finalize+prune）。
  - edge 配置：新增 `RECORDINGS_DIR` / `MAX_RECORDINGS`。
- **不动**：`isales-common`（`call_record.recording_url` 字段保留为 v1.x 预留，本路不写，无 migration）、`isales-worker`（不加 recording-upload consumer）、`isales-api` / `isales-web`（admin 无录音入口）、`isales-engine`（全程不进录音链路）。
- **spec**：`openspec/specs/transcript/spec.md`「录音存储」requirement（delta MODIFIED）。
- **数据 / 隐私**：录音含通话明文音频，仅存 edge 本地磁盘，受本机访问控制；与现有「PII 脱敏 v1 不做」一致，不引入新的留存 / 加密策略。
