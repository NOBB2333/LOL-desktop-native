<script setup lang="ts">
import { ChevronRight, Filter, List, MapPinned, RefreshCw, Search, Trophy } from "@lucide/vue";
import { NButton, NInput, NSelect, useMessage } from "naive-ui";
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import AssetIcon from "../components/AssetIcon.vue";
import LoadingState from "../components/LoadingState.vue";
import MatchDetailCard from "../components/MatchDetailCard.vue";
import MatchHistoryDetail from "../components/MatchHistoryDetail.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { MatchSummary, SummonerSearchCandidate, SummonerSearchResult } from "../types/domain";
import { championImage, platformRegionName, platformRegionOverview, roleName, shortDate } from "../utils/format";
import { visibleMatches } from "../matches/filters";
import { matchHistoryQueryKey } from "../matches/query";
import { useMatchDetail } from "../composables/useMatchDetail";
import { useRoute, useRouter } from "vue-router";

const app = useAppStore();
const route = useRoute();
const router = useRouter();
const message = useMessage();
const summonerQuery = ref(typeof route.query.summoner === "string" ? route.query.summoner : "");
const activeSummoner = ref(summonerQuery.value);
const page = ref(0);
const pageSize = 10;
const search = ref("");
/**
 * 查询表单的解析结果：候选「名字#TAG」列表 + 是否需要补全标签。
 *
 * 本地接口（LCU 的 `lol-summoner/v1/summoners?name=`、Riot Client 的
 * `player-account/aliases/v1/lookup`）都是**精确匹配**，没有任何 name→tags 的
 * 反向索引，所以只给名字不一定查得到；把结果留下来才能在界面上把这件事说清楚，
 * 而不是把「解析失败」伪装成「这个人没有对局」。
 */
const searchResult = ref<SummonerSearchResult | null>(null);
const searchError = ref("");
const searchPending = ref(false);
const result = ref("all");
const queue = ref("all");
const viewMode = ref<"detail" | "index">(typeof localStorage === "undefined" ? "detail" : localStorage.getItem("lol-desktop-match-view") === "index" ? "index" : "detail");
const selectedId = ref<number | null>(null);
const detailOpen = ref(true);
const expandedId = ref<number | null>(null);
const matches = useQuery({ queryKey: computed(() => matchHistoryQueryKey({ mode: app.mode, platformId: app.connection.platformId, gameName: app.connection.gameName, tagLine: app.connection.tagLine, summonerName: activeSummoner.value, page: page.value, pageSize, hideUnfinishedMatches: app.config.providers.hideUnfinishedMatches, rankedOnly: app.config.providers.rankedOnly })), queryFn: () => backend.matches(activeSummoner.value, page.value, pageSize), enabled: computed(() => app.initialized), staleTime: 60_000, refetchOnMount: true });
const rawRows = computed(() => matches.data.value ?? []);
const rows = computed(() => visibleMatches(rawRows.value, app.config.providers.hideUnfinishedMatches, app.config.providers.rankedOnly));
watch(() => [app.config.providers.hideUnfinishedMatches, app.config.providers.rankedOnly], () => {
  page.value = 0;
  queue.value = "all";
  selectedId.value = null;
});
const filtered = computed(() => rows.value.filter((match) => {
  const query = search.value.trim().toLowerCase();
  const matchesSearch = !query || match.championName.toLowerCase().includes(query) || match.queueName.toLowerCase().includes(query) || match.participants.some((participant) => participant.gameName.toLowerCase().includes(query));
  const matchesResult = result.value === "all" || (result.value === "win" ? match.result === "胜利" : result.value === "loss" ? match.result === "失败" : match.result === "未完成");
  const matchesQueue = queue.value === "all" || match.queueName === queue.value;
  return matchesSearch && matchesResult && matchesQueue;
}));
const selectedMatch = computed(() => detailOpen.value ? filtered.value.find((match) => match.gameId === selectedId.value) ?? filtered.value[0] ?? null : null);
// The header describes the loaded recent page, not the temporary search/result
// filter below it. Keep the aggregate stable while the user scans the index.
const summaryRows = computed(() => rows.value.slice(0, 10));
const completedRows = computed(() => summaryRows.value.filter((match) => match.durationMinutes > 0 && !["未完成", "待定"].includes(match.result)));
const wins = computed(() => completedRows.value.filter((match) => match.result === "胜利").length);
const averageDamage = computed(() => completedRows.value.length ? (completedRows.value.reduce((sum, match) => sum + match.damageDealt, 0) / completedRows.value.length / 1000).toFixed(1) : "0.0");
const averageKda = computed(() => completedRows.value.length ? (completedRows.value.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / completedRows.value.length).toFixed(2) : "0.00");
const queueOptions = computed(() => [{ label: "全部模式", value: "all" }, ...Array.from(new Set(rows.value.map((match) => match.queueName))).map((value) => ({ label: value, value }))]);
const hasNextPage = computed(() => rows.value.length === pageSize);

const resultLabel = (match: MatchSummary) => match.durationMinutes === 0 ? "未完成" : match.result;
const resultClass = (match: MatchSummary) => match.durationMinutes === 0 ? "unfinished" : match.result === "胜利" ? "win" : "loss";
const kda = (match: MatchSummary) => `${match.kills}/${match.deaths}/${match.assists}`;
const mvpLabel = (match: MatchSummary) => match.mvp ?? (match.performance === "carry" ? (match.result === "胜利" ? "MVP" : "SVP") : null);

function selectMatch(match: MatchSummary) {
  selectedId.value = match.gameId;
  detailOpen.value = true;
}
function setViewMode(mode: "detail" | "index") {
  viewMode.value = mode;
  detailOpen.value = true;
  if (typeof localStorage !== "undefined") localStorage.setItem("lol-desktop-match-view", mode);
}
function toggleExpanded(gameId: number) { expandedId.value = expandedId.value === gameId ? null : gameId; }
/**
 * 展开的那一行同样要单独拉完整十人数据：列表接口每局只返回查询者本人，
 * 直接用它渲染「十人阵容与 BP」只会显示一个人。
 * 行内视角取这一行自带的那个选手（列表里唯一的那条 participants 就是被查询的人）。
 */
const expandedMatchDetail = useMatchDetail({
  gameId: expandedId,
  subjectPuuid: computed(() => {
    const row = rows.value.find((match) => match.gameId === expandedId.value);
    return row?.participants[0]?.puuid ?? app.connection.puuid ?? "";
  }),
  selfPuuid: computed(() => app.connection.puuid ?? ""),
});
async function searchSummoner() {
  const query = summonerQuery.value.trim();
  searchError.value = "";
  searchResult.value = null;
  // 留空 = 恢复当前登录账号（原来是直接查，这里保持同一语义）。
  if (!query) return void applySummoner("");
  searchPending.value = true;
  try {
    const result = await backend.searchSummoner(query);
    searchResult.value = result;
    // 唯一候选：直接跳过去查，省掉一次点击。
    if (result.candidates.length === 1) return void applySummoner(riotIdOf(result.candidates[0]));
    // 完整的「名字#TAG」即使没解析出候选也值得直接交给 LCU 试一次：
    // 候选解析失败只说明 Riot Client 不可用，不代表这个人不存在。
    if (result.candidates.length === 0 && result.hasTag) return void applySummoner(query);
    // 只给名字又解析不到：不发起注定落空的查询，改为提示补全标签。
    if (result.candidates.length === 0) {
      message.warning("客户端只能精确匹配，请补全为「名字#标签」后再试");
      return;
    }
    message.info(`匹配到 ${result.candidates.length} 个账号，请选择要查询的玩家`);
  } catch (cause) {
    searchError.value = cause instanceof Error ? cause.message : String(cause);
  } finally {
    searchPending.value = false;
  }
}

/** `名字#TAG`；没有标签时退化成只用名字。 */
function riotIdOf(candidate: SummonerSearchCandidate) {
  return candidate.tagLine ? `${candidate.gameName}#${candidate.tagLine}` : candidate.gameName;
}

/** 把当前查询切到某位玩家（或空串恢复当前账号）并刷新列表。 */
async function applySummoner(riotId: string) {
  summonerQuery.value = riotId;
  activeSummoner.value = riotId;
  page.value = 0;
  selectedId.value = null;
  detailOpen.value = true;
  await router.replace({ query: riotId ? { summoner: riotId } : {} });
  await matches.refetch();
  message.success(riotId ? `已查询召唤师：${riotId}` : "已恢复当前账号战绩");
}

function pickCandidate(candidate: SummonerSearchCandidate) {
  void applySummoner(riotIdOf(candidate));
}

/** 当前登录大区，用于在大区参考里高亮。 */
const regionOverview = computed(() => platformRegionOverview(app.connection.platformId || app.connection.region));
async function refresh() { await matches.refetch(); message.success("已请求最新战绩"); }
async function goPage(next: number) { if (next < 0 || (next > page.value && !hasNextPage.value)) return; page.value = next; selectedId.value = null; detailOpen.value = true; await matches.refetch(); }

watch(filtered, (value) => {
  if (!value.some((match) => match.gameId === selectedId.value)) selectedId.value = value[0]?.gameId ?? null;
}, { immediate: true });
watch(() => route.query.summoner, (value) => { const next = typeof value === "string" ? value : ""; if (next !== activeSummoner.value) { summonerQuery.value = next; activeSummoner.value = next; page.value = 0; selectedId.value = null; } });
</script>

<template>
  <div class="page-shell matches-page matches-page--workspace">
    <PageHeader title="战绩" eyebrow="MATCH HISTORY" :meta="activeSummoner ? `Riot ID：${activeSummoner}` : '当前账号 · 以索引 + 详情方式查看最近对局'">
      <div class="matches-page-actions"><NButton quaternary size="small" :loading="matches.isFetching.value" @click="refresh"><template #icon><RefreshCw :size="14" /></template>刷新</NButton><NButton secondary size="small" @click="setViewMode(viewMode === 'detail' ? 'index' : 'detail')"><template #icon><List :size="14" /></template>{{ viewMode === "detail" ? "切换索引模式" : "返回完整列表" }}</NButton></div>
    </PageHeader>

    <section class="matches-query-panel">
      <form class="matches-query-form" @submit.prevent="searchSummoner">
        <label class="matches-query-field"><span>查询其他玩家</span><NInput v-model:value="summonerQuery" size="large" placeholder="名字，或完整的 名字#标签（例如 玩家名#12345）" clearable><template #prefix><Search :size="16" /></template></NInput></label>
        <NButton class="matches-query-submit" type="primary" size="large" attr-type="submit" :loading="searchPending">查询战绩</NButton>
        <p>先尝试解析查询：唯一命中会直接跳转；留空则恢复当前登录账号。</p>
      </form>

      <!-- 候选：名字重复时列出所有精确命中，点一下即查询。 -->
      <div v-if="searchResult && searchResult.candidates.length" class="matches-candidates">
        <span class="matches-candidates__label">精确匹配 {{ searchResult.candidates.length }} 个账号</span>
        <button v-for="candidate in searchResult.candidates" :key="candidate.puuid" type="button" class="matches-candidate" @click="pickCandidate(candidate)">
          <strong>{{ candidate.gameName }}</strong>
          <small v-if="candidate.tagLine">#{{ candidate.tagLine }}</small>
          <em v-if="candidate.puuid === app.connection.puuid">当前账号</em>
        </button>
      </div>

      <!-- 解释「为什么只给名字查不到」：客户端没有 name→tags 的反向索引。 -->
      <p v-if="searchResult?.requiresTag" class="matches-query-note" data-tone="warning">
        客户端只提供精确匹配，没有「按名字列出所有标签」的接口：只给名字时最多在
        {{ regionOverview.current ? `${regionOverview.current.id} · ${regionOverview.current.name}` : "当前大区" }}
        解析一个结果。请补全为 <b>名字#标签</b>——补全后即使是别的大区也能查到。
      </p>
      <p v-else-if="searchError" class="matches-query-note" data-tone="warning">{{ searchError }}</p>

      <!-- 可选大区：本地 API 只能读当前登录大区，这里是可查询的大区清单与编号。 -->
      <div class="matches-regions">
        <div class="matches-regions__head">
          <MapPinned :size="13" />
          <span>可选大区</span>
          <small>当前登录：{{ regionOverview.current ? `${regionOverview.current.id} · ${regionOverview.current.name}` : platformRegionName(app.connection.platformId || app.connection.region) }}</small>
        </div>
        <div class="matches-regions__groups">
          <div v-for="group in regionOverview.groups" :key="group.label" class="matches-regions__group">
            <span class="matches-regions__group-label">{{ group.label }}</span>
            <p v-for="region in group.regions" :key="region.id" :data-current="region.id === regionOverview.current?.id" :title="region.servers">
              <strong>{{ region.id }}</strong><span>{{ region.name }}</span>
            </p>
          </div>
        </div>
        <p class="matches-regions__note">大区由客户端登录状态决定，切换大区需要在客户端重新登录；跨区查战绩只需在查询框里带上完整的「名字#标签」。</p>
      </div>

      <div class="matches-filter-row">
        <div class="matches-filter-title"><Filter :size="14" /><span>当前页筛选</span></div>
        <NInput v-model:value="search" size="small" placeholder="英雄 / 模式 / 玩家" clearable />
        <NSelect v-model:value="result" size="small" :options="[{ label: '全部结果', value: 'all' }, { label: '胜利', value: 'win' }, { label: '失败', value: 'loss' }, { label: '未完成', value: 'unfinished' }]" />
        <NSelect v-model:value="queue" size="small" :options="queueOptions" />
        <span class="matches-filter-count">显示 {{ filtered.length }} 条</span>
      </div>
    </section>

    <LoadingState v-if="matches.isLoading.value" label="正在刷新完整战绩" />
    <template v-else>
      <section class="matches-summary"><div><span>最近 10 局</span><strong>{{ summaryRows.length }} <small>场</small></strong></div><div><span>胜率</span><strong>{{ completedRows.length ? Math.round(wins / completedRows.length * 100) : 0 }}<small>%</small></strong></div><div><span>平均 KDA</span><strong>{{ averageKda }}</strong></div><div><span>平均伤害</span><strong>{{ averageDamage }}<small>k</small></strong></div><div class="matches-summary__result"><Filter :size="14" /><span>{{ viewMode === "detail" ? "当前 10 局聚合 · 点击箭头展开十人阵容" : "最近 10 局聚合 · 详情随左侧选中对局更新" }}</span></div></section>
      <section v-if="viewMode === 'detail'" class="match-table-shell"><header class="match-table-heading"><div><span class="eyebrow">RECENT GAMES / DETAIL ROW</span><h2>完整对局</h2></div><span class="match-table-heading__hint">保留完整信息；点击右侧箭头展开十人阵容与 BP</span></header><div class="match-list match-list--full"><MatchDetailCard v-for="match in filtered" :key="match.gameId" :match="expandedMatchDetail.matchForRow(match)" :expanded="expandedId === match.gameId" :detail-loading="expandedId === match.gameId && expandedMatchDetail.loading.value" :detail-error="expandedId === match.gameId ? expandedMatchDetail.error.value : ''" @toggle="toggleExpanded(match.gameId)" /><div v-if="!filtered.length" class="empty-state">没有匹配的对局</div></div></section>
      <section v-else class="matches-workspace">
        <aside class="matches-index" aria-label="最近对局列表">
          <header class="matches-index__header"><div><span class="eyebrow">RECENT GAMES</span><h2>最近对局</h2></div><span>{{ filtered.length }} / {{ rows.length }}</span></header>
          <div class="matches-index__list">
            <button v-for="match in filtered" :key="match.gameId" class="history-index-row" :class="[`history-index-row--${resultClass(match)}`, { active: selectedMatch?.gameId === match.gameId } ]" type="button" @click="selectMatch(match)">
              <div class="history-index-row__top"><span>{{ shortDate(match.playedAt) }}</span><strong>{{ resultLabel(match) }}</strong></div>
              <div class="history-index-row__main"><AssetIcon kind="champion" :id="match.championId" :name="match.championName" :fallback-url="championImage(match.championId)" size="md" /><span><b>{{ match.championName }}</b><small>{{ match.queueName }} · {{ roleName(match.position) }}</small></span><em>{{ kda(match) }}</em><ChevronRight :size="14" /></div>
              <div class="history-index-row__foot"><span>{{ match.durationMinutes ? `${match.durationMinutes} 分钟` : "训练 / 未完成" }}</span><span v-if="mvpLabel(match)" class="history-index-row__mvp" :data-mvp="mvpLabel(match)" title="本地评分模型生成，并非 Riot 官方字段"><Trophy :size="12" />{{ mvpLabel(match) }}</span><span>{{ Math.round(match.killParticipation * 100) }}% 参团</span></div>
            </button>
            <div v-if="!filtered.length" class="empty-state">没有匹配的对局</div>
          </div>
        </aside>

        <section class="matches-detail-panel" aria-live="polite">
          <Transition name="history-detail" mode="out-in">
            <MatchHistoryDetail v-if="selectedMatch" :key="selectedMatch.gameId" :match="selectedMatch" @close="detailOpen = false" @exported="message.success(`已保存：${$event}`)" @export-error="message.error($event)" />
            <div v-else key="empty-detail" class="matches-detail-empty"><span class="eyebrow">MATCH DETAIL</span><h2>选择一场对局</h2><p>从左侧列表选择记录，查看装备、技能、符文、十人阵容和 BP。</p></div>
          </Transition>
        </section>
      </section>
      <footer class="matches-pagination"><span>第 {{ page + 1 }} 页 · {{ rows.length }} 场</span><div><NButton size="small" secondary :disabled="page === 0" @click="goPage(page - 1)">上一页</NButton><NButton size="small" secondary :disabled="!hasNextPage" @click="goPage(page + 1)">下一页</NButton></div></footer>
    </template>
  </div>
</template>

<style scoped>
.matches-page--workspace { width: 100%; max-width: none; }
.matches-page-actions { display: flex; align-items: center; gap: 5px; }
.matches-query-panel { display: grid; gap: 11px; margin-bottom: 14px; padding: 14px 16px; border: 1px solid var(--line); background: var(--surface); }.matches-query-form { display: grid; grid-template-columns: minmax(280px, 1fr) auto; align-items: end; gap: 10px 14px; }.matches-query-field { display: grid; gap: 5px; min-width: 0; }.matches-query-field > span { color: var(--text-primary); font-size: 11px; font-weight: 700; }.matches-query-field .n-input { width: min(100%, 620px); }.matches-query-submit { justify-self: end; min-width: 116px; }.matches-query-form > p { grid-column: 1 / -1; margin: 0; color: var(--text-secondary); font-size: 9px; }.matches-filter-row { display: grid; grid-template-columns: auto minmax(190px, 1fr) 120px 150px auto; align-items: center; gap: 7px; padding-top: 10px; border-top: 1px solid var(--line); }.matches-filter-title { display: inline-flex; align-items: center; gap: 5px; color: var(--text-muted); font-size: 9px; }.matches-filter-count { justify-self: end; color: var(--text-secondary); font-size: 9px; font-variant-numeric: tabular-nums; }
.matches-candidates { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; padding-top: 10px; border-top: 1px solid var(--line); }.matches-candidates__label { color: var(--text-muted); font-size: 9px; }.matches-candidate { display: inline-flex; align-items: center; gap: 3px; padding: 4px 9px; border: 1px solid var(--line); border-radius: 999px; color: var(--text-primary); background: var(--surface-raised); cursor: pointer; font-size: 11px; transition: border-color 140ms ease, background 140ms ease; }.matches-candidate:hover { border-color: var(--accent); background: var(--accent-soft); }.matches-candidate strong { font-weight: 700; }.matches-candidate small { color: var(--text-secondary); font-size: 10px; }.matches-candidate em { padding: 1px 5px; border-radius: 3px; color: var(--accent); background: var(--accent-soft); font-size: 8px; font-style: normal; font-weight: 700; }
.matches-query-note { margin: 0; padding: 8px 10px; border: 1px dashed var(--line-strong); border-left: 3px solid var(--amber); color: var(--text-secondary); background: var(--surface-raised); font-size: 10px; line-height: 1.5; }.matches-query-note b { color: var(--text-primary); }
.matches-regions { display: grid; gap: 7px; padding-top: 10px; border-top: 1px solid var(--line); }.matches-regions__head { display: flex; align-items: center; gap: 6px; color: var(--text-muted); font-size: 9px; }.matches-regions__head > span { color: var(--text-secondary); font-weight: 700; }.matches-regions__head > small { color: var(--text-muted); }.matches-regions__groups { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 6px 14px; }.matches-regions__group { display: grid; grid-template-columns: 58px minmax(0, 1fr); align-items: center; gap: 6px; min-width: 0; }.matches-regions__group-label { color: var(--text-muted); font-size: 9px; font-weight: 700; }.matches-regions__group p { display: inline-flex; align-items: baseline; gap: 5px; margin: 0 6px 0 0; padding: 2px 7px; border: 1px solid var(--line); border-radius: 4px; background: var(--surface-raised); font-size: 10px; }.matches-regions__group p[data-current="true"] { border-color: var(--accent); background: var(--accent-soft); }.matches-regions__group p strong { color: var(--text-primary); font-variant-numeric: tabular-nums; }.matches-regions__group p span { color: var(--text-secondary); font-size: 9px; }.matches-regions__note { margin: 0; color: var(--text-muted); font-size: 9px; line-height: 1.5; }
.matches-summary { display: grid; grid-template-columns: repeat(4, minmax(110px, 1fr)) minmax(230px, 1.4fr); gap: 1px; margin-bottom: 14px; border: 1px solid var(--line); background: var(--line); }.matches-summary > div { min-height: 70px; padding: 12px 15px; background: var(--surface); }.matches-summary span, .matches-summary strong { display: block; }.matches-summary span { color: var(--text-secondary); font-size: 10px; }.matches-summary strong { margin-top: 9px; font-size: 20px; font-variant-numeric: tabular-nums; }.matches-summary small { color: var(--text-secondary); font-size: 11px; font-weight: 500; }.matches-summary__result { display: flex; align-items: center; gap: 8px; color: var(--text-secondary); font-size: 11px; }.matches-summary__result span { display: inline; }
.match-table-shell { border: 1px solid var(--line); background: var(--surface); }.match-table-heading { display: flex; justify-content: space-between; align-items: flex-end; gap: 12px; padding: 13px 15px 10px; border-bottom: 1px solid var(--line); }.match-table-heading h2 { margin: 4px 0 0; font-size: 16px; }.match-table-heading__hint { color: var(--text-muted); font-size: 9px; }.match-list--full { padding: 8px; overflow-x: auto; }
.matches-workspace { display: grid; grid-template-columns: minmax(184px, .16fr) minmax(0, 1fr); gap: 8px; min-width: 0; align-items: stretch; }.matches-index, .matches-detail-panel { min-width: 0; border: 1px solid var(--line); background: var(--surface); }.matches-index { display: flex; flex-direction: column; overflow: hidden; }.matches-index__header { display: flex; align-items: flex-end; justify-content: space-between; gap: 8px; padding: 11px 12px 9px; border-bottom: 1px solid var(--line); }.matches-index__header h2 { margin: 3px 0 0; font-size: 14px; }.matches-index__header > span { color: var(--text-secondary); font-size: 8px; font-variant-numeric: tabular-nums; }.matches-index__list { display: grid; align-content: start; flex: 1; gap: 4px; padding: 5px; overflow: auto; }
.history-index-row { display: grid; gap: 7px; width: 100%; padding: 9px 10px 8px; border: 1px solid var(--line); border-left: 3px solid var(--line-strong); color: var(--text-primary); background: var(--surface-raised); cursor: pointer; text-align: left; transition: border-color 150ms ease, background 150ms ease, transform 150ms ease; }.history-index-row:hover { border-color: var(--accent); transform: translateX(2px); }.history-index-row.active { border-color: var(--accent); border-left-color: var(--accent); background: color-mix(in srgb, var(--accent-soft) 55%, var(--surface-raised)); }.history-index-row--win { border-left-color: var(--green); }.history-index-row--loss { border-left-color: var(--red); }.history-index-row--unfinished { border-left-color: var(--amber); }.history-index-row__top, .history-index-row__foot { display: flex; align-items: center; justify-content: space-between; gap: 8px; }.history-index-row__top span, .history-index-row__foot span { color: var(--text-muted); font-size: 9px; }.history-index-row__top strong { color: var(--green); font-size: 10px; }.history-index-row--loss .history-index-row__top strong { color: var(--red); }.history-index-row--unfinished .history-index-row__top strong { color: var(--amber); }.history-index-row__main { display: grid; grid-template-columns: 34px minmax(0, 1fr) auto 14px; align-items: center; gap: 8px; min-width: 0; }.history-index-row__main > span { min-width: 0; }.history-index-row__main b, .history-index-row__main small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.history-index-row__main b { font-size: 11px; }.history-index-row__main small { margin-top: 3px; color: var(--text-secondary); font-size: 9px; }.history-index-row__main em { color: var(--text-primary); font-size: 10px; font-style: normal; font-variant-numeric: tabular-nums; white-space: nowrap; }.history-index-row__main svg { color: var(--text-muted); }.history-index-row__foot { padding-top: 6px; border-top: 1px solid var(--line); }.history-index-row__mvp { display: inline-flex; align-items: center; gap: 3px; color: var(--accent) !important; font-weight: 800; }.history-index-row__mvp svg { color: currentColor; }.history-index-row__mvp[data-mvp="SVP"] { color: var(--blue) !important; }
.history-index-row__main :deep(.asset-icon__fallback) { font-size: 0; }
.matches-detail-panel { min-height: 590px; overflow: hidden; }.matches-detail-empty { display: grid; place-items: center; align-content: center; min-height: 590px; padding: 30px; color: var(--text-secondary); text-align: center; }.matches-detail-empty h2 { margin: 10px 0 0; color: var(--text-primary); font-size: 17px; }.matches-detail-empty p { max-width: 290px; margin: 7px auto 0; font-size: 10px; line-height: 1.5; }.history-detail-enter-active, .history-detail-leave-active { transition: opacity 180ms ease, transform 220ms cubic-bezier(.23, 1, .32, 1); }.history-detail-enter-from { opacity: 0; transform: translateX(24px); }.history-detail-leave-to { opacity: 0; transform: translateX(-12px); }
.matches-pagination { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-top: 10px; padding: 10px 14px; border: 1px solid var(--line); color: var(--text-secondary); background: var(--surface); font-size: 10px; }.matches-pagination > div { display: flex; gap: 6px; }
@media (max-width: 980px) { .matches-workspace { grid-template-columns: minmax(205px, .3fr) minmax(0, 1fr); }.matches-filter-row { grid-template-columns: auto minmax(150px, 1fr) 108px 132px auto; }.matches-index__list { max-height: none; } }
@media (max-width: 760px) { .matches-query-form { grid-template-columns: 1fr; }.matches-query-submit { justify-self: start; }.matches-filter-row { grid-template-columns: 1fr 1fr; }.matches-filter-title { grid-column: 1 / -1; }.matches-filter-count { justify-self: start; }.matches-workspace { grid-template-columns: 1fr; }.matches-detail-panel { min-height: 0; }.matches-detail-empty { min-height: 240px; }.matches-index__list { max-height: 420px; }.matches-summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }.matches-summary__result { grid-column: 1 / -1; } }
</style>
