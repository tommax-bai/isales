## 1. Sprint 0 准备（与 A2 impl 并行，不阻塞）

- [ ] 1.1 阿里云 QA 环境开通：ECS 4C16G Ubuntu 22.04 + RDS PG16 + Redis 1G + OSS bucket + 域名 + Let's Encrypt
- [ ] 1.2 阿里 RTC 应用创建（拿 AppId / AppKey）+ 工单确认计费套餐细节（参考 PoC §9 三题工单稿）
- [ ] 1.3 ARTC SDK for Linux Python 与 macOS Python 压缩包下载、放入内部 artifact 仓 / OSS 私有 bucket
- [ ] 1.4 跑 PoC Day 2 实测脚本（[PoC §8](../../v1-roadmap-aliyun-rtc-poc-result.md#8-day-2-实测脚本sprint-0-期间执行)），把决策表"实测"列填实
- [ ] 1.5 Mac mini QA 边缘机准备：插 GSM modem 确认 USB 串口、装 macOS 通过 `impl-deploy-macos` 既有 launchd 套件

## 2. isales-common：proto 定义 + transport 抽象

- [ ] 2.1 新增 `isales_common/proto/cloud_edge.proto`，定义 `service CloudEdge` + `Edge2Cloud` / `Cloud2Edge` 两个 oneof message + `DialCommand` / `CancelCommand` / `Heartbeat` / `CallEvent` / `HardwareAlert` / `ConfigUpdate` / `RtcCredentials` / `DialAck` 字段（与 service-communication spec § 服务定义 一致）
- [ ] 2.2 配置 `make proto` 跑 `protoc` 生成 `cloud_edge_pb2.py` / `cloud_edge_pb2_grpc.py` 编译产物；产物随 pip 包分发
- [ ] 2.3 新增 `isales_common/transport/cloud_edge_abc.py` 抽象基类：`CloudEdgeServer`（云端起 server）+ `CloudEdgeClient`（边缘 client）+ 心跳 / 重连 / token 验证接口
- [ ] 2.4 新增 `isales_common/audio/rtc_backend.py` 抽象：`RtcCaptureBackend` / `RtcPlaybackBackend` 与既有 capture / playback ABC 兼容
- [ ] 2.5 单测：proto 双向序列化 + transport 抽象 mock 实现 + audio backend mock

## 3. isales-engine：云端 ARTC SDK 接入

- [ ] 3.1 新增 `isales_engine/transport/aliyun_rtc.py`，封装 ARTC SDK Linux Python：`RtcSession(channel, token, uid).join() / leave()` + `async on_audio_frame()` 迭代器 + `async push_audio(pcm, ts)` + buffer-full 反压
- [ ] 3.2 SDK vendor 解压脚本：`deploy/cloud/scripts/install-artc-sdk.sh`，从 OSS 拉压缩包到 `/opt/isales/current/vendor/aliyun-artc-linux-python/`，注入 `sys.path` 或 pip 本地 install
- [ ] 3.3 `isales_engine/audio_pipe.py` 新增 `AliyunRTCCapture` / `AliyunRTCPlayback` backend 实现，桥接 `RtcSession` 的 PCM 回调与推送
- [ ] 3.4 v1.0 云端默认 backend 切换为 `AliyunRTCCapture/Playback`；本地开发 backend 通过环境变量 `ISALES_AUDIO_BACKEND=local` 切回
- [ ] 3.5 单测：用 mock SDK 验证 `RtcSession` 入会 / 离会 / 推帧 / 拉帧的状态机

## 4. isales-engine：云-边 gRPC server

- [ ] 4.1 新增 `isales_engine/transport/grpc_server.py`：起 `CloudEdge.Bidi` server，监听 0.0.0.0:50051（TLS via nginx 反代或 grpcio 内置）
- [ ] 4.2 实现 token 验证（gRPC metadata `authorization`）→ 绑定 edge_device_id 到 stream context
- [ ] 4.3 心跳逻辑：收到 Edge `Heartbeat` 后回 Cloud `Heartbeat` + 更新云内 PG `last_heartbeat`
- [ ] 4.4 事件路由：`CallEvent` / `HardwareAlert` / `DialAck` 进 engine session dispatcher（按 call_id 找 session）+ 落 PG
- [ ] 4.5 cloud → edge 命令下发：engine session 发起 `DialCommand` / `CancelCommand` / `ConfigUpdate` / `RtcCredentials` 路径
- [ ] 4.6 集成测试：本地 grpcio + mock edge client 跑通 dial → call_event → cancel → leave 全链路

## 5. isales-engine：engine session co-location 改造

- [ ] 5.1 engine session lifecycle 接 `DialCommand` 触发（替代 Redis Queue 触发）；Redis Queue 接口保留但单实例下走同进程函数
- [ ] 5.2 同进程 asyncio dispatcher：按 call_id 维护 active session 字典；`Edge2Cloud.CallEvent: remote_hangup` 与 cancel 路径直接 deliver 到 session
- [ ] 5.3 cancel 路径**确认不走 Redis Pub/Sub**：在云内 api 触发的 cancel 也改为函数调用进 dispatcher
- [ ] 5.4 RTC token 生成：engine 在派发 DialCommand 前用 AppKey 签发 `engine-{call_id}` 与 `edge-{call_id}` 两个 token，塞进 DialCommand
- [ ] 5.5 端到端测试：本地 mock 边缘 + 云端 engine + 真 ARTC（QA 环境）跑通一通通话 join → audio → leave

## 6. isales-scheduler：dial 路径重构

- [ ] 6.1 选 device 逻辑从"HTTP 调 telephony-api `/devices/select`"改为云内 PG 直查 + 行级锁
- [ ] 6.2 dial 派发：生成 call_id → 写云内 PG call 表 → 通过 engine 暴露的内部接口（云内函数调用 / Redis Queue 保留兜底）发起 → engine 内 grpc_server 发 `DialCommand` 给边缘
- [ ] 6.3 移除 telephony-api HTTP client 代码 + tests
- [ ] 6.4 单测：选 device 算法 + 并发安全（两 dial 不能选同一 idle device）

## 7. isales-telephony：边缘进程重构

- [ ] 7.1 重组 isales-telephony 仓库结构：单一 entry point + asyncio task group（modem-controller / audio-bridge / cloud-edge gRPC client / telephony-api HTTP loopback）
- [ ] 7.2 新增 `isales_telephony/audio_bridge/__init__.py`：ARTC SDK macOS Python wrapper + `JoinChannel` + `SetExternalAudioSource` + `PushExternalAudioFrameRawData` + `OnSubscribeAudioFrame` + 反压
- [ ] 7.3 modem-controller 重构：上行 PCM 不再直接推 Unix socket，改推同进程上行环形 buffer；下行 PCM 从同进程下行环形 buffer 取
- [ ] 7.4 PCM 重采样：上行 8 kHz → 16 kHz、下行 16 kHz → 8 kHz；用 macOS Audio Converter 或 `audioop.ratecv`
- [ ] 7.5 新增 `isales_telephony/transport/grpc_client.py`：与云端 engine 建立 bidi stream + 心跳 + 自动重连 + 本地 SQLite buffer
- [ ] 7.6 SQLite buffer 实现：`~/Library/Application Support/isales/sqlite/edge_buffer.db`，存 `CallEvent` / `HardwareAlert` 待补发；server ACK 后删除
- [ ] 7.7 telephony-api HTTP 角色降级：限制 loopback 监听 + `/devices/select` 加 `Deprecation: 1` header
- [ ] 7.8 单测：环形 buffer 容量 + 反压 + gRPC client 断线重连 + SQLite buffer 补发顺序

## 8. ARTC SDK macOS vendor

- [ ] 8.1 边缘 deploy 脚本：`deploy/edge/scripts/install-artc-sdk.sh` 解压 ARTC SDK macOS 到 `~/Library/Application Support/isales/vendor/aliyun-artc-macos-python/`
- [ ] 8.2 isales-telephony pyproject / requirements 引用 vendor 路径
- [ ] 8.3 macOS 上的实际入会测试（独立小脚本，QA 环境）

## 9. isales-api / isales-worker：云端调整

- [ ] 9.1 isales-api：新增内部 endpoint 给前端"看哪些边缘机在线"（基于云内 PG `edge_device.last_heartbeat`）
- [ ] 9.2 isales-api：签发 `EDGE_DEVICE_TOKEN` 的内部工具 + 文档
- [ ] 9.3 isales-worker：处理 `HardwareAlert` 事件（A2 范围：仅落 PG 与基础日志告警；详细告警 / 一键诊断 由 D2 处理）
- [ ] 9.4 isales-worker：watchdog 监听 cloud-edge stream 健康度，超 120 s 无心跳的边缘机 device 置 offline

## 10. 云端部署脚本与 RUNBOOK

- [ ] 10.1 新增 `deploy/cloud/` 目录：systemd unit (api / engine / scheduler / worker)、nginx 配置（反代 isales-web + isales-api + cloud-edge gRPC SNI）、env.example
- [ ] 10.2 `deploy/cloud/scripts/install.sh`：拉代码 + 装依赖（含 ARTC SDK vendor 步骤）+ 跑 alembic + 重启服务
- [ ] 10.3 `deploy/cloud/scripts/rollback.sh`：切回历史 release 软链 + 重启服务（不动 schema）
- [ ] 10.4 `deploy/cloud/monitoring/`：Prometheus + Grafana + alert rules 模板
- [ ] 10.5 RUNBOOK：阿里云资源开通 / 域名 / TLS / RDS 备份恢复演练 / cloud-edge 调试

## 11. 边缘部署脚本与 RUNBOOK

- [ ] 11.1 新增 `deploy/edge/` 目录：launchd plist + env.example + vendor 安装脚本
- [ ] 11.2 `deploy/edge/scripts/install.sh`：拉代码 + 装 venv + ARTC SDK 解压 + 注册 launchd
- [ ] 11.3 `deploy/edge/scripts/rollback.sh` + launchctl kickstart
- [ ] 11.4 RUNBOOK：边缘机首次配置 / 激活码（A2 用静态 token，多租户由 C2）/ 离线 buffer 排查 / 网络诊断

## 12. 端到端验证

- [ ] 12.1 QA 环境一台 Mac mini + 一台云 ECS：本地拨自己手机 → 听到回声（无 AI 编排，仅验证音频通路）
- [ ] 12.2 接入豆包 ASR/LLM/TTS：拨自己手机 → 听到 AI 念固定开场白 → 挂断 ← **A2 + D1 联合 MVP 验收点**
- [ ] 12.3 端到端 latency 测量 P50 / P95 → 与 design.md Decision 4 budget 对照；如 P95 > 800 ms 触发降级策略（默认 N 角色 = 1）
- [ ] 12.4 故障注入：边缘断网 30 s + cloud engine 重启 + RTC 房间断连 → 验证降级与重连行为符合 spec
- [ ] 12.5 100 seats 压测（QA 环境，模拟边缘）→ 确认单 cloud instance 承载力 + 阿里 RTC SDK 并发上限

## 13. 文档与归档准备

- [ ] 13.1 更新 v1-roadmap.md 标注 A2 已 ship + 修正 NAT 穿透段（fallback 路线已用不到）
- [ ] 13.2 更新 PoC 结果文档：把 Day 2 实测数据补到决策表"实测"列
- [ ] 13.3 准备 A2 archive PR：等 D1 也接近完成时一起规划归档（device-hardware / deployment-topology spec delta 冲突需手工 merge）
- [ ] 13.4 整理 A3 `edge-vad-and-opener-prefetch` propose 阶段需要的上下文（cancel 通道接口 + OSS 开场白预渲染目录）
