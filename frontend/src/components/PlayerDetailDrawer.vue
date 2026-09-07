<script setup lang="ts">
import { BarChart3, Eye, Link2, MapPinned, Maximize2, Minimize2 } from "@lucide/vue";
import { NButton, NDrawer, NDrawerContent } from "naive-ui";
import { computed, ref, watch } from "vue";
import { useRouter } from "vue-router";
import type { EncounterRecord, MatchSummary, PlayerProfile, PlayerTag, RecentMatch } from "../types/domain";
import type { LiveLobby } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import EncounterMatchModal from "./EncounterMatchModal.vue";
import MatchDetailCard from "./MatchDetailCard.vue";
import { championImage, percent, rankName, roleName } from "../utils/format";
import { backend } from "../services/backend";

const props = defineProps<{ show: boolean; player: PlayerProfile | null; lobby?: LiveLobby | null }>();
const emit = defineEmits<{ "update:show": [value: boolean] }>();
const full = ref(false);
const encounterRecords = ref<EncounterRecord[]>([]);
const encounterLoading = ref(false);
const detailedMatches = ref<MatchSummary[]>([]);
const matchesLoading = ref(false);
const matchesError = ref("");
const expandedMatchId = ref<number | null>(null);
const selectedEncounterRecords = ref<EncounterRecord[]>([]);
const encounterModalOpen = ref(false);
const router = useRouter();
const lobbyTeams = computed(() => {
  if (!props.lobby) return [];
  if (props.lobby.teams?.length) return props.lobby.teams.filter((team) => team.players.length);
  return [
    { id: "ally", label: "我方阵容", side: "ally", players: props.lobby.ally, summary: props.lobby.allySummary },
    { id: "enemy", label: "敌方阵容", side: "enemy", players: props.lobby.enemy, summary: props.lobby.enemySummary },
  ].filter((team) => team.players.length);
});
const lobbyPlayers = computed(() => lobbyTeams.value.flatMap((team) => team.players));
const encounterGames = computed(() => {
  if (!props.player || !encounterRecords.value.length) return [];
  const target = props.player.puuid;
  const games = new Map<number, EncounterRecord[]>();
  for (const record of encounterRecords.value) {
    if (Number(props.lobby?.id) === record.gameId) continue;
    const list = games.get(record.gameId) ?? [];
    list.push(record);
    games.set(record.gameId, list);
  }
  return [...games.entries()]
    .filter(([, records]) => records.some((record) => record.puuid === target))
    .sort((left, right) => (right[1][0]?.encounteredAt ?? "").localeCompare(left[1][0]?.encounteredAt ?? ""))
    .map(([gameId, records]) => ({ gameId, target: records.find((record) => record.puuid === target)!, records }));
});
const latestEncounterGame = computed(() => encounterGames.value[0] ?? null);
const drawerMatches = computed<Array<MatchSummary | RecentMatch>>(() => detailedMatches.value.length ? detailedMatches.value : props.player?.recentMatches ?? []);
function openEncounterGame(records: EncounterRecord[]) {
  selectedEncounterRecords.value = records;
  encounterModalOpen.value = true;
}
let matchesRequestId = 0;
async function loadDetailedMatches() {
  const requestId = ++matchesRequestId;
  detailedMatches.value = [];
  expandedMatchId.value = null;
  matchesError.value = "";
  matchesLoading.value = false;
  if (!props.show || !props.player) return;
  const riotId = riotIdFor(props.player);
  if (!props.player.tagLine.trim()) {
    matchesError.value = "选人阶段尚未公开完整 Riot ID，暂时只能显示当前摘要";
    return;
  }
  matchesLoading.value = true;
  try {
    const matches = await backend.matches(riotId, 0, 10);
    if (requestId === matchesRequestId) detailedMatches.value = matches;
  } catch {
    if (requestId === matchesRequestId) matchesError.value = "完整十人数据读取失败，已保留当前摘要";
  } finally {
    if (requestId === matchesRequestId) matchesLoading.value = false;
  }
}
async function loadEncounterRecords() {
  if (!props.show || !props.player?.encounterCount) {
    encounterRecords.value = [];
    return;
  }
  encounterLoading.value = true;
  try { encounterRecords.value = await backend.encounters(props.player.puuid, 100); }
  catch { encounterRecords.value = []; }
  finally { encounterLoading.value = false; }
}
watch(() => [props.show, props.player?.puuid, props.player?.encounterCount], () => { void loadEncounterRecords(); }, { immediate: true });
watch(() => [props.show, props.player?.puuid, props.player?.gameName, props.player?.tagLine], () => { void loadDetailedMatches(); }, { immediate: true });
function encounterTime(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).format(date);
}
function encounterKda(record: EncounterRecord) {
  if (record.kills === undefined || record.deaths === undefined || record.assists === undefined) return "--";
  return `${record.kills}/${record.deaths}/${record.assists}`;
}
function encounterSelfKda(record: EncounterRecord) {
  if (record.selfKills === undefined || record.selfDeaths === undefined || record.selfAssists === undefined) return "战绩待结算";
  return `${record.selfKills}/${record.selfDeaths}/${record.selfAssists}`;
}
function encounterRiotId(name?: string, tag?: string) {
  const value = name?.trim() || "未知玩家";
  return tag?.trim() ? `${value}#${tag.trim()}` : value;
}
function encounterSummary(record: EncounterRecord) {
  const relation = record.side === "ally" ? "当时队友" : "当时对手";
  const result = record.win === undefined ? "结果待结算" : record.win ? "胜" : "负";
  return `最近 ${encounterTime(record.encounteredAt)} · ${relation} · ${record.championName || "未知英雄"} ${encounterKda(record)} ${result}`;
}
function tagEvidence(tag: PlayerTag) {
  if (tag.key !== "met" || !latestEncounterGame.value) return tag.evidence;
  return encounterSummary(latestEncounterGame.value.target);
}
function toggleMatch(gameId: number) {
  expandedMatchId.value = expandedMatchId.value === gameId ? null : gameId;
}
const meterClass = (value: number) => `detail-meter--${Math.min(10, Math.max(0, Math.round(value * 10)))}`;
function riotIdFor(player: PlayerProfile) {
  const gameName = player.gameName.trim();
  const tagLine = player.tagLine.trim();
  return tagLine ? `${gameName}#${tagLine}` : gameName;
}
function openHistory(player: PlayerProfile) {
  const riotId = riotIdFor(player);
  if (!riotId) return;
  emit("update:show", false);
  void router.push({ name: "matches", query: { summoner: riotId } });
}
function sideFor(player: PlayerProfile) {
  return lobbyTeams.value.find((team) => team.players.some((item) => item.puuid === player.puuid))?.side ?? "neutral";
}
</script>

<template>
  <NDrawer :show="show" :width="full ? 'calc(100vw - 32px)' : 700" placement="right" @update:show="$emit('update:show', $event)">
    <NDrawerContent v-if="player" closable>
      <template #header><div class="player-drawer__header"><button type="button" class="player-drawer__identity" :aria-label="`查询 ${riotIdFor(player)} 的战绩`" :title="`查看 ${riotIdFor(player)} 的完整战绩`" data-testid="player-history-link" @click="openHistory(player)"><AssetIcon kind="champion" :id="player.championId" :name="player.championName" :fallback-url="championImage(player.championId)" size="xl" /><span class="player-drawer__identity-copy"><strong>{{ player.gameName }} <small v-if="player.tagLine">#{{ player.tagLine }}</small></strong><span>{{ roleName(player.assignedPosition) }} · {{ rankName(player.rankTier) }} {{ player.rankDivision }} · {{ player.leaguePoints }} LP</span></span></button><NButton class="player-drawer__history-action" secondary size="small" :aria-label="`查看更多 ${riotIdFor(player)} 的战绩`" data-testid="player-history-action" @click="openHistory(player)"><template #icon><BarChart3 :size="15" /></template>查看更多战绩</NButton><NButton quaternary size="small" :aria-label="full ? '退出全屏详情' : '进入全屏详情'" @click="full = !full"><template #icon><Minimize2 v-if="full" :size="15" /><Maximize2 v-else :size="15" /></template></NButton></div></template>
      <section class="player-drawer__overview"><div><span>评分</span><strong>{{ player.score.total.toFixed(0) }}</strong><small>置信度 {{ player.score.confidence.toFixed(0) }}%</small></div><div><span>近10场</span><strong>{{ player.recentMatches.filter((match) => match.win).length }}W {{ player.recentMatches.filter((match) => !match.win).length }}L</strong><small>完整战绩</small></div><div><span>当前英雄</span><strong>{{ player.currentChampionGames }} 场</strong><small>{{ percent(player.currentChampionWinRate) }}</small></div><div><span>位置熟练</span><strong>{{ player.positionGames }} 场</strong><small>{{ percent(player.positionWinRate) }}</small></div></section>
      <section v-if="player.tags.length || player.championPoolConcentration >= .7" class="player-drawer__section"><header><div><span class="eyebrow">PLAYER ANALYSIS</span><h3>分析标签</h3></div><span>{{ player.tags.length + (player.championPoolConcentration >= .7 ? 1 : 0) }} 个信号</span></header><div class="player-drawer__tags"><template v-for="tag in player.tags" :key="tag.key"><button v-if="tag.key === 'met' && latestEncounterGame" type="button" class="player-drawer__tag player-drawer__tag--action" data-testid="encounter-tag" @click="openEncounterGame(latestEncounterGame.records)"><strong :data-tone="tag.tone">{{ tag.label }} {{ player.encounterCount }} 次</strong><span>{{ tagEvidence(tag) }}</span><small>点击查看该局十人阵容</small></button><article v-else class="player-drawer__tag"><strong :data-tone="tag.tone">{{ tag.label }}</strong><span>{{ tagEvidence(tag) }}</span></article></template><article v-if="player.championPoolConcentration >= .7" class="player-drawer__tag"><strong data-tone="warning">英雄池集中</strong><span>单一英雄占近期样本一半以上</span></article></div></section>
      <section v-if="player.encounterCount > 0" class="player-drawer__section player-drawer__encounters">
        <header><div><span class="eyebrow">LOCAL ENCOUNTERS</span><h3>遇到过的对局</h3></div><span>最近一年 {{ encounterGames.length }} 次</span></header>
        <div v-if="encounterLoading" class="player-drawer__encounter-empty">正在读取本地记录…</div>
        <div v-else-if="!encounterGames.length" class="player-drawer__encounter-empty">暂无可展开的历史对局</div>
        <div v-else class="player-drawer__encounter-list">
          <button v-for="game in encounterGames" :key="game.gameId" type="button" class="player-drawer__encounter-game" data-testid="encounter-match-open" @click="openEncounterGame(game.records)">
            <header><div><strong>{{ encounterTime(game.target.encounteredAt) }}</strong><span>{{ game.target.queueName || "对局" }} · {{ game.target.result || "结果待结算" }}</span></div><span class="player-drawer__encounter-action"><Eye :size="13" />查看整局</span></header>
            <div class="player-drawer__encounter-versus">
              <div data-subject="self"><AssetIcon kind="champion" :id="game.target.selfChampionId || 0" :name="game.target.selfChampionName || '未知英雄'" :fallback-url="championImage(game.target.selfChampionId || 0)" size="sm" /><span><small>我</small><strong>{{ encounterRiotId(game.target.selfGameName, game.target.selfTagLine) }}</strong><b>{{ game.target.selfChampionName || "未知英雄" }} · {{ roleName(game.target.selfPosition || "") }}</b></span><em>{{ encounterSelfKda(game.target) }} {{ game.target.selfWin === undefined ? "" : game.target.selfWin ? "胜" : "负" }}</em></div>
              <i>VS</i>
              <div data-subject="target"><AssetIcon kind="champion" :id="game.target.championId" :name="game.target.championName" :fallback-url="championImage(game.target.championId)" size="sm" /><span><small>{{ game.target.side === "ally" ? "当时队友" : "当时对手" }}</small><strong>{{ encounterRiotId(game.target.gameName, game.target.tagLine) }}</strong><b>{{ game.target.championName }} · {{ roleName(game.target.position || "") }}</b></span><em>{{ encounterKda(game.target) }} {{ game.target.win === undefined ? "" : game.target.win ? "胜" : "负" }}</em></div>
            </div>
          </button>
        </div>
      </section>
      <section v-if="player.isPremade" class="player-drawer__section"><header><div><span class="eyebrow">PARTY SIGNAL</span><h3>本局开黑</h3></div><span>LCU 当前局信息</span></header><div class="player-drawer__party"><Link2 :size="16" /><span>{{ player.premadeWith.length ? `与 ${player.premadeWith.join("、")} 一起组队` : "检测到组队，但客户端未返回队友名称" }}</span></div></section>
      <section v-if="player.junglePreference" class="player-drawer__section player-drawer__jungle" data-testid="jungle-preference"><header><div><span class="eyebrow">JUNGLE PREFERENCE</span><h3><MapPinned :size="15" />打野偏好</h3></div><span>基于最近 {{ player.junglePreference.sampleSize }} 场打野</span></header><div class="player-drawer__jungle-head" :data-style="player.junglePreference.style"><div><small>风格判断</small><strong>{{ player.junglePreference.label }}</strong></div><p>{{ player.junglePreference.evidence }}</p></div><div class="player-drawer__jungle-metrics"><div><span>胜率</span><strong>{{ percent(player.junglePreference.winRate) }}</strong><small>{{ player.junglePreference.wins }} 胜 / {{ player.junglePreference.sampleSize }} 场</small></div><div><span>平均 KDA</span><strong>{{ player.junglePreference.averageKda.toFixed(1) }}</strong><small>打野样本</small></div><div><span>平均参团</span><strong>{{ percent(player.junglePreference.averageKillParticipation) }}</strong><small>击杀与助攻参与</small></div><div><span>分均补刀</span><strong>{{ player.junglePreference.averageCsPerMinute.toFixed(1) }}</strong><small>兵线与野怪合计</small></div><div><span>前期参与击杀</span><strong>{{ player.junglePreference.averageEarlyTakedowns?.toFixed(1) ?? "--" }}</strong><small>{{ player.junglePreference.averageEarlyTakedowns === null ? "SGP 暂无数据" : "场均精确挑战数据" }}</small></div><div><span>资源参与</span><strong>{{ player.junglePreference.averageObjectiveTakedowns?.toFixed(1) ?? "--" }}</strong><small>小龙 / 峡谷 / 大龙</small></div><div><span>反野数量</span><strong>{{ player.junglePreference.averageEnemyJungleMonsters?.toFixed(1) ?? "--" }}</strong><small>场均敌方野区击杀</small></div><div><span>本局英雄样本</span><strong>{{ player.junglePreference.currentChampionGames }}</strong><small>近期打野局</small></div></div><div v-if="player.junglePreference.mainChampions.length" class="player-drawer__jungle-champions"><span>常用打野</span><div><span v-for="champion in player.junglePreference.mainChampions" :key="champion.championId"><AssetIcon kind="champion" :id="champion.championId" :name="champion.championName" size="sm" /><strong>{{ champion.championName }}</strong><small>{{ champion.games }} 场 · {{ percent(champion.winRate) }}</small></span></div></div></section>
      <section class="player-drawer__section"><header><div><span class="eyebrow">SCORE EVIDENCE</span><h3>评分构成</h3></div></header><div class="player-drawer__breakdown"><div v-for="item in player.score.components" :key="item.key"><div><span>{{ item.label }}</span><b>{{ item.score.toFixed(1) }} / {{ item.maxScore }}</b></div><i :class="meterClass(item.maxScore ? item.score / item.maxScore : 0)" /><small>{{ item.evidence }}</small></div></div></section>
      <section class="player-drawer__section"><header><div><span class="eyebrow">CHAMPION POOL</span><h3>主要英雄</h3></div><span>{{ Math.round(player.championPoolConcentration * 100) }}% 集中度</span></header><div class="player-drawer__champion-list"><div v-for="champion in player.topChampions" :key="champion.championId"><AssetIcon kind="champion" :id="champion.championId" :name="champion.championName" size="md" /><strong>{{ champion.championName }}</strong><span>{{ champion.wins }} 胜</span><b>{{ champion.games }} 把</b></div></div></section>
      <section v-if="lobbyPlayers.length" class="player-drawer__section"><header><div><span class="eyebrow">CURRENT LOBBY</span><h3>本局 10 人</h3></div><span>{{ lobbyPlayers.length }} 人 · 当前玩家高亮</span></header><div class="player-drawer__lobby"><section v-for="team in lobbyTeams" :key="team.id" class="player-drawer__lobby-team" :data-side="team.side"><header><strong>{{ team.label }}</strong><span>{{ team.players.length }} 人</span></header><div class="player-drawer__lobby-list"><button v-for="item in team.players" :key="item.puuid" type="button" class="player-drawer__lobby-player" :class="{ 'player-drawer__lobby-player--self': item.puuid === player.puuid }" :data-side="sideFor(item)" @click="openHistory(item)"><AssetIcon kind="champion" :id="item.championId" :name="item.championName" :fallback-url="championImage(item.championId)" size="sm" /><span><strong>{{ item.gameName }}<em v-if="item.puuid === player.puuid">本人</em></strong><small>{{ item.championName }} · {{ roleName(item.assignedPosition) }}</small></span><b>{{ item.recentMatches.length ? percent(item.recentMatches.filter((match) => match.win).length / item.recentMatches.length) : "--" }}</b></button></div></section></div></section>
      <section class="player-drawer__section"><header><div><span class="eyebrow">LAST 10 GAMES</span><h3>完整近期战绩</h3></div><span>{{ drawerMatches.length }} 场</span></header><div v-if="matchesLoading" class="player-drawer__match-status">正在读取装备、伤害、视野、十人阵容与 BP…</div><div v-else-if="matchesError" class="player-drawer__match-status" data-tone="warning">{{ matchesError }}</div><div class="player-drawer__matches"><MatchDetailCard v-for="match in drawerMatches" :key="match.gameId" :match="match" :expanded="expandedMatchId === match.gameId" compact clickable @toggle="toggleMatch(match.gameId)" /><div v-if="!drawerMatches.length && !matchesLoading" class="player-drawer__match-status">暂无可读取的近期对局</div></div></section>
    </NDrawerContent>
  </NDrawer>
  <EncounterMatchModal v-if="player" v-model:show="encounterModalOpen" :records="selectedEncounterRecords" :target-puuid="player.puuid" />
</template>

<style scoped>
.player-drawer__header { display: flex; align-items: center; gap: 10px; min-width: 0; }
.player-drawer__identity { display: flex; flex: 1; align-items: center; gap: 10px; min-width: 0; padding: 3px; border: 1px solid transparent; border-radius: 5px; color: inherit; background: transparent; cursor: pointer; text-align: left; transition: border-color 150ms ease, background 150ms ease; }
.player-drawer__identity:hover, .player-drawer__identity:focus-visible { border-color: var(--accent); background: var(--accent-soft); outline: none; }
.player-drawer__identity-copy { min-width: 0; flex: 1; }
.player-drawer__identity-copy strong, .player-drawer__identity-copy > span { display: block; }
.player-drawer__identity-copy strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
.player-drawer__identity-copy strong small { color: var(--text-secondary); font-size: 10px; font-weight: 500; }
.player-drawer__identity-copy > span { margin-top: 4px; color: var(--text-secondary); font-size: 10px; }
.player-drawer__history-action { flex: none; }
.player-drawer__overview { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 1px; margin: 0 -4px 18px; border: 1px solid var(--line); background: var(--line); }
.player-drawer__overview > div { min-height: 72px; padding: 10px; background: var(--surface-raised); }
.player-drawer__overview span, .player-drawer__overview strong, .player-drawer__overview small { display: block; }
.player-drawer__overview span { color: var(--text-muted); font-size: 9px; }
.player-drawer__overview strong { margin-top: 8px; font-size: 17px; }
.player-drawer__overview small { margin-top: 3px; color: var(--text-secondary); font-size: 9px; }
.player-drawer__section { padding: 15px 0; border-top: 1px solid var(--line); }
.player-drawer__section header { display: flex; justify-content: space-between; align-items: flex-end; margin-bottom: 12px; color: var(--text-secondary); font-size: 10px; }
.player-drawer__section h3 { margin: 3px 0 0; color: var(--text-primary); font-size: 14px; }
.player-drawer__tags { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 7px; }
.player-drawer__tag { display: grid; gap: 5px; min-width: 0; padding: 9px 10px; border: 1px solid var(--line); color: inherit; background: var(--surface-raised); text-align: left; }
.player-drawer__tag--action { cursor: pointer; transition: border-color 140ms ease, background 140ms ease; }
.player-drawer__tag--action:hover, .player-drawer__tag--action:focus-visible { border-color: var(--accent); background: var(--accent-soft); outline: none; }
.player-drawer__tags strong { width: fit-content; padding: 3px 5px; border-radius: 3px; color: var(--blue); background: var(--blue-soft); font-size: 10px; }
.player-drawer__tags strong[data-tone="success"] { color: var(--green); background: var(--green-soft); }
.player-drawer__tags strong[data-tone="warning"] { color: var(--amber); background: var(--amber-soft); }
.player-drawer__tags strong[data-tone="danger"] { color: var(--red); background: var(--red-soft); }
.player-drawer__tags span { color: var(--text-secondary); font-size: 9px; line-height: 1.45; }
.player-drawer__tags small { color: var(--accent); font-size: 8px; }
.player-drawer__encounter-empty { padding: 12px; border: 1px dashed var(--line-strong); color: var(--text-secondary); font-size: 10px; }
.player-drawer__encounter-list { display: grid; gap: 8px; }
.player-drawer__encounter-game { width: 100%; padding: 9px 10px; border: 1px solid var(--line); color: inherit; background: var(--surface-raised); cursor: pointer; text-align: left; transition: border-color 140ms ease, background 140ms ease; }
.player-drawer__encounter-game:hover, .player-drawer__encounter-game:focus-visible { border-color: var(--accent); background: color-mix(in srgb, var(--accent-soft) 45%, var(--surface-raised)); outline: none; }
.player-drawer__encounter-game > header { align-items: center; margin-bottom: 9px; }
.player-drawer__encounter-game > header > div { min-width: 0; }
.player-drawer__encounter-game > header strong { color: var(--text-primary); font-size: 11px; }
.player-drawer__encounter-game > header span { display: block; margin-top: 3px; font-size: 9px; }
.player-drawer__encounter-game > header .player-drawer__encounter-action { display: inline-flex; align-items: center; gap: 4px; margin-top: 0; color: var(--accent); font-weight: 700; }
.player-drawer__encounter-versus { display: grid; grid-template-columns: minmax(0, 1fr) 24px minmax(0, 1fr); align-items: stretch; gap: 5px; }
.player-drawer__encounter-versus > div { display: grid; grid-template-columns: 30px minmax(0, 1fr); align-items: center; gap: 7px; min-width: 0; padding: 7px; border-left: 2px solid var(--blue); background: var(--surface); }
.player-drawer__encounter-versus > div[data-subject="target"] { border-left-color: var(--red); }
.player-drawer__encounter-versus > i { align-self: center; color: var(--text-muted); font-size: 8px; font-style: normal; font-weight: 700; text-align: center; }
.player-drawer__encounter-versus span { min-width: 0; }
.player-drawer__encounter-versus span small, .player-drawer__encounter-versus span strong, .player-drawer__encounter-versus span b { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.player-drawer__encounter-versus span small { color: var(--text-muted); font-size: 7px; }
.player-drawer__encounter-versus span strong { margin-top: 2px; font-size: 9px; }
.player-drawer__encounter-versus span b { margin-top: 2px; color: var(--text-secondary); font-size: 8px; font-weight: 500; }
.player-drawer__encounter-versus em { grid-column: 1 / -1; color: var(--text-secondary); font-size: 8px; font-style: normal; font-variant-numeric: tabular-nums; }
.player-drawer__party { display: flex; align-items: center; gap: 8px; padding: 10px; border: 1px solid var(--line); color: var(--blue); background: var(--blue-soft); font-size: 10px; }
.player-drawer__jungle h3 { display: flex; align-items: center; gap: 6px; }
.player-drawer__jungle-head { display: grid; grid-template-columns: 150px minmax(0, 1fr); align-items: center; gap: 12px; padding: 9px 10px; border-left: 3px solid var(--blue); background: var(--blue-soft); }
.player-drawer__jungle-head[data-style="tempo"] { border-left-color: var(--red); background: var(--red-soft); }
.player-drawer__jungle-head[data-style="farm"] { border-left-color: var(--green); background: var(--green-soft); }
.player-drawer__jungle-head small, .player-drawer__jungle-head strong { display: block; }
.player-drawer__jungle-head small { color: var(--text-muted); font-size: 8px; }
.player-drawer__jungle-head strong { margin-top: 3px; font-size: 14px; }
.player-drawer__jungle-head p { margin: 0; color: var(--text-secondary); font-size: 9px; line-height: 1.5; }
.player-drawer__jungle-metrics { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 1px; margin-top: 8px; border: 1px solid var(--line); background: var(--line); }
.player-drawer__jungle-metrics > div { min-height: 66px; padding: 8px; background: var(--surface-raised); }
.player-drawer__jungle-metrics span, .player-drawer__jungle-metrics strong, .player-drawer__jungle-metrics small { display: block; }
.player-drawer__jungle-metrics span { color: var(--text-muted); font-size: 8px; }
.player-drawer__jungle-metrics strong { margin-top: 5px; font-size: 14px; font-variant-numeric: tabular-nums; }
.player-drawer__jungle-metrics small { margin-top: 3px; color: var(--text-secondary); font-size: 8px; }
.player-drawer__jungle-champions { display: grid; grid-template-columns: 70px minmax(0, 1fr); align-items: center; gap: 8px; margin-top: 8px; color: var(--text-secondary); font-size: 9px; }
.player-drawer__jungle-champions > div { display: flex; flex-wrap: wrap; gap: 5px; }
.player-drawer__jungle-champions > div > span { display: grid; grid-template-columns: 26px auto; align-items: center; gap: 2px 6px; min-width: 125px; padding: 4px 6px; border: 1px solid var(--line); background: var(--surface-raised); }
.player-drawer__jungle-champions .asset-icon { grid-row: span 2; }
.player-drawer__jungle-champions strong { font-size: 9px; }
.player-drawer__jungle-champions small { color: var(--text-muted); font-size: 8px; }
.player-drawer__breakdown { display: grid; gap: 10px; }
.player-drawer__breakdown > div > div { display: flex; justify-content: space-between; color: var(--text-secondary); font-size: 10px; }
.player-drawer__breakdown b { color: var(--text-primary); font-variant-numeric: tabular-nums; }
.player-drawer__breakdown i { display: block; height: 5px; margin-top: 5px; background: var(--accent); transform-origin: left; }
.player-drawer__breakdown i[class*="--0"] { transform: scaleX(.05); }.player-drawer__breakdown i[class*="--1"] { transform: scaleX(.15); }.player-drawer__breakdown i[class*="--2"] { transform: scaleX(.25); }.player-drawer__breakdown i[class*="--3"] { transform: scaleX(.35); }.player-drawer__breakdown i[class*="--4"] { transform: scaleX(.45); }.player-drawer__breakdown i[class*="--5"] { transform: scaleX(.55); }.player-drawer__breakdown i[class*="--6"] { transform: scaleX(.65); }.player-drawer__breakdown i[class*="--7"] { transform: scaleX(.75); }.player-drawer__breakdown i[class*="--8"] { transform: scaleX(.85); }.player-drawer__breakdown i[class*="--9"] { transform: scaleX(.95); }.player-drawer__breakdown i[class*="--10"] { transform: scaleX(1); }
.player-drawer__breakdown small { display: block; margin-top: 4px; color: var(--text-muted); font-size: 9px; }
.player-drawer__champion-list { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 7px; }
.player-drawer__champion-list > div { display: grid; grid-template-columns: 34px minmax(0, 1fr); align-items: center; gap: 5px; padding: 7px; border: 1px solid var(--line); background: var(--surface-raised); }
.player-drawer__champion-list strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 10px; }
.player-drawer__champion-list span, .player-drawer__champion-list b { grid-column: 2; font-size: 9px; }
.player-drawer__champion-list span { color: var(--text-secondary); }.player-drawer__champion-list b { color: var(--green); }
 .player-drawer__lobby { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }.player-drawer__lobby-team { min-width: 0; padding: 6px; border: 1px solid var(--line); border-top: 2px solid var(--blue); background: var(--surface); }.player-drawer__lobby-team[data-side="enemy"] { border-top-color: var(--red); }.player-drawer__lobby-team > header { display: flex; align-items: center; justify-content: space-between; margin: 0 0 5px; color: var(--text-secondary); font-size: 8px; }.player-drawer__lobby-team > header strong { color: var(--text-primary); font-size: 9px; }.player-drawer__lobby-list { display: grid; gap: 3px; }.player-drawer__lobby-player { display: grid; grid-template-columns: 26px minmax(0, 1fr) auto; align-items: center; gap: 6px; min-width: 0; padding: 6px; border: 1px solid var(--line); color: var(--text-primary); background: var(--surface-raised); cursor: pointer; text-align: left; }.player-drawer__lobby-player:hover { border-color: var(--accent); }.player-drawer__lobby-player > span { min-width: 0; }.player-drawer__lobby-player strong, .player-drawer__lobby-player small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.player-drawer__lobby-player strong { font-size: 9px; }.player-drawer__lobby-player small { margin-top: 2px; color: var(--text-secondary); font-size: 8px; }.player-drawer__lobby-player b { color: var(--green); font-size: 9px; font-variant-numeric: tabular-nums; }
.player-drawer__lobby-player strong em { display: inline-flex; margin-left: 4px; padding: 1px 3px; border-radius: 2px; color: var(--accent); background: var(--accent-soft); font-size: 7px; font-style: normal; font-weight: 700; }.player-drawer__lobby-player--self { border-color: var(--accent); box-shadow: inset 3px 0 0 var(--accent); background: color-mix(in srgb, var(--accent-soft) 55%, var(--surface-raised)); }.player-drawer__match-status { margin-bottom: 7px; padding: 9px 10px; border: 1px dashed var(--line-strong); color: var(--text-secondary); background: var(--surface-raised); font-size: 9px; }.player-drawer__match-status[data-tone="warning"] { color: var(--amber); }.player-drawer__matches { display: grid; gap: 7px; min-width: 0; overflow: hidden; }.player-drawer__matches :deep(.match-row--compact) { grid-template-areas: "identity kda metrics toggle" "items items traits toggle"; grid-template-columns: minmax(180px, .9fr) minmax(92px, .45fr) minmax(260px, 1.4fr) 28px; gap: 5px 7px; width: 100%; min-width: 0; padding: 8px 8px 7px 10px; }.player-drawer__matches :deep(.match-row--compact .match-row__traits) { display: flex; align-items: center; gap: 7px; min-width: 0; }.player-drawer__matches :deep(.match-row--compact .match-row__badges) { flex-wrap: nowrap; }.player-drawer__matches :deep(.match-row--compact .match-row__items) { min-width: 0; padding-top: 0; border-top: 0; }.player-drawer__matches :deep(.match-row--compact .match-row__items > span) { display: none; }.player-drawer__matches :deep(.match-row--compact .match-row__item-list) { flex-wrap: nowrap; gap: 3px; min-width: 0; overflow: hidden; }.player-drawer__matches :deep(.match-row--compact .match-row__item-slot) { width: 22px; height: 22px; font-size: 6px; }.player-drawer__matches :deep(.match-row--compact .asset-icon--sm) { width: 22px; height: 22px; }.player-drawer__matches :deep(.match-row--compact .match-row__metrics) { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 3px 5px; }.player-drawer__matches :deep(.match-row--compact .match-row__stat) { grid-template-columns: 12px minmax(14px, 1fr) minmax(28px, auto) 20px; gap: 2px; }.player-drawer__matches :deep(.match-row--compact .match-row__stat strong) { font-size: 9px; }.player-drawer__matches :deep(.match-row--compact .match-row__stat small) { width: 20px; font-size: 7px; }.player-drawer__matches :deep(.match-row--compact .match-row__detail) { min-width: 0; overflow: hidden; }
 @media (max-width: 560px) { .player-drawer__lobby, .player-drawer__tags { grid-template-columns: 1fr; }.player-drawer__jungle-head { grid-template-columns: 1fr; }.player-drawer__jungle-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
</style>
