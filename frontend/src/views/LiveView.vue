<script setup lang="ts">
import { ClipboardCheck, Eye, Info, Maximize2, Minus, Plus, RefreshCw, Trash2, UsersRound } from "@lucide/vue";
import { NButton, NEmpty, useMessage } from "naive-ui";
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import LoadingState from "../components/LoadingState.vue";
import MatchDetailCard from "../components/MatchDetailCard.vue";
import PageHeader from "../components/PageHeader.vue";
import PlayerCard from "../components/PlayerCard.vue";
import PlayerDetailDrawer from "../components/PlayerDetailDrawer.vue";
import EncounterDetails from "../components/EncounterDetails.vue";
import { useEncounters } from "../composables/useEncounters";
import TeamSummaryCard from "../components/TeamSummaryCard.vue";
import { backend, isTauri } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { EncounterRecord, LiveLobby, LiveTeam, PlayerProfile } from "../types/domain";
import { createCoalescedAsyncRunner } from "../utils/coalescedAsync";
import { roleName } from "../utils/format";
import { enrichedRosterCoversOverlay, mergeRosterSnapshot, playerCardKey } from "../utils/liveRoster";
import { isActiveGamePhase, isCurrentLiveSnapshot, isVisibleGamePhase, shouldAutoHideLivePanel, shouldResetClearedLivePanel } from "../utils/livePanel";
import { assignPremadeTones, findLocalPlayer, isLocalPartyMember } from "../utils/premadeGroups";
import { queueLabel } from "../utils/queue";

const app = useAppStore();
const message = useMessage();
const MAX_RECENT_MATCHES = 20;
// 先展示快速阵容，再逐步补齐各玩家的段位和战绩。
const initialRosterReady = ref(!isTauri());
const lastSuccessfulLobbyRequestStartedAt = ref(0);
let forceNextLobby = false;
async function fetchLobby() {
  const startedAt = Date.now();
  const force = forceNextLobby;
  forceNextLobby = false;
  const snapshot = await backend.lobby(force);
  lastSuccessfulLobbyRequestStartedAt.value = startedAt;
  return snapshot;
}
const lobby = useQuery({
  queryKey: computed(() => ["lobby", app.mode, app.connection.platformId, app.connection.gameName, app.connection.tagLine, app.config.providers.rankedOnly]),
  queryFn: fetchLobby,
  enabled: computed(() => app.initialized && initialRosterReady.value),
  staleTime: 2000,
  refetchInterval: (query) => {
    if (query.state.data?.loading?.active) return 750;
    if (!app.initialized || app.mode !== "live") return false;
    // 选人到游戏期间连接可能短暂异常，继续轮询以便及时接入游戏阵容。
    return !app.connection.phase || isVisibleGamePhase(app.connection.phase) ? 4000 : 12000;
  },
  retry: 1,
});
const selectedIdentity = ref<Pick<PlayerProfile, "puuid" | "gameName" | "tagLine"> | null>(null);
const selectedPlayer = computed(() => {
  const identity = selectedIdentity.value;
  if (!identity) return null;
  return teams.value.flatMap((team) => team.players).find((player) => player.puuid === identity.puuid || player.rosterKey === identity.puuid
    || (identity.tagLine && player.gameName === identity.gameName && player.tagLine === identity.tagLine)) ?? null;
});
const selectedEncounterRecords = ref<EncounterRecord[]>([]);
const selectedEncounterTarget = ref("");
const encounterModalOpen = ref(false);
const selectedMatchId = ref<number | null>(null);
const drawerOpen = ref(false);
const sending = ref<string | null>(null);
const lastSentLines = ref<string[]>([]);
const lastSentLabel = ref("");
const recentMatchExpanded = ref(false);
const panelCleared = ref(false);
const showRetainedSnapshot = ref(false);
const recentLimit = ref(typeof localStorage === "undefined" ? 10 : Math.min(MAX_RECENT_MATCHES, Math.max(1, Number(localStorage.getItem("lol-desktop-live-match-count")) || 10)));
type RecentColumns = 1 | 2;
const savedRecentColumns = typeof localStorage === "undefined" ? null : localStorage.getItem("lol-desktop-live-recent-column-count");
const recentColumns = ref<RecentColumns>(savedRecentColumns === "2" ? 2 : 1);
let stopLcuEventListener: (() => void) | null = null;
let lcuEventTimer: ReturnType<typeof setTimeout> | null = null;
let rosterPollTimer: ReturnType<typeof setInterval> | null = null;
let rosterGeneration = 0;
const rosterOverlay = ref<LiveLobby | null>(null);
const rosterOverlayRequestStartedAt = ref(0);
const connectionPhaseChangedAt = ref(Date.now());
watch(() => app.config.providers.rankedOnly, () => {
  rosterGeneration += 1;
  rosterOverlay.value = null;
  selectedMatchId.value = null;
});

const liveSnapshot = computed(() => {
  const base = lobby.data.value;
  return rosterOverlay.value ? mergeRosterSnapshot(base, rosterOverlay.value) : base;
});
const snapshotIsCurrent = computed(() => {
  return isCurrentLiveSnapshot({
    snapshotPhase: liveSnapshot.value?.phase,
    basePhase: lobby.data.value?.phase,
    overlayPhase: rosterOverlay.value?.phase,
    baseRequestStartedAt: lastSuccessfulLobbyRequestStartedAt.value,
    overlayRequestStartedAt: rosterOverlayRequestStartedAt.value,
    connectionPhaseChangedAt: connectionPhaseChangedAt.value,
  });
});
const autoPanelHidden = computed(() => {
  if (!liveSnapshot.value || showRetainedSnapshot.value) return false;
  return shouldAutoHideLivePanel({
    enabled: app.config.providers.clearLobbyAfterGame,
    mode: app.mode,
    connectionStatus: app.connection.status,
    connectionPhase: app.connection.phase,
    snapshotPhase: liveSnapshot.value.phase,
    snapshotIsCurrent: snapshotIsCurrent.value,
  });
});
const panelHidden = computed(() => Boolean(liveSnapshot.value) && (panelCleared.value || autoPanelHidden.value));
const current = computed(() => panelHidden.value ? undefined : liveSnapshot.value);
const hiddenPanelDescription = computed(() => panelCleared.value
  ? "对局面板已手动清空；数据快照仍保留，可以随时恢复。"
  : "已离开结算流程，上一局面板已按设置自动清空。数据快照仍保留，可以随时查看。");
const lobbyError = computed(() => {
  const error = lobby.error.value;
  if (!error) return "当前不在可读取的对局阶段";
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "当前不在可读取的对局阶段";
});
const roleOrder: Record<string, number> = {
  TOP: 0, JUNGLE: 1, JUG: 1, MIDDLE: 2, MID: 2, BOTTOM: 3, BOT: 3, ADC: 3, UTILITY: 4, SUPPORT: 4, SUP: 4,
};
function playerRoleOrder(player: PlayerProfile) {
  const position = player.assignedPosition.trim().toUpperCase();
  if (position in roleOrder) return roleOrder[position];
  if (player.summonerSpells?.some((spell) => spell.id === 11 || /smite|惩戒/i.test(spell.name))) return 1;
  return 99;
}
function orderedPlayers(players: PlayerProfile[]) {
  return players.map((player, index) => ({ player, index })).sort((left, right) => playerRoleOrder(left.player) - playerRoleOrder(right.player) || left.index - right.index).map(({ player }) => player);
}
function shouldSortPlayers(value: LiveLobby, source: LiveTeam[]) {
  if (value.phase === "ChampSelect" || value.phase === "ReadyCheck") return false;
  const knownRoles = new Set(source.flatMap((team) => team.players).map((player) => playerRoleOrder(player)).filter((role) => role < 99));
  // 至少确认两种位置才按分路排序，避免无分路模式仅因惩戒而改变顺序。
  return knownRoles.size >= 2;
}
const teams = computed<LiveTeam[]>(() => {
  const value = current.value;
  if (!value) return [];
  const source = value.teams?.length ? value.teams : [
    { id: "ally", label: "我方阵容", side: "ally", players: value.ally, summary: value.allySummary },
    { id: "enemy", label: "敌方阵容", side: "enemy", players: value.enemy, summary: value.enemySummary },
  ];
  const sortRoles = shouldSortPlayers(value, source);
  return source.map((team) => ({ ...team, players: sortRoles ? orderedPlayers(team.players) : team.players }));
});
const classicLayout = computed(() => current.value?.layoutKind !== "arena" && teams.value.length <= 2);
const allyTeam = computed(() => teams.value.find((team) => team.side === "ally") ?? teams.value[0] ?? { id: "ally", label: "我方阵容", side: "ally", players: [], summary: current.value?.allySummary ?? null });
const enemyTeam = computed(() => teams.value.find((team) => team.side === "enemy") ?? teams.value[1] ?? { id: "enemy", label: "敌方阵容", side: "enemy", players: [], summary: current.value?.enemySummary ?? null });
const enemyPlayers = computed(() => enemyTeam.value.players);
const hasLobbyPlayers = computed(() => teams.value.some((team) => team.players.length > 0));
const premadeTones = computed(() => assignPremadeTones(teams.value.map((team) => team.players)));
const premadeTone = (player: PlayerProfile) => premadeTones.value.get(player);
const localPlayer = computed(() => findLocalPlayer(allyTeam.value.players, app.connection.gameName, app.connection.tagLine));
const encounterQuery = useEncounters(
  "", () => Boolean(current.value && app.initialized),
  () => Number(current.value?.id) || 0,
  () => teams.value.flatMap((team) => team.players).map((player) => `${player.puuid}:${player.dataStatus?.fetchedAt}:${player.recentMatches.length}`).join("|"),
);
function selectEncounter(player: PlayerProfile, records: EncounterRecord[]) {
  selectedEncounterTarget.value = player.puuid;
  selectedEncounterRecords.value = records;
  encounterModalOpen.value = true;
}
const isMyPartyMember = (player: PlayerProfile) => isLocalPartyMember(localPlayer.value, player, premadeTones.value);
const dataSource = computed(() => {
  if (current.value?.phase === "Retained") return "上一局快照";
  const player = teams.value.flatMap((team) => team.players).find((item) => item.dataStatus);
  return player?.dataStatus.isStale ? "本地旧快照" : player?.dataStatus.source === "fixture" ? "预览数据" : player?.dataStatus.source === "lcu" ? "客户端阵容 · 在线战绩" : "最新数据";
});
const phaseLabel = computed(() => {
  const phase = current.value?.phase;
  const labels: Record<string, string> = {
    ChampSelect: "禁用与选人",
    GameStart: "正在进入游戏",
    InProgress: "游戏进行中",
    Reconnect: "正在重连",
    WatchInProgress: "观战中",
    Spectating: "观战中",
    Watching: "观战中",
    PreEndOfGame: "等待结算",
    WaitingForStats: "正在结算",
    EndOfGame: "结算确认",
    Retained: "上一局",
  };
  return (phase && labels[phase]) || phase || "等待客户端";
});
const gameModeLabel = computed(() => {
  return queueLabel(current.value?.queueId ?? 0, current.value?.gameMode);
});
const dangerPoints = computed(() => {
  if (!current.value) return [];
  const points: { tone: "danger" | "warning" | "success"; title: string; detail: string }[] = [];
  const enemy = enemyPlayers.value;
  const hot = enemy.find((player) => player.tags.some((tag) => tag.key === "hot"));
  const premade = enemy.filter((player) => player.isPremade);
  const concentrated = enemy.find((player) => player.championPoolConcentration >= .7);
  if (hot) {
    const recent = hot.recentMatches.slice(0, recentLimit.value);
    points.push({ tone: "danger", title: `${roleName(hot.assignedPosition)} 位状态火热`, detail: `${hot.gameName} 近${recentLimit.value}场 ${recent.filter((match) => match.win).length} 胜，当前英雄 ${hot.currentChampionGames} 场。` });
  }
  if (premade.length >= 2) points.push({ tone: "warning", title: "敌方存在已知组队", detail: `${premade.slice(0, 2).map((player) => player.gameName).join(" + ")} 有共同组队证据。` });
  if (concentrated) points.push({ tone: "warning", title: `${roleName(concentrated.assignedPosition)} 英雄池集中`, detail: `${concentrated.gameName} 的英雄池集中度 ${Math.round(concentrated.championPoolConcentration * 100)}%，可结合 BP 针对。` });
  if (!points.length) points.push({ tone: "success", title: "暂未发现高风险玩家", detail: "当前局没有触发高连胜、组队或英雄池集中的规则。" });
  return points;
});

function selectPlayer(player: PlayerProfile) { selectedIdentity.value = { puuid: player.puuid, gameName: player.gameName, tagLine: player.tagLine }; selectedMatchId.value = null; drawerOpen.value = true; }
function selectPlayerMatch(player: PlayerProfile, gameId: number) { selectedIdentity.value = { puuid: player.puuid, gameName: player.gameName, tagLine: player.tagLine }; selectedMatchId.value = gameId; drawerOpen.value = true; }
function adjustRecentLimit(delta: number) {
  recentLimit.value = Math.min(MAX_RECENT_MATCHES, Math.max(1, recentLimit.value + delta));
  if (typeof localStorage !== "undefined") localStorage.setItem("lol-desktop-live-match-count", String(recentLimit.value));
}
const playerColumnCount = (count: number) => Math.min(5, Math.max(1, count));
function setRecentColumns(columns: RecentColumns) {
  recentColumns.value = columns;
  if (typeof localStorage !== "undefined") localStorage.setItem("lol-desktop-live-recent-column-count", String(columns));
}
function clearPanel() {
  if (!liveSnapshot.value) return;
  panelCleared.value = true;
  showRetainedSnapshot.value = false;
  drawerOpen.value = false;
  lastSentLines.value = [];
  lastSentLabel.value = "";
  message.success("对局面板已清空");
}
function showLastPanel() {
  panelCleared.value = false;
  showRetainedSnapshot.value = true;
}
async function refresh() {
  rosterGeneration += 1;
  rosterOverlay.value = null;
  rosterOverlayRequestStartedAt.value = 0;
  forceNextLobby = true;
  await refreshRosterImmediately();
  const result = await lobby.refetch();
  if (result.isError) message.error("对局刷新失败，请重试");
  else message.success(result.data?.loading?.active ? "已开始刷新玩家资料" : "对局数据已刷新");
}
async function send(kind: "ally" | "enemy" | "premade") {
  sending.value = kind;
  try {
    const lines = await backend.sendAssessments(kind);
    lastSentLines.value = lines;
    lastSentLabel.value = kind === "ally" ? "我方评估" : kind === "enemy" ? "敌方评估" : "组队信息";
    message.success(`${lines.length} 条分析已${app.mode === "live" ? "发送到聊天" : "生成预览"}`);
  }
  catch (error) { message.error(error instanceof Error ? error.message : String(error)); }
  finally { sending.value = null; }
}

const rosterRefresh = createCoalescedAsyncRunner(async () => {
  const generation = rosterGeneration;
  const startedAt = Date.now();
  try {
    const snapshot = await backend.lobbyRoster();
    if (generation === rosterGeneration) {
      rosterOverlay.value = snapshot;
      rosterOverlayRequestStartedAt.value = startedAt;
    }
  }
  catch {
    // 快速阵容失败时保留可用快照，后续仍由资料刷新恢复。
  }
});
function refreshRosterImmediately() {
  return rosterRefresh.run();
}
function updateRosterPolling(phase: string | null | undefined) {
  const active = isTauri() && app.mode === "live";
  if (rosterPollTimer) {
    clearInterval(rosterPollTimer);
    rosterPollTimer = null;
  }
  if (active) {
    rosterPollTimer = setInterval(() => void refreshRosterImmediately(), phase === "ChampSelect" || phase === "ReadyCheck" ? 750 : 1500);
  }
}
async function previewAssessments() {
  sending.value = "preview";
  try {
    const lines = await backend.previewAssessments("ally");
    lastSentLines.value = lines;
    lastSentLabel.value = "我方评估（仅生成）";
    message.success(`${lines.length} 条我方评估已生成，未发送`);
  }
  catch (error) { message.error(error instanceof Error ? error.message : String(error)); }
  finally { sending.value = null; }
}

function scheduleLobbyRefresh() {
  void refreshRosterImmediately();
  if (lcuEventTimer) clearTimeout(lcuEventTimer);
  lcuEventTimer = setTimeout(() => {
    lcuEventTimer = null;
    const generation = rosterGeneration;
    void lobby.refetch().then((result) => {
      const overlay = rosterOverlay.value;
      if (generation === rosterGeneration && result.isSuccess && overlay && enrichedRosterCoversOverlay(result.data, overlay)) {
        rosterOverlay.value = null;
        rosterOverlayRequestStartedAt.value = 0;
      }
    });
  }, 900);
}

let savedRankedOnly = app.config.providers.rankedOnly;
watch(() => app.lastSavedAt, () => {
  if (savedRankedOnly === app.config.providers.rankedOnly) return;
  savedRankedOnly = app.config.providers.rankedOnly;
  rosterGeneration += 1;
  rosterOverlay.value = null;
  scheduleLobbyRefresh();
});

watch(() => `${app.mode}/${app.connection.platformId ?? ""}/${app.connection.gameName ?? ""}#${app.connection.tagLine ?? ""}`, () => {
  rosterGeneration += 1;
  rosterOverlay.value = null;
  rosterOverlayRequestStartedAt.value = 0;
  lastSuccessfulLobbyRequestStartedAt.value = 0;
  connectionPhaseChangedAt.value = Date.now();
  selectedIdentity.value = null;
  encounterModalOpen.value = false;
  drawerOpen.value = false;
  panelCleared.value = false;
  showRetainedSnapshot.value = false;
});

watch(() => app.connection.phase, (phase, previous) => {
  updateRosterPolling(phase);
  connectionPhaseChangedAt.value = Date.now();
  if (!isVisibleGamePhase(phase) && isVisibleGamePhase(previous)) {
    rosterGeneration += 1;
    rosterOverlay.value = null;
    rosterOverlayRequestStartedAt.value = 0;
  }
  if (isActiveGamePhase(phase) && !isActiveGamePhase(previous)) {
    panelCleared.value = false;
    showRetainedSnapshot.value = false;
  }
}, { immediate: true });

watch(() => app.mode, () => updateRosterPolling(app.connection.phase));

watch(() => [liveSnapshot.value?.id, liveSnapshot.value?.phase] as const, ([gameId, phase], [previousGameId, previousPhase]) => {
  if (shouldResetClearedLivePanel({ previousGameId, gameId, previousPhase, phase })) {
    panelCleared.value = false;
    showRetainedSnapshot.value = false;
  }
});

onMounted(() => {
  // 资料尚未返回时先展示轻量阵容。
  if (isTauri()) void refreshRosterImmediately().finally(() => { initialRosterReady.value = true; });
  if (!isTauri()) return;
  const onLcuEvent = (rawEvent: Event) => {
    const event = (rawEvent as CustomEvent<{ uri: string }>).detail;
    const uri = event.uri;
    if (["/lol-gameflow/v1/gameflow-phase", "/lol-gameflow/v1/session", "/lol-champ-select/v1/session", "/lol-lobby/v2/lobby", "/lol-matchmaking/v1/ready-check", "/lol-spectator/v1/spectator/metadata", "/lol-spectator/v1/spectator/game"].includes(uri) || uri.startsWith("/lol-champ-select/v1/session/actions/")) scheduleLobbyRefresh();
  };
  window.addEventListener("lol-lcu-event", onLcuEvent);
  stopLcuEventListener = () => window.removeEventListener("lol-lcu-event", onLcuEvent);
});

onBeforeUnmount(() => {
  if (lcuEventTimer) clearTimeout(lcuEventTimer);
  if (rosterPollTimer) clearInterval(rosterPollTimer);
  rosterRefresh.dispose();
  stopLcuEventListener?.();
});
</script>

<template>
  <div class="page-shell game-page live-page">
    <PageHeader title="对局" eyebrow="实时对局工作台" :meta="`${current ? gameModeLabel : '等待对局'} · ${phaseLabel}`">
      <div class="game-page__actions"><span class="live-source" :data-source="dataSource">{{ dataSource || "等待数据" }}</span><NButton quaternary size="small" :loading="lobby.isFetching.value" @click="refresh"><template #icon><RefreshCw :size="15" /></template>刷新</NButton><NButton quaternary size="small" :disabled="!current" @click="clearPanel"><template #icon><Trash2 :size="15" /></template>清空</NButton><NButton quaternary size="small" :disabled="!current" :loading="sending === 'premade'" @click="send('premade')"><template #icon><UsersRound :size="15" /></template>组队</NButton><NButton quaternary size="small" :disabled="!current" :loading="sending === 'preview'" @click="previewAssessments"><template #icon><ClipboardCheck :size="15" /></template>评估</NButton><NButton quaternary size="small" @click="app.toggleSidebar"><template #icon><Maximize2 :size="15" /></template>腾出空间</NButton></div>
    </PageHeader>
    <LoadingState v-if="lobby.isLoading.value && !rosterOverlay" label="正在准备对局数据" />
    <div v-else-if="panelHidden" class="empty-live"><NEmpty :description="hiddenPanelDescription"><template #extra><div class="empty-live__actions"><NButton type="primary" @click="showLastPanel"><template #icon><Eye :size="15" /></template>查看上一局</NButton><NButton secondary :loading="lobby.isFetching.value" @click="refresh"><template #icon><RefreshCw :size="15" /></template>刷新状态</NButton></div></template></NEmpty></div>
    <div v-else-if="lobby.isError.value && !current" class="empty-live"><NEmpty :description="lobbyError"><template #extra><NButton type="primary" @click="refresh">重新连接</NButton></template></NEmpty></div>
    <template v-else-if="current">
      <section class="game-status-bar"><div class="game-status-bar__phase"><i class="pulse-dot" /><span>当前阶段</span><strong>{{ phaseLabel }}</strong></div><div class="game-status-bar__mode"><span>对局模式</span><strong>{{ gameModeLabel }}</strong></div><div class="game-status-bar__meta"><span v-if="current.loading" data-testid="live-loading-progress"><Info :size="14" />{{ current.loading.active ? "加载中" : "已加载" }} {{ current.loading.completed }}/{{ current.loading.total }} 人 · {{ (current.loading.elapsedMs / 1000).toFixed(1) }} 秒<template v-if="current.loading.failed"> · {{ current.loading.failed }} 人待重试</template></span><div class="game-history-stepper" aria-label="玩家战绩显示条数"><button type="button" title="减少显示条数" :disabled="recentLimit <= 1" @click="adjustRecentLimit(-1)"><Minus :size="12" /></button><strong>{{ recentLimit }} 局</strong><button type="button" title="增加显示条数" :disabled="recentLimit >= MAX_RECENT_MATCHES" @click="adjustRecentLimit(1)"><Plus :size="12" /></button></div><div class="segmented-control game-recent-column-switch" aria-label="每张玩家卡最近战绩列数"><button type="button" :class="{ active: recentColumns === 1 }" @click="setRecentColumns(1)">战绩单列</button><button type="button" :class="{ active: recentColumns === 2 }" @click="setRecentColumns(2)">战绩双列</button></div><NButton size="tiny" secondary @click="send('ally')"><template #icon><ClipboardCheck :size="14" /></template>发送我方评估</NButton></div></section>
      <section v-if="lastSentLines.length" class="sent-message-preview" aria-live="polite"><div><span class="eyebrow">{{ lastSentLabel.includes("仅生成") ? "评估结果" : "最近发送" }}</span><strong>{{ lastSentLabel }} · {{ lastSentLines.length }} 条</strong></div><pre>{{ lastSentLines.join("\n") }}</pre><NButton size="tiny" quaternary @click="lastSentLines = []">清除</NButton></section>
      <section v-if="hasLobbyPlayers" class="game-board" :data-layout="current.layoutKind || 'classic'">
        <div v-if="classicLayout" class="game-teams">
          <header class="game-team-heading game-team-heading--ally"><div><span class="side-kicker ally">我方 · {{ allyTeam.players.length }} 人</span><h2>{{ allyTeam.label }}</h2></div><strong>{{ (allyTeam.summary?.score ?? current.allySummary.score).toFixed(1) }}<small> 队伍评分</small></strong></header>
          <div class="game-player-row" :style="{ '--player-columns': playerColumnCount(allyTeam.players.length) }"><PlayerCard v-for="(player, index) in allyTeam.players" :key="playerCardKey(player, index)" :player="player" :premade-tone="premadeTone(player)" :recent-limit="recentLimit" :recent-columns="recentColumns" :suppress-encounters="isMyPartyMember(player)" data-side="ally" show-recent @select="selectPlayer" @select-match="selectPlayerMatch" :encounter-records="encounterQuery.data.value" :encounter-loading="encounterQuery.isFetching.value" :encounter-error="encounterQuery.isError.value" :current-game-id="Number(current?.id) || 0" :local-player="localPlayer" @select-encounter="selectEncounter" @retry-encounters="encounterQuery.refetch()" /></div>
          <header class="game-team-heading game-team-heading--enemy"><div><span class="side-kicker enemy">敌方 · {{ enemyTeam.players.length }} 人</span><h2>{{ enemyTeam.label }}</h2></div><strong>{{ (enemyTeam.summary?.score ?? current.enemySummary.score).toFixed(1) }}<small> 队伍评分</small></strong></header>
          <div class="game-player-row" :style="{ '--player-columns': playerColumnCount(enemyTeam.players.length) }"><PlayerCard v-for="(player, index) in enemyTeam.players" :key="playerCardKey(player, index)" :player="player" :premade-tone="premadeTone(player)" :recent-limit="recentLimit" :recent-columns="recentColumns" data-side="enemy" show-recent @select="selectPlayer" @select-match="selectPlayerMatch" :encounter-records="encounterQuery.data.value" :encounter-loading="encounterQuery.isFetching.value" :encounter-error="encounterQuery.isError.value" :current-game-id="Number(current?.id) || 0" :local-player="localPlayer" @select-encounter="selectEncounter" @retry-encounters="encounterQuery.refetch()" /></div>
        </div>
        <div v-else class="game-teams game-teams--generic">
          <section v-for="team in teams" :key="team.id" class="game-team-group" :data-side="team.side">
            <header class="game-team-heading"><div><span class="side-kicker" :class="team.side">{{ team.side === 'enemy' ? '敌方' : '我方' }} · {{ team.players.length }} 人</span><h2>{{ team.label }}</h2></div><strong v-if="team.summary">{{ team.summary.score.toFixed(1) }}<small> 队伍评分</small></strong></header>
            <div class="game-player-row" :class="{ 'game-player-row--sparse': team.players.length < 5 }" :style="{ '--player-columns': playerColumnCount(team.players.length) }"><PlayerCard v-for="(player, index) in team.players" :key="playerCardKey(player, index)" :player="player" :premade-tone="premadeTone(player)" :recent-limit="recentLimit" :recent-columns="recentColumns" :suppress-encounters="team.side === 'ally' && isMyPartyMember(player)" :data-side="team.side" show-recent @select="selectPlayer" @select-match="selectPlayerMatch" :encounter-records="encounterQuery.data.value" :encounter-loading="encounterQuery.isFetching.value" :encounter-error="encounterQuery.isError.value" :current-game-id="Number(current?.id) || 0" :local-player="localPlayer" @select-encounter="selectEncounter" @retry-encounters="encounterQuery.refetch()" /></div>
          </section>
        </div>
        <aside class="game-summary-column"><div class="game-summary-column__head"><span class="eyebrow">实时概览</span><h2>本局总结</h2><p>{{ dangerPoints.length }} 条规则命中 · {{ teams.length }} 个队伍</p></div><template v-if="classicLayout"><div class="game-summary-team game-summary-team--ally"><strong>我方总结</strong><TeamSummaryCard :summary="current.allySummary" side="ally" /></div><div class="game-summary-team game-summary-team--enemy"><strong>敌方总结</strong><TeamSummaryCard :summary="current.enemySummary" side="enemy" /></div></template><template v-else><div v-for="team in teams.filter((item) => item.summary)" :key="`summary-${team.id}`" class="game-summary-team" :class="`game-summary-team--${team.side}`"><strong>{{ team.side === 'enemy' ? '敌方总结' : '我方总结' }}</strong><TeamSummaryCard :summary="team.summary!" :side="team.side === 'enemy' ? 'enemy' : 'ally'" /></div></template><div class="game-danger-list"><article v-for="(point, index) in dangerPoints" :key="point.title" :data-tone="point.tone"><b>0{{ index + 1 }}</b><div><strong>{{ point.title }}</strong><p>{{ point.detail }}</p></div></article></div><div class="game-summary-foot"><span>快捷键</span><strong>Ctrl + F1</strong><small>随时调出对局速看</small></div></aside>
      </section>
      <section v-else class="game-history-panel">
        <header><div><span class="eyebrow">最近对局 / 回顾</span><h2>当前没有可读取的十人阵容</h2><p>{{ phaseLabel }} 阶段保留对局页；下面显示最近一局完整数据，可展开查看十人阵容与 BP。</p></div><NButton quaternary size="small" :loading="lobby.isFetching.value" @click="refresh"><template #icon><RefreshCw :size="14" /></template>刷新状态</NButton></header>
        <MatchDetailCard v-if="current.recentMatch" :match="current.recentMatch" :expanded="recentMatchExpanded" compact @toggle="recentMatchExpanded = !recentMatchExpanded" />
        <NEmpty v-else description="暂无可回看的历史对局" />
      </section>
    </template>
    <EncounterDetails v-model:show="encounterModalOpen" :records="selectedEncounterRecords" :target-puuid="selectedEncounterTarget" />
    <PlayerDetailDrawer v-model:show="drawerOpen" :player="selectedPlayer" :lobby="current" :initial-match-id="selectedMatchId" :suppress-encounters="selectedPlayer ? isMyPartyMember(selectedPlayer) : false" />
  </div>
</template>

<style scoped>
.game-page {
  container: live-layout / inline-size;
  width: 100%;
  max-width: none;
  padding: 4px 10px 10px;
}
.game-page .page-header {
  margin-bottom: 4px;
}
.game-page__actions {
  display: flex;
  align-items: center;
  gap: 6px;
}
.live-source {
  display: inline-flex;
  align-items: center;
  padding: 2px 8px;
  border-radius: 4px;
  background: var(--surface-muted);
  border: 1px solid var(--line);
  color: var(--text-secondary);
  font-size: 11px;
  font-weight: 600;
}
.game-status-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  min-height: 32px;
  padding: 4px 10px;
  margin-bottom: 6px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface-raised);
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.03);
}
.game-status-bar__phase,
.game-status-bar__mode,
.game-status-bar__meta,
.game-status-bar__meta span {
  display: flex;
  align-items: center;
  gap: 8px;
}
.pulse-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #10b981;
  box-shadow: 0 0 0 2px rgba(16, 185, 129, 0.25);
  animation: pulse-glow 2s infinite ease-in-out;
}
@keyframes pulse-glow {
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.5; transform: scale(0.85); }
}
.game-status-bar__mode {
  min-width: 0;
  padding-left: 14px;
  border-left: 1px solid var(--line);
}
.game-status-bar__mode span {
  flex: none;
  color: var(--text-muted);
  font-size: 11px;
}
.game-status-bar__mode strong {
  overflow: hidden;
  font-size: 12px;
  font-weight: 700;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.game-status-bar__meta {
  flex: 1;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 10px;
}
.game-status-bar__phase span,
.game-status-bar__meta span {
  color: var(--text-secondary);
  font-size: 11px;
}
.game-status-bar__phase strong {
  font-size: 13px;
  font-weight: 800;
  color: var(--text-primary);
}
.game-history-stepper {
  display: grid;
  grid-template-columns: 24px 44px 24px;
  align-items: center;
  height: 25px;
  border: 1px solid var(--line);
  border-radius: 4px;
  background: var(--surface);
  overflow: hidden;
}
.game-history-stepper button {
  display: grid;
  place-items: center;
  width: 24px;
  height: 23px;
  padding: 0;
  border: 0;
  color: var(--text-secondary);
  background: transparent;
  cursor: pointer;
  transition: background 0.12s, color 0.12s;
}
.game-history-stepper button:hover:not(:disabled) {
  color: var(--accent);
  background: var(--accent-soft);
}
.game-history-stepper button:disabled {
  cursor: not-allowed;
  opacity: 0.3;
}
.game-history-stepper strong {
  color: var(--text-primary);
  font-size: 10px;
  font-weight: 700;
  text-align: center;
  font-variant-numeric: tabular-nums;
}
.game-recent-column-switch {
  display: flex;
  gap: 2px;
  padding: 2px;
  border-radius: 5px;
  background: var(--surface-muted);
  border: 1px solid var(--line);
}
.game-recent-column-switch button {
  min-width: 54px;
  padding: 3px 8px;
  border: none;
  border-radius: 4px;
  background: transparent;
  color: var(--text-secondary);
  font-size: 10px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.12s;
}
.game-recent-column-switch button.active {
  background: var(--surface);
  color: var(--accent);
  font-weight: 700;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
}
.sent-message-preview {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 10px;
  margin-bottom: 6px;
  padding: 8px 12px;
  border-radius: 6px;
  border: 1px solid var(--line);
  border-left: 4px solid var(--accent);
  background: var(--surface);
}
.sent-message-preview strong {
  display: block;
  margin-top: 2px;
  font-size: 10px;
}
.sent-message-preview pre {
  max-height: 74px;
  margin: 0;
  overflow: auto;
  color: var(--text-secondary);
  font: 10px/1.45 ui-monospace, monospace;
  white-space: pre-wrap;
  word-break: break-word;
}
.game-history-panel {
  display: grid;
  gap: 12px;
  min-height: calc(100vh - 112px);
  padding: 20px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
}
.game-history-panel > header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 14px;
  padding-bottom: 14px;
  border-bottom: 1px solid var(--line);
}
.game-history-panel h2 {
  margin: 4px 0 0;
  font-size: 18px;
  font-weight: 800;
}
.game-history-panel p {
  margin: 5px 0 0;
  color: var(--text-secondary);
  font-size: 11px;
}
.game-history-panel :deep(.match-row) {
  min-width: 0;
}
.game-board {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 270px;
  gap: 10px;
  min-height: 0;
  align-items: start;
}
.game-teams {
  display: grid;
  grid-template-rows: auto auto auto auto;
  align-content: start;
  gap: 10px;
  min-width: 0;
}
.game-team-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 28px;
  padding: 4px 6px;
  border-radius: 6px;
  background: var(--surface-raised);
}
.game-team-heading h2 {
  margin: 0;
  font-size: 14px;
  font-weight: 800;
  display: inline-block;
  margin-left: 6px;
}
.side-kicker {
  display: inline-flex;
  align-items: center;
  padding: 2px 7px;
  border-radius: 4px;
  font-size: 11px;
  font-weight: 800;
  letter-spacing: 0.02em;
}
.side-kicker.ally {
  color: #fff;
  background: #2563eb;
}
.side-kicker.enemy {
  color: #fff;
  background: #dc2626;
}
.game-team-heading > strong {
  display: inline-flex;
  align-items: baseline;
  gap: 3px;
  color: var(--text-primary);
  font-size: 20px;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
}
.game-team-heading > strong small {
  color: var(--text-muted);
  font-size: 10px;
  font-weight: 600;
}
.game-team-heading--ally {
  border-left: 4px solid var(--blue);
  background: color-mix(in srgb, var(--blue) 6%, var(--surface-raised));
}
.game-team-heading--enemy {
  border-left: 4px solid var(--red);
  background: color-mix(in srgb, var(--red) 6%, var(--surface-raised));
}
.game-player-row {
  display: grid;
  grid-template-columns: repeat(var(--player-columns, 5), minmax(180px, 1fr));
  align-items: start;
  gap: 8px;
  min-width: 0;
  overflow-x: auto;
  padding-bottom: 4px;
}
.game-teams--generic {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(360px, 1fr));
  grid-template-rows: none;
  align-content: start;
  gap: 10px;
}
.game-team-group {
  display: grid;
  gap: 6px;
  min-width: 0;
  padding-top: 4px;
  border-top: 2px solid var(--line-strong);
}
.game-team-group[data-side="ally"] {
  border-top-color: var(--blue);
}
.game-team-group[data-side="enemy"] {
  border-top-color: var(--red);
}
.game-player-row--sparse {
  grid-template-columns: repeat(var(--player-columns, 5), minmax(180px, 1fr));
}
.game-summary-column {
  display: grid;
  grid-template-columns: 1fr;
  align-content: start;
  gap: 8px;
  min-width: 0;
  padding: 10px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.04);
}
.game-summary-column__head {
  padding-bottom: 8px;
  border-bottom: 1px solid var(--line);
}
.game-summary-column__head .eyebrow {
  color: var(--accent);
  font-size: 10px;
  font-weight: 800;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}
.game-summary-column__head h2 {
  margin: 2px 0 0;
  font-size: 16px;
  font-weight: 800;
}
.game-summary-column__head p {
  margin: 2px 0 0;
  color: var(--text-secondary);
  font-size: 10px;
}
.game-summary-team {
  display: grid;
  gap: 4px;
  padding: 6px 0;
  border-top: 1px solid var(--line);
}
.game-summary-team > strong {
  color: var(--text-secondary);
  font-size: 10px;
  font-weight: 700;
}
.game-summary-team--ally {
  border-top: 2px solid var(--blue);
}
.game-summary-team--enemy {
  border-top: 2px solid var(--red);
}
.game-summary-column :deep(.team-summary-card) {
  border-radius: 6px;
  padding: 8px 10px;
}
.game-danger-list {
  display: grid;
  gap: 6px;
  padding-top: 4px;
}
.game-danger-list article {
  display: grid;
  grid-template-columns: 24px 1fr;
  gap: 8px;
  padding: 8px;
  border-radius: 6px;
  border: 1px solid var(--line);
  border-left: 3px solid var(--line-strong);
  background: var(--surface-raised);
}
.game-danger-list article[data-tone="danger"] {
  border-left-color: var(--red);
  background: color-mix(in srgb, var(--red) 5%, var(--surface-raised));
}
.game-danger-list article[data-tone="warning"] {
  border-left-color: var(--amber);
  background: color-mix(in srgb, var(--amber) 5%, var(--surface-raised));
}
.game-danger-list article[data-tone="success"] {
  border-left-color: var(--green);
  background: color-mix(in srgb, var(--green) 5%, var(--surface-raised));
}
.game-danger-list b {
  color: var(--text-muted);
  font-size: 11px;
  font-weight: 800;
}
.game-danger-list strong {
  color: var(--text-primary);
  font-size: 11px;
  font-weight: 700;
}
.game-danger-list p {
  margin: 3px 0 0;
  color: var(--text-secondary);
  font-size: 9px;
  line-height: 1.35;
}
.game-summary-foot {
  display: grid;
  gap: 2px;
  padding-top: 8px;
  border-top: 1px solid var(--line);
}
.game-summary-foot span,
.game-summary-foot small {
  color: var(--text-muted);
  font-size: 9px;
}
.game-summary-foot strong {
  color: var(--accent);
  font-size: 10px;
  font-weight: 700;
}
.empty-live {
  display: grid;
  place-items: center;
  min-height: 460px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
}
.empty-live__actions {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
}
@media (max-width: 1450px) {
  .game-board {
    grid-template-columns: minmax(0, 1fr) 240px;
  }
  .game-player-row {
    gap: 6px;
  }
  .game-summary-column {
    padding: 8px;
  }
}
@media (max-width: 1150px) {
  .game-board {
    grid-template-columns: 1fr;
    min-height: 0;
  }
  .game-summary-column {
    grid-template-columns: 1fr;
  }
  .game-summary-column__head,
  .game-danger-list,
  .game-summary-foot {
    grid-column: 1;
  }
}
@container live-layout (max-width: 1220px) {
  .game-board {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
