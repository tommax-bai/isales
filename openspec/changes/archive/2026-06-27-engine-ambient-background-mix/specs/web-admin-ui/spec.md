## ADDED Requirements

### Requirement: 背景环境音配置 UI

campaign 配置界面 SHALL 提供背景环境音的编辑入口，允许运营选择背景音素材（`ambient_audio`）与设置混入电平（`ambient_gain`）。该入口 SHALL 默认呈现"关闭"状态（未选择素材），并 SHALL 通过既有 campaign 读写端点持久化这两个字段。界面 SHALL 提示电平过高可能引入回声风险。

#### Scenario: 运营开启并配置背景音

- **WHEN** 运营在 campaign 配置中选择一个背景音素材并设置电平后保存
- **THEN** `ambient_audio` 与 `ambient_gain` SHALL 随 campaign 一并持久化
- **AND** 重新打开该 campaign 配置时 SHALL 回显已保存的素材与电平

#### Scenario: 默认关闭

- **WHEN** 运营新建或打开一个未配置背景音的 campaign
- **THEN** 背景音入口 SHALL 呈现关闭状态，不强制选择素材
