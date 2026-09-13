# 架构评估与重构方案（2026-09-13）

参照基准：`D:\4_Code\0_Github_Project\lol\LeagueAkari`（下文简称 AK）。
评估对象：`LOL-desktop-native`（Zig 0.16 后端 + Vue 3 前端）。

---

## 执行进度（2026-09-13 更新）

| 步骤 | 状态 | 结果 |
|---|---|---|
| Step 1 清死代码 | ✅ 完成 | 删 `.zig-cache-current-lobby.json`(249KB)、`src/queries.sql`；6 份一次性文档 → `docs/archive/`；根 `package.json` 描述改 pnpm |
| Step 3a 修依赖方向 | ✅ 完成 | 拆出 `services/browserBackend.ts`（浏览器模拟实现）；`services/backend.ts` 242 行纯分发 |
| Step 3b 归并 utils | ✅ 完成 | `utils/` 24 → 8 个文件；新建 `matches/`、`live/`、`encounters/`、`shortcuts/` |
| Step 2 后端竖切 | 🔄 进行中 | 已拆 4 个 feature 模块 / 9 个 handler；`backend.zig` **8134 → 7655 行** |

验证基线（全绿）：`zig build test -Dplatform=null` → **15/15 steps, 162/162 tests**；
frontend `vue-tsc` 通过 / `oxlint` 0 warning / `vitest` **146/146**。

### 两个被**推翻**的初版结论（重要）

1. **`domain.ts` 没有死类型。** 初版称 5 个类型零引用，是**错的**——它们被活类型传递引用
   （`DashboardSnapshot` ← `AppBootstrap.dashboard`、`CompositionScore` ← `TeamSummary.composition`、
   `ChampionUsage` ← `PlayerProfile.topChampions`、`FriendGroup` ← `FriendToolsSnapshot.groups`、
   `DataSource` ← `DataStatus.source`）。**判死类型必须做可达性分析，不能只 grep 名字出现次数。**
2. **`fixtures/ → tags/` 不是依赖倒置。** `fixtures/data.ts` 与 `createFixtureLobby` 是在
   **复刻后端行为**（后端也算标签信号），它依赖领域规则是合理的。真正的问题是
   **`services/backend.ts`（传输层）里塞了模拟逻辑**——已拆出 `browserBackend.ts` 解决。

---

## 0. 结论（TL;DR）

你的直觉对了一半，但"挤在一起"的重灾区**不在前端**：

| 你的判断 | 实际情况 |
|---|---|
| "模块分得非常乱，所有东西都挤在一起" | 前端目录其实**已经有分层雏形**（views / components / composables / services / stores / utils / tags）。真正挤在一起的是**后端 `src/backend.zig`：8134 行**（已拆到 7655，见进度表）。 |
| — | 前端有两个真问题：**`utils/` 变成杂物间**（24 个文件混装纯函数+领域逻辑+配置），以及 **`services/backend.ts` 里塞了浏览器模拟**（传输层含业务）。两处**均已修**。 |
| "有没有老旧残留" | 有：**2 处真死代码**（`.zig-cache-current-lobby.json` 249KB 已被 git 跟踪且零引用、`src/queries.sql`）+ 1 处错位文档（`MIGRATION.md`）+ 6 份已完成的一次性评审文档。**均不存在**初版误报的"5 个 domain.ts 死类型"。 |

一句话方案：**后端按 feature 竖切（对齐 AK 的 shard 模型）+ 前端归并领域逻辑**。已按 Step 1 → 3a → 3b → 2 推进，前三步完成、第四步进行中，每步独立可验证。

---

## 1. 基准：AK 的 shard 模型长什么样

AK 的后端（`src/main/shards/`）每个功能一个目录，目录内自带五件套：

```
src/main/shards/<feature>/
  index.ts          # 注册进 AkariManager，暴露对外接口
  context.ts        # 依赖注入（只拿别的 shard 的接口，不 import 实现）
  state.ts          # 该 shard 自己的状态
  ipc-handlers.ts   # IPC 入口（薄，只做参数解析）
  *-controller.ts   # 业务逻辑
  *.test.ts         # 就近测试
```

共 33 个 shard（`akari-api` / `auto-select` / `ongoing-game` / `league-client` / `sgp` / `storage` …）。
关键约束是 **`context.ts` 只依赖别的 shard 的公开接口**，所以跨模块不会形成隐式耦合，改 A 不用读 B 的实现。

**对比你的项目**：后端是"一个 `Runtime` 巨型结构体 + 28 个 IPC handler + 100 多个自由函数"全塞在一个文件里；前端是"按文件类型横切"（所有组件放 `components/`、所有工具放 `utils/`）。两者都不是竖切。

---

## 2. 问题清单（按 价值/风险 排序）

### P0-1　后端 god-object：`src/backend.zig` = 8134 行

实测：**386 个顶层声明**（`fn` / `const`），**28 个 IPC handler**。

它同时承担了至少 6 种职责：

| 职责 | 佐证 |
|---|---|
| 连接 / 账号会话 | `live_owner_puuid`、`AccountChanged` 校验、`discoverClient` |
| 配置持久化 | `get_config` / `save_config` |
| live lobby 合并状态机 | `ownerPuuid` 回填、lobby merge |
| match-history DTO 映射 | `matchHistoryDtoPage`（4515 行起，含 3 个变体）、`singleMatchDto` |
| JSON 读写工具 | `jsonInt` / `jsonField` / `nestedObject` / `unwrapHistoryGame` |
| 快捷键 / 自动化 / 事件 | `shortcuts.zig`、`automation.zig` 的编排入口 |

`src/backend/` 目录下**已经抽出了 10 个模块（合计 5189 行）**：

```
backend/automation.zig      627
backend/champions.zig       333
backend/encounters.zig      630
backend/events.zig          120
backend/hotkeys.zig         387
backend/input.zig           357
backend/jungle_analysis.zig 566
backend/live_loading.zig     64
backend/player_signals.zig  613
backend/player_tags.zig     170
```

**说明拆分路线是对的，只是最核心的编排层没搬出去**——`backend.zig` 反而比整个 `backend/` 目录还大（8134 vs 5189）。

**代价**：改任何一个 handler 都要在 8000 行里定位；跑一个单测要编译整个 backend（实测 `compile test Debug native` 约 1 分钟）。

### P0-2　`services/backend.ts` 把传输与模拟混在一起　✅ 已修

```
frontend/src/fixtures/data.ts:19-20   → import "../tags/settings"、"../tags/signals"   ← 合理（模拟后端行为）
frontend/src/services/backend.ts:2    → import "../tags/signals"                      ← 真问题（传输层含业务）
frontend/src/stores/app.ts:5          → import "../fixtures/data"                     ← 合理（fixture 注入）
```

`fixtures/` 的职责是**复刻后端返回的数据**，后端自己也算标签信号，所以它依赖领域规则正确。
真问题是 `services/backend.ts`（纯传输门面）里塞了**整个后端的浏览器模拟**：快捷消息怎么
渲染、标签文案怎么取、fixture 缓存怎么维护，全在传输层里——改一条标签文案要动传输层，
且这条链路无法单独测试。

已拆为 `services/browserBackend.ts`（模拟实现，独占领域依赖）+ `services/backend.ts`
（242 行纯分发）。`services/` 不再 import `tags/`。

### P1-1　死代码 / 老旧残留（逐条已核实零引用）

后端 / 仓库根：

| 路径 | 大小 | 状态 |
|---|---|---|
| `.zig-cache-current-lobby.json` | **249 KB** | **已被 git 跟踪**，全仓零引用 → 意外提交的调试转储 |
| `src/queries.sql` | 761 B | 已跟踪，零引用 |
| `MIGRATION.md` | 6190 B | 已跟踪，零引用 |
| 根 `package.json:5` 的 description | — | 仍写 "runs `npm install --prefix frontend`"，但已切 pnpm → 文案过期 |

前端：

| 项 | 状态 |
|---|---|
| ~~`types/domain.ts` 的 5 个类型~~ | **已复核推翻**：`DashboardSnapshot` / `CompositionScore` / `ChampionUsage` / `FriendGroup` / `DataSource` 看着像死类型（仓内没有第二处直接指名），但它们被 `AppBootstrap.dashboard` / `TeamSummary.composition` / `PlayerProfile.topChampions` / `FriendToolsSnapshot.groups` / `DataStatus.source` 引用，而这些**都是活类型**。domain.ts 的 34 个导出类型**全部可达，零死类型**。 |
| `docs/` 下 5 个一次性评审/审计文档 | 已完成的评审材料（CHANGES_REVIEW、IMPROVEMENT_PLAN、LIVE_LOADING_AUDIT、PROJECT_ASSESSMENT、TAG_SYSTEM_REVIEW） |

> **教训**：判断死类型不能只 grep「仓内有没有第二处出现这个名字」——那会漏掉**传递可达**。
> 必须做可达性分析（活类型引用的字段类型也是活的）。本文件初版误信了 grep 结论。

> 根 `package-lock.json`（19 KB）**不是残留**：根 `package.json` 真有一个依赖 `@native-sdk/cli`，build.zig 要靠它解析 Zig module，用 npm 装是合理的。保留。

### P2-1　`frontend/src/utils/` 曾是杂物间（24 个文件）　✅ 已修

里面混装了三种本质不同的东西：

| 类型 | 文件 |
|---|---|
| 纯工具函数（留 utils 合理） | `format.ts`、`queue.ts`、`coalescedAsync.ts` |
| **领域逻辑（已下沉）** | `encounters.ts`、`premadeGroups.ts`、`matchFilters.ts`、`matchHistoryQuery.ts`、`liveRoster.ts`、`livePanel.ts`、`shortcutTemplate.ts`、`shortcutSendQueue.ts` |
| 配置 | `config.ts`（留 utils） |

8/12 是领域逻辑。它们是"某个功能的规则"，却按"通用工具"归类，于是找不到归属的人继续往里丢
——这正是"越分越乱"的机制。已按域下沉到 `matches/`、`live/`、`encounters/`、`shortcuts/`，
`utils/` 只剩 4 个通用件。

---

## 3. 重构方案

### 方案 A（推荐）：三步走，低风险优先

#### Step 1 — 清死代码（半小时，零风险）

```
git rm .zig-cache-current-lobby.json src/queries.sql
git mv MIGRATION.md docs/archive/migration-boundary.md
# 5 个已完成的评审/审计文档 → docs/archive/
# 修正根 package.json description（npm → pnpm）
```

`.gitignore` 补一行 `.zig-cache-current-lobby.json`，防止旧构建步骤再次把 249KB 转储带进版本库。
`docs/` 的 5 个评审文档**移入 `docs/archive/` 而不是删除**——它们记录了决策过程，删了会丢上下文。
（若你确认不需要，直接 `rm -rf docs/archive` 即可，git 里还留着。）

**不要删 `domain.ts` 的类型**：初版把它列为死代码是**错的**，详见 P1-1 的复核说明。

#### Step 2 — 后端按 feature 竖切（价值最高，中风险）

把 `src/backend.zig` 的 28 个 handler 按领域拆到 `src/backend/`，每个模块导出
`pub fn <handler>(context, invocation, output)`，`Runtime` 只保留**状态 + handler 注册表**。

切分建议（直接按现有 handler 归组）：

| 新模块 | 承接的 handler |
|---|---|
| `backend/connection.zig` | `get_bootstrap`、`get_config`、`save_config`、`set_data_mode`、`refresh_connection`、`set_shortcut_capture`、`check_update`、`open_game_view` |
| `backend/live.zig` | `get_live_lobby`、`get_live_roster` |
| `backend/matches.zig` | `get_match_history`、`get_match_detail`、`save_match_export`、`get_bp_history` |
| `backend/friends.zig` | `get_friends`、`get_friend_last_game`、`delete_friend` |
| `backend/assets.zig` | `get_champions`、`get_asset` |
| `backend/shortcuts_ipc.zig` | `send_shortcut`、`preview_shortcut`、`validate_shortcut_template` |
| `backend/events_ipc.zig` | `get_lcu_events`、`get_shortcut_events` |
| `backend/player_tags_ipc.zig` | `get_player_tags`、`update_player_tag` |
| `backend/encounters_ipc.zig` | `get_encounters` |
| `backend/automation_ipc.zig` | `run_automation` |

（10 个模块，合计覆盖全部 28 个 handler。）

**实际采用的形态**（已验证可行，见下方"已落地"）：

不需要先搬 `Runtime`。Zig 允许文件级互相 `@import`，所以 feature 模块直接
`const backend = @import("../backend.zig")`，通过 `backend.runtime(context)` 取回
Runtime、`backend.parsePayload` / `backend.jsonInt` 等取共享 helper。
代价是 feature 模块仍指向 `backend.zig`；等 handler 搬完，再把 `Runtime` 和这批 helper
收进 `runtime.zig`，依赖方向就彻底翻过来了。**先把 handler 搬空，最后搬基础设施**——
比一次性大爆炸搬迁安全得多。

需要共享的 helper 就地 `pub` 化（如 `jsonString` / `parsePayload` / `discoverClient` /
`runtimeNowMillis` / `copyJson` / `historyGames`）。**测试跟着代码走**：原来测私有 DTO 的
`test` 块必须一起搬进新模块，否则 `zig test` 收不到（已按此处理 friends/assets）。

**已落地（4 个模块 / 9 个 handler）**

| 模块 | 行数 | 承接的 handler |
|---|---|---|
| `backend/events_ipc.zig` | 31 | `get_lcu_events`、`get_shortcut_events` |
| `backend/player_tags_ipc.zig` | 103 | `get_player_tags`、`update_player_tag` |
| `backend/friends_ipc.zig` | 199 | `get_friends`、`get_friend_last_game`、`delete_friend` |
| `backend/assets_ipc.zig` | 193 | `get_champions`、`get_asset` |

**剩余（19 个 handler）**，按风险从低到高：

1. `encounters_ipc.zig`（`get_encounters`）、`automation_ipc.zig`（`run_automation`）
2. `shortcuts_ipc.zig`（`send_shortcut`、`preview_shortcut`、`validate_shortcut_template`）
3. `connection.zig`（`get_bootstrap`、`get_config`、`save_config`、`set_data_mode`、
   `refresh_connection`、`set_shortcut_capture`、`check_update`、`open_game_view`）
4. `matches.zig`（`get_match_history`、`get_match_detail`、`save_match_export`、
   `get_bp_history`，含 `matchHistoryDtoPage` / `singleMatchDto`）
5. `live.zig`（`get_live_lobby`、`get_live_roster`，共享 lobby 合并状态机，**最后做**）
6. 最后：把 `Runtime` + 共享 helper 收进 `runtime.zig`

**环境提醒**：构建里 `run node (migrations.zig)` 这一步需要 **Node ≥ 24**。
只要改动 `src/` 下任何文件就会让它失效重跑，此时若 PATH 里的 node 是 22 会直接报
`TypeScript apps need Node.js 24+`。用 `PATH=/d/4_Code/.miseEnv/installs/node/24.13.0:$PATH zig build test ...`
即可（`--summary all` 输出的三行 `run test` 合计应为 162）。

#### Step 3 — 前端修依赖方向 + utils 归并　✅ 已完成

**3a. 拆 `services/`（实际做法）**

问题不在"import 了 tags"，而在 `services/backend.ts`（396 行）同时干了三件事：
原生 IPC 传输 + **整个后端的浏览器模拟** + 快捷消息模板语义。做法是把它拆成两半：

- `services/browserBackend.ts`（247 行）—— 浏览器预览下的后端模拟实现，独占
  `tags/signals`、`shortcuts/template`、`fixtures/data` 的依赖，并持有
  `browserState`（mode / config / friends / playerTags）。
- `services/backend.ts`（242 行）—— 只剩「走原生还是走模拟」的分发 + 原生传输。
  **不再 import 任何 tags/**。

顺手把重复的占位符 key 表单一化：`backend.ts` 里那份 `templateFields` 与
`utils/shortcutTemplate.ts` 的字段表是两份真相 → 合并为 `shortcuts/template.ts` 的
`shortcutTemplateKeys`，设置页面板与浏览器校验共用同一份。

**3b. utils 归并　✅**

`utils/` 从 24 个文件收到 8 个（只剩 `coalescedAsync` / `config` / `format` / `queue`
四个通用件及其测试），领域逻辑按域新建目录：

| 新位置 | 来源 |
|---|---|
| `matches/filters.ts`、`matches/query.ts` | `utils/matchFilters.ts`、`utils/matchHistoryQuery.ts` |
| `live/roster.ts`、`live/panel.ts`、`live/premadeGroups.ts` | `utils/liveRoster.ts`、`utils/livePanel.ts`、`utils/premadeGroups.ts` |
| `encounters/records.ts` | `utils/encounters.ts` |
| `shortcuts/template.ts`、`shortcuts/sendQueue.ts` | `utils/shortcutTemplate.ts`、`utils/shortcutSendQueue.ts` |

连带修好一处隐含问题：`tags/definitions/met.ts` 原来 `import ../../utils/encounters`
（领域 → 杂物间），现在是对等域 `../../encounters/records`。

### 方案 B（激进，不建议现在做）

前后端全部对齐 shard：`features/<name>/{components,composable,logic}`。收益最大，但改动面覆盖全部业务代码，回归风险高，且没有对应的测试密度支撑。

---

## 4. 执行顺序与验收

```
Step 1（清死代码）        ✅ 完成
Step 3a（拆 services）    ✅ 完成
Step 3b（归并 utils）     ✅ 完成
        ↓
Step 2（后端竖切）        🔄 进行中：4 个模块 / 9 handler 已搬，剩 19 个 handler + 基础设施
```

每一步完成后跑全量验证，基线为：

- `zig build test -Dplatform=null --summary all` → **15/15 steps, 162/162 tests**
  （需 Node ≥ 24 在 PATH 里，见上方环境提醒）
- `frontend`：`vue-tsc --noEmit` 通过 / `oxlint src` 0 warning / `vitest run` **146/146**

### 继续 Step 2 的交接说明

接着做的人只需要重复这个循环（已跑通 4 次）：

1. 新建 `src/backend/<feature>_ipc.zig`，头部 `const backend = @import("../backend.zig");`
2. 从 `backend.zig` 切出该 feature 的 handler + 其**私有 helper**，handler 加 `pub`
3. 被引用的共享 helper 加 `backend.` 前缀；在 `backend.zig` 里把它 `pub` 化
4. `backend.zig` 删掉切走的部分，注册表改成 `<module>.<handler>`
5. **跟着搬 `test` 块**（否则 `zig test` 收不到）
6. `zig build test -Dplatform=null --summary all` 确认仍是 162

顺序按风险从低到高：`encounters_ipc` / `automation_ipc` → `shortcuts_ipc` → `connection`
→ `matches` → `live` → 最后把 `Runtime` 与共享 helper 收进 `runtime.zig`。

---

## 5. 附：核对后**认为不需要动**的地方

避免后续误伤，以下几处经核对**不是**问题：

| 项 | 结论 |
|---|---|
| `config/native.json` vs `app.json` vs `utils/config.ts` | 三个不同职责：build 期 `@embedFile` 配置 / 应用清单（带 `$schema`）/ 运行时前端配置。非重复。 |
| `src/lcu/`（目录）vs `src/lcu.zig` | 一个是 LCU 模块目录，一个是入口。非重复。 |
| `src/runner.zig` vs `backend.zig` | 一个是原生运行器引导，一个是业务后端。非重复。 |
| `frontend/src/components/` 17 个组件 | 抽查 7 个（`MatchHistoryDetail` / `EncounterDetails` / `TeamSummaryCard` / `LoadingState` / `AssetIcon` / `ModeSwitch` / `PageHeader`）**全部有引用**，无死组件。 |
| `frontend/src/utils/config.ts` | 是运行时配置 + `migrateAppConfig`，放 utils 可接受。 |
| 根 `package-lock.json` | 根 `package.json` 真有 `@native-sdk/cli` 依赖，保留。 |

---

## 6. 一句话总结

**前端已经理清**（`utils/` 24→8、`services/` 拆成传输 + 模拟、新建 4 个领域目录），
**后端才是主战场**：`src/backend.zig` 从 8134 行降到 7655 行只是开头，
剩 19 个 handler 和 `Runtime` 基础设施还要按第 4 节的循环继续搬。
每一步都用现有的 162 + 146 条测试守住回归——这套测试是这次重构能安全推进的前提。
