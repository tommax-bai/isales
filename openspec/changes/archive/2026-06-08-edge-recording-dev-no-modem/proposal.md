# edge-recording-dev-no-modem

## Why

`edge-local-call-recording`（archived 2026-06-05）把整通 stereo 录音落地在
**modem 路径**：`AudioBridge` 在上行/下行 loop 里 tap PCM，挂断时
`Recorder.finalize` 写 `左=用户 / 右=AI` 的 16 kHz wav。但 dev 团队日常在
**mac** 上用 `--dev-no-modem` 路径做策略 / 工程闭环演练（见
`device-hardware` § "macOS dev-no-modem 形态"），该路径 **不经过 AudioBridge**
——orchestrator 直接持有 `RtcSession`，所以录音功能在 mac 上完全不生效。

结果是：录音功能本身没法在唯一随手可得的 rig（mac）上验证，必须等 Windows
真 modem 实机；而 dev / QA 复盘一通 AI 对话时也拿不到「含 AI 声音」的整通录音
（dev-no-modem 此前只有 engine 侧 15 s 上行 DIAG dump）。

本 change 把录音扩到 dev-no-modem 路径，做到与 modem 路径**行为对等**，让录音
能在 mac 上 QA 验证、dev 复盘能听到双向音频。

## What Changes

- **MODIFIED** `transcript` § "录音存储"：录音 actor 从「modem-controller」
  泛化为「edge」，覆盖 modem（AudioBridge）与 dev-no-modem（orchestrator 直采）
  两条路径；新增 dev-no-modem 录音 parity 场景（含 48 kHz stereo→16 kHz mono
  降采、声道映射）。
- dev-no-modem 路径接入与 modem 路径**同一个** env-gated `Recorder`
  （`ISALES_EDGE_RECORDINGS_DIR` / `ISALES_EDGE_MAX_RECORDINGS` /
  `ISALES_EDGE_RECORDING_MIN_FREE_GB`），不新增配置。
- 用户上行（左声道）= mac mic 推流 PCM（已是 16 kHz mono，零转换）；AI 下行
  （右声道）= SDK `onPlaybackAudioFrame` 的混音播放帧（48 kHz stereo），经
  numpy 降采到 16 kHz mono 后 `append_ai`（Py 3.14 无 audioop）。

## Impact

- Affected specs: `transcript`（录音存储 requirement）
- Affected code: `isales-telephony` —— `edge/orchestrator.py`（dev-no-modem
  录音接线 + `_downmix_playback_to_engine_mono` helper + AI 录音 pump）、
  `edge/main.py`（dev-no-modem 入口接 `_build_recorder`）。
- 无 proto / DB / 跨仓 ABI 变更；`isales-common` 不动。
- 非 dev-no-modem（生产 Windows modem）路径行为不变。
</content>
</invoke>
