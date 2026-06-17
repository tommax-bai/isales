## Context

`sentence_splitter.py:63-67` 当前在三条件之一命中时切句：句末标点 `。？！` / `\n\n` / `len(buffer) >= MAX_SENTENCE_CHARS(50)`。第三条是逐字符累加到 50 就**立即硬切**，切点由字数决定、与语义边界无关 → 拦腰斩句（在词或短语中间断开）。这既制造最难听的跳变，又把一句拆成多个独立冷 TTS 请求放大跨句韵律重置。

## 决策

### 切句改为「软阈值 + 软标点 + 硬上限」三档

```
should_emit = (
    ch in _TERMINATORS                                       # 句末，不变
    or buffer.endswith("\n\n")                               # 空行，不变
    or (len(buffer) >= SOFT_SENTENCE_CHARS and ch in _SOFT_BOUNDARIES)  # 新：长到软阈值后在停顿处切
    or len(buffer) >= MAX_SENTENCE_CHARS                     # 兜底：硬上限（抬到 120）
)
```

- `_SOFT_BOUNDARIES = "，、；：,;:"`（中英文停顿标点）。
- `SOFT_SENTENCE_CHARS = 60`：低于此不因长度切（短句完全不受影响）；超过后遇到的**下一个**软标点处切——落在自然停顿、且单元已足够大。
- `MAX_SENTENCE_CHARS = 120`（原 50）：仅当持续无任何标点的长串到达此值才硬切，纯兜底防 first-audio 无限拖。正常销售话术极少出现 >120 字零停顿。

### 为何这样取舍

- **消拦腰斩句**：除非单个子句 >120 字且零标点（罕见且本就无处可切），不再在词中间断。
- **减少重置次数**：单元从「≤50 字」放大到「≤120 字 / 到软标点」，跨请求重置变少。
- **切点更不可闻**：软标点处韵律本就下沉，在停顿处重置远比在词中间重置自然。
- **first-audio**：仅长 run-on 开场句首单元略增（等软标点 / 兜底），由固定开场白 + 时间门控垫词（`filler_delay_s` 从 `processing_start` 起算）覆盖；typical 句首句末标点早于 60 字命中，逐字不变。
- **保留软标点于单元内**：emit 时 buffer 含该软标点（`buffer += ch` 在判定前），单元以停顿标点结尾、TTS 自然处理为停顿；`_has_synthesizable_text` 仍有 L/N 字符通过，不触发 vendor「无可读内容」。

## 不做什么

- 不动 provider / 协议 / 音色 / producer-consumer / barge-in（与已评估的 A、双向流式无关，本 change 只调切句）。
- 不引入「按角色 / campaign 可配的切句参数」——v1 用模块常量，需要时再 promote。

## 风险

- 长无标点 run-on 的 first-audio 增加（最坏到 120 字才出首单元）——边界场景，靠垫词 / 开场白覆盖，必要时下调 `MAX_SENTENCE_CHARS`。
- 软阈值 / 硬上限取值是经验值，真机听感后可微调（纯常量，零结构改动）。
