## Context

通话录音的代码地基已大半就位：`isales_telephony/modem_controller/recorder.py` 的 `Recorder` 类能 `begin_call` / `append_user` / `append_ai` / `finalize`，并由 `_write_stereo_wav` 生成 stereo 16 kHz WAV（左=用户上行、右=AI 下行）。`RedisRecordingQueue` 也已写好，准备把录音推给 worker 上传 OSS。

但实际从未接通：modem-controller 主流程没有创建 `Recorder` 实例、没有在通话生命周期里调用 begin/append/finalize；worker 侧没有 `recording-upload` consumer；`call_record.recording_url` 字段空置。现有 `transcript/spec.md`「录音存储」requirement 描述的是 OSS 归档链路，与 v1.0 实际诉求（edge 本机能录、能听，用于调试 / 质检）不匹配，且全链路无一端落地。

edge（modem-controller）天然同时握有两路 PCM：用户上行（modem 读取的 GSM 远端音频）和 AI 下行（cloud engine 经 RTC 下发、edge audio-bridge 写给 modem 的 TTS）。因此录音只需在 edge 完成，cloud engine 全程不进录音链路。

## Goals / Non-Goals

**Goals:**
- 在 edge 端把每通话录成单个 stereo WAV（左=用户、右=AI），落本地磁盘。
- 纯本地滚动保留：只留最近 N 个录音（默认 N=10，按文件个数删旧），磁盘占用有上界。
- 最小改动：只动 `isales-telephony` 一个仓，复用现有 `Recorder` 类，不动 common / worker / api / web / engine。

**Non-Goals:**
- OSS 上传、`recording_url` 回写、admin 后台回放 —— 全部 v1.x 范围外。
- 前端用 transcript `ts` 字段跳转播放 —— 依赖 admin 回放，v1.x 范围外。
- 按总大小 / 时长滚动 —— 本 change 只做按个数；不设大小上限。
- PII 脱敏 / 加密 / 录音留存合规策略 —— 与现有「PII 脱敏 v1 不做」一致，范围外。
- 高可用 —— 录音是 edge 本地文件，机器坏即丢，不做冗余备份。

## Decisions

### Decision 1：录音归属 edge，cloud engine 不碰

录音全程在 modem-controller 完成。理由：edge 是唯一同时握有"未经云端 RTC 编解码 / 重采样折叠"的双向原始 PCM 的节点；让 cloud engine 参与会引入跨云-边传文件的复杂度，且 engine 拿到的音频已是为 ASR 加工过的料（48k→16k、stereo→mono），不适合做存档。这也消掉了原方案里"engine 写 recording_url"的集成缺口。

**备选**：在 cloud engine `_inbound_loop` dump RTC 混流 → 否决，冗余且需跨端归档。

### Decision 2：复用 `Recorder` 类，仅新增 `prune(keep=N)`

`Recorder.begin_call/append_user/append_ai/finalize` 与 `_write_stereo_wav` 原样复用。新增 `prune(keep: int)`：列出录音目录下 `*.wav`，按 `mtime` 降序，删除第 N 个之后的旧文件。在每次 `finalize` 之后调用。

**备选**：每次写文件前清理 → 否决，finalize 后清理更直观（"刚写完，删到只剩 N 个"），且单线程顺序调用无并发竞态。

### Decision 3：滚动按文件个数，不设大小上限

按 `MAX_RECORDINGS`（默认 10）个数滚动。用户明确选择纯个数、不加总大小双保险。一通 5 分钟 ≈ 19 MB，10 个约 190 MB，叠加现有 `DiskFullError`（`min_free_gb` 下限）足以防爆盘。长通话导致单文件偏大属已知 trade-off（见 Risks）。

### Decision 4：`RedisRecordingQueue` 保留不删，本路不调用

保留该类与 `file_sha256`，docstring 标注"为未来 OSS 上传路径预留"。本 change 的 modem-controller 主流程不实例化 / 不调用它。理由：避免删了 v1.x 还要重写；但**不**在主流程里留"如果配置了 OSS 就上传"的分支——那会变成一层无触发条件的 fallback（违反多层兜底规则）。OSS 路径重启用时由对应 v1.x change 显式接线。

### Decision 5：env 配置 `RECORDINGS_DIR` / `MAX_RECORDINGS`

- `RECORDINGS_DIR`：录音落盘目录（edge 本地路径）。
- `MAX_RECORDINGS`：默认 10。设为 0 时禁用录音（不 `begin_call`），用于完全关闭。
- 磁盘下限沿用 `Recorder(min_free_gb=...)` 现有兜底；`begin_call` 抛 `DiskFullError` 时记 warning 并跳过本通录音，不影响通话本身。

## Risks / Trade-offs

- **长通话单文件偏大** → 按个数滚动时 N 个长通话可能远超 ~190 MB 预估。Mitigation：`DiskFullError` 下限兜底；若实测胀得离谱，v1.x 再补大小上限（已在 Non-Goals 标注为本 change 不做）。
- **机器坏 / 磁盘丢 → 录音全失** → 这是"纯本地、不传 OSS"的固有代价，已是用户知情的明确选择。Mitigation：无（接受）；需云端留存时走 v1.x OSS change。
- **录音写入拖慢挂断收尾** → `finalize` 在挂断路径同步写整文件 + prune。Mitigation：5 分钟通话 ~19 MB 顺序写盘亚秒级，可接受；若 P99 偏高，后续可把 finalize 移到挂断后的异步任务。
- **录音含明文通话音频留在 edge 本机** → 与现有「PII 脱敏 v1 不做」一致，仅靠本机访问控制。Mitigation：范围外，沿用现状。
- **`begin_call` 抛 `DiskFullError` 吞掉录音** → 通话正常但无录音文件，易被误判为"录音坏了"。Mitigation：抛错时记结构化 warning（含 free / 阈值），运维可凭日志区分"盘满跳过"与"代码 bug"。
