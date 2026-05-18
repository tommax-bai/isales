## Context

iSales v1.0 商用形态 = Windows + 真 GSM modem + 真 Aliyun ARTC，由 `arch-cloud-edge-split` (A2, 52/64 active) + `windows-artc-pybind11` (39/51 active) 联合交付。云端 4 个服务已部署到 `121.89.85.150`，cloud-edge gRPC smoke 已绿（详见 `deploy/cloud/STATE.md`）。

开发同学的日常工作机是 mac。**之前**的 spec 假设 mac 是"一次性 QA Mac mini"形态（A2 design Decision 7 / 2026-05-14 决策），所以 mac 上 audio_bridge 走 `MacosRtcSession` 同进程 loopback mock（`isales-telephony/audio_bridge/session.py`），engine 那边走 `InMemorySdkChannel`——这种组合验证 wire-format / ABC 契约 / 单测够用，但 dev 测出的 latency / barge-in / VAD / 抗噪行为外推不到 Windows + 真 ARTC + 真 modem 的商用链路。

mac 上接真 Aliyun RTC 信道的唯一路径是 PyObjC bridge。macOS ARTC SDK 形态（`reference_artc_sdk.md` 已记，2026-05-14 inspect）：

- `AliRTCSdk_7.8.10000-SNAPSHOT.zip`（17 MB，远小于 Linux 137 MB）
- 解压后含 3 个 framework：`AliRTCSdk.framework`（主）+ `UTDID.framework` + `PluginAAC.framework`
- `AliRTCSdk.framework/Versions/A/AliRTCSdk` — Mach-O universal binary（x86_64 + arm64 dylib）
- `Headers/`：**19 个 .h 全是 Obj-C interface**（`AliRtcEngine.h` / `AlivcLivePusher.h` 等）
- `engine_c_interface.h`：只有 **4 个 `ALI_RTC_API`**，全是 video/screenshare（`push_external_video_frame` / `start_screen_share` / `stop_screen_share` / `set_screen_share_encoder_configuration`）
- **主 audio API**（`joinChannel:` / `pushExternalAudioFrame:` / `OnSubscribeAudioFrame:` / `setExternalAudioSource:` / `leaveChannel`）**全在 Obj-C interface**，Aliyun 不出 Python wrapper

2026-05-14 决策不做 PyObjC bridge 的理由：mac edge 一次性 QA / Windows D1 落地后退役 / ROI 低。今天前提反转：mac 是**长期 dev 机**，PyObjC bridge 数百行换持续真 RTC 测试能力。

约束：
- `MacosRtcSession` mock（CI / unit-test fixture）必须保留，不能替换
- 商用 PyInstaller / Windows build / cloud deploy 路径不能侵入
- 与 `windows-artc-pybind11` pattern 对称：项目内绑定层、`RtcSession` ABC 实装、与 `WindowsRtcSession` 形状一致
- mac 装不了 GSM modem 驱动；dev 模式必须跳过 modem 链路
- A2 cloud-side 不感知 edge 是真 modem 还是 dev no-modem（已在 superseded change 设计中确立）

## Goals / Non-Goals

**Goals:**
- mac 上 audio_bridge 可以**真 join Aliyun RTC 房间**作为 "edge-{call_id}"，与 cloud engine（121.89.85.150 上的 Linux Python wrapper SDK）通过真 ARTC PaaS 互通
- 复用既有 A2 控制面（cloud-edge gRPC bidi）+ 数据面（真 ARTC），dev 测出来的延迟 / barge-in / VAD / 抗噪可以直接外推到 Windows 商用
- 与 `windows-artc-pybind11` pattern 对称：项目内绑定 + 实施 `RtcSession` ABC + 失败模式对齐
- mac dev 形态可演练完整 v1.0 策略层（拨真手机 / 听 AI 开场白 / barge-in / 垫词 / handoff），但不进入 v1.0 MVP 验收路径
- 商用路径零侵入：商用 PyInstaller / Windows / cloud 不引入 PyObjC / framework / 任何代码路径

**Non-Goals:**
- **不**做 video / screenshare 相关 API（v1.0 audio-only）
- **不**做完整 `AliRtcEngineDelegate`，只 audio-only 子集回调（≤ 8 个）
- **不**替换 `MacosRtcSession` mock（CI fixture 保留）
- **不**替代 `windows-artc-pybind11` 真验收（v1.0 MVP 验收点仍是 Windows + 真 GSM modem + 真 ARTC + 拨真手机）
- **不**做 macOS PyInstaller frozen exe 商用打包（PyObjC + framework 打包复杂；dev 用 .venv）
- **不**做 macOS 上真 GSM modem 集成（mac 装不了 driver；dev-no-modem 路径接住）
- **不**支持多并发 call（单 modem 单 call）
- **不**做 macOS Apple Silicon vs Intel mac 差异处理（framework 是 universal binary）

## Decisions

### Decision 1: PyObjC `objc.loadBundle` 加载 framework，运行时显式 `bundle_path`

**选**：用 `objc.loadBundle("AliRTCSdk", globals(), bundle_path=<path>)` 加载 framework；`bundle_path` 默认值 `~/codes/vendor/AliRTCSdk_macos/AliRTCSdk.framework`（与 `reference_artc_sdk.md` 约定一致），env var `ISALES_MACOS_ARTC_FRAMEWORK_PATH` 可 override。

**否决**：把 framework 拷进 `isales-telephony` package（违反"vendor SDK 不进 git"约定）；通过 `DYLD_FRAMEWORK_PATH` 环境变量加载（隐式状态，CI / 多机一致性差）；把 framework 装进 `/Library/Frameworks/` 系统目录（需要 sudo / 全机污染）。

**Why**：
- `objc.loadBundle(bundle_path=...)` 是 PyObjC 标准 framework 加载入口；运行时一行调用，错误信息明确
- 显式 path > env var > 隐式系统目录的次序匹配 v1.0 部署规范（Linux Python wrapper 用 `ISALES_RTC_SDK_PATH` 同样模式）
- 配合 `~/codes/vendor/` 约定，与 Linux / Windows SDK 落地路径风格一致

### Decision 2: 项目内 PyObjC `NSObject` 子类作 delegate，audio-only 子集

**选**：在 `macos_artc_pyobjc.py` 写 PyObjC NSObject 子类 `_AliRtcAudioDelegate(NSObject)`，实施 audio-only 子集回调（5-8 个 selector）：

- `onJoinChannelResult:channel:elapsed:` — join 成功 / 失败
- `onLeaveChannelResult:` — leave 完成
- `onError:` — SDK 错误
- `onSubscribeAudioFrame:` — 入站 PCM 帧（per-uid before-mixing）
- `onPushAudioFrameBufferFull:` — 出站反压
- `onConnectionLost` / `onConnectionRecovery` — 连接事件
- `onRemoteUserOnLineNotify:` / `onRemoteUserOffLineNotify:` — 远端 uid 上线 / 离线

**否决**：写一个 facade 库（C++ wrapper / Swift wrapper）封装 Obj-C 形态再用 ctypes 调（额外构建复杂度，性价比低）；只接 `onError:` + `onSubscribeAudioFrame:` 两个最少集（缺 join 完成回调 SDK 反馈无路径）。

**Why**：
- audio-only 子集已经覆盖 v1.0 所有 RTC 语义（`reference_artc_sdk.md` Linux 段同样的 API 集）
- PyObjC NSObject 子类是项目内 ~50-100 行代码；C++ wrapper 路径需要新建 sub-package、写 build 脚本、跨语言调试，成本超 PyObjC 直写
- 不接 video / screenshare delegate / 完整 90+ event interface，控制实施面

### Decision 3: Cocoa thread → asyncio 桥用 `loop.call_soon_threadsafe`，与 `WindowsRtcSession` 同模式

**选**：所有 PyObjC delegate 回调（跑在 Cocoa main / random SDK thread）通过 `self._loop.call_soon_threadsafe(self._on_X_dispatch, *args)` 投递到 asyncio loop；`_on_X_dispatch` 在 loop 上 set future / put queue。

**否决**：用 PyObjC 的 `NSRunLoop` integration（与 asyncio loop 互锁，PyObjC ↔ asyncio 整合是个 known 复杂问题，PyObjC 文档明示不直接支持）；自己写 thread bridge with `queue.Queue` + asyncio `loop.run_in_executor` polling（自旋 / 延迟差）。

**Why**：
- `call_soon_threadsafe` 是 Python stdlib asyncio 的 cross-thread 标准 API，无 PyObjC 复杂依赖
- `WindowsRtcSession` 的 pybind11 binding 已用同样 pattern（详见 `windows_rtc_session.py::_on_join` 等），形状对齐
- 不引入 NSRunLoop / Qt event loop / 第三方 bridge，依赖最小

**风险**：
- Delegate 回调在 PyObjC NSObject 子类上注册，PyObjC autorelease pool 管理；如果 dispatch 闭包持有 PyObjC 对象，跨线程释放可能 race。Mitigation：闭包内只传值 / 不持有 Obj-C 对象，必要时显式 `objc.autorelease_pool()` 包一层。

### Decision 4: `MacosArtcPyObjCSession` 形状镜像 `WindowsRtcSession`

**选**：`MacosArtcPyObjCSession` 类内部状态、生命周期、错误映射与 `WindowsRtcSession` 一一对应：

- `__init__(*, inbound_capacity=64)` —— 同 Windows
- `async def join(channel, token, uid, *, send_sample_rate=16000, send_channels=1)`：创建 engine → set delegate → set external audio source → join channel → 等 `_join_future` (`call_soon_threadsafe` 触发) → 起 drainer task
- `async def leave()`：`leave_channel` → cancel drainer → release engine → idempotent
- `def is_joined(self) -> bool` —— property
- `def audio_frames(self) -> AsyncIterator[PcmFrame]` async generator，yield from `asyncio.Queue`，drainer 投递
- `async def push_audio(pcm, *, timestamp_ms)`：调 `pushExternalAudioFrame:`，错误翻 `RtcError`
- 5 秒 join timeout（与 Windows 一致）
- `RtcError` / `RtcNotJoined` / `RtcPushBackpressure` 映射规则同 Windows

**Why**：
- AudioBridge / EdgeOrchestrator 上层对 `RtcSession` 实装是 polymorphic 的，shape 严格一致让上层代码零分支
- 失败模式对齐让 e2e 测试结果可比对（Windows 和 mac 同一测试套件）
- 镜像 windows-artc-pybind11 实装减少 review 心智负担（diff 主要在"Obj-C delegate" vs "pybind11 listener" 这一段）

### Decision 5: `audio_bridge/__init__.py` 平台路由 + fallback 到 mock

**选**：`get_default_rtc_session_class()` 在 darwin 平台改逻辑：

```python
if sys.platform == "darwin":
    try:
        from isales_telephony.audio_bridge.macos_artc_pyobjc import MacosArtcPyObjCSession
        return MacosArtcPyObjCSession
    except ImportError as exc:
        logger.warning("macos-artc-pyobjc 不可用，回退到 MacosRtcSession mock loopback；如需真 ARTC，pip install -e '.[macos-artc]' 并解压 SDK 到 ~/codes/vendor/AliRTCSdk_macos/", extra={"detail": str(exc)})
        return MacosRtcSession
```

**否决**：env var `ISALES_EDGE_RTC_BACKEND=mock|real` 显式切换（与 `device-hardware` spec L402 "platform 选择 MUST NOT 通过环境变量强制覆盖"精神冲突）；硬错（fresh checkout 没装 extras 直接 crash，dev onboarding 体验差）。

**Why**：
- Fallback 到 mock 让 unit-test / fresh checkout / 没装 vendor SDK 时一切照常跑（CI 不会因为引入本 change 而需要装 PyObjC + framework）
- WARN log + 装包指引让 dev 同学一眼看到为什么没走真 ARTC，不会偷偷降级到 mock 还不自知
- `MacosRtcSession` 仍 export 让 unit-test 显式 `from .session import MacosRtcSession` 完全不受影响

### Decision 6: dev-no-modem CLI flag 接入（沿用 superseded `macos-local-audio-dev` 设计）

**选**：把 superseded change 的 dev-no-modem 设计照搬过来 — `isales-telephony-edge --dev-no-modem --dev-channel <name> --dev-uid <id> [--dev-peer-uid <id>]`：

- `main.py` argparse 加顶层 flag
- `EdgeOrchestrator.__init__` 加 `dev_no_modem: bool = False` + dev params
- `start()` 检测 dev mode：跳过 `SerialATClient` + USB watcher + AT 命令；cloud 主动 `Cloud2Edge.dial` 时构造"已接通" CallSession 走既有 `_handle_connected` 部分逻辑（跳过 cpcmreg_enable / capture & playback pumps，直接 audio_bridge.join + 真 ARTC session 拿到的 mac 系统 audio device）
- SIGINT / SIGTERM teardown → `Edge2Cloud.remote_hangup{hangup_cause="dev_terminate"}` + audio_bridge.leave

**否决**：让 `MacosArtcPyObjCSession` 包"假装有 modem"（spec 模糊 / 复杂度高）；写独立的 `isales-telephony-edge-dev` console script（多入口维护成本，design Decision 3 否决理由不变）。

**Why**：
- mac 装不了 GSM modem 驱动是物理约束，dev-no-modem 路径必须存在
- 把 dev-no-modem 接入做在 orchestrator 层让 audio_bridge 完全聚焦"接真 RTC"，关注点分离
- cloud-side engine 看到的是正常 connected session（与 Windows + 真 modem 路径一致），cloud 零侵入
- 真 ARTC session 由 SDK 内部处理 mac mic / speaker（SDK 默认 audio device 路径），不需要本 change 写 sounddevice / PortAudio 桥

### Decision 7: vendor SDK 加载失败 / 版本不兼容时 fail-fast，不 silent-degrade

**选**：`MacosArtcPyObjCSession.__init__` 立即 `objc.loadBundle()`；任何加载失败（路径不存在 / 不是 framework / 架构不兼容 / Obj-C class lookup 失败）抛 `RtcError` with 具体诊断信息；启动 join 之前在 dispatch 工厂 (`get_default_rtc_session_class`) 已 fallback 到 mock（Decision 5）。

**Why**：
- 类实例化失败 → fallback 在工厂层；join 失败 → 已是 dev 跑 demo 阶段，硬错比 mock 替换更明确
- 与 Windows `WindowsRtcSession` "SDK 装载失败 ImportError" 对齐（dev 阶段问题暴露在第一时间）

### Decision 8: extras 命名 `[macos-artc]` 独立于既有 `[macos]`

**选**：新建 `[macos-artc]` extras = `pyobjc-core>=10.0` + `pyobjc-framework-Cocoa>=10.0`；不动既有 `[macos]` extras（`sounddevice>=0.4.6`，给 modem-controller `macos_coreaudio` backend 用，与本 change 无关）。

**Why**：
- 关注点分离：`[macos]` 是 modem-controller 的 audio I/O backend（mic / speaker 接 modem 8k PCM），`[macos-artc]` 是 audio_bridge 的 RTC SDK binding（接 16k RTC PCM）
- dev 装 `pip install -e '.[dev,macos,macos-artc]'` 一次拿全；CI 只装 `[dev]` 仍跑 mock
- 命名与 `[windows]`（Windows backend extras）平行

## Risks / Trade-offs

- **[风险] Cocoa thread ↔ asyncio 跨线程桥实施不当导致 deadlock / race / lost wakeup** → Mitigation: 严格走 `loop.call_soon_threadsafe` + `asyncio.run_coroutine_threadsafe`，delegate 闭包不持有 PyObjC 对象引用，所有 future 用 `set_result_threadsafe` 包装；写专门的单测覆盖"delegate 在异步线程 fire → asyncio loop yield 收到" pattern。
- **[风险] macOS ARTC SDK SNAPSHOT 版本（7.8.10000-SNAPSHOT）API 不稳定 / 行为差异 vs Linux 7.10.2 GA** → Mitigation: dev-only 形态，发现问题不阻塞商用路径；遇到 API 差异在 RUNBOOK 记差异点，必要时 Aliyun 工单跟进。
- **[风险] PyObjC autorelease pool / GIL 互动** — Obj-C delegate 回调在 SDK thread，PyObjC 自动包 autorelease pool 但 Python GIL 释放点不清；高频 audio 回调（50 Hz）下可能引起 GIL 抢占 → Mitigation: drainer 设计采用 batch（一次拉 N 帧）减少 Python 侧调用频率；类似 `WindowsRtcSession` 的 `_DRAIN_BATCH_SIZE = 8` 经验值。
- **[风险] framework search path 在 macOS 12 / 13 / 14 / 15 行为差异 + Apple Silicon vs Intel mac 加载行为** → Mitigation: `objc.loadBundle(bundle_path=...)` 显式路径绕开 system framework path 问题；universal binary 在两种架构都直接跑；RUNBOOK 标明测试过的 macOS 版本。
- **[Trade-off] dev 装包成本（pyobjc-core + Cocoa）** → ~30 MB 额外 pip install 体积，dev 一次性成本可接受；可选 extras 不影响 base install。
- **[Trade-off] dev 测出来的 latency 与 Windows + 真 modem 链路有差异**（mac 上没有 modem 8 kHz ↔ RTC 16 kHz 重采样这段，audio I/O 由 ARTC SDK 接 mac default device 而非 modem PCM 串口）→ 已知差异，RUNBOOK 记录，不外推 absolute 数字到商用；策略机制（barge-in / VAD / 垫词 / handoff）行为可外推。

## Migration Plan

无 migration。纯追加：
- 新代码：`macos_artc_pyobjc.py` / `get_default_rtc_session_class` darwin 分支调整 / argparse `--dev-no-modem` / orchestrator dev-no-modem 分支 / `[macos-artc]` extras / RUNBOOK
- 既有 `MacosRtcSession` mock、`WindowsRtcSession`、Windows 商用路径、cloud-side engine、所有 spec 既有 Requirement / Scenario 全部不动

回滚策略：
- 删除 `macos_artc_pyobjc.py` + 还原 `__init__.py` darwin 路由 → 自动回到 `MacosRtcSession` mock loopback（即 superseded 之前的状态）
- dev-no-modem 路径删除 argparse flag + orchestrator 分支即可

## Open Questions

无。
