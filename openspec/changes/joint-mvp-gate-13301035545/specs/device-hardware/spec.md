## MODIFIED Requirements

### Requirement: device 状态机

`device.status` SHALL 在以下状态间转换：

- `unknown` → `detected` → `registered` → `idle` → `dialing` → `in_call` → `idle`
- 任何状态 → `offline`（USB 拔出）
- `idle` / `in_call` → `flagged`（健康度低）
- `detected` → `error`（AT 初始化失败）

#### Scenario: 设备插入后初始化

- **WHEN** udev 检测到新 USB 设备且识别为 GSM modem
- **THEN** device.status = `detected`；modem-controller 发 AT 命令初始化；初始化成功后 → `registered` → `idle`

#### Scenario: 拨号期间状态

- **WHEN** engine 调 dial 接口选中某 device
- **THEN** device.status = `dialing` → 接通后 `in_call` → 挂断后 `idle`

#### Scenario: USB 拔出

- **WHEN** udev 检测到 USB 设备拔出
- **THEN** 对应 device 状态 SHALL 立即置 `offline`；正在使用该 device 的 call_session MUST 收到 device_error 事件并优雅清理

#### Scenario: edge daemon 五件套真启动后双通道实测

- **WHEN** Windows edge `isales_telephony.main_windows` daemon 启动且通过 cloud-edge gRPC 与 ECS engine 建链 (`grpc_connected`)
- **THEN** 同一进程 SHALL 同时持有：① COM12 (HS-USB AT) `pyserial` 句柄 ATR `AT\r\n → OK`；② COM11 (HS-USB Audio Class=Ports) PCM byte stream gated by `AT+CPCMREG=1`；③ `aliyun_artc_pywrap.EngineHandle` 实例 (Windows pybind .pyd 加载成功 + ARTC vendor DLL 链路顺)；④ `.edge-token-test.jwt` 加载完成 (cloud-edge gRPC client 持 bearer)；五件套全 active 后 `device.status` SHALL 透过 cloud-edge `Heartbeat` 上报 → `registered` (无 USB 拔出 / 无 AT 失败 / 无 RTC join 失败)；MUST 在 tray icon 显示 green
