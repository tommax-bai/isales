## Why

长文本 TTS 合成时跨句音色 / 语气跳变，根因是引擎按句切、每句一个独立冷 TTS 请求、无跨请求上下文（详见已评估的 `engine-tts-bidi-streaming` proposal + memory `project_tts_timbre_and_protocol_history`）。对该根因的完整治本（双向流式整轮一个 session）代价大、且强制换音色、前提尚未实测——经多视角评估后决定**按阶梯走，先做最便宜、零回归、能立刻听效果的一档**。

本 change 是阶梯第 1 档（B）：当前 `sentence_splitter.py` 在 buffer 满 50 字时**硬切**（`len(buffer) >= max_chars`，不管切在哪），会**拦腰斩句**——在词/ 短语中间切断，制造最难听的那种跳变，且把本可连续的一句拆成多个独立冷请求、放大跨句重置。修复：满字数时不再硬切，而是**退到最近的软标点（、，；：）在自然停顿处断**，并把硬上限抬高只作兜底——单元更大、切点落在韵律本就下沉的停顿处、跨请求重置更少更不可闻。纯单文件改动、不换音色、不碰协议、零回归风险。

## What Changes

- **修改** `isales-engine/streaming/sentence_splitter.py` 的切句条件：
  - 新增软阈值 `SOFT_SENTENCE_CHARS`（默认 60）：buffer ≥ 软阈值后，遇到软标点（`，、；：,;:`）即在该处切句（自然停顿）。
  - `MAX_SENTENCE_CHARS` 从 50 抬到 120，语义从「到此硬切」改为「硬上限兜底」：只有持续无任何标点的长串到达 120 字才硬切（防 first-audio 无限拖）。
  - 句末标点 `。？！`、`\n\n`、stream 结束 flush、无可读内容过滤——**全部不变**。
- **修改** `tests/test_sentence_splitter.py`：更新 `test_char_cap_forces_split` 反映新语义，新增软标点切句 + 硬上限兜底用例。
- **不改** provider、协议、音色、producer/consumer 流水线、barge-in 路径。

## Capabilities

### New Capabilities
<!-- 无新增 capability：仅调整既有 sentence boundary detector 的切句条件。 -->

### Modified Capabilities
- `ai-pipeline`: `sentence boundary detector` 要求的切句条件——「满 50 字硬切」改为「满软阈值后在软标点处切 + 硬上限兜底」；同步「main LLM 流式 token → sentence → TTS」场景里对 50 字 cap 的措辞。

## Impact

- **代码**：`isales-engine/isales_engine/streaming/sentence_splitter.py`（单文件）+ `tests/test_sentence_splitter.py`。无 common / api / web / alembic 改动。
- **行为**：长无标点句不再在第 50 字拦腰切；TTS 合成单元变大、切点落在停顿处。typical 短句（< 60 字、有句末标点）行为逐字不变。
- **延迟**：长 run-on 开场句的 first-audio 略增（等到软标点或硬上限），由已上线的固定开场白 + 时间门控垫词覆盖。
- **部署**：scp engine 单文件 + 重启 engine。
- **阶梯后续**（本 change 不含，按评估结论后置）：A = 整轮 / 大块合并成一个单向请求；D = 双向流式（`engine-tts-bidi-streaming`，parked）。先听 B 效果再决定是否上 A / D。
