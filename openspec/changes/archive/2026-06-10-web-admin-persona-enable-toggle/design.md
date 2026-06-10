## Context

persona 卡（`PromptTierEditor.vue` with `kind="persona"` + `collapsible`）卡头有一个 `el-switch`：

```vue
<el-switch v-if="collapsible" v-model="expanded" active-text="展开" inactive-text="收起" />
```

```ts
const expanded = ref(false);
const open = computed(() => !props.collapsible || expanded.value);
```

`expanded` 是本地 ref，只驱动 `v-if="open"`，不落库、不影响引擎。功能开/关的真实承载是 `campaign.persona_fanout_cap`（1=关、2/3=开），它的数字控件目前在 `RoutingRulesTab.vue:16-21`。引擎 `run_loop.py` 已只读 `persona_fanout_cap`（`enabled_personas = personas[:cap-1]`），所以把开关接到该字段即可使其真生效，无需任何后端改动。

## Goals

- persona 卡头开关 = 真功能开关：关→cap=1，开→cap≥2。
- 并发上限（2/3）与开关同处一卡，opt-in 体验自洽。
- 不引入冗余的"关"状态（不加 `persona_enabled`）。

## Decision 1 — 复用 persona_fanout_cap 作为开/关唯一承载（不加新布尔列）

**选 A：开关写 `persona_fanout_cap`（关=1 / 开=2-3）**，而非新增 `persona_enabled` 布尔列。

理由：
- `persona_fanout_cap=1` 在引擎语义里**本就是**"仅 main、无推测"（功能关）。再加一个 `persona_enabled` 会出现 `cap=1` 与 `enabled=false` 两处可表达"关"，二者并存即冗余、可不一致——正是「多层兜底是问题味道」要避免的。
- A 是**纯 web 改动**（引擎/common/api 零改动），B 要跨 common(迁移)/engine/api/web 四仓且制造冗余状态。

代价（已接受）：DB 里"关"只记 `cap=1`，重新加载时无法区分"关之前是 2 还是 3"，再开默认回到 2。这是单一真相的必然结果，可接受。

## Decision 2 — 开关 on/off ↔ cap 的映射

```ts
const fanoutCap = defineModel<number>("personaFanoutCap"); // 双向，父绑 form.persona_fanout_cap

const personaOn = computed<boolean>({
  get: () => (fanoutCap.value ?? 1) > 1,
  set: (on) => { fanoutCap.value = on ? Math.max(2, fanoutCap.value ?? 2) : 1; },
});
const open = computed(() => !props.collapsible || personaOn.value);
```

- 关→`cap=1`、卡体收起。
- 开→若当前 `<2` 置 `2`，否则保留现值（2/3 不变）；卡体展开。
- 卡体内并发上限控件 `v-model="fanoutCap"` `:min="2" :max="3"`（开时 cap 必 ≥2，故 min=2；越界由 el-input-number clamp）。

**保存时机**：`persona_fanout_cap` 是 `CampaignBase` 字段，随底部「保存」条经 `buildPayload()` 走 campaign PATCH——与当前 cap 在 `RoutingRulesTab` 的保存时机完全一致（deferred，非即时）。persona 行（label/model/prompt）仍各自即时保存，行为不变。

## Decision 3 — collapsible 与 persona 的耦合

`collapsible` 目前**仅** persona 卡使用，且功能开关语义本就 persona 专属（绑 `persona_fanout_cap`）。故把 collapsible 卡的开关直接接到 `personaOn`，不再保留泛化的"纯展开" `expanded` ref。若未来出现非 persona 的可折叠卡需求，再抽象（YAGNI，不提前分叉）。

## Non-goals

- 不改引擎 persona fan-out 逻辑、不改 cap 的 [1,3] 数据约束。
- 不动 persona delete-guard / routing_rules 引用校验。
- 不清理死代码 `views/Campaigns/Tabs/RoleConfigTab.vue`（无人 import，超出本 change 范围）。
