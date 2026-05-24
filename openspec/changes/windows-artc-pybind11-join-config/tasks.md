## 1. 扩 bindings.cpp

- [ ] 1.1 加 enum binding (~20 行 in pybind module init): `AliEngineChannelProfile` (`ChannelProfileCommunication=0` + `ChannelProfileInteractiveLive=1`) + `AliEngineClientRole` (`AliEngineClientRoleInteractive=0` + `AliEngineClientRoleLive=1`)；用 `py::enum_<AliEngineChannelProfile>` / `py::enum_<AliEngineClientRole>` 暴露
- [ ] 1.2 加 `EngineHandle::set_channel_profile(profile)` 方法 — 内部调 `engine_->SetChannelProfile(profile)`；非零 rc 抛 `AliyunArtcError(rc, "SetChannelProfile failed")`
- [ ] 1.3 加 `EngineHandle::set_client_role(role)` 方法 — 同 pattern，调 `engine_->SetClientRole(role)`
- [ ] 1.4 加 `EngineHandle::set_external_audio_source(enable: bool, sample_rate: int, channels: int)` 方法 — 调 `engine_->SetExternalAudioSource(enable, sample_rate, channels)`
- [ ] 1.5 加 `EngineHandle::publish_local_audio_stream(enabled: bool)` 方法 — 调 `engine_->PublishLocalAudioStream(enabled)`
- [ ] 1.6 在 `PYBIND11_MODULE` 块的 EngineHandle class 注册 4 个新 method 的 `.def()` 行
- [ ] 1.7 grep 确认 `join_channel(4 args)` 现签名**未改**（per design D1 setter pattern；不加 5-arg overload）

## 2. CMake rebuild .pyd

- [ ] 2.1 cd `C:\Users\tianx\codes\isales-telephony\deploy\edge\windows`；run `.\build.ps1 -SkipPyInstaller`（per windows STATE.md § "pybind11 binding build" 既有流程）
- [ ] 2.2 验产出 `pybind\aliyun_artc_pywrap\aliyun_artc_pywrap.cp312-win_amd64.pyd` mtime > pre-change；filesize 不显著缩水 (~258 KB +/- 20 KB acceptable)
- [ ] 2.3 import smoke: `py -3.12 -c "import sys; sys.path.insert(0, 'deploy/edge/windows/pybind/aliyun_artc_pywrap'); import aliyun_artc_pywrap as a; print(sorted([s for s in dir(a) if not s.startswith('_')]))"` 输出含新加的 `AliEngineChannelProfile` + `AliEngineClientRole` 加 6 既有符号 = 8 个 module-level 符号
- [ ] 2.4 instance method smoke: `engine = a.EngineHandle(); engine.create(extras='{"app_id":"o6dpsan9"}'); 'set_channel_profile' in dir(engine); 'set_client_role' in dir(engine); 'set_external_audio_source' in dir(engine); 'publish_local_audio_stream' in dir(engine); engine.destroy()` 全 True

## 3. 适配 smoke script

- [ ] 3.1 改 `isales-telephony/scripts/pybind_rtc_join_smoke.py` `[2/4] creating EngineHandle` 段：在 `engine.set_event_listener(listener)` 之后，`engine.join_channel(...)` 之前，依序插：① `engine.set_channel_profile(artc.AliEngineChannelProfile.ChannelProfileInteractiveLive)`；② `engine.set_client_role(artc.AliEngineClientRole.AliEngineClientRoleInteractive)`；③ `engine.set_external_audio_source(True, 8000, 1)`；④ `engine.publish_local_audio_stream(True)`
- [ ] 3.2 同样适配 `scripts/pybind_pcm_loopback_smoke.py`（§9.5 也走完整 setup）

## 4. 真跑 §9.4 smoke

- [ ] 4.1 `$env:PYTHONPATH = "C:\Users\tianx\codes\isales-telephony\deploy\edge\windows\pybind\aliyun_artc_pywrap"; cd C:\Users\tianx\codes\isales-telephony; .\.venv-runtime\Scripts\python.exe scripts\pybind_rtc_join_smoke.py --channel mvp-9-4-test --user-id edge-mvp --duration 5`
- [ ] 4.2 期望输出: `[1/4] minting token` → `token minted` → `[2/4] creating EngineHandle` → `[3/4] join_channel ...` → `on_join(code=0, channel='mvp-9-4-test', user_id='edge-mvp', elapsed_ms=N)` 5s 内 → `[4/4] idle 5s 监听 error events` → 无 on_error → `leave_channel + destroy` → `✓ §9.4 RTC join smoke PASSED` → 最末行 JSON `{"ok": true, ...}` + exit 0
- [ ] 4.3 失败 troubleshoot: ① on_join code 仍非 0 → 检查 SDK 错误码表 + 可能要加 `SetVideoEnabled(False)` / `SetAudioProfile(...)` 等 setter (design Open Q §1 §2)；② create() silent abort → 重检 extras JSON 含 app_id + os.add_dll_directory 注入；③ 找不到 vendor DLL → check pybind 目录 5 个 DLL 完整 (AliRTCSdk + alivcffmpeg + alivcx265 + PluginAAC + x264)
- [ ] 4.4 把通过证据 (timestamp + channel + elapsed_ms + on_join code=0) 加进 `isales-telephony/deploy/edge/windows/STATE.md § "pybind §9.4 smoke 通过"`

## 5. 清理 + 验证 + archive

- [ ] 5.1 `openspec validate windows-artc-pybind11-join-config --strict` 通过
- [ ] 5.2 `openspec validate --specs && --changes` 全绿
- [ ] 5.3 写 `acceptance.md` (verified local + 真跑 §9.4 输出 + binding gap 6 行总结 + 关联 joint-mvp-gate-13301035545 §3 解锁)
- [ ] 5.4 commit + push isales-telephony (bindings.cpp + smoke scripts adapter) + meta-repo (specs + acceptance)
- [ ] 5.5 `openspec archive windows-artc-pybind11-join-config --yes`
- [ ] 5.6 通知 joint-mvp-gate-13301035545 §3-§7 可继续：把 §3.2 BLOCKED 注释改为"unblocked 2026-XX-XX by windows-artc-pybind11-join-config"
