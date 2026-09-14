<script setup lang="ts">
import { BarChart3, Link2, MapPinned, Maximize2, Minimize2 } from "@lucide/vue";
import { NButton, NDrawer, NDrawerContent } from "naive-ui";
import { useQuery } from "@tanstack/vue-query";
import { computed, nextTick, ref, watch } from "vue";
import { useRouter } from "vue-router";
import type { EncounterRecord, MatchSummary, PlayerProfile, RecentMatch } from "../types/domain";
import type { LiveLobby } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import EncounterMatchModal from "./EncounterDetails.vue";
import MatchDetailCard from "./MatchDetailCard.vue";
import PlayerTagArea from "../tags/components/PlayerTagArea.vue";
import PlayerTagMetPopover from "../tags/components/PlayerTagMetPopover.vue";
import { championImage, percent, rankName, roleName } from "../utils/format";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import { matchHistoryQueryKey } from "../matches/query";
import { useEncounters } from "../composables/useEncounters";
import { useMatchDetail } from "../composables/useMatchDetail";
import { encounterGames as groupEncounters } from "../encounters/records";

const props = defineProps<{
  show: boolean;
  player: PlayerProfile | null;
  lobby?: LiveLobby | null;
  initialMatchId?: number | null;
  suppressEncounters?: boolean;
  localPlayer?: PlayerProfile | null;
  playerNotes?: string[];
  canEditNotes?: boolean;
}>();
const emit = defineEmits<{
  "update:show": [value: boolean];
  "edit-notes": [player: PlayerProfile];
}>();
const app = useAppStore();
const full = ref(false);

const expandedMatchId = ref<number | null>(null);
/** 已经自动展开过的 initialMatchId；避免后台刷新数据时把用户手动收起的行再次弹开。 */
let autoExpandedMatchId: number | null = null;
const matchesSection = ref<HTMLElement | null>(null);
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
const encounterQuery = useEncounters(
  () => props.player?.puuid ?? "",
  () => Boolean(props.show && props.player && !props.suppressEncounters),
  () => Number(props.lobby?.id) || 0,
  () => props.lobby?.generatedAt ?? props.player?.dataStatus?.fetchedAt ?? "",
);
const encounterGames = computed(() => groupEncounters(encounterQuery.data.value ?? [], props.player?.puuid ?? "", Number(props.lobby?.id) || 0));
const encounterLoading = encounterQuery.isFetching;
const selectedMatchPage = computed(() => {
  if (!props.player || props.initialMatchId == null) return 0;
  const index = props.player.recentMatches.findIndex((match) => match.gameId === props.initialMatchId);
  return index < 0 ? 0 : Math.floor(index / DRAWER_PAGE_SIZE);
});
/**
 * 抽屉里的战绩分页。
 *
 * 之前这里固定只拉一页（10 场），于是抽屉顶部的「N 场」永远停在 10，
 * 外面战绩页能一直翻、抽屉里却看不到多出来的那些。
 *
 * 现在按「已加载页数」累积：默认 1 页，点「加载更多」再加一页；
 * 目标那一局（`initialMatchId`）所在的页会被自动补上，否则自动展开会落空。
 */
const DRAWER_PAGE_SIZE = 10;
/**
 * 上限 5 页 = 50 场。后端 `getMatches` 把 LCU 的历史窗口固定成
 * `begIndex=0&endIndex=49` 再本地切片，第 6 页起必然是空的，所以不给出这个按钮。
 */
const DRAWER_MAX_PAGES = 5;
const drawerPages = ref(1);
const requiredDrawerPages = computed(() => Math.min(DRAWER_MAX_PAGES, selectedMatchPage.value + 1));
watch(requiredDrawerPages, (value) => {
  if (value > drawerPages.value) drawerPages.value = value;
}, { immediate: true });
/** 最后一页刚好装满才认为后面还有，和后端「按页切片」的口径一致。 */
function loadMoreDrawerMatches() {
  if (drawerPages.value < DRAWER_MAX_PAGES) drawerPages.value += 1;
}
const selectedRiotId = computed(() => props.player ? riotIdFor(props.player) : "");
const detailedMatchQuery = useQuery({
  queryKey: computed(() => matchHistoryQueryKey({
    mode: app.mode,
    platformId: app.connection.platformId,
    gameName: app.connection.gameName,
    tagLine: app.connection.tagLine,
    summonerName: selectedRiotId.value,
    // 以「已加载条数」当分页维度：键随加载深度变化，缓存按深度区分。
    page: 0,
    pageSize: drawerPages.value * DRAWER_PAGE_SIZE,
    hideUnfinishedMatches: app.config.providers.hideUnfinishedMatches,
    rankedOnly: app.config.providers.rankedOnly,
  })),
  queryFn: () => {
    const summoner = selectedRiotId.value;
    if (!summoner) return Promise.resolve<MatchSummary[]>([]);
    // 后端总是先拉满 LCU 的 50 场窗口再本地切片，所以一次要「已加载条数」就够：
    // 按页并发再拼会把同一份窗口重复拉 N 次，拼接处还会重叠。
    return backend.matches(summoner, 0, drawerPages.value * DRAWER_PAGE_SIZE);
  },
  enabled: computed(() => Boolean(props.show && props.player?.tagLine.trim() && selectedRiotId.value)),
  staleTime: 60_000,
  retry: 1,
});
const detailedMatches = computed(() => detailedMatchQuery.data.value ?? []);
const matchesLoading = computed(() => detailedMatchQuery.isLoading.value);
/** 最后一页刚好装满才认为后面还有，和后端「按页切片」的口径一致。 */
const drawerHasMore = computed(() => drawerPages.value < DRAWER_MAX_PAGES && detailedMatches.value.length >= drawerPages.value * DRAWER_PAGE_SIZE);
const matchesError = computed(() => {
  if (props.player && !props.player.tagLine.trim()) return "选人阶段尚未公开完整 Riot ID，暂时只能显示当前摘要";
  return detailedMatchQuery.isError.value ? "完整十人数据读取失败，已保留当前摘要" : "";
});
/**
 * 展开的那一局单独去拿完整十人数据。
 *
 * LCU 的战绩**列表**接口 `/lol-match-history/v1/products/lol/{puuid}/matches`
 * 每局只带查询者本人的一条 `participants`（实测本机缓存 32/32 局都是 1 条），
 * 所以列表里的 MatchSummary 直接拿来渲染「十人阵容」只会显示一个人。
 */
const expandedMatchDetail = useMatchDetail({
  gameId: expandedMatchId,
  subjectPuuid: computed(() => props.player?.puuid ?? ""),
  // 账号归属（后端 AccountChanged 校验）用连接信息里的 puuid；旧快照可能没有，
  // 再退回本局识别出来的本人。
  selfPuuid: computed(() => app.connection.puuid ?? props.localPlayer?.puuid ?? props.player?.puuid ?? ""),
  enabled: computed(() => props.show),
});
const { matchForRow, loading: expandedDetailLoading, error: expandedDetailError } = expandedMatchDetail;
const drawerMatches = computed<Array<MatchSummary | RecentMatch>>(() => detailedMatches.value.length ? detailedMatches.value : props.player?.recentMatches ?? []);
function openEncounterGame(records: EncounterRecord[]) {
  selectedEncounterRecords.value = records;
  encounterModalOpen.value = true;
}
/**
 * 换人或关抽屉时清空展开态。
 *
 * 注意必须写成「多个 source 的数组」而不是「一个返回数组的 getter」：
 * `() => [a, b]` 每次求值都是新数组，Vue 用 `Object.is` 比较整个返回值，永远算「变了」；
 * 而 LiveView 的 roster 轮询（1.2~1.5s）会不断替换 `props.player` 的对象引用，
 * 于是这个 watch 每秒都会误触发，把用户刚手动展开的那一局收回 `null`。
 * 多 source 数组由 Vue 逐元素比较，只有 show / puuid 真的变了才触发。
 * （LeagueAkari 的 `watch([puuid, () => me.puuid], ...)` 也是这个写法。）
 */
watch([() => props.show, () => props.player?.puuid], () => {
  expandedMatchId.value = null;
  autoExpandedMatchId = null;
  encounterModalOpen.value = false;
  selectedEncounterRecords.value = [];
  // 换人后分页回到第一页；目标那一局的页会由 `requiredDrawerPages` 再补回来。
  drawerPages.value = 1;
});
/** 下一帧；`requestAnimationFrame` 在部分测试环境里不存在，退化成定时器。 */
function nextFrame(callback: () => void) {
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(callback);
  else window.setTimeout(callback, 16);
}
/**
 * 把抽屉滚到对应那一局。
 *
 * 之前滚的是「完整近期战绩」这个 section（`matchesSection`）本身，所以最多只滚到
 * 列表顶部；用户点的那一行可能排在很后面（第 20、30 场），根本没进视野。
 * 要滚的是那一行自己的元素（`MatchDetailCard` 根节点上的 `data-game-id`）。
 *
 * 另外两件事让这个动作不能只做一次：
 * - 目标行要等分页数据回来才渲染，所以先按帧等它出现；
 * - 抽屉自身的进入动画会在之后再次改变布局，所以落位后再补一次。
 *
 * 容器没了（抽屉已关 / 组件已卸载）就立刻收手，避免留下一串空转的定时器。
 */
function scrollToMatchInDrawer(gameId: number, attempt = 0) {
  void nextTick(() => {
    const section = matchesSection.value;
    if (!section) return;
    const row = section.querySelector<HTMLElement>(`[data-game-id="${gameId}"]`);
    if (!row) {
      if (attempt < 8) nextFrame(() => scrollToMatchInDrawer(gameId, attempt + 1));
      return;
    }
    row.scrollIntoView?.({ behavior: "smooth", block: "center" });
    if (attempt === 0) window.setTimeout(() => scrollToMatchInDrawer(gameId, 1), 320);
  });
}
watch([() => props.show, () => props.initialMatchId, () => detailedMatchQuery.data.value], async () => {
  if (!props.show || props.initialMatchId == null || autoExpandedMatchId === props.initialMatchId) return;
  const matches = detailedMatchQuery.data.value;
  if (!matches?.some((match) => match.gameId === props.initialMatchId)) return;
  autoExpandedMatchId = props.initialMatchId;
  expandedMatchId.value = props.initialMatchId;
  scrollToMatchInDrawer(props.initialMatchId);
}, { immediate: true });
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
  <NDrawer :show="show" :width="full ? 'calc(100vw - 8px)' : 'min(1120px, calc(100vw - 24px))'" placement="right" @update:show="$emit('update:show', $event)">
    <NDrawerContent v-if="player" closable>
      <template #header><div class="player-drawer__header"><button type="button" class="player-drawer__identity" :aria-label="`查询 ${riotIdFor(player)} 的战绩`" :title="`查看 ${riotIdFor(player)} 的完整战绩`" data-testid="player-history-link" @click="openHistory(player)"><AssetIcon kind="champion" :id="player.championId" :name="player.championName" :fallback-url="championImage(player.championId)" size="xl" /><span class="player-drawer__identity-copy"><strong>{{ player.gameName }} <small v-if="player.tagLine">#{{ player.tagLine }}</small></strong><span>{{ roleName(player.assignedPosition) }} · {{ rankName(player.rankTier) }} {{ player.rankDivision }} · {{ player.leaguePoints }} LP</span></span></button><NButton class="player-drawer__history-action" secondary size="small" :aria-label="`查看更多 ${riotIdFor(player)} 的战绩`" data-testid="player-history-action" @click="openHistory(player)"><template #icon><BarChart3 :size="15" /></template>查看更多战绩</NButton><NButton quaternary size="small" :aria-label="full ? '退出全屏详情' : '进入全屏详情'" @click="full = !full"><template #icon><Minimize2 v-if="full" :size="15" /><Maximize2 v-else :size="15" /></template></NButton></div></template>
      <section class="player-drawer__overview"><div><span>评分</span><strong>{{ player.score.total.toFixed(0) }}</strong><small>置信度 {{ player.score.confidence.toFixed(0) }}%</small></div><div><span>近10场</span><strong>{{ player.recentMatches.slice(0, 10).filter((match) => match.durationMinutes > 0 && match.win).length }}W {{ player.recentMatches.slice(0, 10).filter((match) => match.durationMinutes > 0 && !match.win).length }}L</strong><small>完整战绩</small></div><div><span>当前英雄</span><strong>{{ player.currentChampionGames }} 场</strong><small>{{ percent(player.currentChampionWinRate) }}</small></div><div><span>位置熟练</span><strong>{{ player.positionGames }} 场</strong><small>{{ percent(player.positionWinRate) }}</small></div></section>
      <section class="player-drawer__section"><header><div><span class="eyebrow">玩家分析</span><h3>分析标签</h3></div><span>标注即详情，悬停查看依据</span></header><PlayerTagArea :player="player" :local-player="localPlayer" :suppress-encounters="suppressEncounters" :encounter-records="encounterQuery.data.value ?? []" :encounter-loading="encounterLoading" :encounter-error="encounterQuery.isError.value" :current-game-id="Number(lobby?.id) || 0" :player-notes="playerNotes" :can-edit-notes="canEditNotes" @select-encounter="openEncounterGame" @retry-encounters="encounterQuery.refetch()" @edit-notes="emit('edit-notes', player)" /></section>
      <section v-if="!suppressEncounters" class="player-drawer__section player-drawer__encounters">
        <header><div><span class="eyebrow">共同战绩</span><h3>遇到过的对局</h3></div><span>共同对局 {{ encounterGames.length }} 次</span></header>
        <div v-if="encounterQuery.isError.value" class="player-drawer__match-status" data-tone="warning">共同对局读取失败，<button type="button" class="player-drawer__retry" @click="encounterQuery.refetch()">重试</button></div>
        <div v-else-if="encounterLoading && !encounterGames.length" class="player-drawer__match-status">正在读取共同对局…</div>
        <PlayerTagMetPopover :games="encounterGames" :total="Math.max(encounterGames.length, player.encounterCount)" :target-name="player.gameName" :last-met-at="player.lastEncounteredAt ?? ''" hide-summary @inspect="openEncounterGame" />
      </section>
      <section v-if="player.isPremade" class="player-drawer__section"><header><div><span class="eyebrow">组队信息</span><h3>本局开黑</h3></div><span>LCU 当前局信息</span></header><div class="player-drawer__party"><Link2 :size="16" /><span>{{ player.premadeWith.length ? `与 ${player.premadeWith.join("、")} 一起组队` : "检测到组队，但客户端未返回队友名称" }}</span></div></section>
      <section v-if="player.junglePreference" class="player-drawer__section player-drawer__jungle" data-testid="jungle-preference"><header><div><span class="eyebrow">打野分析</span><h3><MapPinned :size="15" />打野偏好</h3></div><span>基于最近 {{ player.junglePreference.sampleSize }} 场打野</span></header><div class="player-drawer__jungle-head" :data-style="player.junglePreference.style"><div><small>风格判断</small><strong>{{ player.junglePreference.label }}</strong></div><p>{{ player.junglePreference.evidence }}</p></div><div class="player-drawer__jungle-metrics"><div><span>胜率</span><strong>{{ percent(player.junglePreference.winRate) }}</strong><small>{{ player.junglePreference.wins }} 胜 / {{ player.junglePreference.sampleSize }} 场</small></div><div><span>平均 KDA</span><strong>{{ player.junglePreference.averageKda.toFixed(1) }}</strong><small>打野样本</small></div><div><span>平均参团</span><strong>{{ percent(player.junglePreference.averageKillParticipation) }}</strong><small>击杀与助攻参与</small></div><div><span>分均补刀</span><strong>{{ player.junglePreference.averageCsPerMinute.toFixed(1) }}</strong><small>兵线与野怪合计</small></div><div><span>前期参与击杀</span><strong>{{ player.junglePreference.averageEarlyTakedowns?.toFixed(1) ?? "--" }}</strong><small>{{ player.junglePreference.averageEarlyTakedowns === null ? "SGP 暂无数据" : "场均精确挑战数据" }}</small></div><div><span>资源参与</span><strong>{{ player.junglePreference.averageObjectiveTakedowns?.toFixed(1) ?? "--" }}</strong><small>小龙 / 峡谷 / 大龙</small></div><div><span>反野数量</span><strong>{{ player.junglePreference.averageEnemyJungleMonsters?.toFixed(1) ?? "--" }}</strong><small>场均敌方野区击杀</small></div><div><span>本局英雄样本</span><strong>{{ player.junglePreference.currentChampionGames }}</strong><small>近期打野局</small></div></div><div v-if="player.junglePreference.mainChampions.length" class="player-drawer__jungle-champions"><span>常用打野</span><div><span v-for="champion in player.junglePreference.mainChampions" :key="champion.championId"><AssetIcon kind="champion" :id="champion.championId" :name="champion.championName" size="sm" /><strong>{{ champion.championName }}</strong><small>{{ champion.games }} 场 · {{ percent(champion.winRate) }}</small></span></div></div></section>
      <section class="player-drawer__section"><header><div><span class="eyebrow">评分依据</span><h3>评分构成</h3></div></header><div class="player-drawer__breakdown"><div v-for="item in player.score.components" :key="item.key"><div><span>{{ item.label }}</span><b>{{ item.score.toFixed(1) }} / {{ item.maxScore }}</b></div><i :class="meterClass(item.maxScore ? item.score / item.maxScore : 0)" /><small>{{ item.evidence }}</small></div></div></section>
      <section class="player-drawer__section"><header><div><span class="eyebrow">英雄池</span><h3>主要英雄</h3></div><span>{{ Math.round(player.championPoolConcentration * 100) }}% 集中度</span></header><div class="player-drawer__champion-list"><div v-for="champion in player.topChampions" :key="champion.championId"><AssetIcon kind="champion" :id="champion.championId" :name="champion.championName" size="md" /><strong>{{ champion.championName }}</strong><span>{{ champion.wins }} 胜</span><b>{{ champion.games }} 把</b></div></div></section>
      <section v-if="lobbyPlayers.length" class="player-drawer__section"><header><div><span class="eyebrow">当前阵容</span><h3>本局玩家</h3></div><span>{{ lobbyPlayers.length }} 人 · 当前玩家高亮</span></header><div class="player-drawer__lobby"><section v-for="team in lobbyTeams" :key="team.id" class="player-drawer__lobby-team" :data-side="team.side"><header><strong>{{ team.label }}</strong><span>{{ team.players.length }} 人</span></header><div class="player-drawer__lobby-list"><button v-for="item in team.players" :key="item.puuid" type="button" class="player-drawer__lobby-player" :class="{ 'player-drawer__lobby-player--self': item.puuid === player.puuid }" :data-side="sideFor(item)" @click="openHistory(item)"><AssetIcon kind="champion" :id="item.championId" :name="item.championName" :fallback-url="championImage(item.championId)" size="sm" /><span><strong>{{ item.gameName }}<em v-if="item.puuid === player.puuid">本人</em></strong><small>{{ item.championName }} · {{ roleName(item.assignedPosition) }}</small></span><b>{{ item.recentMatches.length ? percent(item.recentMatches.filter((match) => match.win).length / item.recentMatches.length) : "--" }}</b></button></div></section></div></section>
      <section ref="matchesSection" class="player-drawer__section"><header><div><span class="eyebrow">近期战绩</span><h3>完整近期战绩</h3></div><span>已加载 {{ drawerMatches.length }} 场</span></header><div v-if="matchesLoading" class="player-drawer__match-status">正在读取装备、伤害、视野、十人阵容与 BP…</div><div v-else-if="matchesError" class="player-drawer__match-status" data-tone="warning">{{ matchesError }}</div><div class="player-drawer__matches"><MatchDetailCard v-for="match in drawerMatches" :key="match.gameId" :match="matchForRow(match)" :expanded="expandedMatchId === match.gameId" :expandable="true" compact :detail-loading="expandedMatchId === match.gameId && expandedDetailLoading" :detail-error="expandedMatchId === match.gameId ? expandedDetailError : ''" @toggle="toggleMatch(match.gameId)" /><div v-if="!drawerMatches.length && !matchesLoading" class="player-drawer__match-status">暂无可读取的近期对局</div></div><div v-if="drawerHasMore" class="player-drawer__more"><NButton size="small" secondary :loading="matchesLoading" @click="loadMoreDrawerMatches">加载更多对局</NButton><small>一次 10 场，最多 50 场（LCU 战绩窗口上限）</small></div></section>
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
.player-drawer__retry { padding: 0; border: 0; color: var(--accent); background: transparent; font: inherit; cursor: pointer; text-decoration: underline; }
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
.player-drawer__more { display: flex; align-items: center; justify-content: center; gap: 8px; margin-top: 9px; }
.player-drawer__more small { color: var(--text-muted); font-size: 9px; }
 @media (max-width: 720px) { .player-drawer__lobby { grid-template-columns: 1fr; }.player-drawer__jungle-head { grid-template-columns: 1fr; }.player-drawer__jungle-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
</style>
