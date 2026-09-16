<script setup lang="ts">
import { Link2, MapPinned } from "@lucide/vue";
import type { EncounterRecord, PlayerProfile, RankQueueSummary } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import PlayerTagArea from "../tags/components/PlayerTagArea.vue";
import { premadeGroupLabel } from "../tags/tones";
import { championImage, rankName, roleName, shortDate, shortDay } from "../utils/format";

type RecentColumns = 1 | 2;
const props = withDefaults(
  defineProps<{
    player: PlayerProfile;
    selected?: boolean;
    showRecent?: boolean;
    recentLimit?: number;
    recentColumns?: RecentColumns;
    premadeTone?: number;
    suppressEncounters?: boolean;
    encounterRecords?: EncounterRecord[];
    encounterLoading?: boolean;
    encounterError?: boolean;
    currentGameId?: number;
    localPlayer?: PlayerProfile | null;
    /** 本地玩家为该玩家写的备注。 */
    playerNotes?: string[];
    canEditNotes?: boolean;
  }>(),
  { recentLimit: 10, recentColumns: 1 },
);
const emit = defineEmits<{
  select: [player: PlayerProfile];
  "select-match": [player: PlayerProfile, gameId: number];
  "select-encounter": [player: PlayerProfile, records: EncounterRecord[]];
  "retry-encounters": [];
  "edit-notes": [player: PlayerProfile];
}>();

const visibleMatches = (player: PlayerProfile) => player.recentMatches.slice(0, props.recentLimit);
const completed = (player: PlayerProfile) => visibleMatches(player).filter((match) => match.durationMinutes > 0);
const allCompleted = (player: PlayerProfile) => player.recentMatches.filter((match) => match.durationMinutes > 0);
const recentWins = (player: PlayerProfile) => completed(player).filter((match) => match.win).length;
const recentLosses = (player: PlayerProfile) => completed(player).length - recentWins(player);
const recentWinRate = (player: PlayerProfile) => {
  const list = completed(player);
  if (!list.length) return 0;
  return Math.round((recentWins(player) / list.length) * 100);
};

const kdaValue = (player: PlayerProfile) => {
  const list = completed(player);
  if (!list.length) return 0;
  return list.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / list.length;
};

const kda = (player: PlayerProfile) => {
  const val = kdaValue(player);
  return completed(player).length ? val.toFixed(1) : "--";
};

const kdaLevelClass = (player: PlayerProfile) => {
  const val = kdaValue(player);
  if (!completed(player).length) return "";
  if (val >= 4.5) return "kda--carry";
  if (val >= 3.2) return "kda--good";
  if (val < 2.0) return "kda--poor";
  return "kda--normal";
};

const winRateLevelClass = (player: PlayerProfile) => {
  const rate = recentWinRate(player);
  if (!completed(player).length) return "";
  if (rate >= 65) return "rate--high";
  if (rate >= 50) return "rate--mid";
  return "rate--low";
};

const mainPositions = (player: PlayerProfile) => {
  const counts = new Map<string, { position: string; games: number; wins: number }>();
  for (const match of allCompleted(player)) {
    const position = roleName(match.position);
    if (position === "待定") continue;
    const current = counts.get(position) ?? { position, games: 0, wins: 0 };
    current.games += 1;
    if (match.win) current.wins += 1;
    counts.set(position, current);
  }
  const positions = [...counts.values()].sort((a, b) => b.games - a.games || b.wins - a.wins).slice(0, 2);
  if (!positions.length && roleName(player.assignedPosition) !== "待定") {
    positions.push({ position: roleName(player.assignedPosition), games: 0, wins: 0 });
  }
  return positions;
};

const soloRank = (player: PlayerProfile): RankQueueSummary | null =>
  player.soloRank ??
  (player.rankTier
    ? {
        queueType: "RANKED_SOLO_5x5",
        tier: player.rankTier,
        division: player.rankDivision,
        leaguePoints: player.leaguePoints,
        wins: player.wins,
        losses: player.losses,
      }
    : null);

const queueRank = (rank?: RankQueueSummary | null) => {
  if (props.player.unavailableSources?.includes("rank")) return props.player.dataStatus?.source === "unavailable" ? "读取中" : "暂不可用";
  const tier = rank?.tier?.trim();
  if (!tier || ["UNRANKED", "NA"].includes(tier.toUpperCase())) return "未定级";
  return `${rankName(tier)} ${rank?.division ?? ""}`.trim();
};

const queueRankTitle = (label: string, rank?: RankQueueSummary | null) =>
  rank
    ? `${label}：${queueRank(rank)} · ${rank.leaguePoints} LP · ${rank.wins}胜${rank.losses}负`
    : `${label}：未定级`;

const tierClass = (tier?: string) => (tier ? `tier-${tier.toLowerCase()}` : "tier-unranked");
const premadeClass = () => {
  if (!props.player.isPremade && props.premadeTone === undefined) return "";
  return props.premadeTone === undefined
    ? "bp-player-card--premade bp-player-card--premade-unresolved"
    : `bp-player-card--premade bp-player-card--premade-${props.premadeTone}`;
};
const premadeLabel = () => {
  // 与标签区共用 AK 的字母分组（`小队 A`~`小队 L`），避免头部显示序号、标签显示字母。
  const team = premadeGroupLabel(props.premadeTone);
  return team === null ? "组队" : `小队 ${team}`;
};
function selectFromKeyboard(event: KeyboardEvent) {
  if (event.target !== event.currentTarget) return;
  emit("select", props.player);
}
</script>

<template>
  <article
    class="bp-player-card"
    :class="[premadeClass(), { 'bp-player-card--selected': selected, 'bp-player-card--recent': showRecent }]"
    role="button"
    tabindex="0"
    @click="emit('select', player)"
    @keydown.enter="selectFromKeyboard"
    @keydown.space.prevent="selectFromKeyboard"
  >
    <!-- 卡片头部：位置徽章、头像、玩家名、Tagline、开黑组队标识 -->
    <header class="bp-player-card__header">
      <span class="bp-player-card__role" :data-role="player.assignedPosition">{{ roleName(player.assignedPosition) }}</span>
      <div class="bp-player-card__avatar-wrap">
        <AssetIcon
          kind="champion"
          :id="player.championId"
          :name="player.championName"
          :fallback-url="championImage(player.championId)"
          size="md"
        />
      </div>
      <div class="bp-player-card__identity">
        <strong :title="player.gameName">
          {{ player.gameName }}
          <em v-if="player.isBot" class="bp-player-card__bot">人机</em>
        </strong>
        <small :title="`#${player.tagLine}`">#{{ player.tagLine || "--" }}</small>
      </div>
      <span
        v-if="player.isPremade || premadeTone !== undefined"
        class="bp-player-card__premade"
        :title="player.premadeWith.length ? `与 ${player.premadeWith.join('、')} 开黑` : '检测到已知组队'"
      >
        <Link2 :size="13" />
        <b>{{ premadeLabel() }}</b>
      </span>
    </header>

    <!-- 段位与评分条：大号段位高亮 + LP + 综合战力评分 -->
    <div class="bp-player-card__rank">
      <div class="bp-player-card__rank-left">
        <span class="bp-player-card__tier" :class="tierClass(player.rankTier)">
          {{ player.unavailableSources?.includes('rank') ? (player.dataStatus?.source === 'unavailable' ? '段位读取中' : '段位暂不可用') : `${rankName(player.rankTier)} ${player.rankDivision}` }}
        </span>
        <b v-if="!player.unavailableSources?.includes('rank')" class="bp-player-card__lp">{{ player.leaguePoints }} LP</b>
      </div>
      <em class="bp-player-card__score" title="综合对局评分">
        <span class="score-num">{{ player.recentMatches.length ? player.score.total.toFixed(0) : '--' }}</span>
        <span class="score-unit">分</span>
      </em>
    </div>

    <!-- 关键指标 4 格看板：近况胜率、KDA水平、主力位置、排位双段位 -->
    <div class="bp-player-card__metrics">
      <!-- 近况与胜率 -->
      <div class="metric-cell metric-cell--record">
        <span>近{{ recentLimit }}场</span>
        <div class="metric-val-wrap">
          <strong class="metric-record">{{ recentWins(player) }}胜{{ recentLosses(player) }}负</strong>
          <small v-if="completed(player).length" class="metric-rate-badge" :class="winRateLevelClass(player)">
            {{ recentWinRate(player) }}%
          </small>
        </div>
      </div>

      <!-- KDA -->
      <div class="metric-cell metric-cell--kda">
        <span>KDA</span>
        <strong class="metric-kda" :class="kdaLevelClass(player)">{{ kda(player) }}</strong>
      </div>

      <!-- 主要位置 -->
      <div class="metric-cell bp-player-card__position">
        <span>主要位置</span>
        <template v-if="mainPositions(player).length">
          <strong v-for="position in mainPositions(player)" :key="position.position" class="position-tag">
            {{ position.position }} {{ position.games }}场
          </strong>
        </template>
        <strong v-else class="empty-pos">待定</strong>
      </div>

      <!-- 双排位段位 -->
      <div class="metric-cell bp-player-card__queue-ranks">
        <span>排位段位</span>
        <strong :title="queueRankTitle('单双排', soloRank(player))">
          <em>单双</em>{{ queueRank(soloRank(player)) }}
        </strong>
        <strong :title="queueRankTitle('灵活排位', player.flexRank)">
          <em>灵活</em>{{ queueRank(player.flexRank) }}
        </strong>
      </div>
    </div>

    <!-- 近况战绩走势条（胜绿负红） -->
    <div class="bp-player-card__trend" :title="`近 ${visibleMatches(player).length} 局战况走势`">
      <i
        v-for="match in visibleMatches(player)"
        :key="match.gameId"
        :class="match.durationMinutes === 0 ? 'trend-unfinished' : match.win ? 'trend-win' : 'trend-loss'"
        :title="`${match.championName || '对局'} · ${match.durationMinutes === 0 ? '未完成' : match.win ? '胜利' : '失败'} (${match.kills}/${match.deaths}/${match.assists})`"
      />
    </div>

    <!-- 最近对局列表（战绩核心区） -->
    <div
      v-if="showRecent"
      class="bp-player-card__recent"
      :class="{ 'bp-player-card__recent--single': recentColumns === 1 }"
      :style="{ '--recent-columns': recentColumns }"
    >
      <span class="bp-player-card__section-label">最近对局 <b>{{ visibleMatches(player).length }}场</b></span>

      <template v-if="visibleMatches(player).length">
        <button
          v-for="match in visibleMatches(player)"
          :key="`recent-${match.gameId}`"
          type="button"
          class="recent-match-row"
          data-testid="player-recent-match"
          :data-result="match.durationMinutes === 0 ? 'unfinished' : match.win ? 'win' : 'loss'"
          :title="`${match.win ? '胜利' : '失败'} · ${match.championName || ''} · ${match.kills}/${match.deaths}/${match.assists} · ${match.queueName || ''} · ${match.durationMinutes}分钟`"
          @click.stop="emit('select-match', player, match.gameId)"
        >
          <!-- 胜负标识条与英雄头像 -->
          <div class="match-left">
            <span class="match-result-indicator" :class="match.durationMinutes === 0 ? 'ind--unf' : match.win ? 'ind--win' : 'ind--loss'">
              {{ match.durationMinutes === 0 ? '平' : match.win ? '胜' : '负' }}
            </span>
            <AssetIcon
              kind="champion"
              :id="match.championId"
              :name="match.championName"
              :fallback-url="championImage(match.championId)"
              size="xs"
            />
          </div>

          <!-- KDA 数据与 MVP/SVP 徽章 -->
          <div class="match-kda-box">
            <b>
              <span class="kda-kills">{{ match.kills }}</span>/<span class="kda-deaths" :class="{ 'high-deaths': match.deaths >= 7 }">{{ match.deaths }}</span>/<span class="kda-assists">{{ match.assists }}</span>
              <em v-if="match.mvp" class="bp-player-card__mvp" :data-mvp="match.mvp">
                {{ match.mvp }}
              </em>
            </b>
          </div>

          <!-- 模式 -->
          <small class="bp-player-card__recent-mode" :title="match.queueName || '未知模式'">
            {{ match.queueName || "未知模式" }}
          </small>

          <!-- 时间与耗时 -->
          <time class="bp-player-card__recent-time" :datetime="match.playedAt" :title="shortDate(match.playedAt)">
            <span>{{ shortDay(match.playedAt) }}</span>
            <em>{{ match.durationMinutes }}m</em>
          </time>
        </button>
      </template>
      <span v-else class="bp-player-card__empty">暂无最近对局</span>
    </div>

    <!-- 常用英雄 -->
    <div class="bp-player-card__champions">
      <span class="champions-label">常用英雄 · 当前样本</span>
      <div class="champions-list">
        <template v-if="player.topChampions.length">
          <span
            v-for="champion in player.topChampions.slice(0, 3)"
            :key="champion.championId"
            class="bp-player-card__champion"
            :title="`${champion.championName}：${champion.games} 场 · ${champion.wins} 胜 (${Math.round((champion.wins / Math.max(1, champion.games)) * 100)}%胜率)`"
          >
            <AssetIcon
              kind="champion"
              :id="champion.championId"
              :name="champion.championName"
              :fallback-url="championImage(champion.championId)"
              size="xs"
            />
            <div class="champ-info">
              <b>{{ champion.championName }}</b>
              <em>{{ champion.games }}把</em>
            </div>
          </span>
        </template>
        <span v-else class="bp-player-card__empty">暂无常用英雄</span>
      </div>
    </div>

    <div v-if="player.junglePreference" class="bp-player-card__jungle" :data-style="player.junglePreference.style" :title="player.junglePreference.evidence">
      <MapPinned :size="12" />
      <span>打野偏好</span>
      <strong>{{ player.junglePreference.label }}</strong>
      <small>{{ player.junglePreference.sampleSize }} 场 · {{ Math.round(player.junglePreference.winRate * 100) }}%</small>
    </div>

    <!-- 特色标签区：统一由标签系统渲染，顺序与开关见 frontend/src/tags -->
    <footer class="bp-player-card__tags">
      <PlayerTagArea
        :player="player"
        :local-player="localPlayer"
        :premade-tone="premadeTone"
        :suppress-encounters="suppressEncounters"
        :encounter-records="encounterRecords"
        :encounter-loading="encounterLoading"
        :encounter-error="encounterError"
        :current-game-id="currentGameId"
        :player-notes="playerNotes"
        :can-edit-notes="canEditNotes"
        @select-encounter="(records) => emit('select-encounter', player, records)"
        @retry-encounters="emit('retry-encounters')"
        @edit-notes="emit('edit-notes', player)"
      />
    </footer>
  </article>
</template>

<style scoped>
/* 玩家卡片基础容器 */
.bp-player-card {
  position: relative;
  display: flex;
  flex-direction: column;
  width: 100%;
  min-width: 0;
  min-height: 220px;
  padding: 10px 11px;
  border: 1px solid var(--line);
  border-top: 3px solid var(--line-strong);
  border-radius: 8px;
  color: var(--text-primary);
  background: var(--surface);
  text-align: left;
  cursor: pointer;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.04);
  transition: all 0.18s cubic-bezier(0.4, 0, 0.2, 1);
}

.bp-player-card[data-side="ally"] {
  --side-color: var(--blue);
  border-top-color: var(--blue);
}

.bp-player-card[data-side="enemy"] {
  --side-color: var(--red);
  border-top-color: var(--red);
}

.bp-player-card:hover {
  border-color: var(--accent);
  background: var(--surface-raised);
  transform: translateY(-2px);
  box-shadow: 0 6px 16px rgba(0, 0, 0, 0.08);
}

.bp-player-card--selected {
  border-color: var(--accent);
  box-shadow: 0 0 0 2px var(--accent-soft), 0 4px 12px rgba(0, 0, 0, 0.08);
}

/* 开黑组队样式 */
.bp-player-card--premade {
  border: 2px solid var(--premade-color);
  border-left: 5px solid var(--side-color, var(--premade-color));
  background: color-mix(in srgb, var(--premade-color) 8%, var(--surface));
  --player-card-panel: color-mix(in srgb, var(--premade-color) 10%, var(--surface-raised));
}

.bp-player-card--premade-0 { --premade-color: #f97316; }
.bp-player-card--premade-1 { --premade-color: #8b5cf6; }
.bp-player-card--premade-2 { --premade-color: #10b981; }
.bp-player-card--premade-3 { --premade-color: #06b6d4; }
.bp-player-card--premade-4 { --premade-color: #ec4899; }
.bp-player-card--premade-5 { --premade-color: #eab308; }
.bp-player-card--premade-6 { --premade-color: #84cc16; }
.bp-player-card--premade-7 { --premade-color: #6366f1; }
.bp-player-card--premade-unresolved { --premade-color: #64748b; }

.bp-player-card--premade:hover {
  border-color: var(--premade-color);
  background: color-mix(in srgb, var(--premade-color) 12%, var(--surface));
  box-shadow: 0 6px 16px color-mix(in srgb, var(--premade-color) 20%, transparent);
}

/* 1. 卡片头部 */
.bp-player-card__header {
  display: flex;
  align-items: center;
  gap: 7px;
  min-width: 0;
}

.bp-player-card__role {
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 32px;
  height: 22px;
  padding: 0 5px;
  border-radius: 4px;
  color: var(--text-secondary);
  background: var(--surface-muted);
  border: 1px solid var(--line);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.02em;
}

.bp-player-card__avatar-wrap {
  position: relative;
  flex: none;
  border-radius: 6px;
  overflow: hidden;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
}

.bp-player-card__identity {
  min-width: 0;
  flex: 1;
}

.bp-player-card__identity strong {
  display: flex;
  align-items: center;
  gap: 4px;
  overflow: hidden;
  color: var(--text-primary);
  font-size: 13px;
  font-weight: 700;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.bp-player-card__identity small {
  display: block;
  margin-top: 1px;
  overflow: hidden;
  color: var(--text-muted);
  font-size: 10px;
  font-family: ui-monospace, monospace;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.bp-player-card__bot {
  display: inline-flex;
  padding: 1px 4px;
  border-radius: 3px;
  color: #3b82f6;
  background: color-mix(in srgb, #3b82f6 15%, var(--surface));
  font-size: 9px;
  font-style: normal;
  font-weight: 700;
}

.bp-player-card__premade {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  flex: none;
  padding: 2px 5px;
  border-radius: 4px;
  color: var(--premade-color, var(--accent));
  background: color-mix(in srgb, var(--premade-color, var(--accent)) 14%, var(--surface));
  border: 1px solid color-mix(in srgb, var(--premade-color, var(--accent)) 40%, var(--line));
}

.bp-player-card__premade b {
  font-size: 10px;
  font-weight: 800;
  white-space: nowrap;
}

/* 2. 段位与评分行 */
.bp-player-card__rank {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
  margin-top: 7px;
  padding: 4px 7px;
  border-radius: 5px;
  background: var(--surface-muted);
  border: 1px solid var(--line);
}

.bp-player-card__rank-left {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

.bp-player-card__tier {
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.02em;
  white-space: nowrap;
}

.bp-player-card__lp {
  color: var(--text-secondary);
  font-size: 10px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.bp-player-card__score {
  display: inline-flex;
  align-items: baseline;
  gap: 1px;
  padding: 2px 6px;
  border-radius: 4px;
  color: var(--accent);
  background: var(--accent-soft);
  font-style: normal;
}

.bp-player-card__score .score-num {
  font-size: 14px;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
}

.bp-player-card__score .score-unit {
  font-size: 9px;
  font-weight: 700;
  opacity: 0.85;
}

/* 各段位色彩高亮 */
.tier-challenger { color: #f59e0b; }
.tier-grandmaster { color: #ef4444; }
.tier-master { color: #a855f7; }
.tier-diamond { color: #0284c7; }
.tier-emerald { color: #059669; }
.tier-platinum { color: #0d9488; }
.tier-gold { color: #d97706; }
.tier-silver { color: #64748b; }
.tier-bronze { color: #b45309; }
.tier-iron { color: #6b7280; }
.tier-unranked { color: var(--text-muted); }

/* 3. 关键指标看板：2×2 网格（近况胜率 | KDA / 主要位置 | 排位段位）
   4 列单行在非全屏窗口下每格只有 ~30px，KDA 数字会溢出、主要位置文字被截断；
   改成两列后每格宽度翻倍，保证小窗口下依然可读。 */
.bp-player-card__metrics {
  display: grid;
  /* grid-template-columns: 1.0fr 0.8fr 1.05fr 1.35fr; */
  grid-template-columns: 0.85fr 0.55fr 1.05fr 1.15fr;

  /* grid-template-columns: repeat(4, 1fr); */
  gap: 1px;
  margin: 6px 0 5px;
  border: 1px solid var(--line);
  border-radius: 5px;
  background: var(--line);
  overflow: hidden;
}

.metric-cell {
  min-width: 0;
  padding: 4px 4px;
  background: var(--player-card-panel, var(--surface-raised));
}

.metric-cell span {
  display: block;
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 600;
  margin-bottom: 2px;
  white-space: nowrap;
}

.metric-val-wrap {
  display: flex;
  flex-direction: column;
  gap: 1px;
}

.metric-record {
  color: var(--text-primary);
  font-size: 11px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.metric-rate-badge {
  display: inline-block;
  align-self: flex-start;
  padding: 1px 3px;
  border-radius: 3px;
  font-size: 9px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  line-height: 1.1;
}

.metric-rate-badge.rate--high {
  color: #15803d;
  background: color-mix(in srgb, #15803d 15%, var(--surface));
}

.metric-rate-badge.rate--mid {
  color: #b45309;
  background: color-mix(in srgb, #b45309 15%, var(--surface));
}

.metric-rate-badge.rate--low {
  color: #dc2626;
  background: color-mix(in srgb, #dc2626 15%, var(--surface));
}

.metric-kda {
  display: block;
  font-size: 12px;
  font-weight: 900;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
}

.metric-kda.kda--carry { color: #10b981; }
.metric-kda.kda--good { color: #0284c7; }
.metric-kda.kda--normal { color: var(--text-primary); }
.metric-kda.kda--poor { color: #dc2626; }

.bp-player-card__position strong,
.bp-player-card__queue-ranks strong {
  display: block;
  overflow: hidden;
  font-size: 9.5px;
  font-weight: 600;
  text-overflow: ellipsis;
  white-space: nowrap;
  line-height: 1.25;
}

.bp-player-card__position strong + strong,
.bp-player-card__queue-ranks strong + strong {
  margin-top: 1px;
}

.bp-player-card__queue-ranks em {
  display: inline-block;
  margin-right: 2px;
  color: var(--text-muted);
  font-size: 8px;
  font-style: normal;
  font-weight: 500;
}

/* 4. 战况走势条 */
.bp-player-card__trend {
  display: flex;
  align-items: center;
  gap: 3px;
  height: 6px;
  margin: 2px 0 5px;
}

.bp-player-card__trend i {
  flex: 1;
  height: 5px;
  border-radius: 2px;
  background: var(--surface-muted);
  transition: transform 0.12s;
}

.bp-player-card__trend i:hover {
  transform: scaleY(1.5);
}

.bp-player-card__trend .trend-win {
  background: #10b981;
  box-shadow: 0 0 4px rgba(16, 185, 129, 0.4);
}

.bp-player-card__trend .trend-loss {
  background: #ef4444;
  box-shadow: 0 0 4px rgba(239, 68, 68, 0.3);
}

.bp-player-card__trend .trend-unfinished {
  background: #f59e0b;
}

/* 5. 最近对局区域 */
.bp-player-card__recent {
  display: grid;
  grid-template-columns: repeat(var(--recent-columns, 1), minmax(0, 1fr));
  gap: 4px;
  margin-top: 2px;
}

.bp-player-card__section-label {
  display: flex;
  grid-column: 1 / -1;
  align-items: center;
  justify-content: space-between;
  padding: 2px 1px 3px;
  color: var(--text-muted);
  font-size: 10px;
  font-weight: 700;
  border-bottom: 1px dashed var(--line);
  margin-bottom: 2px;
}

.bp-player-card__section-label b {
  color: var(--text-secondary);
  font-size: 9px;
  font-weight: 700;
}

.recent-match-row {
  display: grid;
  grid-template-areas: "left kda mode time";
  grid-template-columns: auto minmax(0, 1.2fr) minmax(0, 0.9fr) auto;
  align-items: center;
  gap: 5px;
  min-height: 28px;
  padding: 3px 6px;
  border-radius: 5px;
  border: 1px solid var(--line);
  background: var(--surface-raised);
  font-size: 10px;
  font-variant-numeric: tabular-nums;
  transition: background 0.12s, border-color 0.12s;
  width: 100%;
  color: inherit;
  font-family: inherit;
  text-align: left;
  cursor: pointer;
}

.recent-match-row:hover {
  border-color: var(--accent);
  background: var(--surface);
}

.recent-match-row[data-result="win"] {
  border-color: color-mix(in srgb, #10b981 40%, var(--line));
  background: color-mix(in srgb, #10b981 8%, var(--surface));
}

.recent-match-row[data-result="loss"] {
  border-color: color-mix(in srgb, #ef4444 35%, var(--line));
  background: color-mix(in srgb, #ef4444 6%, var(--surface));
}

.recent-match-row[data-result="unfinished"] {
  border-color: color-mix(in srgb, #f59e0b 35%, var(--line));
  background: color-mix(in srgb, #f59e0b 6%, var(--surface));
}

.match-left {
  grid-area: left;
  display: flex;
  align-items: center;
  gap: 4px;
}

.match-result-indicator {
  display: inline-grid;
  place-items: center;
  width: 16px;
  height: 16px;
  border-radius: 3px;
  font-size: 9px;
  font-weight: 900;
  line-height: 1;
}

.match-result-indicator.ind--win {
  color: #fff;
  background: #10b981;
}

.match-result-indicator.ind--loss {
  color: #fff;
  background: #ef4444;
}

.match-result-indicator.ind--unf {
  color: #fff;
  background: #f59e0b;
}

.match-kda-box {
  grid-area: kda;
  min-width: 0;
  display: flex;
  align-items: center;
}

.match-kda-box b {
  display: inline-flex;
  align-items: center;
  gap: 2px;
  color: var(--text-primary);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: -0.02em;
  white-space: nowrap;
}

.kda-kills { color: var(--text-primary); }
.kda-deaths { color: var(--text-secondary); }
.kda-deaths.high-deaths { color: #dc2626; font-weight: 800; }
.kda-assists { color: var(--text-secondary); }

.bp-player-card__mvp {
  display: inline-flex;
  margin-left: 2px;
  padding: 1px 3px;
  border-radius: 3px;
  color: #b45309;
  background: #fef3c7;
  border: 1px solid #fcd34d;
  font-size: 8px;
  font-style: normal;
  font-weight: 900;
  letter-spacing: 0.02em;
  box-shadow: 0 1px 2px rgba(245, 158, 11, 0.2);
}

.bp-player-card__mvp[data-mvp="SVP"] {
  color: #4338ca;
  background: #e0e7ff;
  border-color: #a5b4fc;
  box-shadow: 0 1px 2px rgba(99, 102, 241, 0.2);
}

.bp-player-card__recent-mode {
  grid-area: mode;
  min-width: 0;
  overflow: hidden;
  color: var(--text-secondary);
  font-size: 10px;
  font-weight: 500;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.bp-player-card__recent-time {
  grid-area: time;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  min-width: 0;
  color: var(--text-muted);
  font-size: 9px;
  font-variant-numeric: tabular-nums;
  line-height: 1.15;
  white-space: nowrap;
}

.bp-player-card__recent-time span {
  font-size: 9px;
  color: var(--text-secondary);
}

.bp-player-card__recent-time em {
  font-size: 8px;
  font-style: normal;
  color: var(--text-muted);
}

.bp-player-card__recent--single {
  max-height: 380px;
  overflow-y: auto;
  padding-right: 2px;
}

/* 6. 常用英雄 */
.bp-player-card__champions {
  margin-top: 8px;
  padding-top: 6px;
  border-top: 1px dashed var(--line);
}

.champions-label {
  display: block;
  margin-bottom: 5px;
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 700;
}

.champions-list {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 5px;
}

.bp-player-card__champion {
  display: flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
  padding: 3px 4px;
  border-radius: 4px;
  background: var(--surface-muted);
  border: 1px solid var(--line);
}

.champ-info {
  min-width: 0;
  flex: 1;
}

.champ-info b {
  display: block;
  overflow: hidden;
  color: var(--text-primary);
  font-size: 9.5px;
  font-weight: 700;
  text-overflow: ellipsis;
  white-space: nowrap;
  line-height: 1.2;
}

.champ-info em {
  display: block;
  margin-top: 1px;
  color: var(--text-secondary);
  font-size: 8.5px;
  font-style: normal;
  font-weight: 600;
}

.bp-player-card__jungle { display: grid; grid-template-columns: auto auto minmax(0, 1fr) auto; align-items: center; gap: 5px; min-height: 25px; margin-top: 7px; padding: 4px 6px; border-left: 2px solid var(--blue); color: var(--text-secondary); background: var(--blue-soft); font-size: 9px; }
.bp-player-card__jungle svg { color: var(--blue); }
.bp-player-card__jungle strong { overflow: hidden; color: var(--text-primary); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.bp-player-card__jungle small { color: var(--text-muted); font-size: 8px; white-space: nowrap; }
.bp-player-card__jungle[data-style="tempo"] { border-left-color: var(--red); background: var(--red-soft); }
.bp-player-card__jungle[data-style="tempo"] svg { color: var(--red); }
.bp-player-card__jungle[data-style="farm"] { border-left-color: var(--green); background: var(--green-soft); }
.bp-player-card__jungle[data-style="farm"] svg { color: var(--green); }

/* 7. 标签区：chip 的尺寸/配色统一由 styles/main.css 的 .tag-chip 负责，
   这里只保留分区本身的分隔线。 */
.bp-player-card__tags {
  margin-top: 8px;
  padding-top: 6px;
  border-top: 1px dashed var(--line);
}

/* 针对双列模式微调：两行排列，保证在狭窄列宽下绝不重叠 */
@media (min-width: 0px) {
  .bp-player-card__recent:not(.bp-player-card__recent--single) .recent-match-row {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    justify-content: center;
    padding: 3px 5px;
    gap: 2px;
    min-height: 38px;
  }

  .bp-player-card__recent:not(.bp-player-card__recent--single) .match-left {
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }

  .bp-player-card__recent:not(.bp-player-card__recent--single) .recent-match-row > :first-child {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .bp-player-card__recent:not(.bp-player-card__recent--single) .match-kda-box {
    margin-left: auto;
  }

  .bp-player-card__recent:not(.bp-player-card__recent--single) .recent-match-row > :nth-child(2) {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 4px;
    padding-top: 1px;
    border-top: 1px dotted color-mix(in srgb, var(--line) 60%, transparent);
  }

  .bp-player-card__recent:not(.bp-player-card__recent--single) .bp-player-card__recent-mode {
    font-size: 9px;
  }

  .bp-player-card__recent:not(.bp-player-card__recent--single) .bp-player-card__recent-time {
    flex-direction: row;
    align-items: baseline;
    gap: 3px;
    font-size: 8.5px;
  }
}
</style>
