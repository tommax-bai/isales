## MODIFIED Requirements

### Requirement: sentence boundary detector

engine SHALL 在 `streaming/sentence_splitter.py` 模块实装 sentence boundary 切分逻辑：累积 main LLM yield 的 token 到 buffer，命中下列条件之一时切一句送 TTS：

- 命中句末标点 `。？！`（及 ASCII `.?!`）或换行 `\n\n`
- buffer 长度达到软阈值 `SOFT_SENTENCE_CHARS`（默认 60）后，遇到软标点（停顿类 `，、；：,;:`）即在该软标点处切——在自然停顿边界切，MUST NOT 在词 / 短语中间硬切
- buffer 长度达到硬上限 `MAX_SENTENCE_CHARS`（默认 120）即切——仅作兜底，防持续无任何标点的长串把 first audio 无限拖后
- stream 结束时 buffer 不空，整体作为末句 flush

切句条件 SHALL 优先在语义 / 停顿边界切：长度只有在到达软阈值后才参与切句、且优先落在软标点处；硬上限是无标点 run-on 的最后兜底。该设计相对早期「buffer 累积超 50 字即在第 50 字处硬切」是**收紧**：早期按字数硬切会拦腰斩句（在词中间断开），既制造最难听的跨句跳变、又把本可连续的一句拆成多个独立冷 TTS 请求放大跨句韵律重置。短句（长度低于软阈值、且含句末标点）的切分行为 MUST 与早期逐字节一致。无可读内容（纯标点 / 空白）的片段过滤规则不变（见 § "TTS 不合成无可读内容的句"）。

#### Scenario: 中文标点切句

- **WHEN** main LLM yield token 累积成 "您好张总，请问周三上午方便吗？"
- **THEN** sentence_splitter SHALL 切成 ["您好张总，请问周三上午方便吗？"] 一句；命中 `？` 后立即返回；buffer 清空（该句长度未达软阈值，句中的 `，` MUST NOT 触发长度切）

#### Scenario: 长句在软标点处切（非拦腰）

- **WHEN** main LLM 输出一段长文本，在出现句末标点 `。？！` 之前 buffer 长度已达到软阈值 `SOFT_SENTENCE_CHARS`
- **THEN** sentence_splitter SHALL 在达到软阈值后遇到的**下一个软标点**（`，、；：,;:`）处切句（该软标点保留在切出的单元末尾），MUST NOT 在第 N 个字符处不看标点硬切；切出的单元落在自然停顿边界

#### Scenario: 无标点长串到达硬上限兜底切

- **WHEN** main LLM 输出持续无任何句末标点 / 软标点的长串，buffer 长度到达硬上限 `MAX_SENTENCE_CHARS`
- **THEN** sentence_splitter SHALL 在硬上限处切句（兜底，防 first audio 无限拖）；此为唯一允许的非标点边界切

#### Scenario: stream 结束 flush

- **WHEN** main LLM `chat_stream` AsyncIterator 结束（StopAsyncIteration）且 buffer 不空
- **THEN** sentence_splitter SHALL 把 buffer 作为最后一句 yield；buffer 清空
