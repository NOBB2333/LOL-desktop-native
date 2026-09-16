# 对局界面标签 —— 与 LeagueAkari 逐项对齐报告

日期：2026-09-16（第二轮更新）
范围：`frontend/src/tags/**`（10 人卡片标签）、`frontend/src/live/**`（队伍级标签）、
`src/backend.zig`（标签所需数据的获取）
基准：LeagueAkari 的 `player-card-tags`、`widgets/TeamTagsArea.vue`、
`analysis/player/**`、`src/shared/i18n/zh-CN/renderer/ongoing-game.yaml`

---

## 0. 结论

| 项目 | 状态 |
|---|---|
| 10 人卡片标签：清单 / 顺序 / 文案（21 条） | ✅ 1:1 对齐 |
| 队伍级标签条（胜率 / KDA / N 黑 / 胜率队 / 败率队） | ✅ 已补齐（此前完全没有） |
| 「好抓 / 难抓」数据来源 | ✅ 已放开网络获取（此前永远拿不到数据） |
| 聚合口径（KDA / 单杀 / 队内占比） | ✅ 按 AK 的公式改写 |
| 预组队分组：字母与配色 | ✅ 8 组 → 12 组，序号 → A~L |

用户提出的「不一样的地方可能 LCU 数据获取的差异」判断是对的：
最大的缺口就是**我们不抓每场的 DETAILS / timeline**，而 AK 抓。
本轮把标签需要的那部分数据补上了（见 §3）。

---

## 1. 注册表结构：1:1

`frontend/src/tags/registry.ts::PLAYER_CARD_TAGS` 与 AK 的 `tags/index.ts`
**同为 21 条、顺序完全相同**：

```
self → tagged → premade-team → high-win-rate → met → privacy
→ winning-streak → losing-streak → great-performance
→ suspicious-flash-position → easy-gank → solo-kills
→ average-team-damage → average-team-damage-taken → average-team-gold
→ average-cs-per-minute → average-damage-gold-efficiency
→ average-enemy-missing-pings → average-vision-score
→ average-kill-damage-efficiency → akari-score
```

设置项默认值与 AK 的 `DEFAULT_ONGOING_GAME_PANEL_PLAYER_CARD_TAG_SETTINGS` 一致。

---

## 2. 逐项对照表（21 条卡片标签）

| # | tag id | AK 文案（zh-CN） | 我们现在的文案 | 状态 |
|---|---|---|---|---|
| 1 | `self` | 自己 | 自己 | ✅ |
| 2 | `tagged` | 已标记 | 已标记 | ✅ 不可编辑时也显示 |
| 3 | `premade-team` | `小队 {{team}}`，A~L | `小队 A` ~ `小队 L` | ✅ 原先「开黑 2」 |
| 4 | `high-win-rate` | 极高胜率（≥16 场且 ≥85%） | 极高胜率 | ✅ |
| 5 | `met` | 遇到过 / 上局队友 / 上局对手 | 同 | ✅ |
| 6 | `privacy` | 生涯隐藏 | 生涯隐藏 | ✅ 原先「战绩隐藏」 |
| 7 | `winning-streak` | `{{count}} 连胜` | `N 连胜` | ✅ |
| 8 | `losing-streak` | `{{count}} 连败` | `N 连败` | ✅ |
| 9 | `great-performance` | 优异 / 通天代，`totalPrecision=1` | 同 | ✅ |
| 10 | `suspicious-flash-position` | 闪现异位；弹层「闪现位置分布」 | 同 | ✅ 原先「闪现位置可疑」 |
| 11 | `easy-gank` | 难抓 / 好抓 / 非常好抓 | 同 | ✅ 文案 + 数据源均已通 |
| 12 | `solo-kills` | `{{times}} 单杀` | `0.9 单杀` | ✅ 去掉自创的「≥3 场」门槛 |
| 13 | `average-team-damage` | `伤害 {{rate}}%` | 同 | ✅ |
| 14 | `average-team-damage-taken` | `承伤 {{rate}}%` | 同 | ✅ 原先缺数据时整条隐藏 |
| 15 | `average-team-gold` | `经济 {{rate}}%` | 同 | ✅ |
| 16 | `average-cs-per-minute` | `{{value}} 补兵 / 分` | 同 | ✅ 原先「分均补刀 8.0」 |
| 17 | `average-damage-gold-efficiency` | `伤转率 {{rate}}%` | 同 | ✅ |
| 18 | `average-enemy-missing-pings` | `问号 {{count}} 次` | 同 | ✅ 原先「消失信号」 |
| 19 | `average-vision-score` | `视野分 {{count}}` | 同 | ✅ |
| 20 | `average-kill-damage-efficiency` | K 头 / 打工 | K 头 / 打工 | ✅ 原先「击杀伤害转化高/低」 |
| 21 | `akari-score` | `Akari {total.toFixed(2)}` + 3 位小数弹层 | 同 | ✅ 原先 1 位小数 |

判定阈值逐条核对过：极高胜率 16/0.85、连胜连败 3、
好抓 `>2 / ≥1.5 / ≥1(不标注) / 其余`、击杀伤害转化 1.35 / 0.65、
优异 ≥6.5 且 ≥5 场、通天代 ≥8 且 ≥8 场、Akari 满分 17。

---

## 3. 本轮补齐的缺口

### A. 「好抓 / 难抓」数据来源（已修）

`earlyDeathsWithEnemyJungler` 只有 `enrichRecentGankMetrics`（`src/backend.zig`）会写，
而它内部要走 DETAILS / timeline，之前调用点传 `allow_network = false`
→ 缓存没热过就直接 `return null` → **标签永远显示不出来**。

现在：
- 调用点放开网络（`allow_network = true`），行为对齐 AK；
- 用 `runtimeEasyGankEnabled(self)` 读取 `playerTags.showEasyGankTag`
  （默认开），用户关掉该标签时整段跳过，不发无谓请求；
- 成本有上界：每位玩家最多试 5 场候选、凑够 3 场有效样本即停，
  且结果写 `gankMetric` / `jungleDetails` 落盘，同一局只付一次；
- 该步骤在既有的后台批处理线程里跑（1800ms 预算），不阻塞界面。

### B. 队伍级标签条（已实现）

移植 AK `widgets/TeamTagsArea.vue`：

- `frontend/src/live/teamStats.ts`
  - `analyzeTeamStats()` ← AK `analysis/team/index.ts::analyzePlayers`
    （`avgKda = (Σ击杀 + Σ助攻) / Σ死亡`，`avgWinRate = Σ胜 / Σ场次`）
  - `resolvePremadeTeamTags()` ← AK `winRateTeams` 的两套判定，
    常量原样照抄：`MIN_MATCHES 13`、`OTHER_MEMBER_WIN_STREAK 4`、
    `MIN_SIZE 3 / 2`、`MIN_WIN_RATE 0.9`、`MAX_WIN_RATE 0.25`
- `frontend/src/live/components/TeamTagsArea.vue`：`胜率%` │ `KDA` │ `N 黑` 药丸
  （胜率队 `#7e2c85` / 败率队 `#893b3b`；胜率 ≥50% 绿、<50% 红，深浅色各一套）
- 接进 `LiveView.vue` 的三处队伍标题（我方 / 敌方 / 通用布局）

### C. 聚合口径（已按 AK 改写）

| 项 | 之前 | 现在（= AK） |
|---|---|---|
| `averageKda` | 逐局 KDA 求平均 | `(Σ击杀 + Σ助攻) / Σ死亡` |
| `averageSoloKills` | 只对有值的场次求平均 | `avgIfAllNonNull`：任一场缺值即 null |
| 开门类场均指标 | 缺数据时整条隐藏 | 缺值按 0 参与（`avgOrZero`） |

> 唯一的故意偏离：`killDamageEfficiency` 在「本人 0 伤害但队伍有伤害」时
> AK 会算出 `Infinity` 判成「K 头」，我们按 1 处理（不显示）。这个更合理，保留。

---

## 4. 本轮改动文件

| 文件 | 改动 |
|---|---|
| `live/teamStats.ts` | 新增：队伍聚合 + 胜率队/败率队判定 |
| `live/teamStats.test.ts` | 新增：6 条用例（聚合口径、空队伍、胜率队、败率队、普通双排、互斥性） |
| `live/components/TeamTagsArea.vue` | 新增：队伍级标签条 |
| `views/LiveView.vue` | 新增 `teamPremadeGroups()`，三处队伍标题接入标签条 |
| `live/premadeGroups.ts` | `PREMADE_TONE_COUNT` 8 → 12（与 12 色板同长，避免第 9 组撞色） |
| `tags/tones.ts` | 新增深色板 `PREMADE_GROUP_COLORS_DARK`；`premadeGroupColor(tone, dark)` |
| `tags/facts.ts` | 聚合 KDA / 单杀口径对齐 AK；更正注释 |
| `src/backend.zig` | 放开 gank 指标的网络获取 + `runtimeEasyGankEnabled` 开关 |

第一轮（文案与条件对齐）改动的文件见 git 记录，此处不重复。

---

## 5. 验收

| 检查 | 结果 |
|---|---|
| `npx vue-tsc --noEmit` | 干净（exit 0） |
| `npx oxlint src` | 0 warnings / 0 errors（98 files） |
| `npx vitest run` | **165 passed / 27 files** |
| `npx vite build` | 成功（LiveView 包 122.7 → 126.6 kB） |
| `zig build test`（本机沙箱内） | 后端 **158/158 passed**；通过 `ast-check` 校验了 `backend.zig` 语法，且 150 条 backend 用例（模块根即 `src/backend.zig`）在改动后仍全绿 → 改动能编译 |
| `zig build test`（完整 15/15） | ⚠️ 无法在本次会话的沙箱里跑通，原因见下 |

### 关于 `zig build test` 跑不满

沙箱内的 PATH 与用户真实终端不同，会命中两个环境坑（与本次代码改动无关）：

1. `frontend.bundle → pnpm`：早先 `findProgram("pnpm")` 命中的是 mise shim
   （无扩展名脚本 → `InvalidExe`）。本机另有一份可用的
   `D:\1_Application\5_Coding\Scoop_install\shims\pnpm.exe`。
2. `migrations.zig` 生成步骤：沙箱 PATH 里排在最前的 `node.exe` 是 22.x，
   而 `@native-sdk/cli` 要求 **Node 24+**。

试过的修法（**均已回滚**，避免为了迁就沙箱而改动仓库）：
在 `mise.toml` 声明 `pnpm`、以及让 `build.zig` 优先挑 `.exe` / `.cmd`。
后者会连带把 `node` 也挑成沙箱里的 22.x，等于用真问题换假问题。

**结论：仓库保持原样。** 上一次会话里同一命令是 15/15 steps、165/165 tests 全绿，
说明用户自己的终端环境没有这两个坑。
