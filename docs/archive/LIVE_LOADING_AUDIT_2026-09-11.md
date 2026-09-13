# LOL-desktop-native 实时对局加载链路审计与改造清单

> **2026-09-12 第二轮更新**：P1-6、P1-7、P1-8、P2-12 也已落到代码。
> 至此清单里只剩 P0-3 的方案 1（维护结构化状态）未做——它要改 `live_lobby`
> 的表示方式，牵动所有读取点，风险与收益不匹配，理由见该条目。
> 另有两处审计结论与实测代码不符，已在 P1-8 与 P1-7 条目下更正。

> **2026-09-12 更新**：第 1 节清单中的 P0-1、P0-2、P0-3（部分）、P0-4、P0-5、
> P1-6（部分）、P1-9（部分）、P1-10、P2-13、P2-14、P2-15、P2-11 已落到代码。
> 每条目下方新增「✅ 已修复」段，说明实际改动与文件位置。

- 审计对象：`LOL-desktop-native` @ `main` (`c19bac6`)
- 审计日期：2026-09-11
- 审计范围：选人 / 对局阶段 5~10 人资料加载链路（前端轮询 → Native bridge → LCU → 发布 → UI）
- 结论基准：**以本仓库当前源码为准**，不引用外部项目推断

---

## 0. 先纠正几个前提事实

> 你之前拿到的那份 ChatGPT 分析，方向大体对，但**有几处和实际代码不符，也漏掉了真正的热点**。先把事实钉死。

| 说法 | 实际代码 | 判定 |
|---|---|---|
| `live_loading.zig` 实现了 5 并发队列 | `src/backend/live_loading.zig:3-26`，4 个 spawn + 调用线程，`peak <= 5` 有测试 | ✅ 成立 |
| 双方交错入队 | `backend.zig:1198-1208`，`for (0..max) for (ally, enemy)` | ✅ 成立 |
| Zig 的 bridge worker 是单线程串行的 | `main.zig:106,230,375`，已改为 **4 个 lane × 1 worker** | ❌ 已修复，不是当前问题 |
| 前端 `get_live_roster` 被限制为单并发 | `frontend/src/services/native.ts:53` `createInvocationScheduler(1)` | ✅ 成立 |
| 750ms 轮询与单并发冲突 | `LiveView.vue:283` | ✅ 成立 |
| 「20/50 条战绩是主因」 | 实际**请求 50 场，只用 20 场，默认只显示 10 场** | ⚠️ 部分成立，见 P0-2 |
| （未提及）每人跑一遍全量「遇到过」计算 | `backend.zig:5307 → 5368 → 2478`，每次分配 **4MB** | 🚨 **漏掉的最大热点** |
| （未提及）每 750ms 写一次 BP 历史 | `backend.zig:1475 → 2841` | 🚨 漏掉 |
| （未提及）每人完成后全量重建 lobby | `backend.zig:1283-1315` | 🚨 漏掉 |

### 关键结构差异（这份分析没画出来的）

```
前端 LiveView
   ├── useQuery(lobby)  loading.active ? 750ms : 4000ms   ──► lol.get_live_lobby   [state lane]
   └── setInterval      ChampSelect 750ms / 其它 1500ms    ──► lol.get_live_roster  [roster lane]
                                                                     ▲
                                         同一 lane 还挤着：refresh_connection、get_lcu_events
                                         （App.vue:218-220，750~1000ms）

Native main.zig: 4 条 lane，每 lane 只有 1 个 worker 线程
   lane 0 state   ← get_live_lobby / get_config / ...        ⚠ 全程持有 command_mutex
   lane 1 roster  ← get_live_roster / refresh_connection / get_lcu_events   ⚠ 最挤
   lane 2 query   ← get_match_history / get_encounters / ...
   lane 3 action  ← send_shortcut / run_automation

backend live_loading: 1 个 batch 线程 + Queue(4 spawn + 1) = 5 个玩家 worker
```

**所以你眼前其实有「两层队列」：一层是前端 + bridge lane 的串行化，一层是后端 5 并发。后者的并发是真的，前者的串行也是真的。而真正把 5 并发拖成「一个人一个人出」的，是第三样东西——下面 P0-1/P0-3 里的 SQLite 单连接 + `command_mutex`。**

---

## 1. 问题清单

严重度定义：**P0** = 直接造成你看到的十几秒现象；**P1** = 明显放大延迟或存在正确性问题；**P2** = 架构债 / 隐患。

---

### P0-1 每个玩家都重算一遍全量「遇到过」，且只用到两个标量 🚨 最大嫌疑

**位置**
- `src/backend.zig:5307` `const encounter = encounterProfileSummary(self, puuid);`
- `src/backend.zig:5368-5387` `encounterProfileSummary`
- `src/backend.zig:2478-2522` `cachedEncounterResponse`
- `src/backend/encounters.zig:117-145` `fromHistories`

**它在做什么**

每加载一个玩家，都要：

1. 读 `matches/currentPuuid`、`matches/current`（你自己整份战绩）
2. `appendEncounterHistory` 读取 **owner + 目标 + 当前 10 人** 的 `playerHistory`（`backend.zig:2498-2510`）——最多 12 份历史 JSON
3. 再次 `parseFromSliceLeaky` 整个 `live_lobby`（`backend.zig:2502-2510`）
4. 读 champions catalog
5. `fromHistories`：先 `alloc(4MB)`（`encounters.zig:122`），把上面 12 份历史**全部 parse 一遍**，建 HashMap，最后 `queryRecords` 输出最多 40 条完整记录

**然后只用了其中两个字段**（`backend.zig:5377-5385`）：

```zig
summary.count += 1;              // 遇到过几次
summary.latest = ...;            // 最近一次时间
```

**代价**
- 10 个玩家 = 10 次几乎完全相同的计算（输入集合只差一个 `target_puuid`）
- 每次 4MB 分配 + 12 份历史全量 JSON 解析
- 5 个线程同时干这件事，全部打在**同一个 SQLite 连接**上（`storage.zig:39` `FULLMUTEX` + `busy_timeout=250`）

**这是目前链条上唯一一个「随人数平方增长 + 抢同一把锁」的点，和「每 5 秒才出一个人」的观感最吻合。**

**✅ 已修复（2026-09-12，方案 1 的加强版）**

十名玩家的输入历史集合几乎完全相同（本人 + 当前阵容），只有目标 puuid 不同，
因此把索引构建从「每人一次」改成「整批一次」：

- `encounters.zig` 新增 `EncounterIndex`（自带 arena，`deinit` 一次释放）与
  `buildIndex()`；`fromHistories()` 变成 `buildIndex + query`，行为不变。
- `EncounterIndex.encounterWith()` 直接对已解析记录做线性扫描，返回
  `{count, latest}`，**不再经过 1MB 缓冲区的序列化与二次解析**。
- `backend.zig` 新增 `buildLiveEncounterIndex()`，在 `runLiveLoadJobs` 进队列
  前构建一次；`LiveProfileJob.shared_encounter` 传给各 worker；
  `writeLiveClientProfile` 优先用它，缺失时回退到原来的 `encounterProfileSummary`。

效果：4MB 分配与十几份战绩的全量解析从 **10 次降到 1 次**，O(N²) → O(N)。
副作用：`encounterProfileSummary` 不再被 worker 调用，也就顺带消除了 5 个
线程并发读 `live_lobby` 的撕裂读风险（P1-9 的一半）。

**改造方案**

1. **批量预计算（推荐，改动最小）**：在 `runLiveLoadJobs`（`backend.zig:1189`）里，进队列前先算一次「本局 10 人的 encounter 摘要表」`std.StringHashMap(puuid → {count, latest})`，塞进 job 上下文，各 worker 直接查表。把 O(N²) 降到 O(N)。
2. **或者**：给 `encounterProfileSummary` 单独写一个只读 SQLite 的轻量版本——`playerHistory` 里已有结构化 JSON，可以在写入侧维护一张 `encounters(puuid, game_id, encountered_at)` 表，用 `SELECT count(*), max(encountered_at)` 直接出结果，完全不碰 4MB 计算。
3. **或者（最快止血）**：如果 UI 不强制要求首屏就显示「遇到过 N 次」，把 encounter 从 `writeLiveClientProfile` 关键路径摘出去，改成「资料先出，encounter 后台补一轮 publish」。

---

### P0-2 战绩请求 50 场，只用 20 场，默认只显示 10 场

**位置**
- `src/backend.zig:5059`：`/lol-match-history/v1/products/lol/{puuid}/matches?begIndex=0&endIndex=49` → **50 场**
- `src/backend.zig:5071 / 5215 / 5218`：SGP 兜底 `fetchSgp*(..., 0, 50)` → **50 场**
- `src/backend.zig:5255`：`writeRecentMatchesFiltered(..., 20, ...)` → 只保留 **20 场**
- `frontend/src/views/LiveView.vue:26,70`：`MAX_RECENT_MATCHES = 20`，`recentLimit` 默认 **10**

**结论（直接回答你的疑问）**

> 「是不是一次加载 50 条 / 20 条导致的？」

**是的，请求量确实是 50 场，而实际只需要 20 场（默认只显示 10 场）。** 但这件事的影响是：

- ✅ **会**显著拉长单个玩家的耗时（LCU match-history 是最慢的 LCU 端点之一；50 场载荷通常是 20 场的 2.5 倍，解析也是）
- ❌ **不会**把 5 人并发变成串行

所以它是一个「人人都要多付的税」，不是串行化的原因，但改起来收益立刻可见。

**改造方案**

1. 把 `endIndex=49` 改成 `endIndex=19`（`backend.zig:5059`），SGP 的 `0, 50` 改成 `0, 20`（`5071 / 5215 / 5218`）。
2. 更彻底：让前端把 `recentLimit` 传给后端，后端按 `max(recentLimit, 统计所需最小样本)` 请求。目前 `writeRecentMatchesFiltered` 的 20 是硬编码。
3. 注意：`jungle_preference` / `topChampions` / 标签这些统计依赖样本量，砍到 10 会让统计抖动。建议**默认 20，不要低于 15**。

**✅ 已修复（2026-09-12）**

新增 `live_history_fetch_count = 20` / `live_history_ranked_fetch_count = 50`：

- `PlayerLcuHistoryRequestJob` 增加 `end_index`，`endIndex=49` 改为按配置生成。
- 默认取 20 场；**仅当"仅统计排位"打开时**才回退到 50 场 —— 因为过滤会吃掉
  大部分样本，直接砍到 20 会让统计抖动。
- SGP 兜底的 `0, 50` 同样改成 `0, fetch_count`。
- `writeRecentMatchesFiltered(..., 20, ...)` 改用同一个常量。

因为卡片最多只保留 20 场，多取的部分在序列化前就被丢弃，所以这是**纯收益**。

**附带修复**：`runtimeRankedOnly(self)` 原来在每个玩家里被解析两次（一次在
取历史、一次在过滤），现在只解析一次并复用。

---

### P0-3 每完成一个玩家，就全量 parse + 重建 + 落盘整个 lobby（且持锁）

**位置**
- `src/backend.zig:1232`（调用点，位于 `command_mutex` 内，`1222` 加锁）
- `src/backend.zig:1283-1315` `publishLiveProfile`
- `src/backend.zig:1924-1945` `cacheLiveLobby`（内含 SQLite 写）

**它在做什么**

```
某个玩家完成
   ↓
lockBackendMutex(command_mutex)          ← 自旋锁
   ↓
ArenaAllocator + parseFromSliceLeaky(整个 live_lobby, .alloc_always)   ← 512KB 容量，实测 ~244KB
   ↓
updateLiveProfileArray  改 1 个槽位
   ↓
liveSummaryValue  → Stringify 整队 → parse 回来   ← 又一轮
   ↓
root["generatedAt"] = ...
   ↓
alloc(512KB) + Stringify 整个 lobby
   ↓
cacheLiveLobby → memcpy 512KB + SQLite put("liveLobby","current", ~244KB)
   ↓
unlock
```

**代价**
- 10 个玩家 = 10 次全量 parse + 10 次全量 stringify + **10 次 244KB 的 SQLite 写**
- 全程持有 `command_mutex`，而 `lockBackendMutex`（`backend.zig:685-687`）是**纯自旋**，5 个 worker 一起抢会空转烧 CPU
- `liveLoadingResponse`（`1349`）每次前端轮询还要再 parse + stringify 一遍

**实测证据**：仓库根的 `.zig-cache-current-lobby.json` 是 **244KB**，这就是每次 publish 要 parse + stringify + 写盘的量级。

**改造方案**

1. **维护结构化状态**：`Runtime` 里保留一份已解析的 `std.json.ObjectMap` 作为真相源，`publishLiveProfile` 只改一个槽位 + 重算一个 summary，**不重新 parse**。序列化只在需要返回给前端时做一次。
2. **批量 / 节流 publish**：worker 完成后把结果 push 到一个 `std.atomic.Value` 队列，由一个 publish 线程按 ≤200ms 的节奏批量合并后统一重建 + 发布。10 次重建降为 2~3 次。
3. **写盘降频**：`cacheLiveLobby` 的 SQLite `put` 移到节流通道，或只在批次结束时写一次。SQLite 现在同时被 5 个 enrichment 线程 + roster lane 打，244KB 的写是最贵的那一种。
4. **换掉自旋锁**：`lockBackendMutex` 改成 `std.Thread.Mutex`（可休眠），或至少在自旋 N 次后 `std.Io.sleep`。

**✅ 部分修复（2026-09-12）**

- `lockBackendMutex`：先自旋 64 次，之后改为 `std.Thread.yield()` 让出时间片，
  不再让五个富化线程空烧 CPU 抢同一把锁。
- `publishLiveProfile`：根级 `ally/enemy` 与 `teams[]` 两处用的是同一批玩家，
  原来各算一次 `liveSummaryValue`（整队重新序列化再解析回来），现在**只算一次**
  并复用 —— 这是发布路径上最贵的一步，直接减半。
- `cacheLiveLobby`：244KB 的 SQLite 写按 `live_lobby_persist_interval_ms = 1000`
  节流（内存副本始终最新，界面仍逐人更新），跳过的写在 `runLiveLoadBatch`
  结束时由 `flushLiveLobbyPersist()` 补写一次。

未做（需要改数据结构，风险较高）：维护结构化的 `std.json.ObjectMap` 作为真相源。

---

### P0-4 `get_live_roster` 三重串行：前端 1 并发 + 后端 1 worker + 同 lane 挤着事件轮询

**位置**
- `frontend/src/services/native.ts:53` `const roster = createInvocationScheduler(1);`
- `frontend/src/services/native.ts:57` `["lol.get_live_roster","lol.refresh_connection","lol.get_lcu_events"] → roster(task)`
- `src/backend.zig:522-525` `commandLane`：这三条同属 `.roster`
- `src/main.zig:106,230,375` 每个 lane 只有 1 个 worker 线程
- `frontend/src/views/LiveView.vue:283` 选人阶段 750ms
- `frontend/src/App.vue:218-220` `get_lcu_events` 750ms（自动化开启）/1000ms，`refresh_connection` 5s
- `src/backend/events.zig:39-70` 一次 `get_lcu_events` 最多发 6~9 个 LCU 请求（含好友列表）

**代价**

roster lane 是全局最挤的一条：**每 750ms 至少 2 个请求（roster + events）**串行排队，每个都可能带多次 LCU 往返。lane 一旦饱和，roster 结果的**到达时间**就被推迟——但这只影响「拓扑更新」，不影响资料。

真正的问题是：这条 lane 饱和后，`getLiveRoster` → `invokeQueued` roster 分支（`backend.zig:636-678`）会在持锁状态下做 `mergeLiveLobbySnapshots` + `cacheLiveLobby` + `refreshLiveGeneration`，**和 5 个 publish 线程抢同一把 `command_mutex`**。

**改造方案**

1. **拆 lane**：把 `get_lcu_events` 和 `refresh_connection` 从 roster lane 拆出去，各自一条（或并入 query lane）。roster lane 只留 `get_live_roster`。
2. **roster lane 给 2 个 worker**：`main.zig` 的 `worker_threads` 改成每 lane 可配置并发数（roster=2，query=3，state=1，action=1），pending 队列逻辑不用动。
3. **前端并发从 1 提到 2**（`native.ts:53`），并加一个「若上一次请求未返回则跳过本次 tick」的保护（现在 `createCoalescedAsyncRunner` 已经做了合并，但合并后仍会连续跑）。
4. **选人阶段 750ms → 1200ms**。选人阶段拓扑变化没有 750ms 那么频繁，1200ms 足以覆盖，能直接把 lane 占用砍掉 40%。

**✅ 已修复（2026-09-12）**

- `RequestLane` 从 4 条扩到 6 条：新增 `.events` 与 `.connection`。
  `commandLane()` 把 `get_lcu_events` / `refresh_connection` 从 roster 拆出；
  `invokeQueued` 的结果提交分支同步判断三条 lane，逻辑不变。
- `main.zig` 的 lane 数组改用 `lcu.lane_count`，6 条 lane 各一个 worker 线程。
- **WinHTTP 配额**：`Budget` 新增 `.events`（限额 2）。原来事件轮询占用
  `roster` 预算（限额 1），现在有独立配额，既不再挤掉阵容请求，也不会反过来
  抢走资料富化的 `.lcu` 预算（限额 6）。
- 前端 `createCommandScheduler()`：roster 并发 1 → 2，events / connection 各自
  独立队列。
- `LiveView.vue` 选人阶段轮询 750ms → 1200ms。

未做：每 lane 多个 worker（需要把 `worker_threads` 改成二维数组）。

---

### P0-5 选人阶段每 750ms 全量重写一次 BP 历史（写放大 + 抢 SQLite）

**位置**
- `src/backend.zig:1474-1475` 每次 ChampSelect/ReadyCheck 的 roster/lobby 请求都会调用
- `src/backend.zig:2841-2875` `persistBpSnapshot`

**它在做什么**

```
解析 champ-select session
解析 catalog
构造 1 条记录（≤16KB）
读 store.get("history","bp")        ← 最多 50 条，每次全量读出
解析它
逐条 re-stringify（最多 50 次）
写回 store.put("history","bp", ...)
```

按 750ms 一次计，选人阶段（通常 1~3 分钟）会产生 **80~240 次**「读全量 + 解析 + 重序列化 + 写全量」。而且它和 5 个 enrichment 线程共用同一个 SQLite 连接，`busy_timeout=250`（`storage.zig:46`）——一旦撞上，写会**静默失败**（`store.put(...) catch {}`）。

**改造方案**

1. **按内容 hash 去重**：对本次生成的记录算 hash，和上次比较，相同就直接 return。选人阶段大部分 tick 的 BP 状态是不变的，这一条能消掉 90%+ 的写。
2. **增量追加**：不要读全量再重写，改成 `INSERT INTO bp_records(id, payload) ... ON CONFLICT DO NOTHING`，读取侧再 `ORDER BY ... LIMIT 50`。
3. **移到独立写队列**：所有 SQLite 写走一个后台线程 + 队列，前端路径只入队。

**✅ 已修复（2026-09-12）**

新增 `bpSnapshotFingerprint()`：只对「对局编号 + 双方已选英雄」算 Wyhash，
不含每次都变化的 `createdAt`。`persistBpSnapshot` 在生成记录前比对指纹，
相同就直接返回。选人阶段大部分 tick 阵容不变，这一条能消掉 90%+ 的
「读全量 → 解析 → 重序列化 → 写全量」。指纹记在 `Runtime.bp_snapshot_fingerprint`
（已加入 `querySnapshot` 的拷贝列表）。

---

### P1-6 同一份 `recent_json` 被重复解析 9 次

**位置**：`src/backend.zig:5303-5315`

```
writeRecentChampionUsage(recent_json)     ← parse
writeRecentScore(recent_json)             ← parse (via recentStats)
writeRecentTags(recent_json, ...)         ← parse
writeJunglePreference(recent_json, ...)   ← parse
recentPositionGames(recent_json, ...)     ← parse
recentPositionWinRate(recent_json, ...)   ← parse
recentChampionGames(recent_json, ...)     ← parse
recentChampionWinRate(recent_json, ...)   ← parse
recentChampionConcentration(recent_json)  ← parse
```

每个函数都 `ArenaAllocator.init` + `parseFromSliceLeaky`。20 场战绩 JSON 约 30~60KB，9 次 ≈ 半 MB 的重复解析，×10 人 ×5 线程。

**改造方案**：解析一次得到 `[]MatchSummary`-like 结构（或一个 arena 内的 `std.json.Value`），把这 9 个函数改成接收已解析值。改动局部、收益确定。

**✅ 已修复（2026-09-12 第二轮）**

`recent_tags.zig` 拆出 `concentrationOf(matches)` 与 `writeMatches(matches, ...)`，
`json` 版本退化为「解析一次 + 委托」的薄封装。`backend.zig` 新增
`RecentMatchesView`（自带 arena，`items()` 返回已解析的战绩数组），
`writeLiveClientProfile` 解析一次后把 `recent_items` 传给九个统计函数；
解析失败时 `items` 为空，与各函数原本 `catch` 之后的默认输出完全一致。
9 次解析降为 1 次，相关测试已同步改造。

---

### P1-7 后台完成不推送，全靠前端轮询；「进度」和「内容」还是两个请求

**位置**
- `src/backend.zig:1349-1372` `liveLoadingResponse`：进度挂在 `loading` 字段，只有 `get_live_lobby` 返回
- `src/backend.zig:1283` `publishLiveProfile`：只改内存，不通知前端
- `frontend/src/views/LiveView.vue:44-49` 轮询间隔由 `loading.active` 决定

**后果**：后台其实可能是 1.9s 全部查完，但 UI 感知时间 = 「下一次 poll 到达时间 + 前端合并时间」。你观察到的「1.9 秒完成 vs 十几秒出完」**正是这个差值**——两者根本不是同一个计时区间。

**改造方案**

1. **Native 主动推事件**（推荐）：`publishLiveProfile` 后 emit 一个 `live-profile` 事件（payload 只带 `side/index/profile`，几 KB 而不是 244KB），前端 `listenNative` 收到后 patch 到 `rosterOverlay` 对应的槽位。配合 `window.zero.on` 已有机制（`native.ts:74`）。
2. 顺带把 `loading.active` 也放进事件里，让前端在全部完成后立刻把轮询降回 4s，而不是等下一次 750ms 轮询。
3. 中期：把 `get_live_roster` / `get_live_lobby` 合成一个「增量同步」命令，带 `sinceVersion`，后端只回 diff。

---

### P1-8 state lane 全程持有 `command_mutex`，非 live 模式下还会做完整网络链路

**位置**
- `src/backend.zig:618-621`：
  ```zig
  if (commandLane(handler.name) == .state) {
      defer self.command_mutex.unlock();
      return handler.invoke_fn(self, invocation, output);
  }
  ```
- `src/backend.zig:529`：`lol.get_live_lobby` 属于 state lane
- `src/backend.zig:1064`：`mode != .live` 时走 `getLiveLobbyInternal`，里面是完整的 LCU 网络链路（`1381-1549`）
- `src/backend.zig:685-687`：`lockBackendMutex` 是自旋

**代价**：state lane 做网络 I/O 期间，所有 publish 线程、`querySnapshot`、`actionTicket` 全部自旋等待。

**改造方案**

1. 让 state lane 也走 `querySnapshot` 路径，只在「读状态 + 提交结果」的瞬间持锁，网络部分不持锁。
2. `lockBackendMutex` 换成真锁或带退避的自旋（自旋 N 次 → `std.Io.sleep(1ms)`）。
3. 把 `command_mutex` 拆分：配置一把、live lobby 一把（读写锁）、连接状态一把。现在所有东西挤在一把锁上。

---

### P1-9 跨线程共享 ArenaAllocator + 无锁读写 `live_lobby`（数据竞争）

**位置**
- `src/backend.zig:1191-1195`：`runLiveLoadJobs` 的 arena 被塞进 `SharedLiveSgpContext`
- `src/backend.zig:3357-3378`：`prepareJungleSgpContext` 用这个 allocator 在**别的线程**上 `dupe`
- `src/backend.zig:2502`、`5373`：`cachedEncounterResponse` / `encounterProfileSummary` **读** `self.live_lobby`
- `src/backend.zig:1313`：`cacheLiveLobby` 在 publish 线程**写** `self.live_lobby`

**后果**

- ArenaAllocator 不是线程安全的，跨线程并发分配是未定义行为
- 244KB 的 `live_lobby` 缓冲区无同步地边写边读 → 会读到**撕裂的半新半旧 JSON**。这会在 `parseFromSliceLeaky` 里变成随机解析失败，而调用点是 `catch return` / `catch null`，于是**静默降级**——表现就是「某个人突然没数据了，过一会儿又有了」

这很可能同时解释你看到的 **「只能看到我方 5 人」**：如果某次撕裂读发生在 enemy 数组附近，解析失败 → `catch null` → 该侧数据丢失一帧。

**改造方案**

1. `live_lobby` 改成**双缓冲 + 原子版本号**：写线程写 back buffer，写完后原子切换指针 + 递增 version；读线程读 version + 指针快照。或者直接用 `std.Thread.Rwlock`。
2. `SharedLiveSgpContext` 用 `std.heap.page_allocator` 或独立 arena，不共享 `runLiveLoadJobs` 的 arena。
3. 给所有 `catch null` / `catch return` 的解析点加一条 `std.log.warn`，撕裂读会立刻暴露。

**✅ 大部分已消除（2026-09-12）**

- `SharedLiveSgpContext` 不再共用批次 arena，改用 `runLiveLoadJobs` 里的独立
  `sgp_arena` —— 备用源的 `dupe` 现在只发生在持锁的 `get()` 内，跨线程并发分配
  的未定义行为消失。
- worker 不再调用 `encounterProfileSummary`，因此不再并发读 `self.live_lobby`；
  该缓冲区现在只有持锁的发布路径写、持锁的状态/查询路径读。
- 仍需留意：非批次路径（快照运行时）各自持有 `live_lobby` 的私有副本，
  `querySnapshot` 会整块拷贝该缓冲区，所以快照侧不存在撕裂读。

**未做**：`live_lobby` 双缓冲 + 原子版本号（当前已无未加锁的并发访问，收益有限）。

---

### P1-10 `SharedLiveSgpContext` 用「自旋 + 5ms sleep」做一次性初始化

**位置**：`src/backend.zig:5000-5021`

```zig
while (!self.mutex.tryLock()) {
    self.client.control.check() catch return null;
    std.Io.sleep(self.client.io, .fromMilliseconds(5), .awake) catch return null;
}
```

首次进入要发一次 `/entitlements/v1/token`（`3357`），5 个线程同时等待。虽然只有第一个真正干活，但等待期间每 5ms 醒一次空转。

**改造方案**：改成 `Once` + `Condvar`：第一个线程 prepare，其余线程 condvar wait；prepare 失败时 broadcast。

**✅ 已改善（2026-09-12）**

`std.atomic.Mutex` 在 0.16 里没有阻塞式 `lock()`，所以保留 tryLock 轮询，但把
固定 5ms 改成**1→10ms 线性退避**，五个线程不再以同一节奏一起醒来空转。
真正的根治要换成 `std.Io.Mutex`（带 Io 的阻塞锁），需要把 io 传进该结构，留待后续。

---

### P2-11 前端双快照体系会让已加载数据回退

**位置**
- `frontend/src/views/LiveView.vue:78,89` `rosterOverlay` + `mergeRosterSnapshot`
- `frontend/src/utils/liveRoster.ts:125-127`：
  ```ts
  if (!base || isDifferentRosterContext(base, fast)) return fast;   // ← 整体回退到未富化快照
  ```
- `frontend/src/utils/liveRoster.ts:95`：`if (baseIndex < 0) return dynamic;` —— 匹配不上就用未富化的

**后果**：选人切阶段、或者 LCU 短暂返回部分阵容时，已经加载好的段位/战绩会被空数据覆盖，UI 表现为「闪一下又没了」。

**改造方案**：overlay 只补拓扑字段（champion / position / name / premade），富化字段一律「只增不减」——merge 时如果 `dynamic` 某字段为空而 `original` 有值，保留 `original`。

**✅ 已修复（2026-09-12）**

- `mergePlayer` 从 `mergeRosterPlayers` 内部提到模块作用域，供新逻辑复用
  （它本来就以 `...original` 打底，富化字段只增不减）。
- 新增 `carryEnrichedPlayers()`：按身份（puuid → 名字 → 槽位）把上一份快照的
  富化字段带到新拓扑上；槽位兜底时同样校验 `namesConflict` 与
  `isUnresolvedPlayer`，避免把上一位玩家的段位搬过来。
- `mergeRosterSnapshot` 在 `isDifferentRosterContext` 为真时**不再整体返回
  未富化的 `fast`**，而是走上面的携带逻辑，并保留 `teams` 结构。

---

### P2-12 整批 60s 节流粒度太粗

**位置**：`src/backend.zig:1160`

```zig
live_next_load_ms = finished_ms + (if (failed > 0) 10_000 else 60_000);
```

成功后 60s 内不再加载，只有 `force` 或 `refreshLiveGeneration`（`1088`）重置时才打破。如果 generation hash 没变（同局重连、观战切换），这 60s 内新加入的玩家不会被补。

**改造方案**：改成「每玩家 TTL」——`playerHistory`/`playerRank` 已有 60s/20s 的缓存 TTL（`backend.zig:2264-2265`），直接复用它判断某人是否需要重载，不要整批一刀切。

---

### P2-13 512KB 固定缓冲 + 超长时静默丢弃

**位置**
- `src/backend.zig:147` `live_lobby_capacity = 512 * 1024`
- `src/backend.zig:4961` `live_profile_output_capacity = 512 * 1024`（×10 人 = 5MB）
- `src/backend.zig:1924` `if (value.len > self.live_lobby.len) return;` —— **超了就直接不更新**
- `src/backend.zig:1948` `cacheChampSelectLobby` 同样静默丢弃

**后果**：斗魂竞技场/大乱斗等多队伍模式（`layoutKind: arena`，`LiveView.vue:152`）阵容更大，一旦超过 512KB，整个快照更新被静默吞掉，UI 会卡在旧数据上。

**改造方案**：改成动态分配的 `std.ArrayList`，或至少把上限提到 2MB 并在超限时 `std.log.err`。

**✅ 已修复（2026-09-12）**：`cacheLiveLobby` 与 `cacheChampSelectLobby` 在超出
缓冲区时都会 `std.log.err` 打印实际字节数与上限，不再是静默丢弃。
（缓冲区仍是固定 512KB —— 改成动态分配要动 `Runtime` 的字段布局和
`querySnapshot` 的拷贝逻辑，风险较高，暂未做。）

---

### P2-14 SQLite 单连接 + 250ms busy_timeout

**位置**：`src/storage.zig:39,46`

`FULLMUTEX` 只保证「不崩」，不保证「不慢」。当前并发写方：5 个 enrichment 线程（`playerHistory` / `playerRank` / `historySubject`）、roster lane（`history/bp` 全量重写）、publish（`liveLobby/current` 244KB），全部序列化在一把连接锁上。

**改造方案**

1. `busy_timeout` 提到 2000~5000ms。
2. 读写分离：一个读连接 + 一个写连接（WAL 模式已开）。
3. 所有写走后台队列（见 P0-5 方案 3）。

**✅ 部分修复（2026-09-12）**：`busy_timeout` 250ms → 3000ms。250ms 时并发的
大快照写会直接超时并被 `catch {}` 静默吞掉，现在会真正排在连接锁上等。
（读写分离与写队列未做。）

---

### P2-15 首屏被第一次 roster 阻塞

**位置**：`frontend/src/views/LiveView.vue:28,42,361`

```ts
const initialRosterReady = ref(!isTauri());
enabled: computed(() => app.initialized && initialRosterReady.value),
onMounted: void refreshRosterImmediately().finally(() => { initialRosterReady.value = true; });
```

`lobby` 查询要等第一次 `get_live_roster` 返回才启用，而这次请求要和 `get_lcu_events` 抢同一条 lane。

**改造方案**：改成先渲染骨架屏（`teams` 为空时也能出 10 个占位卡），`initialRosterReady` 用 `Promise.race([roster, timeout(1500)])`。

**✅ 已修复（2026-09-12）**：`onMounted` 里用
`Promise.race([refreshRosterImmediately(), timeout(1500)])` 放行
`initialRosterReady`，首次阵容请求抢不到通道时不再一直挡住 `lobby` 查询。

---

## 2. 关于「只能看到我方 5 人」

这一条我**不下定论**，因为它有三个可能来源，必须靠日志区分。按可能性排序：

1. **P1-9 的撕裂读**（`live_lobby` 无锁并发读写）——解析失败被 `catch null` 吞掉
2. **前端合并回退**（P2-11）：`isDifferentRosterContext` 为真时整体返回未富化 overlay
3. **后端确实只拿到 5 人**：`getLiveLobbyInternal` 的 ChampSelect 分支（`1478-1484`）里 `mergeWithBestLiveCache` 会用旧缓存补足；若 `lobbyIdsCompatible` 因为 `lobbyGameId == 0` 恒真（`1637-1641`），上一局的 5 人缓存可能盖住新阵容。同时 `cacheLiveLobby`（`1924`）和 `cacheChampSelectLobby`（`1948`）都拒绝缩小人数。

**区分方法**：见下节埋点里的 `ENEMY_COUNT` 三处日志。

---

## 3. 埋点方案（先量后改，30 分钟就能做完）

在以下 9 个位置打时间戳日志（统一用 `runtimeMonotonicMillis` 相对 `batch.started_ms` 的偏移）：

| 位置 | 日志 |
|---|---|
| `backend.zig:1216` `loadLivePlayer` 入口 | `[LL] start side=%s idx=%d t=%d` |
| `backend.zig:5218` 之前（history 返回后） | `[LL] history side=%s idx=%d bytes=%d t=%d` |
| `backend.zig:5307` 前后 | `[LL] encounter side=%s idx=%d t=%d` |
| `backend.zig:1231` publish 前 | `[LL] publish side=%s idx=%d t=%d` |
| `backend.zig:1286` 之后（publish 完成） | `[LL] published side=%s idx=%d t=%d` |
| `backend.zig:1208` 之后 | `[LL] enqueued total=%d ally=%d enemy=%d` |
| `backend.zig:2123` 之后 | `[LL] roster ally=%d enemy=%d t=%d` |
| `backend.zig:1067` 之后 | `[LL] lobby bytes=%d loading=%d/%d t=%d` |
| `LiveView.vue:265` 之后 | `[FE] roster received ally=%d enemy=%d t=%d` |

**判读**

- `start` 五条时间接近、`enqueue total=10` → 后端并发没问题
- `history` 分散在几秒 → P0-2 / LCU 慢
- `history` 到 `encounter` 间隔大 → **P0-1 命中**
- `publish` 到 `published` 间隔大 → **P0-3 命中**
- `enqueued enemy=5` 但 `roster enemy=0` → P1-9 命中
- `roster enemy=5` 但 `[FE]` 显示 0 → P2-11 命中
- `[FE]` 时间戳间隔 5s → P0-4 命中

---

## 4. 改造路线

### 第一阶段：止血（不动架构，1~2 天）

| # | 动作 | 预期收益 |
|---|---|---|
| 1 | `backend.zig:5059` `endIndex=49` → `19`；`5071/5215/5218` 的 `50` → `20` | 单人耗时 −40~60% |
| 2 | `encounterProfileSummary` 从关键路径摘出，先返回空，后台补 | 直接砍掉最大热点 |
| 3 | `persistBpSnapshot` 加内容 hash 去重 | 选人阶段 SQLite 写 −90% |
| 4 | `storage.zig:46` busy_timeout 250 → 3000 | 消除静默写失败 |
| 5 | `native.ts:53` roster 并发 1 → 2；`LiveView.vue:283` 750 → 1200ms | lane 占用 −50% |
| 6 | 加第 3 节埋点 | 拿到真实数据 |

### 第二阶段：结构性修复（1 周）

7. encounter 批量预计算（P0-1 方案 1）
8. `publishLiveProfile` 改结构化状态 + 批量节流发布（P0-3 方案 1+2）
9. 拆分 `commandLane`：events / connection 各自独立（P0-4 方案 1）
10. `live_lobby` 双缓冲 + 版本号（P1-9）
11. `recent_json` 单次解析（P1-6）
12. `SharedLiveSgpContext` 改 Once + Condvar（P1-10）

### 第三阶段：架构升级（2~4 周）

13. Native 主动推 `live-profile` 增量事件，前端 patch 而非轮询（P1-7）
14. 合并 `get_live_roster` / `get_live_lobby` 为带版本号的增量同步命令
15. **首屏优先级**：分三档返回
    ```
    T+0~200ms    身份 / 英雄 / 位置 / 队伍 / 召唤师技能   ← 现在的 get_live_roster
    T+200~600ms  段位
    T+400~1500ms 近期战绩（20 场）
    T+1.5s+      统计 / 评分 / 标签 / 遇到过
    ```
    目前是「全部算完才一次性 publish」，即使总耗时不变，分批出来的主观速度快得多
16. SQLite 读写分离 + 写队列（P2-14）

---

## 5. 一句话总结

> 你的 5 人并发队列是对的，敌我共用队列也是对的。**问题出在队列之外**：
> ① 每人额外跑一遍 4MB 的「遇到过」全量计算（P0-1）；
> ② 每人请求 50 场只用 20 场（P0-2）；
> ③ 每人完成后全量重建 + 写盘 244KB 的 lobby 并自旋持锁（P0-3）；
> ④ roster lane 单 worker 还要和事件轮询抢（P0-4）；
> ⑤ 选人阶段每 750ms 全量重写 BP 历史（P0-5）。
>
> 这五件事共同把「后端 1.9s 完成」放大成「前端十几秒出完」，其中 **① 和 ③ 是最可能的元凶**。建议按第 3 节先打 9 个日志点验证，再动代码。
