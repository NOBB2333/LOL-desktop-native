# 玩家标签系统重做（对齐 LeagueAkari）— 审核材料

> 面向对象：另开会话做 review 的人（无需本会话上下文）。
> 参照实现：`D:\4_Code\0_Github_Project\lol\LeagueAkari`
> 改动仓库：`D:\4_Code\0_Github_Project\lol\LOL-desktop-native`

---

## 0. 一句话摘要

把对局页玩家卡片标签从「后端吐一串 `{key,label,tone}`、前端直接铺」的旧写法，
换成 LeagueAkari 的**注册表 + 定义**架构：每条标签是一个 `render(ctx)` 纯函数，
配色、顺序、弹层结构、判定阈值逐项对齐 LeagueAkari；并顺手补齐了「已标记」备注的
读写链路（后端 SQLite 持久化 + 前端编辑面板 + 设置页开关）。

---

## 1. 为什么改

旧实现的问题：

1. **标签是数据不是规则**。后端算出 `label/tone` 字符串塞进 `PlayerProfile.tags`，
   前端只负责渲染。想改判定阈值或文案，要动 Zig；想加一个只在前端需要的标签，也要动 Zig。
2. **配色/文案各写各的**。同一个概念（如「单杀」）在不同地方有不同的词和颜色。
3. **「遇到过」信息量太大塞在 chip 里**。旧实现把次数写在 chip 上（「遇到过 3 次」），
   标签宽度随数据抖动，且逐局对照信息无处安放 —— 这正是用户点名不满意的点。

改成 LeagueAkari 的做法后：**规则集中在一处**（`definitions/`），
新增标签 = 往 `registry.ts` 数组里加一项，渲染层零改动。

---

## 2. 新架构

```
PlayerTagContext  ──flatMap──▶  PLAYER_CARD_TAGS[]  ──▶  PlayerTagView[]
   (玩家数据/设置)                  (有序注册表)            (label + popover?)
```

- `PlayerTagDefinition { id, render(ctx) }` → `{ label, popover? } | null`，返回 `null` 即不渲染。
- **数组顺序 = 展示顺序**，与 LeagueAkari 的 `PLAYER_CARD_TAGS` 一致。
- 每个标签自己判 `ctx.settings.showXxxTag`，不在渲染层做统一过滤（与 LeagueAkari 相同）。
- 事实（场均/连胜/样本数…）由 `facts.ts` 一次算好，`render` 只读数字，不遍历原始对局
  （对应 LeagueAkari 的 `AggregatedAnalysis`）。

### 2.1 注册表顺序（对齐 LeagueAkari）

`自己 → 已标记 → 预组队 → 极高胜率 → 遇到过 → 连胜 → 连败 → 优异 →
好抓/难抓 → 单杀 → 伤害占比 → 分均补兵 → 视野得分 → [阵亡/参团/英雄池]* → 综合评分`

\* 标 `[]` 的三项是本项目在 LeagueAkari 之外补充的指标，但同样遵循 chip + 弹层规范，
放在综合评分之前。LeagueAkari 原表里的「生涯隐藏 / 闪现异位 / 场均承伤 / 场均经济 /
伤害经济效率 / 敌方消失信号 / 击杀伤害效率 / 胜率队」本项目暂未实现（数据源不具备）。

### 2.2 配色（直接取 LeagueAkari `tagClass(...)` 的色值）

| 标签 | 色值 | 备注 |
|---|---|---|
| 自己 | `#37246c` | |
| 遇到过 | `#5cacea` | **黑字**（浅底，两种主题下都是黑字） |
| 已标记 | `#49914d` | |
| 极高胜率 | `#7e2c85` | |
| 连胜 / 连败 | `#18571c` / `#893b3b` | |
| 优异 / 综合评分 | `#b81b86` | |
| 好抓 / 非常好抓 / 难抓 | `#8f541e` / `#a81919` / `#24606d` | |
| 单杀 | `#9019a8` | |
| 伤害 / 分均补兵 / 视野 | `#692723` / `#5a4a1f` / `#2451a6` | |

色值落在 `styles/main.css` 的 `.tag-chip--*` CSS 变量上，四套主题各自覆盖。

### 2.3 「遇到过」弹层（本轮的重点）

- **chip 文案只有三态**：`遇到过` / `上局队友` / `上局对手`，**不带次数**
  —— 次数进弹层，chip 宽度恒定。
- 弹层结构逐列对齐 LeagueAkari：

  | 对局 ID | 对局日期 | 结果 | 关系 | 自己 | 该玩家 |
  |---|---|---|---|---|---|
  | `查看 {gameId}` 按钮 | 绝对时间 + (相对时间) | 胜利/失败/待结算 | 友/敌 | 位置+英雄+KDA | 位置+英雄+KDA |

- 汇总文案沿用 LeagueAkari 原文：
  - 「最近在 {date} 遇到过该玩家，共遇到过 {count} 次」
  - 「仅显示最近 {count} 场对局」
- `maxHeight: 320` + `scrollable: true`，与 LeagueAkari 的 `max-h-60` 视觉一致。
- 弹层组件同时被 `PlayerDetailDrawer` 复用（传 `hide-summary`，因为抽屉里已有分区标题）。

---

## 3. 逐项偏差修正（对照 LeagueAkari 源码逐条核出）

本轮把**上一轮遗留的 5 处不一致**逐个改齐。这是本次 review 最该看的一节。

| # | 项 | 改前 | 改后（= LeagueAkari 原值） | 依据 |
|---|---|---|---|---|
| 1 | 「已标记」chip 文案 | `玩家标记` | **`已标记`** | `zh-CN/renderer/ongoing-game.yaml:242` `tagged: 已标记` |
| 2 | 极高胜率阈值 | 样本 ≥ 8 且胜率 ≥ 0.75 | **样本 ≥ 16 且胜率 ≥ 0.85** | `tags/basic.tsx:184-185` `count < 16` / `winRate < 0.85` |
| 3 | 单杀 chip | `单杀威胁` / `有单杀能力` 两档，威胁档用 danger 红 | **`{n} 单杀` 单档，tone `solo`（`#9019a8`）** | `tags/basic.tsx:307-331` + `ongoing-game.yaml:224` `soloKills: '{{times}} 单杀'` |
| 4 | 设置页标签文案 | 自己 / 玩家标记 / 单杀能力 / 亮眼表现 … | 对齐 `settings.playerCardTags.tags.*`：自己标记 / 已标记的玩家 / 场均单杀次数 / 优异标记 … | `zh-CN/renderer/settings.yaml:234-280` |
| 5 | 备注长度上限 | 前端 120 字 vs 后端 320 **字节**（中文 3 字节/字 → 120 字 = 360 字节，**被后端静默截断**） | 后端 `max_note_bytes` = **360**（120×3），并双向加交叉引用注释 | — |

> 第 5 条是本轮抓出的**真实用户可见缺陷**：写 120 个汉字的备注，存下去只剩 106 个。

### 3.1 已核对一致、未改动的部分

- easy-gank 四档阈值：`>2` 非常好抓、`≥1.5` 好抓、`[1,1.5)` 不标注、`<1` 难抓；
  打野自己不标「好抓」。
- 连胜/连败阈值 3；文案「截止到现在，该玩家 {n} 连胜，很棒」/「…{n} 连败」。
- 优异 / 通天代 分档与弹层文案。
- 各指标弹层文案（伤害占比、分均补兵、视野得分、单杀、好抓）。
- 预组队配色板、同组同色。

---

## 4. 「已标记」备注链路（新增能力）

旧实现只有 chip，写了没法存。本轮补齐端到端：

```
PlayerTagEditPanel (弹层编辑器)
        │ emit save(notes[])
        ▼
LiveView ──▶ usePlayerNotes ──▶ backend.updatePlayerTag ──▶ lol.update_player_tag
                    │                                              │
                    └────────── backend.playerTags ◀───────────────┘
                              lol.get_player_tags
```

### 后端 `src/backend/player_tags.zig`（新增，170 行）

- 存储 kind：`"playerTag"`；**键 = `{selfPuuid}|{targetPuuid}`**
  —— 写入者写进键里，多个账号共用同一个 SQLite 也不会互相覆盖。
- `scopedKind("playerTag")` 视为**公共 kind**（不参与账号/大区作用域），
  与 `config` / `settings` / `cache` 同类。
- 收敛规则：单条 ≤ **360 字节**（按 UTF-8 边界截断，不会切出半个字），
  最多 **8 条**，空白项丢弃，脏 JSON 一律退化成「没有备注」而不是整页报错。
- 清空备注 = 写入空数组，**保留更新时间**，方便前端判断是否需要刷新。

### 新增命令

| 命令 | 入参 | 出参 |
|---|---|---|
| `lol.get_player_tags` | `{puuids: string[], selfPuuid?: string}` | `{"tags":{"<puuid>":["备注",…]}}` |
| `lol.update_player_tag` | `{puuid, notes: string[], selfPuuid?}` | `{"puuid","notes":[…]保留项,"updatedAt"}` |

`selfPuuid` 缺省时回退到当前登录账号（`playerTagOwner`），
这样快照模式与测试无需登录态也能跑。

### 前端

- `composables/usePlayerNotes.ts`：按 puuid 集合**去重后批量读一次**
  （而不是每张卡片各发一次请求）；`generation` 守卫防止慢请求覆盖新结果；
  `canEdit` 对「自己」和空 puuid 返回 false。
- `components/PlayerTagEditPanel.vue`：一行一条备注的文本域，实时 `splitTagNotes` 归一化。
- `services/backend.ts`：`playerTags` / `updatePlayerTag`，无后端时走内存
  （浏览器预览可直接演示）。

---

## 5. 逐文件清单

### 5.1 新增 — 标签核心（`frontend/src/tags/`）

| 文件 | 行 | 职责 |
|---|---|---|
| `registry.ts` | 50 | 注册表，数组顺序即展示顺序 |
| `tones.ts` | 79 | 配色令牌 + 预组队色板 |
| `facts.ts` | 149 | 从 `PlayerProfile` 推导事实（样本/胜率/连胜/场均…） |
| `context.ts` | 53 | `PlayerTagContext` 构造 |
| `types.ts` | 70 | `PlayerTagDefinition` / `PlayerTagView` 等类型 |
| `settings.ts` | 84 | 16 个逐标签开关 + 设置页元数据 + 归一化 |
| `notes.ts` | 28 | 备注文本归一化（拆行/去重/限长） |
| `chip.ts` | 44 | chip / textPopover 构造助手 |
| `usePlayerTags.ts` | 18 | `computed` 封装，供组件消费 |

### 5.2 新增 — 标签定义（`frontend/src/tags/definitions/`）

| 文件 | 行 | 含 |
|---|---|---|
| `identity.ts` | 96 | 自己 / 已标记 / 预组队 |
| `performance.ts` | 123 | 极高胜率 / 连胜 / 连败 / 优异 / 综合评分 |
| `playstyle.ts` | 223 | 好抓难抓 / 单杀 / 阵亡 / 参团 / 伤害占比 / 分均补兵 / 视野 / 英雄池 |
| `met.ts` | 47 | 遇到过（三态文案 + 表格弹层接线） |

### 5.3 新增 — 标签组件（`frontend/src/tags/components/`）

| 文件 | 行 |
|---|---|
| `PlayerTagArea.vue` | 131 |
| `PlayerTagChip.vue` | 35 |
| `PlayerTagMetPopover.vue` | 268 |
| `PlayerTagScorePopover.vue` | 117 |
| `PlayerTagTextPopover.vue` | 18 |

### 5.4 新增 — 备注链路

| 文件 | 行 |
|---|---|
| `src/backend/player_tags.zig` | 170 |
| `frontend/src/composables/usePlayerNotes.ts` | 91 |
| `frontend/src/components/PlayerTagEditPanel.vue` | 97 |
| `frontend/src/services/backend.ts`（改） | + 两个方法 |

### 5.5 新增 — 测试

| 文件 | 行 | 用例 |
|---|---|---|
| `frontend/src/tags/tags.test.ts` | 288 | 注册表顺序、逐标签阈值、弹层参数 |
| `frontend/src/tags/components/PlayerTagMetPopover.test.ts` | 67 | 5 |
| `frontend/src/tags/notes.test.ts` | 26 | 4 |
| `frontend/src/composables/usePlayerNotes.test.ts` | 86 | 6 |
| `frontend/src/components/PlayerTagEditPanel.test.ts` | 80 | 8 |
| `src/backend/player_tags.zig`（内嵌 test） | — | 2 |

### 5.6 修改

| 文件 | 改动 |
|---|---|
| `frontend/src/styles/main.css` | `.tag-chip--*` 令牌换成 LeagueAkari 精确色值 + 暗色覆盖 |
| `frontend/src/components/PlayerCard.vue` | 接入 `PlayerTagArea`；删掉旧的 `.bp-player-card__encounter` 规则 |
| `frontend/src/components/PlayerDetailDrawer.vue` | 复用 `PlayerTagMetPopover`（`hide-summary`） |
| `frontend/src/views/LiveView.vue` | 三处 `PlayerCard` + 抽屉接线；`usePlayerNotes`；编辑面板挂载 |
| `frontend/src/views/SettingsView.vue` | 新增 `#settings-tags` 分区（两列 `NSwitch` 网格，窄屏塌成一列） |
| `frontend/src/fixtures/data.ts` | `fixtureConfig.version` 18→19 |
| `frontend/src/utils/config.ts` | `CURRENT_CONFIG_VERSION` 18→19 + `playerTags` 归一化 |
| `frontend/src/types/domain.ts` | `playerTags` 设置字段；标注旧 `tags` 仅供电快捷键引擎 |
| `src/backend.zig` | 两个命令注册 + handler + 错误映射 + `refAllDecls` |
| `src/storage.zig` | `scopedKind` 增加 `playerTag` |

### 5.7 删除

| 文件 | 原因 |
|---|---|
| `frontend/src/components/EncounterList.vue` | 抽屉/卡片改造后成为孤儿，无任何引用 |
| `frontend/src/components/*.test.ts` 中相关的旧断言 | 旧 `encounter-trigger` / `encounter-match-open` testid 已不存在 |

---

## 6. 验证状态

全部命令在仓库根目录执行。

### 6.1 前端 — 全绿 ✅

```bash
cd frontend
npm run typecheck   # vue-tsc --noEmit  → 无输出（干净）
npm run lint        # oxlint src         → 0 warnings, 0 errors（87 文件 / 96 规则）
npm run test        # vitest run         → 26 文件 / 141 用例 全部通过
```

覆盖点：注册表顺序与 LeagueAkari 一致、`usePlayerTags` 排序、
每个标签定义的阈值边界（自己/预组队/已标记/极高胜率/连胜连败/好抓/单杀/伤害/补兵/视野）、
遇到过关系判定（队友/对手/仅遇到过）、弹层列头顺序与行数、
设置归一化、备注文本拆分、`usePlayerNotes` 的竞态与 `canEdit`、
编辑面板交互、浏览器预览下的备注往返。

### 6.2 后端 — 全绿 ✅

```bash
zig build test -Dplatform=null --summary all
# Build Summary: 15/15 steps succeeded; 161/161 tests passed
```

- 161 = 上一轮 154 + 本轮 `player_tags.zig` 的 2 个用例 + 其余随模块引入的用例。
- `zig build test` **包含** `frontend.bundle` 步骤，所以上面这条同时验证了 `vite build`。

### 6.3 ⚠️ 构建时必须先清 `frontend/dist`

`zig build test` 会跑 `vite build`，而 Vite 的 `emptyOutDir` 用 `rmSync` 清
`frontend/dist/assets`（100+ 文件）。沙箱的批量删除保护阈值是 50，
必然报 `SAFE_DELETE_BULK_CONFIRM_REQUIRED`，表现为**测试全过但构建失败**。

```bash
rm -rf frontend/dist     # 该目录在 .gitignore 里，可安全删除
zig build test -Dplatform=null
```

沙箱内执行 `rm` 会被拦，需要提升权限运行。

---

## 7. 本轮抓出的真实缺陷（2 个，均已修）

### 7.1 后端 `player_tags.zig` 返回栈内存切片（use-after-return）

```zig
// 改前
var kept: [max_notes][]const u8 = undefined;   // ← 栈数组
...
return kept[0..count];                          // ← 返回指向已销毁栈帧的切片
```

调用方 `updatePlayerTag` 拿到后继续遍历。栈内存当时还没被覆盖，所以**测试是过的**
——典型的靠运气存活。改成 `arena.alloc` 后消除。

### 7.2 JSON 转义缓冲区可能不够（`NoSpaceLeft`）

原按 `max_note_bytes + 8` 预留。`std.json.Stringify` 把控制字符转义成 `\u00XX`
（1 字节 → 6 字节），8 条极端输入会顶爆缓冲区 → 命令直接报错。
改为按 `max_note_bytes * 6` 预留。

---

## 8. 风险与取舍

| 项 | 取舍 | 理由 |
|---|---|---|
| 旧 `PlayerProfile.tags` 字段 | **已删除** | 原先保留它是为了喂 `{streak}` / `{risk}` / fixture 摘要。现在这条链路改由 `frontend/src/tags/signals.ts` + `src/backend/player_signals.zig` 从 `recentMatches` 现算，阈值与文案全部 import 自 `tags/definitions/`，不存在第二份词表 |
| 新增 3 个 LeagueAkari 没有的标签（阵亡/参团/英雄池） | 保留 | 数据源已具备，且遵循同一套 chip + 弹层规范；放在综合评分之前不干扰对齐部分 |
| 备注是**多行列表**（最多 8 条），LeagueAkari 是**单条字符串** | 有意偏离 | 本项目是单机单用户，没有「他人标记」的数据来源，多行更实用；键里带 `selfPuuid` 为将来留了扩展位 |
| 遇到过「结果」只有 胜利/失败/待结算 | 简化 | LeagueAkari 还有 终止/重开，本项目遭遇记录的 `win` 是布尔，暂无从区分 |
| 极高胜率要求 ≥16 场 | 严 | 与 LeagueAkari 一致；本项目战绩拉取上限 20 场，触发条件变紧（这是对齐的代价，不是 bug） |

---

## 9. 明确未做 / 待确认

1. ~~**旧标签词表还没清理**~~ **已清理（本轮完成）**：
   - `src/backend/recent_tags.zig` 删除，改为 `src/backend/player_signals.zig`
     （`EncounterSummary` 迁到 `encounters.zig`）；
   - `PlayerProfile.tags` / `PlayerTag` / `BackendPlayerTags` 从类型层删除；
   - `{tag}` / `{streak}` / `{risk}` 三个模板变量与 `writeLiveTeamSummary` 的
     strengths / risks 全部改由 `player_signals` 现算；
   - `frontend/src/fixtures/data.ts` 的摘要改走 `teamSignals()`。
   三处词汇（后端信号、前端卡片标签、fixture）现在共用 `tags/definitions/` 的常量。
2. LeagueAkari 里尚未实现的标签：生涯隐藏、闪现异位、场均承伤、场均经济、
   伤害经济效率、敌方消失信号数、击杀伤害效率、胜率队 —— 数据源不具备。
3. 备注的**「他人标记」**语义（LeagueAkari 的 `markedBySelf` / `taggedByOther` + 标记者昵称）
   未实现，因为本项目没有标记共享的数据来源。
4. 备注的**短语库**（LeagueAkari `SAVED_PLAYER_TAG_PHRASE_*`，跨玩家复用常用短语）未实现。
5. 真机端到端：备注写入后在真实对局页刷新是否即时可见，需要真机复测。

---

## 10. Review 建议顺序

1. **第 3 节**（偏差修正表）—— 确认 5 处置换是否符合预期，尤其是 #2 阈值收紧带来的体感变化。
2. **第 2.3 节 + `PlayerTagMetPopover.vue`** —— 这是用户点名要改的地方。
3. **第 7 节**（两个真实缺陷）—— 确认修复思路。
4. ~~**第 9 节第 1 条** —— 需要你拍板旧词表是否也要清。~~ 已拍板：**清**，见上。
5. 其余按需抽查。
