<!-- SUPERSEDED 2026-06-08 by `engine-rtc-dingrtc-migration`（§7）。本提案补全的是 ARTC binding 的 join-config 接口，但整个 ARTC binding 已被 DingRTC 替换删除（engine 5e1ab5f），需求作废。spec delta 为废弃设计，归档 --skip-specs 不并入 specs/。 -->

## Why

`windows-artc-pybind11` spec § "必绑定的最小 SDK 接口集" 明列 binding
必须暴露 5-arg `JoinChannel(token, channel, uid, username, joinConfig)`
+ `SetExternalAudioSource` + `PushExternalAudioFrameRawData`。

但当前 `aliyun_artc_pywrap.cp312-win_amd64.pyd` (build at 2026-05-17 by
windows-artc-pybind11 §9.1) **实装 incomplete**：
- `EngineHandle.join_channel(token, channel, uid, name)` — 只 4 args，**缺
  joinConfig**
- `SetClientRole` / `PublishLocalAudioStream` / `SetExternalAudioSource`
  全部**未暴露**
- `JoinChannelConfig` struct / `ChannelProfile` / `AudioFormat` /
  `VideoFormat` / `AliEngineClientRole` enum 全部**未暴露**

2026-05-24 joint-mvp-gate-13301035545 §3.2 真跑 ARTC RTC join smoke
discovered：native `JoinChannel` 返 rc=16974081 拒接缺 config 的 join；
on_join 也由 native 异步回调一个 error code。所有上层 (joint-mvp-gate
§3-§7 拨号链路) 阻塞在此。

## What Changes

- **MODIFIED**: `isales-telephony/deploy/edge/windows/pybind/aliyun_artc_pywrap/src/bindings.cpp`
  扩 EngineHandle binding 加 setter (per ARTC C++ native API
  `engine_interface.h` 真实签名 — Windows 用 setter pattern，不是 Linux
  Python wrapper 的 JoinChannelConfig struct pattern；两边 ARTC API 差异
  本是 vendor 设计)：
  - 加 `set_channel_profile(profile: AliEngineChannelProfile)` —
    `SetChannelProfile()` per engine_interface.h:3843
  - 加 `set_client_role(role: AliEngineClientRole)` — per :3855
  - 加 `publish_local_audio_stream(enabled: bool)` — per :4189
  - 加 `set_external_audio_source(enable: bool, sample_rate: int, channels: int)`
    — per AliEngineExternalAudioStreamConfig + AddExternalAudioStream
    既有 binding 已部分用，本 change 暴露独立 setter 接口
  - 加 enum binding: `AliEngineChannelProfile` (含
    `ChannelProfileCommunication / ChannelProfileInteractiveLive`) +
    `AliEngineClientRole` (含 `AliEngineClientRoleInteractive /
    AliEngineClientRoleLive`)
  - **保留** `join_channel(token, channel, user_id, user_name)` 4 args
    现签名（ARTC Windows native API 就这么定的；不加 5-arg overload，
    因 native 不存在）
  - 调用方在 `join_channel` 之前 SHALL 顺序调:
    `set_channel_profile(InteractiveLive)` → `set_client_role(Interactive)`
    → `set_external_audio_source(True, 8000, 1)` → `publish_local_audio_stream(True)`
- **重 build** `.pyd` via 既有 `CMakeLists.txt` + `build.ps1` 流程
- **MODIFIED**: `isales-telephony/scripts/pybind_rtc_join_smoke.py` 适配
  5-arg join_channel + JoinChannelConfig setup（已在 2026-05-24 commit
  189f669 部分发现 binding gap；本 change 收尾让 smoke pass）
- **更新** `isales-telephony/deploy/edge/windows/STATE.md` §"pybind §9.4
  smoke 通过" 加证据 (on_join(code=0) timestamp / elapsed_ms)
- **MODIFIED**: `windows-artc-pybind11` change spec 中 § "必绑定的最小
  SDK 接口集" Scenario 加详细字段清单 (展开 joinConfig 必须暴露的 7 个
  字段 + 4 个 enum 类型) 让未来维护者知道 "已经全暴露" vs "差什么"。

## Capabilities

### New Capabilities

<!-- 无 — 不引入新 spec capability，本 change 仅实施已 spec'd 但未实
     装的 binding 接口。 -->

### Modified Capabilities

- `device-hardware` (via `windows-artc-pybind11` 待 archive 的 spec)：
  § "必绑定的最小 SDK 接口集" Scenario 加详细字段清单。Scenario 行为不
  变（"必须暴露 5-arg JoinChannel + joinConfig"），仅把约束写得更精确
  方便实施验证。

## Impact

- **affected repos**:
  - `isales-telephony` (中)：
    - `deploy/edge/windows/pybind/aliyun_artc_pywrap/src/bindings.cpp` 扩 ~150 行
    - `aliyun_artc_pywrap.cp312-win_amd64.pyd` 重 build (CMake) — 输出
      文件 gitignored，运行时本机生成
    - `scripts/pybind_rtc_join_smoke.py` 适配 5-arg + 加 JoinChannelConfig
      setup (channelProfile = InteractiveLive, isAudioOnly=True, 等)
    - `deploy/edge/windows/STATE.md` 加 §9.4 smoke 证据块
- **affected specs**: `device-hardware` Requirement "必绑定的最小 SDK
  接口集" Scenario 详化（在 windows-artc-pybind11 change scope 内）。
- **依赖** (must be true before apply):
  - Windows dev box Python 3.12.10 + CMake 4.3.2 + MSVC 19.44 + pybind11
    v3.0.4 (per windows STATE.md ✓ 全就位 since 2026-05-17)
  - ARTC vendor SDK headers + DLLs 在 vendor 目录 ✓ (gitignored 已就位)
  - ECS engine `isales-engine-mint-rtc-token` CLI ✓
    (joint-mvp-gate-13301035545 §2 已落地)
- **BREAKING**: pybind binding API surface 变 — `join_channel(4 args)`
  改成 `join_channel(5 args)`，旧 4-arg 调用法**移除**。但 `.pyd` 是
  gitignored 运行时构建物 + 没有外部依赖方（仅 `isales-telephony` 自身
  + smoke scripts 使用），本 BREAKING 范围零；smoke scripts 同步改 5-arg。
- **回滚**: 万一新 binding 触发 SDK 端 regress，回滚 `bindings.cpp` 到
  pre-change commit + rebuild `.pyd` 即可；C++ 源码层 git revert 直接。
- **unblock**: 本 change archive 后 joint-mvp-gate-13301035545 §3-§7 可
  继续跑（pybind binding 完整后真 RTC join + PCM loopback + 真拨号都
  能用统一 binding 通路）。
