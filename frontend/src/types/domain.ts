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
  error: string | null;
}

export interface ConnectionState {
  status: ConnectionStatus;
  phase: string | null;
  summonerName: string | null;
  gameName: string | null;
  tagLine: string | null;
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
  killParticipation: number;
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
  killParticipation?: number;
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

export interface PlayerProfile {
  rosterKey?: string;
  puuid: string;
  gameName: string;
  tagLine: string;
  isBot: boolean;
  championId: number;
  championName: string;
  profileIconId: number;
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
  loading?: { active: boolean; completed: number; total: number; failed: number; elapsedMs: number; firstPlayerMs: number | null };
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
  killParticipation: number;
  performance: "carry" | "solid" | "carried" | "struggling";
  mvp: "MVP" | "SVP" | null;
  teamKills: number;
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
  dataStatus: DataStatus;
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
    shortcutSendIntervalMs: number;
    protectChatInput?: boolean;
    shortcutRecentGameCount: number;
    shortcuts: ShortcutDefinition[];
  };
  providers: { statsProvider: string; requestTimeoutSeconds: number; cacheTtlMinutes: number; hideUnfinishedMatches: boolean; rankedOnly: boolean; clearLobbyAfterGame: boolean };
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
