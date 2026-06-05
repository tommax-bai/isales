<!-- Telephony-side code landed in isales-telephony commit 8db0be4
     (branch debug/mac-dev-no-modem-asr-stereo-fix-20260601). -->

## 1. 降采 helper

- [x] 1.1 `edge/orchestrator.py` 新增纯函数 `_downmix_playback_to_engine_mono(pcm, src_rate, src_channels)`：stereo→mono（按声道均值）+ `np.interp` 重采样到 `ENGINE_SAMPLE_RATE`；空输入返回 `b""`；clip 到 int16
  <!-- numpy（recorder 已依赖），Py 3.14 无 audioop。import ENGINE_SAMPLE_RATE from modem_controller.audio_pipe。 -->
- [x] 1.2 单测 `_downmix_playback_to_engine_mono`：空→空；16k mono 原样返回；48k stereo(L=1000,R=3000)→16k mono≈2000 且样本数 1/6
  <!-- tests/edge/test_orchestrator_dev_no_modem.py::test_downmix_playback_to_engine_mono -->

## 2. dev-no-modem 录音接线

- [x] 2.1 `_arun_dev_no_modem`（`edge/main.py`）复用 `_build_recorder()`，把 `recorder` / `max_recordings` 传进 `EdgeOrchestrator`（与 modem 入口同一 env 三件套，不新增配置）
  <!-- 与 _arun 对齐；env 未设 → recorder=None → 行为同改前。 -->
- [x] 2.2 `_on_dial_dev_no_modem`：join 成功后，`recorder is not None and max_recordings>0` 时 `begin_call(call_id)` + 设 `ctx.recorder` / `ctx.max_recordings`；`DiskFullError` → warning 跳过、通话继续（镜像 modem 路径）
  <!-- 复用既有 _CallContext.teardown 的 finalize+prune，dev 路径不另写收尾。 -->
- [x] 2.3 用户上行（左）：`_dev_no_modem_mic_capture_pump` 推流后 `ctx.recorder.append_user(call_id, chunk)`（16k mono，零转换）
- [x] 2.4 AI 下行（右）：新增 `_dev_no_modem_ai_recording_pump` 消费 `rtc_session.audio_frames()`，每帧经 §1.1 降采后 `append_ai`；仅录音开启时启动；`RtcNotJoined`（leave 抢先）静默返回，其它异常 log 不阻断通话
  <!-- 顺带排空原本无消费者、走 drop-oldest 的播放队列。 -->
- [x] 2.5 接线单测：带 `Recorder(tmp_path)` 的 dev-no-modem 通话（`ISALES_DEV_NO_MIC_CAPTURE=1` 跳过真 mic），fake `audio_frames` 喂 48k stereo 帧 → 挂断后断言写出 stereo/16k wav 且右声道非静音、左声道静音
  <!-- ::test_dev_no_modem_records_ai_channel；全套 tests/edge + recorder + audio_bridge 67 passed -->

## 3. 验证

- [x] 3.1 mac `--dev-no-modem` 真机：设 `ISALES_EDGE_RECORDINGS_DIR` 起 edge → 触发一通 AI 对话 → 确认 `RECORDINGS_DIR/<call_id>.wav` 写出、stereo 16k、左=自己说话 / 右=AI、`recording_finalized` 日志出现、`call_record.recording_url` 仍为空
  <!-- 2026-06-05 call 155: ~/isales-recordings/155.wav 2.6MB, ch=2 sr=16000 40.8s; 左(用户)RMS=249/peak=1940/非静音37.7%, 右(AI)RMS=721/peak=20098/非静音6.1% — 双声道分离正确。recording_url 仍 NULL。 -->
- [x] 3.2 文档：`deploy/edge/macos/RUNBOOK.md` § 7 补「开录音」一步（设 `ISALES_EDGE_RECORDINGS_DIR` + WAV 落盘位置），替换原 § 7.5「dev 无正式录音」的结论
  <!-- RUNBOOK § 7.5 重写为「Recording the call (both channels)」：export ISALES_EDGE_RECORDINGS_DIR 开录音、WAV 落盘路径 + afplay；engine 15s DIAG dump 降为 fallback。 -->

## 4. 验收

- 全套 `tests/edge/ + test_audio_bridge + test_modem_recorder` 67 passed
- `openspec validate edge-recording-dev-no-modem --strict` 通过
- mac call 155 真机录音双声道实证（见 3.1）
</content>
