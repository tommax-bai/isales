## Context

Windows ARTC SDK 通过项目内 `aliyun_artc_pywrap` pybind11 binding 暴露
到 Python (per `windows-artc-pybind11` change，2026-05-17 §9.1 §9.2
ticked，.pyd 已 build)。但 binding **暴露的方法集 incomplete**:

- 当前 EngineHandle 方法：`create / is_alive / set_event_listener /
  register_audio_observer / unregister_audio_observer /
  add_external_audio_stream / push_external_audio /
  remove_external_audio_stream / join_channel(4 args) / leave_channel /
  destroy`
- **缺**：`set_channel_profile / set_client_role /
  publish_local_audio_stream / set_external_audio_source`
- 缺 enum binding: `AliEngineChannelProfile / AliEngineClientRole`

2026-05-24 真跑 ARTC RTC join smoke (joint-mvp-gate-13301035545 §3.2)
discovered：缺这些 setter 直接调 `JoinChannel` → ARTC SDK native rc =
16974081 + on_join callback 报同样的错误码异步上来。SDK 拒接 default
config 下的 join (channelProfile 默认 0 / 客户角色未指定 / 外部音频源
未声明)。

ARTC native API 实际签名 (per `vendor/aliyun-artc-windows/include/rtc/
engine_interface.h` 一手验证):

```cpp
// :3843
virtual int SetChannelProfile(const AliEngineChannelProfile channelProfile) = 0;
// :3855
virtual int SetClientRole(const AliEngineClientRole clientRole) = 0;
// :4189
virtual int PublishLocalAudioStream(bool enabled) = 0;
// :3936 (现有 binding 用的就是这个)
virtual int JoinChannel(const char *token, const char *channelId,
                        const char *userId, const char *userName) = 0;
```

**重要发现**: Windows ARTC native API **没有** Linux Python wrapper 用的
5-arg `JoinChannel(..., JoinChannelConfig)` 签名。Linux wrapper 是 SDK
方在 Python 层封装的 syntactic sugar。Windows 走 setter pattern。我们
不要照 Linux 形式扩 5-arg JoinChannel，那是错的设计假设。

## Goals / Non-Goals

**Goals:**
- pybind binding 扩 4 个 setter 方法 + 2 个 enum，使 `pybind_rtc_join_smoke.py`
  在 join 前能完整 setup 进入 SDK 满意的状态机
- 重 build `.pyd` via 既有 build.ps1 / CMake 流程
- §9.4 smoke pass — `on_join(code=0)` + clean leave + destroy + idle 5s
  无 disconnect / error
- 解锁上游 `joint-mvp-gate-13301035545` §3-§7 拨号闭环

**Non-Goals:**
- **不**加 5-arg JoinChannel overload — Windows ARTC native 没这签名
- **不**做 §9.5 PCM push/pull 端到端 (joint-mvp-gate §4 跑)
- **不**做 PyInstaller frozen exe (windows-artc-pybind11 §9.3 独立)
- **不**测试真拨号 (joint-mvp-gate §7)
- **不**改 Linux ARTC wrapper (`isales-engine/_rtc_sdk.py`)；两边各自 API
  原生不一致是 vendor 设计本身

## Decisions

### D1: setter pattern，不模仿 Linux 5-arg JoinChannel

Windows ARTC SDK native `JoinChannel(token, channel, uid, name)` 是
4-arg signature；channel profile / client role / audio source 通过单独
setter 在 join 前调。Linux Python wrapper 把这些设置打包成
`JoinChannelConfig` struct 是 Linux wrapper 层的封装，**不是 native
API**。本 binding 走 setter 与 native 对齐。

**Alternatives:**
- ① 加 5-arg JoinChannel — 拒绝。Native 没这签名，binding 加了会变成 fake
  facade 内部仍要逐个调 setter，零价值且误导。
- ② 在 Python 高层抽 JoinChannelHelper class 一次性传 dict — 可考虑下次
  迭代；本 change scope 仅 binding 接口对齐 native。

### D2: enum 暴露范围

仅暴露本次需要的 enum constant，**不**追求全暴露 (ARTC SDK enum 文件
很大，每条都暴露 maintenance burden 高):

- `AliEngineChannelProfile`: `ChannelProfileCommunication` (0) +
  `ChannelProfileInteractiveLive` (1)
- `AliEngineClientRole`: `AliEngineClientRoleInteractive` (0) +
  `AliEngineClientRoleLive` (1)

未来需要其他 profile / role 时再扩。

### D3: SetExternalAudioSource 签名

per engine_interface.h, `SetExternalAudioSource` 的 native 签名是:
```cpp
int SetExternalAudioSource(bool enable, unsigned int sampleRate,
                           unsigned int channelsPerFrame);
```
pybind 暴露成 Python `set_external_audio_source(enable: bool,
sample_rate: int, channels: int)`。返回值 native int，Python 端无返回
(异常机制承担错误传播 — 与既有 EngineHandle 方法一致)。

注意: 既有 `add_external_audio_stream` binding 是另一个 ARTC API
(`AddExternalAudioStream` returns stream_id，支持多个 stream)。这是
**不同概念**:
- `SetExternalAudioSource(true, 8k, 1)` — 全局开启外部音频源 + 配采样率
- `AddExternalAudioStream(cfg)` — 加一路外部 stream，多路并发场景

iSales 单路对话用 `SetExternalAudioSource`。本 change 加它；不动现有
`add_external_audio_stream`。

### D4: smoke script setup 顺序

`pybind_rtc_join_smoke.py` 在 binding fix 后调用顺序:

```python
engine = artc.EngineHandle()
engine.create(extras=json.dumps({"app_id": app_id}))
engine.set_event_listener(listener)
engine.set_channel_profile(artc.AliEngineChannelProfile.ChannelProfileInteractiveLive)
engine.set_client_role(artc.AliEngineClientRole.AliEngineClientRoleInteractive)
engine.set_external_audio_source(True, 8000, 1)
engine.publish_local_audio_stream(True)
engine.join_channel(token, channel, user_id, user_name)
# wait on_join(code=0)
...
engine.leave_channel()
engine.destroy()
```

setter 调用顺序与 Linux wrapper `_rtc_sdk.py:304-312` 一致 (PublishLocalAudioStream
→ SetExternalAudioSource → SetClientRole → JoinChannel)。

## Risks / Trade-offs

- **[Risk] 仍 native rc != 0 即使 setup 全做** → 可能 ARTC SDK 还需其他
  setup (e.g., `SetAudioProfile` for sample rate compatibility / 房间
  权限 / AppId 在 console 启用)。**Mitigation**: smoke script 在每个
  setter 之间 print intermediate state；如果 setter 返非 0 native error
  本身就有 trace；on_error callback 也会触发并打印。
- **[Risk] enum 值跨 SDK 版本可能变** → ARTC SDK ABI 版本绑死在 vendor
  目录；本 change 假设 v2.0.20250825c5ac4f4 (per windows STATE.md 2026-05-17
  build smoke)；SDK 升级是独立 PR 评估。
- **[Trade-off] 不暴露 AliEngineChannelParam (engine_interface.h:3955
  的 3-arg + ChannelParam 重载)** → Windows native 这个 overload 含
  meet number / camera 等 video-related 字段，本 change audio-only
  场景用不到；暴露反而误导。如需 video, 走单独 change。
- **[Risk] CMake rebuild 失败** → 既有 build.ps1 流程在 2026-05-17 已
  跑通过 (per STATE.md "Built .pyd in dev location" 部分)，本 change
  只加 ~150 行 cpp，rebuild 失败概率低；若 fail 走 STATE.md § "pybind11
  binding build" troubleshoot path。

## Migration Plan

1. **改 bindings.cpp**:
   - 加 enum binding (~20 行)
   - 加 4 个 setter method 实装 + .def() 注册 (~80 行)
   - 不动现有 join_channel binding
2. **rebuild .pyd**:
   ```powershell
   cd C:\Users\tianx\codes\isales-telephony\deploy\edge\windows
   .\build.ps1 -SkipPyInstaller
   # 期望产出: pybind/aliyun_artc_pywrap/aliyun_artc_pywrap.cp312-win_amd64.pyd
   ```
3. **adapt smoke script**:
   `scripts/pybind_rtc_join_smoke.py` 在 set_event_listener 后 +
   join_channel 前插 4 个 setter (channel profile / client role /
   external audio / publish local audio)
4. **真跑 §9.4 smoke**:
   `py -3.12 scripts/pybind_rtc_join_smoke.py --channel mvp-test
   --user-id edge-mvp --duration 5`
   期望: `on_join(code=0)` 5s 内 + 5s idle 无 disconnect/error +
   clean leave + destroy + exit 0
5. **STATE.md**: 加 §"pybind §9.4 smoke 通过" 含 timestamp + elapsed_ms
6. **commit + push isales-telephony + meta-repo + archive**

## Open Questions

1. **SetAudioProfile / SetAudioOnly 也要绑吗?** Linux wrapper 设
   `isAudioOnly=True` 在 cfg 里。Windows native 看下来用
   `SetVideoEnabled(false)` 或 audio-only profile。**RESOLVED**: 本
   change 先不加，等 smoke 跑通；若 SDK 仍 reject 再加 `SetVideoEnabled`
   或类似。
2. **是否必须 `SetAudioProfile(sample_rate)` 显式调?** ARTC 默认 8kHz
   单声道应该足够 iSales 场景。**RESOLVED**: 不加；走 SDK 默认；smoke
   跑通即过。
3. **publish_local_audio_stream(True) 之后 ARTC 会试图打开本地 mic 吗?**
   Windows 端可能弹权限。**RESOLVED**: 应该不会—— `set_external_audio_source(True, ...)`
   已声明用外部源，SDK 不再尝试本机 mic。smoke 跑通即过。
