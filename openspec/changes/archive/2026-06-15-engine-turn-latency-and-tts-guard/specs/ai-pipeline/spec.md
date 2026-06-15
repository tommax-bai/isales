## ADDED Requirements

### Requirement: TTS 不合成无可读内容的句

`sentence_splitter` 切出的每一句在送 TTS `synthesize_stream` 之前 SHALL 保证含至少一个可合成字符;纯标点 / 空白 / 符号的句(如省略号 "..." 被逐点切出的裸 "." / "…" / "。")MUST NOT 送 TTS。判定 SHALL 基于 Unicode 类别(含任一字母 L* 或数字 N* 即可合成),MUST NOT 维护硬编码标点表。

理由:Volcengine TTS 对纯标点文本返回 `code=45002001 "No readable text!"`(call 194 turn 4 实录),既丢碎片又刷 error。固定话术(开场白 / 静默催促 / 转人工短语)经 `_play_tts` 不过 splitter,是受控输入,不在本约束范围。

#### Scenario: 裸标点句被丢弃

- **WHEN** main LLM 输出 "呃...那个，您听岔啦" 经 splitter 切出裸 "." / "…" chunk
- **THEN** splitter MUST NOT yield 该 chunk;含可读字的句("呃." / "那个，您听岔啦")照常 yield 送 TTS

#### Scenario: 整句皆无可读内容

- **WHEN** 某一轮 main 回复切出的所有 chunk 均为纯标点 / 空白
- **THEN** 该轮 MUST NOT 向 TTS 发任何合成请求;first_audio_ms 留空(无音频);通话主路径不受影响

### Requirement: 重组轮落 pipeline_trace

restructure 重组流播放完成后 engine SHALL 为该重组输出轮(其独立 `turn_id`)落一条 `pipeline_trace` 记录,与正常对话轮对齐——记 `main_reply_text` / `main_duration_ms` / `main_tokens_*` / `first_audio_ms` / `restructure_active=true` / `restructure_source_text`。MUST NOT 只发 `ai_reply` 转录事件而不落 trace(否则该轮延迟/token 不可事后查询)。

> 说明:门控判定走 restructure 时已落一条「决策行」(承载 `restructure_active` + source_text,turn_id = 被打断的 main 轮);本 requirement 要求的是重组**输出行**(turn_id = 重组流自身),二者 turn_id 不同、互补。

#### Scenario: 重组输出轮有 trace 行

- **WHEN** 路由命中 restructure 且重组流跑完(InterruptText 非空)
- **THEN** `pipeline_trace` SHALL 含一条 turn_id = 重组流 turn_id 的行,`restructure_active=true` 且 `main_reply_text` = 重组回复

### Requirement: pipeline_trace 记 main 首 token / 首句延迟

每轮 main(及重组)轮落 `pipeline_trace` 时 engine SHALL 写 `main_first_token_ms`(从 main 生成起到 LLM 首个 token)与 `main_first_sentence_ms`(到首个可切句),供事后分解「首音频延迟来自 LLM TTFT 还是 TTS 合成」。两字段在 fallback / 异常 / 无 token 等场景 MAY 为空。

#### Scenario: 正常流式轮记首 token/首句

- **WHEN** main LLM 流式产出 ≥1 token 且 ≥1 句
- **THEN** 该轮 `pipeline_trace` 的 `main_first_token_ms` / `main_first_sentence_ms` SHALL 为非空整数(ms);`main_first_token_ms` ≤ `main_first_sentence_ms` ≤ `main_duration_ms`
