## MODIFIED Requirements

### Requirement: v1 单主机部署

v1 SHALL 把全部服务（engine + telephony + scheduler + worker + USB GSM modem）部署在一台服务器，匹配 ≤8 路并发目标。多主机扩展 MUST 列入 v2。支持的主机操作系统为 **Linux（Ubuntu 22.04 LTS+）** 或 **macOS 14+ Sonoma on Apple Silicon**；二者并行支持，业务代码在两个平台上行为一致。

#### Scenario: 部署拓扑

- **WHEN** v1 投产
- **THEN** 7 个进程（含 telephony-api 和 modem-controller 两个 entry point）SHALL 同主机部署；USB GSM modem 直插同一主机

#### Scenario: 进程隔离

- **WHEN** 部署 v1
- **THEN** 每个服务 SHALL 独立的"系统服务单元"——Linux 上是 systemd unit、macOS 上是 launchd plist；isales-common 作为依赖嵌入各进程，无独立运行进程

#### Scenario: 平台条件依赖

- **WHEN** 任一服务（最关键的是 isales-telephony 仓的 modem-controller）需要平台原生 API
- **THEN** 服务 MUST 通过 ABC + `sys.platform` 选实现的方式隔离平台特定代码；业务代码 MUST NOT 直接 import 平台原生绑定（如 `pyudev` / `pyobjc`）；ABC 设计 MUST 不绑死 Linux + macOS 二元，应允许将来扩展第三种实现（如 Windows）而不需要重构调用方

#### Scenario: 仅 Apple Silicon

- **WHEN** v1 部署 macOS 主机
- **THEN** 主机 MUST 是 Apple Silicon（M1 及更新）；Intel Mac MUST NOT 作为生产主机；理由：Intel Mac 已停产 4+ 年、brew 路径分叉（`/usr/local` vs `/opt/homebrew`）维护成本高、新增客户基本都是 ARM
