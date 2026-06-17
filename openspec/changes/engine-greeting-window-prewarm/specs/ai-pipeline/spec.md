## ADDED Requirements

### Requirement: 开场白窗口期预热下游连接

开场白(GREETING 内部阶段)播放期间是一段对外部网络空闲的窗口。engine SHALL 利用该窗口**并行预热**第一轮真实回复所需的下游连接,使一次性建连握手开销从 turn-1(第一句 AI 回复)移走;预热 MUST 与开场白播放并行、MUST NOT 串行阻塞开场白播放或第一轮入口。预热包含 **ASR WebSocket 建连**与 **main LLM 槽连接池预热**两项;referee 槽、TTS 连接、厂商前缀缓存均不在本要求范围内。

预热是纯优化:任一预热失败 MUST **fail-soft**——回落到原有懒连路径、MUST NOT 阻塞或中断通话。这是本能力允许的唯一一层兜底。

#### Scenario: 开场白播放期间并行建立 ASR WebSocket

- **WHEN** engine 进入开场白播放(GREETING 内部阶段)
- **THEN** engine SHALL 与开场白播放并行发起 ASR WebSocket 的 connect + 配置帧握手,使握手与开场白播放在时间上重叠,而非在开场白结束后才开始

#### Scenario: 开场白期间不把音频喂入 ASR finalize

- **WHEN** ASR WebSocket 已在开场白窗口期建连,但开场白尚未播放完成
- **THEN** engine MUST NOT 把入向音频路由进 ASR finalize(保持开场白不可打断、不把开场白回声 / 客户抢话计入首句识别)
- **AND** 开场白播放完成时 engine MUST drain 开场白期累积的入向缓冲帧,然后才开始正常的 ASR 音频消费

#### Scenario: 开场白播放期间预热 main LLM 槽连接池

- **WHEN** engine 进入开场白播放,且开场白为固定模板模式(不调用任何 LLM)
- **THEN** engine SHALL 与开场白播放并行向 main 槽 LLM 发一次轻量预热请求,使 main 槽 httpx keep-alive 连接池在 turn-1 的 `chat_stream` 之前完成 TCP+TLS 握手

#### Scenario: LLM 生成开场白自然预热 main 连接池

- **WHEN** 开场白为 LLM 生成模式,经由 main 槽 client 调用 `chat`
- **THEN** 该 `chat` 调用已使 main 槽连接池热;engine MUST NOT 为同一 main 槽 client 再发冗余的额外预热请求

#### Scenario: 预热失败回落不阻塞通话

- **WHEN** ASR 提前建连或 main 槽预热请求失败(网络错误 / 超时 / 异常)
- **THEN** engine MUST fail-soft:记录日志并回落到原有懒连路径(turn-1 自行建连),MUST NOT 抛出中断通话、MUST NOT 改变对外可观测行为

## MODIFIED Requirements

### Requirement: 开场白不走管线

开场白(GREETING 状态的播放内容)MUST NOT 经过 referee 或 extractor,原因是内容可预期、合规性提前由 Campaign 创建者保证。"不走 referee / extractor 管线"仅指开场白内容本身不被门控 / 抽取处理;它**不**意味着开场白窗口期不得预热下游连接——开场白播放期间 engine MAY 并行预热 ASR / main LLM 连接(见「开场白窗口期预热下游连接」),前提是不改变开场白不可打断语义、不把开场白期音频喂入 ASR finalize。

#### Scenario: 固定模板开场白

- **WHEN** Campaign 配置固定模板开场白
- **THEN** engine SHALL 直接 TTS 播放该模板,不调用任何 LLM 来生成开场白内容(预热用的轻量探测请求不产生开场白内容,不属于此处禁止的"生成开场白"调用)

#### Scenario: LLM 生成开场白

- **WHEN** Campaign 配置 LLM 生成开场白
- **THEN** engine SHALL 调用 main LLM 生成(用 `chat` 非流式接口,因为开场白短);直接 TTS;**MUST NOT 调 referee / extractor**

#### Scenario: 开场白记入对话历史

- **WHEN** 开场白播放完成
- **THEN** engine MUST 把开场白文本作为 `assistant` 角色追加到 dialog_history(参与后续轮次的 main LLM 上下文)
