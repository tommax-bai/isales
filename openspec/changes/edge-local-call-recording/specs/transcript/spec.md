## MODIFIED Requirements

### Requirement: 录音存储

录音 SHALL 由 modem-controller 在通话建立后启动 PCM 录音，整通录成单个 stereo wav 文件（左声道=用户上行、右声道=AI 下行），落 edge 本地磁盘。录音 SHALL 纯本地保留最近 N 个（默认 N=10，按文件个数滚动删除最旧），不上传 OSS、不回写数据库、admin 后台不可见。

OSS 上传、`call_record.recording_url` 回写、前端用 transcript `ts` 字段跳转回放 MUST 列入 v1.x 范围外；`call_record.recording_url` 字段保留为 v1.x 预留，v1.0 不写入。

#### Scenario: 录音落盘路径

- **WHEN** 一通通话结束（挂断）
- **THEN** modem-controller SHALL 在 `RECORDINGS_DIR` 下写入单个 stereo 16 kHz wav 文件，文件名以 `call_id` 标识
- **AND** 文件 MUST NOT 上传 OSS，`call_record.recording_url` MUST 保持为空

#### Scenario: 按个数滚动保留

- **WHEN** 录音文件写入完成后
- **THEN** modem-controller SHALL 按文件 mtime 仅保留最近 `MAX_RECORDINGS`（默认 10）个 wav，删除更旧的文件
- **AND** 当 `MAX_RECORDINGS` 设为 0 时 MUST 完全禁用录音（不创建文件）

#### Scenario: 磁盘下限兜底

- **WHEN** 通话建立时录音目录可用空间低于配置下限
- **THEN** modem-controller SHALL 跳过本通话录音并记结构化 warning（含可用空间与阈值）
- **AND** 通话本身 MUST NOT 受影响
