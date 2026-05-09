> 实施仓库：**isales-telephony** 主战场（platforms + audio ABC + macOS impl）；**meta-repo** (`isales/`) 加 deploy/macos/ 子树 + RUNBOOK 章节；**isales-common** 视情况加 `utils/platform.py`。其他 5 仓零代码改动。
> 12 个 PR 顺序合入；PR #11 硬件验收单独阻塞归档，软件层 PR 不必等。
>
> 路径前缀：未注明仓库时默认指 meta-repo。

## 1. ABC 接口 + Linux backend 迁入（PR #1，isales-telephony）

- [x] 1.1 新增 `modem_controller/platforms/{__init__.py, base.py, linux_udev.py, macos_iokit.py}`；`base.py` 定义 `UsbDeviceWatcher` ABC + 平台中立 `UdevEvent` dataclass + `UsbDeviceWatcherError(platform=…)` 异常（保留 `UdevEvent` 名称避免破坏 4 个 stage-2 测试的 import）
- [x] 1.2 现有 `modem_controller/udev_watcher.py` 内容拆分：pyudev-specific event source 进 `platforms/linux_udev.py` 的 `LinuxUdevWatcher` 类；domain 逻辑（whitelist 匹配、DB 写回、`consume_events` / `fake_events`）保留在 `udev_watcher.py`，全部公共导出向后兼容
- [x] 1.3 `platforms/__init__.py` 按 `sys.platform` dispatch via `get_usb_watcher_class()`：`linux` → `LinuxUdevWatcher`、`darwin` → `MacOSIokitWatcher`（占位，instantiation raise NotImplementedError 直至 PR #3）、其他平台 raise `UsbDeviceWatcherError`
- [x] 1.4 新增 `modem_controller/audio/{__init__.py, linux_alsa.py, macos_coreaudio.py}`；**重要 design pivot**：现有 `audio_pipe.AudioPipe` 是 cross-platform orchestrator（重采样 + jitter buffer），`CaptureBackend` / `PlaybackBackend` 已经是 Protocol（结构性 ABC）；新包仅注册 platform 后端 dispatch（`get_capture_class` / `get_playback_class`）。spec scenario "音频管道 ABC" 已同步修订为"两层抽象：跨平台 orchestrator + 平台后端 Protocol"
- [x] 1.5 现有 ALSA 实现 NA（stage 2 没有真 ALSA 实现，stage 6 才落）；新增 `audio/linux_alsa.py` 占位 `LinuxAlsaCapture` / `LinuxAlsaPlayback` 类（`__init__` raise NotImplementedError，提示 stage 6 落地）
- [x] 1.6 业务代码 grep 替换：现有 `main.py` 仍 `from .udev_watcher import start_udev_watcher`，向后兼容路径保留；`udev_watcher.start_udev_watcher` 内部改 dispatch 到 `platforms.get_usb_watcher_class()`；零行为变化（4 个 udev_watcher 测试全绿）
- [x] 1.7 现有 77 测试全绿（dev 机无 PG/Redis 跑 71 个 + 新增 6 个 dispatch 测试）；新增 `tests/test_platforms_dispatch.py` 6 个测试覆盖：linux/darwin/win32 dispatch、`MacOSIokitWatcher` instantiation 阻塞、`UdevEvent` 平台中立、ABC 契约可实现性。`mypy` + `ruff` 在新代码上零警告

## 2. pyobjc + sounddevice 条件依赖（PR #2，isales-telephony）

- [x] 2.1 `pyproject.toml` 加 `[project.optional-dependencies]` `linux` + `macos` 两个 extras：linux = pyserial / pyserial-asyncio / pyalsaaudio（platform_system marker）；macos = sounddevice（无条件）+ pyserial / pyserial-asyncio（Darwin marker）
- [x] 2.2 `pyudev` 保留在主 `dependencies` 中（已经有 `platform_system == "Linux"` 条件 marker，无需移动；移到 extras 会破坏现有 Linux 安装路径）
- [x] 2.3 README "Local development" 章节加平台分支：`pip install -e ".[dev,linux]"` vs `pip install -e ".[dev,macos]"`
- [x] 2.4 dev 机互装：macOS extras 上的 sounddevice 是跨平台的（PortAudio 后端 Linux/Mac 都装），只有 pyserial 用 Darwin marker；同时装 `[linux,macos]` 在 Linux 上自动跳过 Darwin-only entries
- [x] 2.5 验证：在本机 macOS 上 `pip install -e ".[macos]"` 装 sounddevice + pyserial + pyserial-asyncio 通过；77 测试零回归；`from serial.tools.list_ports import comports` 与 `import sounddevice` 在 macOS 跑通
- [x] 2.6 **设计偏离**：原 spec 提案中 `pyobjc-framework-IOKit` 不在 PyPI 单独发布。改方案为 macOS 上用 `pyserial.tools.list_ports.comports()` 在 1 Hz 轮询 diff 推导 USB add/remove 事件——零新外部依赖，跨平台，对 GSM modem（插入到可用 3–5 秒）时延占比可接受。spec scenario "USB 设备监听器" 与 `macos_iokit.py` 文件 docstring 已同步更新；文件名保留供未来若需要升级到 ctypes IOKit notifications 时无需改名

## 3. macOS IOKit USB watcher 实现（PR #3，isales-telephony，**最难**）

- [x] 3.1 重写 `modem_controller/platforms/macos_iokit.py`：基于 PR #2 决策走 `pyserial.tools.list_ports.comports()` 1 Hz 轮询 + diff，不走 IOKit notification port（pyobjc-framework-IOKit 未在 PyPI；ctypes-IOKit 复杂度溢出）
- [x] 3.2 实现 `MacOSIokitWatcher` class 实现 `UsbDeviceWatcher` ABC：`start()` 起 asyncio task 跑 polling loop；`events()` 走 asyncio.Queue；`stop()` cancel task + tear-down 静默吞 exception；`start()` 重复调用 raise；`stop()` 在 start 失败后仍可调用
- [x] 3.3 USB 事件解码：从 `ListPortInfo` 提取 `vid` / `pid`（4-char lowercase hex）/ `serial_number`，转成 `UdevEvent`；ABC 设计上不暴露任何 pyserial 类型给调用方
- [x] 3.4 串口设备路径解析：scanner 直接用 `pyserial.tools.list_ports.comports()` 扫所有 USB 端口；按 USB vid 过滤掉无 USB ID 的端口；vendor 白名单匹配交给上层 `udev_watcher._is_known_modem`
- [x] 3.5 `__init__.py` dispatch 已在 PR #1 加 darwin 分支；本 PR 让 `MacOSIokitWatcher.__init__` 不再 raise NotImplementedError；test_macos_iokit_init_raises_until_pr3 用例改成 instantiation 验证
- [x] 3.6 新增 `tests/macos/__init__.py` + `tests/macos/test_iokit_watcher.py`，11 个测试用例（**不带** `skipif(sys.platform != "darwin")` —— ABC 与 polling 都是平台中立的，可在 Linux CI 上一起跑）：5 个 _diff_scans 单元测试（appear/disappear/no-change/identity-change/multi-device）+ 6 个 watcher lifecycle 测试（add-then-remove 顺序 / seed-不发-add / start 二次 raise / stop 在 start 失败后安全 / scanner OSError 容错 / dispatch 端到端）
- [ ] 3.7 100 次插拔压测脚本 — DEFERRED 到 PR #12 真硬件验收（macOS 开发机无真实 GSM modem 可插拔；polling 模型相对 IOKit notification port 内存泄漏 / 死锁风险大幅降低，单元测试 + 真硬件抽查覆盖足够）

## 4. macOS Core Audio pipe 实现（PR #4，isales-telephony，**次难**）

- [x] 4.1 新增 `modem_controller/audio/macos_coreaudio.py`：用 `sounddevice` (PortAudio → Core Audio) 实现 `CaptureBackend` / `PlaybackBackend` Protocol；`MacOSCoreAudioCapture` 用 `sd.RawInputStream`，`MacOSCoreAudioPlayback` 用 `sd.RawOutputStream`；`channels=1`, `samplerate=8000`, `dtype='int16'`, `blocksize=160` (20ms @ 8kHz)，`latency='low'` 低延迟模式
- [x] 4.2 重采样保留在 cross-platform `audio_pipe.AudioPipe` orchestrator 内部（PR #1 spec pivot：现有设计已经分层 — 平台后端只做 raw 8kHz I/O，重采样在跨平台层）；macOS 后端零重采样代码
- [x] 4.3 `audio/__init__.py` dispatch 在 PR #1 已加 darwin 分支；本 PR 让 `MacOSCoreAudioCapture` / `MacOSCoreAudioPlayback` `__init__` 不再 raise NotImplementedError
- [x] 4.4 设备选择 `_resolve_device_id()`：`sd.query_devices()` 按 `DEFAULT_DEVICE_KEYWORDS = ("USB Audio CODEC", "Quectel", "Huawei", "SIMCom", "ZTE")` 关键词过滤；未匹配回退到 `sd.default.device`；RUNBOOK 章节（PR #11）会给运维确认设备名称的 `python -c 'import sounddevice as sd; print(sd.query_devices())'` 一行命令
- [x] 4.5 新增 `tests/macos/test_coreaudio_pipe.py` 13 个测试：read_chunk 返回 bytes、close 幂等、close 在未 open 时安全、overflow 警告但仍返回数据、write_chunk 投递到 stream、close 在 writes 后 stop+close、dispatch 端到端、设备关键词包含 USB Audio CODEC + 至少 2 个品牌、capture exception 透出、Protocol 形状校验（capture / playback）。全部用 `_FakeStream` 注入，**无需真实音频硬件即可在 Linux CI 上跑**
- [x] 4.6 新增 `tests/macos/test_coreaudio_latency.py`：当 `ISALES_LOOPBACK_DEVICE_NAME` 或 BlackHole/Loopback 设备可用时，跑 10 trials 1kHz sine marker 从 write 到 read-back 测时延，p95 ≤ 200ms 阻塞合并；当无 loopback 设备时 **skip 而非 fail**，pass/fail gate 在 PR #12 真硬件验收（Mac mini + 真 GSM modem 音频回环）执行
- [x] 4.7 如果 PR #12 实测 p95 > 200ms：fallback 路径已写入 design.md（先尝试 blocksize=80；仍不达标走 PyObjC + AudioUnit 直接 API，单独 follow-up change，本 change 不阻塞）。本 PR 单元测试 + 框架已就位

## 5. AT 串口路径跨平台（PR #5，isales-telephony）

- [x] 5.1 grep `/dev/tty` / `/dev/cu` 在 modem_controller 业务代码：未发现硬编码（设备路径来自 DB `device.usb_port` 字段，已经是字符串字段；stage 2 only `MockATClient` 不连真硬件）。无需改业务代码
- [x] 5.2 AT 设备识别策略归 PR #3：在 macOS USB watcher 实现里复用 stage-2 已有的 `GSM_MODEM_WHITELIST` 通过 vendor/product ID 匹配；本 PR 不引入新匹配代码
- [x] 5.3 共享 serial discovery 工具归 PR #3：在实现 macOS USB watcher 时如果重复 `comports()` 调用 ≥ 2 处再抽出；YAGNI，本 PR 不创建空模块
- [x] 5.4 `pyserial` + `pyserial-asyncio` 从 Linux-only `[hardware]` extras 提升到主 `dependencies` 平台无关：Linux 与 macOS 安装都自动得到；`hardware` / `linux` extras 收敛为只剩 `pyalsaaudio`（Linux ALSA backend），macOS extras 只剩 `sounddevice`（PortAudio 跨平台），无 pyserial 重复
- [x] 5.5 验证：本机 macOS `pip install -e ".[macos]"` 装通 sounddevice + main pyserial；77 测试零回归；`from serial.tools.list_ports import comports` 在 macOS 跑通拿到 2 个端口

## 6. deploy/ 重构 + 共享 _lib.sh（PR #6，meta-repo）

- [ ] 6.1 现有 `deploy/scripts/` 重命名为 `deploy/linux/scripts/`
- [ ] 6.2 新增 `deploy/scripts` 软链 → `deploy/linux/scripts`（git tracked symlink）；deprecation warning 加到 `_lib.sh` 顶部
- [ ] 6.3 抽出共用部分到 `deploy/common/_lib.sh`：`log_info` / `log_warn` / `die` / `confirm` / `parse_common_flags` / `require_cmd` / `require_root` / `run` / `write_file`
- [ ] 6.4 `deploy/linux/scripts/_lib.sh` 改为只 source common 后加 Linux 特定（apt 包列表常量等）
- [ ] 6.5 主仓 `Makefile` `deploy-check` target 跑 shellcheck 范围扩展到 `deploy/{linux,macos,common}/scripts/*.sh`
- [ ] 6.6 主仓 README 路径引用 `deploy/scripts/` 改为 `deploy/linux/scripts/`（保留软链指向，文档内容直接走 canonical 路径）
- [ ] 6.7 验证：`make deploy-check` 通过；`bash deploy/scripts/install.sh --help` 仍能跑（走软链）

## 7. macOS provision.sh + brew baseline（PR #7）

- [ ] 7.1 新增 `deploy/macos/scripts/provision.sh`：`set -euo pipefail` + `--dry-run`；require root；require Apple Silicon (`uname -m == arm64`) + macOS 14+ (`sw_vers -productVersion`)
- [ ] 7.2 brew install 系统包：`postgresql@15` `redis` `nginx` `python@3.12` `node@20` `pkg-config` `git`；幂等检测（`brew list <pkg>` 已装则跳）
- [ ] 7.3 创建 `_isales` 系统账户（用 `dscl . -create /Users/_isales` + `sysadminctl -addUser` 一套；UID < 500；shell `/usr/bin/false`）；幂等
- [ ] 7.4 创建目录骨架 `/opt/isales/{releases,backups/{pg,redis},logs}` + `/etc/isales/env` + `/var/run/isales`；权限 `0750 root:_isales`
- [ ] 7.5 配置 Redis AOF：写入 `/opt/homebrew/etc/redis.conf` 设置 `appendonly yes` + `appendfsync everysec`；`brew services restart redis`
- [ ] 7.6 PG init：`brew services start postgresql@15` + `createuser isales --pwprompt`（密码从 random_secret 生成 → 写入 `/etc/isales/env/`）+ `createdb isales --owner=isales`；幂等 (`psql -lqt | grep isales` 跳)
- [ ] 7.7 bootstrap env files（与 Linux provision.sh 同名同字段，调用 `deploy/common/_lib.sh` 的 `bootstrap_env_file`，仅区别在 PG 路径默认值）
- [ ] 7.8 `--dry-run` 端到端通过；幂等：连跑两次第二次都是 "already exists, skipped"
- [ ] 7.9 验证：在 Mac mini 干净系统上跑 provision.sh 两次，第二次输出全部是幂等跳过

## 8. macOS install.sh + plist 装配（PR #8）

- [ ] 8.1 新增 `deploy/macos/plist/com.isales.api.plist` 等 6 份 launchd plist（`api/engine/scheduler/worker/telephony-api/modem-controller`）
  - `Label` = `com.isales.<service>`；`UserName` = `_isales`；`KeepAlive.SuccessfulExit=false`
  - `ProgramArguments` 指向 `/opt/isales/current/venv/bin/<entry>`
  - `StandardOutPath` / `StandardErrorPath` 指向 `/opt/isales/logs/<service>.{out,err}.log`
  - `WorkingDirectory` 指向 `/opt/isales/current/<repo>`
  - `EnvironmentVariables` 留空字典占位（install.sh 装配期注入）
- [ ] 8.2 新增 `deploy/macos/scripts/install.sh`：`set -euo pipefail` + `--dry-run`；与 Linux install.sh 平行结构
- [ ] 8.3 install.sh 在 `/opt/isales/releases/<ts>/` 下 git clone 7 仓 + `python3.12 -m venv venv` + `pip install -e isales-common` + 6 个服务（注意 isales-telephony 装 `[macos]` extras）
- [ ] 8.4 install.sh 跑 `cd isales-web && npm ci && npm run build`
- [ ] 8.5 install.sh 把 6 份 plist 同步到 `/Library/LaunchDaemons/`，并把 `/etc/isales/env/<service>.env` 内联展开到对应 plist 的 `<EnvironmentVariables>` 字典（用 `plistlib` Python 脚本完成）
- [ ] 8.6 install.sh 同步 nginx.conf 到 `/opt/homebrew/etc/nginx/servers/isales.conf`；symlink `/opt/homebrew/var/www/isales-web` → `/opt/isales/current/isales-web/dist`
- [ ] 8.7 install.sh trap ERR 清理失败 release 目录；MUST NOT 切 current 软链
- [ ] 8.8 验证：在 PR #7 已 provision 的 Mac 上跑 install.sh，目录结构 + plist + env 内联展开都 OK

## 9. macOS deploy.sh + rollback.sh + migrate.sh（PR #9）

- [ ] 9.1 新增 `deploy/macos/scripts/migrate.sh`：与 Linux 几乎一致（alembic 跨平台），调整 ALEMBIC = `/opt/isales/current/venv/bin/alembic`
- [ ] 9.2 新增 `deploy/macos/scripts/deploy.sh`：切 current 软链 + 按顺序 `launchctl kickstart -k system/com.isales.<svc>`；nginx `brew services reload nginx` 替代 systemctl reload
- [ ] 9.3 deploy.sh 低峰期闸门 + `--force` / `--include-modem` 与 Linux 版语义一致
- [ ] 9.4 deploy.sh 检测每个服务状态：`launchctl print system/com.isales.<svc>` 解析 `state = running`；非 running 失败 abort 并打印 `log show --predicate 'subsystem == "com.isales.<svc>"' --last 5m --no-pager`
- [ ] 9.5 新增 `deploy/macos/scripts/rollback.sh`：与 Linux 同结构，命令换 launchctl
- [ ] 9.6 验证：在 PR #8 已 install 的 Mac 上跑 deploy.sh，6 个服务全 running、nginx 可访问

## 10. macOS 备份脚本 + launchd cron 替代（PR #10）

- [ ] 10.1 新增 `deploy/macos/scripts/backup_pg.sh`：复用 Linux 版逻辑（pg_dump libpq URL）；logger 调用改 `logger -t isales-backup -p user.info` 写 unified logging
- [ ] 10.2 新增 `deploy/macos/scripts/backup_redis.sh`：复用 redis-cli --rdb 路径；同样 unified logging
- [ ] 10.3 新增 `deploy/macos/launchd-jobs/com.isales.backup.plist`：launchd plist 用 `StartCalendarInterval` 字典 `Hour=2 Minute=30`；`ProgramArguments` 跑 `/opt/isales/current/deploy/macos/scripts/backup_pg.sh && backup_redis.sh`
- [ ] 10.4 install.sh 把 `com.isales.backup.plist` 部署到 `/Library/LaunchDaemons/` 并 `launchctl bootstrap`
- [ ] 10.5 RUNBOOK macOS 章节加"如何手工触发备份"："`sudo launchctl kickstart -k system/com.isales.backup`"
- [ ] 10.6 验证：手工触发备份 plist；`/opt/isales/backups/{pg,redis}/<date>.{sql,rdb}.gz` 生成；`log show --predicate 'subsystem=="isales-backup"' --last 5m` 看到 ok 日志

## 11. RUNBOOK + macOS 章节（PR #11）

- [ ] 11.1 `deploy/macos/README.md`：与 `deploy/README.md` 平行的 macOS 部署模型说明（拓扑图、目录骨架、主机依赖、快速开始）
- [ ] 11.2 主 `deploy/RUNBOOK.md` 加 § "macOS 部署 (Apple Silicon, macOS 14+)" 章节，覆盖：首次部署、日常发版、回滚、备份恢复、故障排查 cheatsheet
- [ ] 11.3 RUNBOOK § macOS 用 `<details><summary>macOS</summary>...</details>` 折叠；每个章节 Linux 节与 macOS 节平行展示
- [ ] 11.4 macOS 故障排查 cheatsheet 至少：
  - PG/Redis 服务不起来：`brew services list` + `brew services restart`
  - launchd 服务不起来：`launchctl print system/com.isales.X` + 看 `state` / 看 `log show`
  - USB modem 不识别：`ioreg -p IOUSB | grep -i modem`、`system_profiler SPUSBDataType`
  - AT 串口被抢占：`lsof /dev/cu.usbmodem*` + 禁用系统 modem 服务步骤
  - Core Audio 异常：`sd.query_devices()` Python 一行命令排查设备名
- [ ] 11.5 主仓 README "Production deployment" 节链接更新（Linux 与 macOS 双链接）
- [ ] 11.6 `make deploy-check` 在 macOS 上能跑通 shellcheck（`deploy/macos/scripts/*.sh` 全绿）

## 12. 真硬件验收 + 归档准备（PR #12，**release-gate**）

- [ ] 12.1 准备一台 Mac mini M2/M4 或 Mac Studio M2，macOS 14+
- [ ] 12.2 跑完整序列：clone meta-repo + 7 服务仓 → `provision.sh` → 编辑 `/etc/isales/env/*.env` → `install.sh v0.x.0` → `migrate.sh` → `deploy.sh <ts> --force --include-modem`
- [ ] 12.3 插入 1 枚 USB GSM modem，等 modem-controller 日志 "device.status = registered" + "USB add: vendor=..."
- [ ] 12.4 创建 mock provider campaign + 1 个测试 lead；通过 isales-web UI 启动 campaign；观察 modem 拨号成功
- [ ] 12.5 接通后跑 3 轮真实对话（自己手机接 / 听）；挂断后 `call_record.status = end` + transcript 写入
- [ ] 12.6 测时延：用 `tests/macos/test_coreaudio_latency.py` 在真实音频路径上重复测，记录 p50 / p95 / p99；**MUST p95 ≤ 200ms**，否则阻塞归档（与 PR #4 单元时延测试呼应）
- [ ] 12.7 演练 rollback：第二次 install + deploy → rollback 回上一个 release，验证服务恢复且 modem-controller 仍能识别现有 modem
- [ ] 12.8 演练备份：`launchctl kickstart system/com.isales.backup`，验证 `/opt/isales/backups/{pg,redis}/` 文件生成 + `gunzip -t` 完整
- [ ] 12.9 把演练日志（含时延数据 + 截图）附到归档 PR 描述
- [ ] 12.10 `/opsx:archive impl-deploy-macos`
