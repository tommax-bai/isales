## ADDED Requirements

### Requirement: campaign.ambient_audio / ambient_gain 背景环境音配置列

`campaign` 表 SHALL 新增两列用于配置出向背景环境音：`ambient_audio`（背景音素材标识，可空字符串；空或 NULL 表示关闭背景音）与 `ambient_gain`（背景音混入电平，float，默认对应低电平约 -20dB 量级）。两列 SHALL 通过加性 alembic 迁移引入，默认值 SHALL 使存量 campaign 等价于"关闭背景音"。isales-common 的 campaign Pydantic schema SHALL 暴露这两个字段，并通过 dial 消息传递给引擎。

#### Scenario: 存量 campaign 默认关闭

- **WHEN** 迁移在已有 campaign 数据上执行
- **THEN** 每个存量 campaign 的 `ambient_audio` SHALL 为空（关闭），`ambient_gain` SHALL 为默认值
- **AND** 这些 campaign 的出向音频行为 SHALL 与变更前一致

#### Scenario: dial 消息携带背景音配置

- **WHEN** 引擎收到一通启用了 `ambient_audio` 的 campaign 的 dial 消息
- **THEN** dial 消息 SHALL 包含 `ambient_audio` 与 `ambient_gain` 字段供引擎初始化混音泵
