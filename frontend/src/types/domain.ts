import type { PlayerTagSettings } from "../tags/settings";

export type DataMode = "live" | "fixture" | "replay";
export type ConnectionStatus = "connected" | "disconnected" | "connecting" | "error";
export type DataSource = "lcu" | "sgp" | "opgg" | "sqlite-fresh" | "sqlite-stale" | "fixture" | "unavailable";
export type AccountPresence = "offline" | "online" | "away" | "inQueue" | "customLobby" | "readyCheck" | "champSelect" | "inGame" | "spectating" | "endOfGame" | "unknown";
export interface DataStatus {
  source: DataSource;
  fetchedAt: string;
  expiresAt: string | null;
  isStale: boolean;
  /** 这一遍为这位玩家花了多少毫秒（后端实测值，用来定位「某个人特别慢」）。 */
  fetchMs?: number;
  error: string | null;
}

export interface ConnectionState {
  status: ConnectionStatus;
  phase: string | null;
  summonerName: string | null;
  gameName: string | null;
  tagLine: string | null;
  /** 当前登录账号的 puuid。区分「账号归属」与「行内视角」时用它，不要靠昵称猜。 */
  puuid: string | null;
  summonerLevel: number | null;
  profileIconId: number | null;
  platformId: string | null;
  region: string | null;
  presence: AccountPresence;
  soloRank: RankQueueSummary | null;
  flexRank: RankQueueSummary | null;
  queueLabel: string | null;
  message: string | null;
  checkedAt: string;
}

export interface RankQueueSummary {
  queueType: string;
  tier: string;
  division: string;
  leaguePoints: number;
  wins: number;
  losses: number;
}

/**
 * 某个 puuid 的等级与段位（后端 `lol.get_player_stats` 按人取）。
 *
 * 三个字段都可能为 `null`，含义各不相同，界面上一律显示「—」、不要用 0 兜底：
 * - `summonerLevel`：LCU 没有这个召唤师（跨区 / 改名）时为 null。
 * - `soloRank` / `flexRank`：该赛季没打这个队列、或战绩隐藏时为 null。
 *   这是「没打」而不是「无段位」。
 */
export interface PlayerStatSummary {
  puuid: string;
  summonerLevel: number | null;
  soloRank: RankQueueSummary | null;
  flexRank: RankQueueSummary | null;
}

export interface RecentMatch {
  gameId: number;
  queueId?: number;
  championId: number;
  championName: string;
  queueName: string;
  position: string;
  kills: number;
  deaths: number;
  assists: number;
  durationMinutes: number;
  items: ItemSummary[];
  summonerSpells: SpellSummary[];
  runes: RuneSummary[];
  damageDealt: number;
  damageTaken: number;
  heal: number;
  goldEarned: number;
  cs: number;
  damageShare: number;
  /**
   * 参团率。战绩列表接口每局只带查询者一条 `participants`，用它的「队伍击杀」
   * 当分母算出来恒为 100%（分子是击杀 + 助攻）——所以后端在**拿不到整队数据**时
   * 写 `null`，展示必须走 `percentOrDash`，不要 `?? 0` 也不要直接乘 100。
   */
  killParticipation: number | null;
  /**
   * 队伍占比类字段。只有拿到十人明细（SGP 富化后的战绩）时才由后端输出——
   * 战绩列表接口本身每局只带查询者一条 participants。缺字段时标签侧会把这些
   * 指标排除在样本外，而不是按 0 混进去拉低均值。
   * 见 `src/backend.zig` 的 `writeRecentMatchesFiltered`。
   */
  damageTakenShare?: number | null;
  goldShare?: number | null;
  csShare?: number | null;
  visionScoreShare?: number | null;
  /** 该局己方队伍人数；AK 的「理应贡献比」= 队伍占比 × 队伍人数。 */
  teamSize?: number | null;
  /** 该局己方队伍总击杀；用于击杀伤害转化。 */
  teamKills?: number | null;
  /** 该局己方队伍总承伤；用于治疗效率。 */
  teamDamageTaken?: number | null;
  /** 本局发出的「敌人消失」信号次数；LCU 数据源没有这个字段，因此可能为 null。 */
  enemyMissingPings?: number | null;
  /** 视野得分；后端仅在数据源提供时输出。 */
  visionScore?: number | null;
  /** 15 分钟前被敌方打野参与击杀的次数；仅峡谷对局且时间线富化后可用。 */
  earlyDeathsWithEnemyJungler?: number | null;
  soloKills?: number | null;
  takedownsFirstXMinutes?: number | null;
  jungleCsBefore10Minutes?: number | null;
  alliedJungleMonsterKills?: number | null;
  enemyJungleMonsterKills?: number | null;
  dragonTakedowns?: number | null;
  baronTakedowns?: number | null;
  riftHeraldTakedowns?: number | null;
  scuttleCrabKills?: number | null;
  performance: "carry" | "solid" | "carried" | "struggling";
  mvp: "MVP" | "SVP" | null;
  win: boolean;
  playedAt: string;
}

export interface ItemSummary {
  id: number;
  name: string;
  iconUrl: string;
  /**
   * 客户端里的格子序号（0–5 装备、6 饰品/视野位），由后端 `writeItems` 输出。
   *
   * 有它才能画固定的 6+1 个格子：中间空一格（卖掉一件装备）时，后面的装备要留在
   * 自己原来的格子里，不能整体前移。老缓存里的 DTO 没有这个字段，前端此时退回
   * 「按数组下标顺位」渲染。
   */
  slot?: number;
}

export interface SpellSummary {
  id: number;
  name: string;
  iconUrl: string;
}

export interface RuneSummary {
  id: number;
  name: string;
  style: string;
  iconUrl: string;
}

export interface BanSummary {
  id: number;
  name: string;
  iconUrl: string;
  side?: "ally" | "enemy" | string;
  pickTurn?: number;
  bannedBy?: string;
}

export interface MatchParticipant {
  puuid: string;
  gameName: string;
  isBot: boolean;
  championId: number;
  championName: string;
  side: "ally" | "enemy" | string;
  /**
   * **绝对**阵营：100 = 蓝方、200 = 红方。
   *
   * 与 `side` 的区别要记牢：`side` 是相对这一局视角方的（看别人的历史时，`ally`
   * 指的是**他**那一队）。跟时间线座位（带绝对 100/200）配对时必须用这个字段，
   * 用 `side` 在「视角方在红方」的对局里会把十个人全配空。
   * 老缓存里可能没有该字段，配对代码要留相对 `side` 的兜底。
   */
  team?: number;
  position: string;
  kills: number;
  deaths: number;
  assists: number;
  damageDealt: number;
  damageTaken: number;
  goldEarned: number;
  cs: number;
  win: boolean;
  items?: ItemSummary[];
  summonerSpells?: SpellSummary[];
  runes?: RuneSummary[];
  heal?: number;
  damageShare?: number;
  damageTakenShare?: number;
  killParticipation?: number | null;
  towerDamage?: number;
  turretKills?: number;
  wardsPlaced?: number;
  wardsKilled?: number;
  visionScore?: number;
  visionWardsBought?: number;
  sightWardsBought?: number;
}

export interface ChampionUsage {
  championId: number;
  championName: string;
  games: number;
  wins: number;
  winRate: number;
}

export interface JunglePreference {
  sampleSize: number;
  wins: number;
  winRate: number;
  style: "tempo" | "farm" | "balanced" | string;
  label: string;
  evidence: string;
  averageKda: number;
  averageKillParticipation: number;
  averageCsPerMinute: number;
  averageEarlyTakedowns: number | null;
  averageObjectiveTakedowns: number | null;
  averageEnemyJungleMonsters: number | null;
  mainChampions: ChampionUsage[];
  currentChampionGames: number;
}

export type JungleZone = "top" | "mid" | "bot";

export interface JunglePathPoint {
  x: number;
  y: number;
  zone: JungleZone;
}

export interface JungleCampCounts {
  blue: number;
  red: number;
  wolves: number;
  raptors: number;
}

/**
 * 打野路线图数据（`lol.get_jungle_path`）。
 *
 * 一个点位属于「常规开」还是「入侵开」由它自己的半区决定，所以后端按
 * 「阵营 + 常规/入侵」四组分开计数，落点坐标在前端。
 */
export interface JunglePathMap {
  /** 成功解析出逐帧数据的场次。 */
  games: number;
  /** 这些场次里使用的英雄；0 表示不限英雄。 */
  championId: number;
  zone: Record<JungleZone, number>;
  camps: {
    blueOwn: JungleCampCounts;
    blueInvade: JungleCampCounts;
    redOwn: JungleCampCounts;
    redInvade: JungleCampCounts;
  };
  /** 判定为「3 级抓」/「4 级抓」的场次数量。 */
  level3: number;
  level4: number;
  /** 蓝方 / 红方样本场次；营地占比的分母，和快捷消息的口径一致。 */
  blueGames: number;
  redGames: number;
  minutePoints: JunglePathPoint[];
  gankPoints: JunglePathPoint[];
  level3Points: JunglePathPoint[];
  level4Points: JunglePathPoint[];
}

export interface ScoreComponent {
  key: string;
  label: string;
  score: number;
  maxScore: number;
  evidence: string;
}

export interface ScoreBreakdown {
  total: number;
  confidence: number;
  components: ScoreComponent[];
}

/**
 * 一局的时间线：分钟帧 + 关键事件。
 *
 * 数据源与打野路线图相同（LCU 的 `game-timelines`），但口径完全不同——路线图按玩家
 * 聚合落点，这里按「分钟」横向铺开，用来画经济曲线和事件轴。
 */
export interface MatchTimelineParticipant {
  participantId: number;
  /** 100 = 蓝方，200 = 红方。 */
  team: number;
  championId: number;
}

export interface MatchTimelineFrame {
  minute: number;
  blueGold: number;
  redGold: number;
  /** 蓝方减红方；正数表示蓝方领先。 */
  goldDiff: number;
  blueCs: number;
  redCs: number;
  /** 10 项，按 participantId 1..10 顺序，缺座位补 0。 */
  gold: number[];
  /** 10 项；这一分钟各人的英雄等级（观战式等级徽标用），缺座位补 0。 */
  level: number[];
  /** 10 项；这一分钟各人的**累计对英雄伤害**（每波团伤害 = 团后帧减团前帧），缺座位/缺字段补 0。 */
  damage: number[];
  /** 10 项；这一分钟各人的**累计承受伤害**（每波团承伤同理），缺座位/缺字段补 0。 */
  taken: number[];
  /**
   * 10 项；这一分钟各人的地图位置（观战小地图的头像用它），0/0 = 该帧没有位置。
   *
   * 注意这是**每分钟一个采样点，不是轨迹**：帧之间怎么走的数据不存在。前端仍会把相邻两帧
   * 之间平滑过渡（`matches/timeline.ts` 的 `animatedPositions`）——**只为画面连贯，不是
   * 真实路径**（不插值就是「整分钟不动 + 集体闪现」，2026-09-27 试过、被否掉）；
   * 真数据只有每分钟那一个点，悬停玩家时画的那串点就是它（`positionHistory`）。
   */
  positions: { x: number; y: number }[];
}

export interface MatchTimelineEvent {
  /** CHAMPION_KILL / ELITE_MONSTER_KILL / BUILDING_KILL / TURRET_PLATE_DESTROYED */
  type: string;
  seconds: number;
  /** 做这件事的一方（推塔方 / 拿龙方 / 击杀方），未知为 0。 */
  team: number;
  killerId: number;
  victimId: number;
  assistCount: number;
  /** 助攻者的 participantId 名单（1..10）。后端原样带出，用来把「谁参与了」按人去重。 */
  assistIds: number[];
  killerChampionId: number;
  victimChampionId: number;
  /**
   * 事件发生的位置（游戏坐标，mapId 11 的 0..14820 × 0..14881 域）。
   * 0/0 表示这一条没有位置（例如被小兵推掉的塔）——**不能**当成「在左上角」。
   */
  posX: number;
  posY: number;
  monsterType: string;
  monsterSubType: string;
  buildingType: string;
  towerType: string;
  laneType: string;
}

export interface MatchTimeline {
  gameId: number;
  durationSeconds: number;
  participants: MatchTimelineParticipant[];
  frames: MatchTimelineFrame[];
  events: MatchTimelineEvent[];
}

/**
 * 本地录制里的一名玩家（采样当刻的快照）。
 *
 * 数据源是**游戏进行中本机**的 Live Client Data（127.0.0.1:2999），不走公网，也不是
 * 官方战绩接口。官方接口**没有**伤害字段，也没有装备购买的精确时刻——所以这里存的只能
 * 是「某一刻的状态」，装备变化要靠相邻两帧对比，精度就是采样间隔。
 */
export interface GameRecordingPlayer {
  puuid: string;
  /** `名字#标签`（Live Client 的 `riotId`）。 */
  rid: string;
  /** `ORDER` / `CHAOS`。 */
  team: string;
  /** 英雄英文名：Live Client 只给这个名字，中文名要另查。 */
  champ: string;
  /** 英雄数字 id（后端拿英雄目录反查出来的），画头像用；查不到为 0。 */
  cid: number;
  pos: string;
  lvl: number;
  k: number;
  d: number;
  a: number;
  cs: number;
  /** 视野分（`wardScore`）。 */
  ward: number;
  dead: boolean;
  /** 复活倒计时（秒）；活着是 0。 */
  respawn: number;
  bot: boolean;
  /** 身上装备的 itemID 列表，只含 `count > 0` 的槽位。 */
  items: number[];
  spells: string[];
}

/**
 * 本地玩家自己那一份。
 *
 * `championStats`（AD/AP/护甲/魔抗/移速/血量）**只有本人**在本地接口里拿得到，
 * 别人的这些字段根本不存在——所以单独挂在帧上，不要试图给十个人都补。
 */
export interface GameRecordingSelf {
  rid: string;
  gold: number;
  lvl: number;
  ad: number;
  ap: number;
  armor: number;
  mr: number;
  ms: number;
  hp: number;
  maxHp: number;
}

/** 录制里的一帧 = 采样那一刻的全场状态。 */
export interface GameRecordingFrame {
  /** 游戏内时间（秒）。 */
  t: number;
  gameId: number;
  sampledAt: string;
  players: GameRecordingPlayer[];
  /** 拿不到本人数据时为 null（例如观战视角）。 */
  me: GameRecordingSelf | null;
}

/**
 * `lol.get_game_recording` 的结果。
 *
 * `frames` 为空数组**不是错误**：这一局没录到（开关没开 / 不是本机在打 / 已经超过
 * 保留局数被回收）都回空数组，界面据此决定要不要画时间轴。
 */
export interface GameRecording {
  gameId: number;
  /** 采样间隔（秒）。相邻两帧的时间差就是它，装备变化的最小精度也是它。 */
  intervalSeconds: number;
  /**
   * 本机库里现有多少局录制。**专门用来区分两种「空」**：
   * `0` = 这功能从没采到过（开关没生效 / 打的时候应用没开 / 客户端不在），
   * `> 0` = 功能好好的，只是这一局没录。
   * 没有它的话这两种情况在界面上长得一模一样，只能让用户猜。
   */
  recordedGames: number;
  frames: GameRecordingFrame[];
}

export interface PlayerProfile {
  rosterKey?: string;
  puuid: string;
  gameName: string;
  tagLine: string;
  isBot: boolean;
  championId: number;
  championName: string;
  profileIconId: number;
  /**
   * 召唤师等级。后端逐人取（`/lol-summoner/v2/summoners/puuid/{puuid}`），
   * 拿不到时为 null —— 界面上要区分「没这个数据」和「等级 0」，所以别用 0 兜底。
   */
  summonerLevel?: number | null;
  assignedPosition: string;
  summonerSpells?: SpellSummary[];
  rankTier: string;
  rankDivision: string;
  leaguePoints: number;
  wins: number;
  losses: number;
  soloRank?: RankQueueSummary | null;
  flexRank?: RankQueueSummary | null;
  recentMatches: RecentMatch[];
  topChampions: ChampionUsage[];
  score: ScoreBreakdown;
  junglePreference?: JunglePreference | null;
  encounterCount: number;
  lastEncounteredAt: string | null;
  isPremade: boolean | null;
  premadeGroup?: string | null;
  premadeWith: string[];
  /** Role labels for party members, stable during champ-select when Riot IDs are hidden. */
  premadePositions?: string[];
  positionGames: number;
  positionWinRate: number;
  currentChampionGames: number;
  currentChampionWinRate: number;
  championPoolConcentration: number;
  /**
   * 客户端返回的生涯可见性；`"PRIVATE"` 表示该玩家隐藏了战绩。
   * LCU 不一定带上这个字段，缺失时为 null，此时「战绩隐藏」标签不会渲染。
   */
  privacy?: string | null;
  dataComplete: boolean;
  unavailableSources: string[];
  dataStatus: DataStatus;
}

export interface CompositionScore {
  early: number;
  mid: number;
  late: number;
  teamfight: number;
}

export interface TeamSummary {
  side: string;
  score: number;
  title: string;
  focusPlayerPuuid: string | null;
  strengths: string[];
  risks: string[];
  composition: CompositionScore | null;
}

export interface LiveLobby {
  loading?: { active: boolean; completed: number; total: number; failed: number; elapsedMs: number; firstPlayerMs: number | null; errorName?: string | null };
  id: string;
  queueId: number;
  gameMode: string;
  phase: string;
  ally: PlayerProfile[];
  enemy: PlayerProfile[];
  allySummary: TeamSummary;
  enemySummary: TeamSummary;
  layoutKind?: "classic" | "arena" | "generic";
  teams?: LiveTeam[];
  recentMatch?: MatchSummary | null;
  generatedAt: string;
  isFixture: boolean;
}

export interface LiveTeam {
  id: string;
  label: string;
  side: "ally" | "enemy" | "neutral" | string;
  players: PlayerProfile[];
  summary: TeamSummary | null;
}

export interface MatchSummary {
  gameId: number;
  championId: number;
  championName: string;
  position: string;
  queueId: number;
  queueName: string;
  result: string;
  kda: string;
  kills: number;
  deaths: number;
  assists: number;
  durationMinutes: number;
  items: ItemSummary[];
  summonerSpells: SpellSummary[];
  runes: RuneSummary[];
  damageDealt: number;
  damageTaken: number;
  damageTakenShare: number;
  heal: number;
  goldEarned: number;
  cs: number;
  towerDamage: number;
  turretKills: number;
  towerLeader: boolean;
  damageShare: number;
  /** 参团率；拿不到整队数据时为 `null`（见 `RecentMatch.killParticipation`）。 */
  killParticipation: number | null;
  performance: "carry" | "solid" | "carried" | "struggling";
  mvp: "MVP" | "SVP" | null;
  /** 己方队伍总击杀；拿不到整队数据时为 `null`，不要当成 0。 */
  teamKills: number | null;
  participants: MatchParticipant[];
  bans: string[];
  banDetails?: BanSummary[];
  playedAt: string;
  dataStatus: DataStatus;
}

export interface ChampionOverview {
  id: number;
  name: string;
  alias: string;
  abilities: string[];
  roles: string[];
  tier: string;
  winRate: number;
  pickRate: number;
  banRate: number;
  kda: number;
  iconUrl: string;
  baseSource: string;
  statsSource: string;
  /** 胜率/选取率是哪个区服、哪个分段的（OP.GG 的 region / tier）。 */
  statsRegion: string;
  statsTier: string;
  dataStatus: DataStatus;
}

/**
 * 一个技能的**每级数组**（1..5 级，个别技能 6 级）。
 *
 * 原样带出，**不做补齐也不做截断**——长度是几就是几。缺字段是空数组：
 * 补 0 会让「不知道」看起来像「 0 伤害 / 0 冷却」。
 */
export interface ChampionAbility {
  /** `q` / `w` / `e` / `r`。这是槽位的唯一真源（LCU 直接给，不靠下标猜）。 */
  slot: string;
  /** 技能名。LCU 已按客户端语言本地化——国服就是中文。 */
  name: string;
  description: string;
  /** 带 `@TotalDamage@` 这类占位符的模板；占位符的取值要另一份数据，这里原样展示。 */
  dynamicDescription: string;
  /** 各级冷却（秒）。亚索 E 会出现 0.5 这种小数。 */
  cooldown: number[];
  /** 各级法力消耗。 */
  cost: number[];
  /** 施法距离。 */
  range: number[];
  /** LCU 资源路径（`/lol-game-data/assets/…`），走 `get_asset` 取图。 */
  iconPath: string;
  /** 技能演示视频（webm）；LCU 资源路径下的相对路径。 */
  videoPath: string;
  /** 演示视频的封面图。 */
  videoImagePath: string;
}

/** 被动：没有等级数组，只有一条文案。 */
export interface ChampionPassive {
  name: string;
  description: string;
  iconPath: string;
  videoPath: string;
  videoImagePath: string;
}

/**
 * 单英雄的技能详情。
 *
 * 来源是 LCU 本地文件 `/lol-game-data/assets/v1/champions/{id}.json`（不是公网），
 * 所以技能名和描述**自带客户端语言**。真实每级伤害（AD/AP 系数）**不在**这里——
 * LCU 那份里 `coefficients` 全是 0，前端因此只展示文案与冷却/耗蓝/射程。
 */
export interface ChampionAbilities {
  championId: number;
  alias: string;
  name: string;
  title: string;
  passive: ChampionPassive | null;
  spells: ChampionAbility[];
}

/**
 * 技能文案里 `@变量@` 的**逐级真实数值**（一项）。
 *
 * `values` 是各级取值：技能等级 1..5（部分技能 6 级）。空数组表示 CDragon 那边
 * 这一项没有逐级数组（例如纯系数），**不要**当成 0 显示。
 */
export interface ChampionAbilityValueEntry {
  /** 逐级数值。 */
  values: number[];
  /** 若这一项带加成系数（`+1.0 法强`）。 */
  ratio?: number;
  /** 系数乘的属性：`AP` / `AD` / `Armor` / `MR` / `Health`。 */
  ratioStat?: string;
}

/** 一个槽位的取值表：变量名 → 数值。名字和 LCU 文案里的 `@名字@` 严格一致。 */
export interface ChampionAbilityValueSet {
  /** `p`（被动）/ `q` / `w` / `e` / `r`。 */
  slot: string;
  values: Record<string, ChampionAbilityValueEntry>;
}

/**
 * 单个英雄所有技能的变量取值。
 *
 * 来源是 CommunityDragon 的角色文件（公网），**不是** LCU——LCU 那份里
 * `coefficients` 全是 0、`effectAmounts` 是占位。`mSpellCalculations` 的键名恰好
 * 和 LCU 文案里的 `@名字@` 同一套，所以不需要映射表。
 *
 * 填不满是正常的：随**英雄等级**插值的（`@MinimumMoveSpeed@`）、依赖实时属性的
 * （护甲/魔抗）、以及 `@SpellModifierDescriptionAppend@`（它不是数值，是客户端
 * 拼接装备加成的位置）这三类**故意不出现**，前端保留原文并说明原因。
 */
export interface ChampionAbilityValues {
  alias: string;
  spells: ChampionAbilityValueSet[];
}


export interface EncounterRecord {
  gameId: number;
  selfPuuid?: string;
  selfGameName?: string;
  selfTagLine?: string;
  selfChampionId?: number;
  selfChampionName?: string;
  selfPosition?: string;
  selfKills?: number;
  selfDeaths?: number;
  selfAssists?: number;
  selfWin?: boolean;
  puuid: string;
  gameName: string;
  tagLine?: string;
  championId: number;
  championName: string;
  side: string;
  result: string | null;
  encounteredAt: string;
  queueId?: number;
  queueName?: string;
  kills?: number;
  deaths?: number;
  assists?: number;
  win?: boolean;
  position?: string;
  liveSnapshot?: boolean;
}

export interface FriendGroup {
  id: number;
  name: string;
  priority: number;
}

export interface FriendRecord {
  id: string;
  puuid: string;
  summonerId: number;
  gameName: string;
  gameTag: string;
  icon: number;
  groupId: number;
  availability: string;
  /** 客户端的游戏状态（好友对象的 `lol.gameStatus`），`ingame` 表示正在对局。 */
  gameStatus: string;
  /**
   * 是否拿得到观战密钥。
   *
   * 客户端只在好友「在线且正在对局中」时才下发 `lol.spectatorKey`，所以这个字段是
   * 「现在能不能观战」的**权威**依据——不要只看 `availability` 自己推断。
   */
  canSpectate: boolean;
  friendsSince: string | null;
  lastGameAt: string | null;
}

export interface FriendToolsSnapshot {
  groups: FriendGroup[];
  friends: FriendRecord[];
}

export interface FinalBpRecord {
  id: string;
  queueId: number;
  gameMode: string;
  allyChampionIds: number[];
  allyChampions: string[];
  enemyChampionIds: number[];
  enemyChampions: string[];
  allyScore: number;
  enemyScore: number;
  aiSummary: string | null;
  createdAt: string;
}

export interface DashboardSnapshot {
  connection: ConnectionState;
  recentMatches: MatchSummary[];
  recentEncounters: EncounterRecord[];
  patch: string;
  cachedChampions: number;
}

/**
 * 查询串 → 候选「名字#TAG」。
 *
 * 本地 API 只有精确匹配（LCU 的 `lol-summoner/v1/summoners?name=` 覆盖当前大区，
 * Riot Client 的 `player-account/aliases/v1/lookup` 覆盖跨区但要 gameName + tagLine
 * 两个字段），没有任何 name→tags 的反向索引，所以「只给名字列出所有 TAG」做不到。
 * `requiresTag` 就是用来把这个限制讲清楚的：只给了名字又没查到任何候选时为 `true`。
 */
export interface SummonerSearchCandidate {
  gameName: string;
  tagLine: string;
  puuid: string;
  /**
   * 等级与段位由本地 LCU 补（同大区才有）。
   *
   * 跨区候选是通过 Riot Client 解析出来的，本机没有那个大区的段位数据，所以这三项
   * 会是 null —— 界面要显示「—」，不要退化成「无段位」，那是两件不同的事。
   */
  summonerLevel?: number | null;
  soloRank?: RankQueueSummary | null;
  flexRank?: RankQueueSummary | null;
}

export interface SummonerSearchResult {
  query: string;
  hasTag: boolean;
  requiresTag: boolean;
  candidates: SummonerSearchCandidate[];
}

export interface AppBootstrap {
  dataMode: DataMode;
  dashboard: DashboardSnapshot;
  configPath: string;
  databasePath: string;
  appDataPath: string;
  appVersion: string;
}

export interface AppConfig {
  version: number;
  appearance: { theme: string; colorMode: "light" | "dark"; compact: boolean };
  playerTags: PlayerTagSettings;
  connection: { kind: "local" | "ssh"; sshTarget: string; identityFile: string; forwardedPort: number };
  automation: {
    enabled: boolean;
    advisoryMode: boolean;
    autoAccept: boolean;
    autoAcceptDelaySeconds: number;
    autoPick: boolean;
    autoPickDelaySeconds: number;
    autoPickStrategy: "just-show" | "show-and-lock-in" | "lock-in-immediately" | string;
    autoBan: boolean;
    pickChampionIds: number[];
    banChampionIds: number[];
    /**
     * 大乱斗自动抢英雄（走替补席换人）。
     *
     * 极地大乱斗与海克斯大乱斗共用这一份偏好与这一个开关：两者选人机制相同
     * （随机分英雄 + 替补席），判据是 `session.benchEnabled`，而替补席只在这两种
     * 模式里存在。
     */
    aramGrab: boolean;
    aramChampionIds: number[];
    /** 从「在替补席上看到目标」到真正换人之间的等待秒数（对齐 AK 的 2.9 秒）。 */
    aramSwapDelaySeconds: number;
    shortcutSendIntervalMs: number;
    shortcutRecentGameCount: number;
    shortcuts: ShortcutDefinition[];
  };
  providers: {
    statsProvider: string;
    requestTimeoutSeconds: number;
    cacheTtlMinutes: number;
    hideUnfinishedMatches: boolean;
    rankedOnly: boolean;
    clearLobbyAfterGame: boolean;
    /** 房间/匹配中（还没进选人）也拉队友资料，对齐 AK 的 `queryInLobbyPhase`。 */
    lobbyRoster: boolean;
    /**
     * 对局录制（**可选功能，默认关**）。
     *
     * 开着时游戏进行中每隔 `intervalSeconds` 秒把本地 Live Client Data 的公开数据
     * 存一帧（KDA / 补刀 / 视野分 / 装备 / 等级 / 复活倒计时），打完可以在对局页按
     * 时间轴回放。关着时后台那一跳不发任何请求。
     */
    recording: {
      enabled: boolean;
      intervalSeconds: number;
      /**
       * 录制的保留期（天）。**0 = 永久保留**，默认 30 天。
       *
       * 界面上给的是「3 天 / 7 天 / 一个月 / 永久」四个选项，落到配置里就是这个数字
       * （「永久」= 0）。后端 `game_recording.parseSettings` 会再夹一次，
       * 而且**必须**判字段在不在——它对缺失字段返回的 0 恰好是「永久」这个合法值，
       * 直接读会把老配置静默升级成「永不清理」。见那条同名后端用例。
       */
      retentionDays: number;
    };
  };
  ai: {
    enabled: boolean;
    provider: string;
    protocol: string;
    baseUrl: string;
    model: string;
    apiKey: string;
    automaticPregameAnalysis: boolean;
  };
}

export type ShortcutTarget = "ally" | "enemy" | "jungle" | "premade" | "encounter" | "lobby" | "custom";

export interface ShortcutDefinition {
  id: string;
  label: string;
  key: string;
  target: ShortcutTarget;
  template: string;
  enabled: boolean;
}

export interface ShortcutValidation {
  valid: boolean;
  errors: string[];
  preview: string;
}

export interface AssetPayload {
  kind: string;
  id: number;
  mimeType: string;
  dataUrl: string;
  source: string;
}

/* -------------------------------------------- 一键领取（自动化页）/ 客户端急救（对局页） */

/** 一键领取的三个来源：任务 / 奖励（grants）/ 事件中心奖励轨道。 */
export type ClaimSource = "mission" | "reward" | "event";

export interface ClaimItem {
  /** `来源:id`，领取时用它指认具体条目。 */
  key: string;
  source: ClaimSource;
  sourceLabel: string;
  id: string;
  title: string;
  detail: string;
  iconUrl: string | null;
  /** 这一项里包含几份奖励（多选一的只算实际会提交的那几份）。 */
  count: number;
}

export interface ClaimSourceSummary {
  source: ClaimSource;
  label: string;
  count: number;
}

export interface ClaimSnapshot {
  items: ClaimItem[];
  sources: ClaimSourceSummary[];
  total: number;
}

/**
 * 领取结果里的**一条**。
 *
 * 后端把成功与失败放在同一个 `claimed` 数组里、用 `reason` 的有无区分，
 * 所以这里两个字段都是可选的：有 `reason` 就是没领成。
 */
export interface ClaimResultEntry {
  source: ClaimSource;
  id: string;
  title: string;
  detail?: string;
  reason?: string;
}

export interface ClaimOutcome {
  claimed: ClaimResultEntry[];
  claimedCount: number;
  failedCount: number;
}

/** 客户端急救动作。键名与后端 `gameflow_ipc.action_table` 逐项对应。 */
export type GameflowActionKey = "dodge" | "leave-lobby" | "play-again" | "reconnect" | "ack-failed-launch";

export interface GameflowActionResult {
  action: GameflowActionKey | string;
  ok: boolean;
  /** 执行时客户端所处的 gameflow 阶段；读不到时为空串。 */
  phase: string;
  /** 失败原因（成功时为空串）。后端永远返回结构化结果而不是抛错。 */
  reason: string;
}

export interface FriendDeleteResultEntry {
  id: string;
  ok: boolean;
  reason: string;
}

export interface FriendDeleteOutcome {
  results: FriendDeleteResultEntry[];
  deleted: number;
  failed: number;
}

/**
 * 被删好友在本地库里的存档（回收站的每一行）。
 *
 * 删除是不可逆的，所以删之前后端会把**客户端当时那条好友记录**抄一份到本地。
 * 这里只有「这个人是谁 + 什么时候删的」——`availability` 这类实时状态刻意不存，
 * 它在回收站里早就过期了。
 */
export interface DeletedFriendRecord {
  id: string;
  puuid: string;
  summonerId: number;
  gameName: string;
  gameTag: string;
  icon: number;
  groupId: number;
  /** 删除时刻（ISO 8601）。 */
  deletedAt: string | null;
}

export interface DeletedFriendsSnapshot {
  friends: DeletedFriendRecord[];
}

/**
 * 回收站里的动作结果。
 *
 * `added` 只对「重新加回」有意义：客户端只有**发好友申请**这一个入口
 * （见后端 `friends_ipc.restoreFriend`），不是直接恢复好友关系——删除是单方面的，
 * 加回来要对方同意，界面必须把这点说清楚。
 */
export interface RestoreFriendResult {
  ok: boolean;
  reason: string;
  added: boolean;
  gameName: string;
  gameTag: string;
}

export interface SpectateResult {
  ok: boolean;
  reason: string;
  /**
   * 这次走的是哪条路线。
   *
   * - `buddy`：好友路线，用客户端下发的 `spectatorKey`。
   * - `observe`：观察者模式，**不带密钥**，所以不要求对方是好友。
   * - `""`：失败时无意义。
   */
  route?: "buddy" | "observe" | "";
}

/**
 * 一个「可以一键启动的东西」。
 *
 * 应用本来只会在客户端**已经跑起来**时接管（靠 lockfile 找凭据）；这套类型服务的是
 * 另一半场景——用户先开了应用、客户端还没开，点一下直接把它拉起来。
 */
export interface ClientLaunchEntry {
  /** 稳定标识（`tcls` / `wegame-launcher` / `wegame` / `riot-client` / `league-client`）。 */
  id: string;
  label: string;
  /** 这条入口是从哪探到的（安装清单 / 扫盘 / 环境变量），排查用。 */
  detail: string;
  path: string;
}

export interface ClientInstallations {
  entries: ClientLaunchEntry[];
}

/**
 * GitHub Release 上的新版本（`lol.check_update`）。
 *
 * 原生侧只有在新版本严格大于当前版本时才返回内容；查不到更新时前端拿到的是 null，
 * 「已是最新」就是 null 的另一种说法。
 */
export interface ReleaseUpdate {
  /** 不带 v 前缀的版本号（后端已从 tag_name 剥掉）。 */
  version: string;
  /** Release 标题。 */
  title: string;
  /** ISO 8601 发布时间。 */
  publishedAt: string;
  /** Release 页面链接。 */
  url: string;
  /** Release 说明（后端截断过，可能不是全文）。 */
  notes: string;
}

export interface ClientLaunchResult {
  ok: boolean;
  reason: string;
  /** 实际启动了哪个入口；空串表示没启动。 */
  id: string;
  label: string;
}

/**
 * 本地「见过的玩家」搜索结果的一项。
 *
 * 数据只来自本地已沉淀的东西（历史遇到记录 + 好友列表），**不做任何网络查询**：
 * 本地没有任何 name→全服玩家 的反向索引，所以这里只可能搜到「你确实见过的人」。
 */
export interface LocalPlayerHit {
  puuid: string;
  gameName: string;
  tagLine: string;
  /** 本地遇到记录里出现过几局。 */
  encounterGames: number;
  /** 是否同时是好友（好友列表取不到时一律 false）。 */
  isFriend: boolean;
  lastSeenAt: string | null;
  /** 最近一次遇到时用的英雄，空串表示没记录。 */
  lastChampion: string;
}
