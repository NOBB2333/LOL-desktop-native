# 对局时间线：调研与方案（#125）

> 2026-09-24 · 对应版本 2.5.0
> 需求原文：「对局时间线 我想要的那种类似比赛一样的展示形式，观战时间节点，重大事件，
> 甚至某一波团战里面的输出数据什么的（这是一个很大的工作量，要单独的文件模块重构），
> 可能要做成类似视频剪辑时间轴的那种可以拖动查看。最后这个我不确定能最终做成什么样子，
> 你一定要充分调研后再做。」
>
> 这份文档只做调研与设计，**没有改任何代码**。结论是：能不能做取决于一个数据源切换，
> 而那个切换的第一步只有一个动作——**抓一份真实样本**。

## 一、结论速览

1. **我们现在读的数据源里没有伤害数据**，所以「某一波团战的输出」这条路在当前实现上是**打不通的**。
   我们读的是本地客户端的 `/lol-match-history/v1/game-timelines/{gameId}`。
2. 富数据在**另一个接口**上：SGP 的 `DETAILS`。它才有
   `victimDamageDealt / victimDamageReceived`，而且**额外还有**
   `victimTeamfightDamageDealt / victimTeamfightDamageReceived`——
   这几乎就是「某一波团战里的输出数据」的官方字段。
3. 「观战时间节点」这一项**我们不能承诺**。我们没有任何回放数据，位置信息只有
   **每分钟一帧**（LCU 与 SGP 都是 `frameInterval = 60s`），做不出剪辑软件那种丝滑的逐帧回看。
   SGP 有一个 replay 流接口，但连 LeagueAkari 都只是把方法声明了、**从未调用**，
   没有任何证据表明它能给出可用数据。
4. 「重大事件」和「可拖动时间轴」是**可达的**：前者靠 SGP 的事件类型（首杀/多杀/团灭/龙魂/镀层/守卫），
   后者是纯前端工作量——因为我们的「视频」里没有像素，只有稀疏事件 + 分钟帧，
   拖动轴的本质是**拖动一个游标去改状态**，而不是拖一个播放器。
5. 因此方案是 **先换数据源、再建模块**：新建 `src/backend/timeline_detail.zig` + 新命令，
   **不动**现有的 `lol.get_match_timeline`（现有页签继续用），前端新建 `frontend/src/timeline/` 特性模块。

## 二、证据

### 2.1 我们现在的实现

`src/backend/timeline.zig`（403 行）读 `/lol-match-history/v1/game-timelines/{gameId}`，
把数据压成「分钟帧（双方经济/补刀 + 每个人 totalGold）+ 4 类事件」，
事件里只取：`type / timestamp / killerId / victimId / assistingParticipantIds`、
`killerTeamId`、`teamId`、`monsterType / monsterSubType / buildingType / towerType / laneType`。

盯的事件类型写死在 `watched_events`：
`CHAMPION_KILL / ELITE_MONSTER_KILL / BUILDING_KILL / TURRET_PLATE_DESTROYED`。

### 2.2 这个数据源到底有什么（真实抓包，不是猜）

参考库里有一份**真机抓包快照**：
`LeagueAkari/src/shared/test-fixtures/api/snapshots/2026-05-16-tencent-hn10/lcu/match-history/timelines/`
（2026-05-16，腾讯服 HN10，15 局）。逐局统计：

| 样本 | 帧数 | 出现的事件类型 |
| --- | --- | --- |
| `q_1700.json`（极地大乱斗） | 20 | `CHAMPION_KILL` × 65 |
| `q_420.json`（单双排） | 31 | `CHAMPION_KILL` × 84、`ELITE_MONSTER_KILL` × 9、`BUILDING_KILL` × 9 |
| `q_2400.json`（大乱斗） | 25 | `CHAMPION_KILL` × 168、`BUILDING_KILL` × 11 |

字段层面（同一份抓包实测）：

```
CHAMPION_KILL 的键：
assistingParticipantIds, buildingType, itemId, killerId, laneType, monsterSubType,
monsterType, participantId, position, skillSlot, teamId, timestamp, towerType,
type, victimId

participantFrame 的键：
currentGold, dominionScore, jungleMinionsKilled, level, minionsKilled,
participantId, position, teamScore, totalGold, xp
```

**没有** `victimDamageDealt` / `victimDamageReceived` / `bounty` / `killStreakLength`；
**没有** `damageStats` / `championStats`。事件类型只有三种。

两个副作用值得记下来：

- 我们 `watched_events` 里的 **`TURRET_PLATE_DESTROYED` 在 LCU 侧从未出现过**——
  按这份抓包它是一段死代码。（LCU 的事件类型表本身也不完整，参考库的类型定义里就留着
  `// TODO：需要确认 LCU 数据源中是否存在这些内容`。抓包是更硬的证据。）
- `participantFrame` **有 `position`，但我们现在没用**。也就是说「在地图上按分钟画走位」
  在现有数据源上是可行的小功能（虽然 60 秒一帧，很粗）。

### 2.3 富数据在哪：SGP `DETAILS`

参考库 `src/shared/http-api-axios-helper/sgp/match-history-query.ts`：

```
GET /match-history-query/v1/products/lol/{subId}_{gameId}/DETAILS
    headers: { <SGP server id>: ..., <token type>: "entitlements" }
```

返回 `SgpGameDetailsLol = { metadata, json }`，其中
`json = { endOfGameResult, frameInterval, frames: DetailedTimelineFrame[], gameId, participants: [{participantId, puuid}] }`。

而 `DetailedTimelineFrame` 里才有我们要的东西（`src/shared/types/sgp/match-history.ts`）：

- **事件类型共 17 种**：`PAUSE_END / LEVEL_UP / SKILL_LEVEL_UP / ITEM_PURCHASED / ITEM_SOLD /
  ITEM_DESTROYED / ITEM_UNDO / WARD_PLACED / WARD_KILL / CHAMPION_KILL / CHAMPION_SPECIAL_KILL /
  BUILDING_KILL / ELITE_MONSTER_KILL / DRAGON_SOUL_GIVEN / OBJECTIVE_BOUNTY_PRESTART / GAME_END /
  TURRET_PLATE_DESTROYED`。
- `CHAMPION_KILL` 带：
  `position`、`bounty`、`shutdownBounty`、`killStreakLength`、
  `victimDamageDealt?`、`victimDamageReceived`、
  **`victimTeamfightDamageDealt?`、`victimTeamfightDamageReceived?`**。
  伤害明细 `DamageDetail = { basic, magicDamage, physicalDamage, trueDamage, name, spellName,
  spellSlot, participantId, type }`。
- `CHAMPION_SPECIAL_KILL` 带 `killType ∈ { KILL_FIRST_BLOOD, KILL_MULTI, KILL_ACE }` 与
  `multiKillLength`（几杀）。
- `BUILDING_KILL` 带 `towerType`（外/内/高地/枢纽）、`laneType`、`bounty`。
- `participantFrame` 带 `championStats`（法强/护甲/攻击力/攻速…）与
  `damageStats`（物理/魔法/真实/总伤害）。

**参考库自己就把两个源分了级**：`src/shared/data-adapter/match-history/frames.ts` 里

```ts
export function toFrames(details: LcuOrSgpGameDetails) {
  const { source, data } = details
  if (source === 'sgp') return data.json.frames          // 详细帧
  return data.frames                                     // LCU 的朴素帧
}
export function isSgpDetailedTimelineFrame(frame: any): frame is DetailedTimelineFrame {
  const anyFrame = frame?.participantFrames?.[1]
  return anyFrame && 'damageStats' in anyFrame && 'championStats' in anyFrame
}
```

也就是说：**同一句「读时间线」，两个源的丰富度差一个量级**，
而且参考库是运行时探测（`'damageStats' in frame`）来判定的，不是靠猜。

### 2.4 参考库的界面做到哪一步

`src/renderer-shared/components/match-card/tabs/MatchCardEventsTab.vue`（466 行）是**竖向事件流**，
不是可拖动的时间轴：

- 按事件类型分组渲染（击杀 / 特殊击杀 / 摧毁建筑 / 摧毁镀层 / 结束）。
- 每条事件有「查看位置」；SGP 的击杀事件额外有「查看受害者伤害明细」。
- 顶部有**按英雄筛选**；另有镀层统计。

`getMatchHistoryReplayStreamByGameId`（`/match-history-query/v3/product/lol/matchId/{subId}_{gameId}/infoType/replay`）
在参考库里**声明了但全仓库没有任何调用点**。

→ 结论：**「赛事级可拖动时间轴」在这个生态里没有人做过**，没有现成蓝图可抄。
这既说明它有价值，也说明我们必须自己验证数据、自己设计交互。

## 三、需求逐条对表

| 用户要的 | 数据支撑 | 判定 |
| --- | --- | --- |
| 重大事件 | SGP：首杀/多杀/团灭/龙魂/战略点/镀层/守卫/买装 | ✅ 可达（SGP） |
| 某一波团战的输出数据 | SGP：`victimTeamfightDamageDealt/Received`、每分钟 `damageStats` | ✅ 可达（SGP），这是最亮的一项 |
| 事件发生的位置 | LCU 已有 `position`；SGP 同样有 | ✅ 可达 |
| 观战时间节点（类似比赛的节点标记） | 只有「事件时间点」，**没有回放数据** | ⚠️ 降级理解才能做：「关键事件节点」＝击杀/拿龙/掉塔的秒级时间戳，这个有 |
| 逐帧回放 / 拖动查看「比赛录像」 | 最高分辨率是 **60 秒一帧**；replay 流接口证据不足 | ❌ 不做承诺。地图上按分钟画走位可以，但那是「每分钟一张快照」，不是回放 |
| 视频剪辑式时间轴交互 | 纯前端 | ✅ 可达，但形态要改：拖的是**游标**，不是播放头 |

## 四、风险与硬约束

1. **样本是前置条件。** 第 2.3 节全部来自参考库的**类型声明**，不是我们自己的抓包。
   在写解析器之前必须先抓一份真实的 SGP `DETAILS` 落盘当 fixture——
   否则等于照着一张二手图纸施工。（第 2.2 节已经证明：二手类型表会把 LCU 说多。）
2. **输出缓冲区。** SGP `DETAILS` 一局 40 分钟、10 人、每次击杀带两组伤害数组，
   原始体积很大。桥的输出缓冲是有上限的（现有时间线已经要按 `max_minutes = 90` 截断），
   所以后端必须**投影**（只保留前端画得出来的字段、每次击杀的伤害取 Top-N），
   并沿用逐局落盘缓存（现有 kind `matchTimeline`，新的用 `matchTimelineDetail`）。
3. **账号与区服。** SGP 请求要 SGP host + entitlements token，
   和现有 `fetchSgpHistoryWithContext` 同一条路；跨区读战绩本来就**没有打通**
   （见 `MEMORY.md` 的「玩家查询边界」），所以这个功能只在**同大区**可靠。
4. **不要动现有实现。** 用户的原则是「要加不要换」：现有 `lol.get_match_timeline`
   与历史页第三个页签保持原样，新东西另起模块。

## 五、建议方案

### Phase 0 — 先证明数据（唯一的前置动作）

写一个一次性脚本（放在 `scripts/` 或直接复用现有 `verify-runtime` 通道），
对一个真实 `gameId` 请求 SGP `DETAILS`，把原始响应**原样落盘**并回答四个问题：

1. 真的存在 `victimTeamfightDamageDealt/Received` 吗？覆盖率多少（每次击杀都有，还是偶尔）？
2. `frameInterval` 实测是多少？
3. 一次 `DETAILS` 的原始字节数是多少（决定投影策略）？
4. LCU 那一侧`TURRET_PLATE_DESTROYED` 是不是真的从不出现（决定是否清掉死代码）？

**四个问题没有明确答案之前，不写任何解析代码。**

### Phase 1 — 后端投影（新模块）

- 新文件 `src/backend/timeline_detail.zig`，新命令 `lol.get_match_timeline_detail`
  （`query` 通道；加命令要同步三处：`command_table`、`app.json` 的 `bridge.commands`、
  前端 `native.ts` 的调度器）。
- 输出形状（草案）：`{ participants[], frames[{minute, gold[], cs[], level[], damage[]}],
  events[{kind, seconds, team, position, ...}] }`，`events` 按类型各自裁剪字段，
  击杀的伤害只保留 Top-N 并标注 `truncated`。
- 缓存 kind `matchTimelineDetail`（逐局不变，可直接当权威）。
- 后端测试用 Phase 0 冻下来的 fixture。

### Phase 2 — 前端特性模块

新建 `frontend/src/timeline/`（不塞进 `views/`，这是用户说的「很大的工作量、单独重构」）：

- `state.ts` — 游标位置、时间范围、筛选（按玩家/事件类型）、当前聚焦的团战窗口。
- `events.ts` — 把稀疏事件聚成**团战窗口**（例如：同队 3 人以上在 12 秒内互有击杀/助攻 → 一波团）。
- 组件：
  - `MatchTimelineCanvas.vue` — 横向时间轴：轨道（经济差曲线 / 击杀轨道 / 目标物轨道 / 玩家轨道）
    + **可拖动的游标**（鼠标拖动、点击跳转、方向键微调）。
  - `TeamfightInspector.vue` — 当前游标落在某波团时展开：双方参战者、每个人这一波的
    伤害/承伤、技能命中（`spellName`）。
  - `TimelineEventTrack.vue` — 事件点渲染 + 悬浮卡（复用现有地图资源做位置预览）。
- 挂载位置：历史页「对局时间线」页签内**新增一个视图切换**（走势 / 赛事），
  现有 `MatchTimelinePanel` 保持不动。

### Phase 3 — 打磨

播放/暂停（按秒推进游标）、快捷键、局部放大、导出当前团战为文本。
这些都不依赖新数据，可最后做。

## 六、如果只做一半

按「用户能感知到的价值 ÷ 工作量」排序，唯一值得先做的是：

> **Phase 0 + 「团战伤害」这一条主线**：换到 SGP → 投影出每次击杀的团战伤害 →
> 前端做一版只含「击杀轨道 + 团战检视器」的最小时间轴。

`victimTeamfightDamageDealt` 这一项是整件事里唯一**别的工具都没有**的东西，
它也是用户原话里最具体的一句。其余的（守卫、买装、镀层、龙魂）都是同一份数据里的顺带产物，
可以后续逐个补，不构成风险。

---

## 七、落地记录（2026-09-24 晚间 · v2.5.0）

这份文档原来停在「Phase 0 抓样本」。样本**没抓到**（当时客户端没开、拿不到 lockfile），
但用户当天又提了新要求并当场落地，结论与上文的部分设想**相反**，必须记下来，
否则下一个人会照着第三、五节把已经否掉的东西再做一遍：

1. **「每分钟一帧的经济曲线」被用户否掉了**（原话：「对局曲线事件什么的做的真垃圾」）。
   所以 Phase 2 里那套「多轨道 + 可拖动游标」的走势图**不要按原计划做**——
   它回答的是宏观走势，用户要看的是「这一局**发生了什么**」。
   原页签 `MatchTimelinePanel.vue` 与「经济曲线与关键事件」整块已**删除**，
   连同它的单测（`MatchTimelinePanel.test.ts`）一起删。
2. **「每波团」改成纯本地推导，不等 SGP 了。** 前提写清楚：Riot 的数据里**没有团战事件**，
   我们也不再等 SGP 的 `victimTeamfightDamageDealt`。`frontend/src/matches/teamfights.ts`
   用「击杀事件时间聚类（相邻击杀间隔 ≤ 12s）+ 去重参与人数 ≥ 3」划团战边界，
   多杀按「同一杀手 10s 窗口内连杀」推，首杀取最早一次击杀。
   判定的地基是 `src/backend/timeline.zig` 新加的两个字段：
   `assistIds`（助攻座位号）与 `posX/posY`（事件 `position`）。
   ⚠️ **位置缺失时后端写 0/0，而 0/0 在本图域（`0..14820 × 0..14881`）里是个真实坐标**
   ——判「有没有位置」必须用 `posX > 0 || posY > 0`，不能只看 falsy。
3. **界面形态变了**：历史页从四个页签收成**两个**——「对局」与「人」（用户原话：
   「重新设计 只要 人和对局就行了」）。展开一局 = 首杀 / 每波团（地图落点 + 双方参战者）/
   事件流 / 同场的人；「人」= 首页「关系记录」那批人的详细版（同一套聚合口径）。
   逐帧数据只在展开某一局时才拉，且逐局落盘缓存。
4. Phase 0 的四个问题里，第 4 个（LCU 的 `TURRET_PLATE_DESTROYED` 是否真的从不出现）
   **仍未回答**：它还在 `watched_events` 里，没当成死代码清掉。
   Phase 1 / Phase 2 的 SGP 路线整体仍是**未开工**状态——真要「某一波团的输出数据」，
   还得从这里的 Phase 0 继续。
