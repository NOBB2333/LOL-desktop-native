<script setup lang="ts">
import { Grid2X2, List, RefreshCw, Search, SlidersHorizontal } from "@lucide/vue";
import { NButton, NInput, NSelect, NTag, useMessage } from "naive-ui";
import { computed, ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import AssetIcon from "../components/AssetIcon.vue";
import LoadingState from "../components/LoadingState.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import { championImage, percent } from "../utils/format";

const app = useAppStore();
const message = useMessage();
const search = ref("");
const tier = ref("all");
const role = ref("all");
const sort = ref("winRate");
const viewMode = ref<"list" | "grid">(typeof localStorage === "undefined" ? "list" : (localStorage.getItem("lol-desktop-champion-view") as "list" | "grid" | null) ?? "list");
const champions = useQuery({ queryKey: computed(() => ["champions", app.mode]), queryFn: backend.champions, enabled: computed(() => app.initialized), staleTime: 120_000, retry: 1 });
const rows = computed(() => champions.data.value ?? []);
const roleLabels: Record<string, string> = { TOP: "上路", JUNGLE: "打野", MIDDLE: "中路", MID: "中路", BOTTOM: "下路", ADC: "下路", UTILITY: "辅助", SUPPORT: "辅助" };
const roleLabel = (value: string) => roleLabels[value.toUpperCase()] ?? value;
const roles = computed(() => [{ label: "全部位置", value: "all" }, ...Array.from(new Set(rows.value.flatMap((champion) => champion.roles))).filter(Boolean).map((value) => ({ label: roleLabel(value), value }))]);
const filtered = computed(() => rows.value.filter((champion) => {
  const query = search.value.trim().toLowerCase();
  return (!query || champion.name.toLowerCase().includes(query) || champion.alias.toLowerCase().includes(query)) && (tier.value === "all" || champion.tier === tier.value || champion.tier.startsWith(tier.value)) && (role.value === "all" || champion.roles.includes(role.value));
}).sort((left, right) => {
  if (sort.value === "name") return left.name.localeCompare(right.name, "zh-CN");
  if (sort.value === "tier") return tierOrder(left.tier) - tierOrder(right.tier) || right.winRate - left.winRate;
  const key = sort.value as "winRate" | "pickRate" | "banRate" | "kda";
  return right[key] - left[key] || left.name.localeCompare(right.name, "zh-CN");
}));
const sortOptions = [
  { label: "胜率从高到低", value: "winRate" },
  { label: "名称排序", value: "name" },
  { label: "梯队排序", value: "tier" },
  { label: "登场率从高到低", value: "pickRate" },
  { label: "禁用率从高到低", value: "banRate" },
  { label: "KDA 从高到低", value: "kda" },
];
const tierOrder = (value: string) => ({ S: 1, T1: 1, A: 2, T2: 2, B: 3, T3: 3, C: 4, T4: 4, D: 5, T5: 5 }[value.toUpperCase()] ?? 99);
const sourceLabel = (source: string) => source === "opgg" ? "OP.GG" : source === "lcu" ? "LCU" : source === "sqlite-stale" ? "缓存回退" : source === "fixture" ? "Fixture" : "本地数据";
const sourceTone = (source: string, stale: boolean) => stale ? "stale" : source;
const tierClass = (value: string) => value === "T1" ? "tier-s" : value === "T2" ? "tier-a" : value === "T3" ? "tier-b" : "tier-c";
const meterClass = (value: number) => `champion-meter-${Math.min(100, Math.max(0, Math.round(value * 20) * 5))}`;
function setView(value: "list" | "grid") { viewMode.value = value; if (typeof localStorage !== "undefined") localStorage.setItem("lol-desktop-champion-view", value); }
async function refresh() { await champions.refetch(); message.success("英雄数据已刷新"); }
</script>

<template>
  <div class="page-shell champions-page champions-page--dense">
    <PageHeader title="英雄" eyebrow="CHAMPION DATA" meta="统计来自 OP.GG；英雄、装备和图标优先读取 LCU / SQLite 缓存">
      <div class="champions-toolbar"><NInput v-model:value="search" size="small" placeholder="搜索英雄或别名" clearable><template #prefix><Search :size="14" /></template></NInput><NSelect v-model:value="tier" size="small" :options="[{ label: '全部梯队', value: 'all' }, { label: 'T1', value: 'T1' }, { label: 'T2', value: 'T2' }, { label: 'T3', value: 'T3' }, { label: 'T4', value: 'T4' }, { label: 'T5', value: 'T5' }]" /><NSelect v-model:value="role" size="small" :options="roles" /><NSelect v-model:value="sort" class="champion-sort" size="small" :options="sortOptions" /><div class="view-toggle" aria-label="英雄视图"><button type="button" :class="{ active: viewMode === 'list' }" title="列表视图" @click="setView('list')"><List :size="15" /></button><button type="button" :class="{ active: viewMode === 'grid' }" title="网格视图" @click="setView('grid')"><Grid2X2 :size="15" /></button></div><NButton quaternary size="small" :loading="champions.isFetching.value" @click="refresh"><template #icon><RefreshCw :size="14" /></template>刷新</NButton></div>
    </PageHeader>
    <LoadingState v-if="champions.isLoading.value" label="正在加载英雄统计" />
    <template v-else>
      <section class="champion-data-banner"><SlidersHorizontal :size="16" /><div><strong>LCU 基础资料 + OP.GG 统计</strong><span>LCU 提供名称、定位和头像；OP.GG 提供胜率、登场率、禁用率、梯队和位置。网络不可用时统计回退 SQLite 旧快照。</span></div><div class="champion-data-banner__sources"><span class="source-chip source-chip--lcu">LCU 基础</span><span class="source-chip source-chip--opgg">OP.GG 统计</span><b>{{ filtered.length }} / {{ rows.length }}</b></div></section>
      <section v-if="viewMode === 'list'" class="champion-table-shell">
        <header class="champion-table-head"><span>英雄</span><span>定位</span><span>梯队</span><span>胜率</span><span>登场率</span><span>禁用率</span><span>KDA</span><span>统计来源</span></header>
        <div v-for="champion in filtered" :key="champion.id" class="champion-table-row"><div class="champion-table-name"><AssetIcon kind="champion" :id="champion.id" :name="champion.name" :fallback-url="champion.iconUrl || championImage(champion.id)" size="md" /><div><strong>{{ champion.name }}</strong><small>{{ champion.alias }}</small></div></div><div class="champion-table-roles"><NTag v-for="item in champion.roles.slice(0, 3)" :key="item" size="small" :bordered="false">{{ roleLabel(item) }}</NTag><span v-if="!champion.roles.length">-</span></div><strong class="champion-tier" :class="tierClass(champion.tier)">{{ champion.tier }}</strong><div class="champion-table-stat"><strong>{{ percent(champion.winRate) }}</strong><i :class="meterClass(champion.winRate)" /></div><span class="champion-table-number">{{ percent(champion.pickRate) }}</span><span class="champion-table-number">{{ percent(champion.banRate) }}</span><span class="champion-table-number">{{ champion.kda ? champion.kda.toFixed(2) : "-" }}</span><span class="champion-source" :data-source="sourceTone(champion.dataStatus.source, champion.dataStatus.isStale)"><small>LCU</small> + {{ sourceLabel(champion.statsSource || champion.dataStatus.source) }}<em v-if="champion.dataStatus.isStale">旧</em></span></div>
        <div v-if="!filtered.length" class="empty-state">没有匹配的英雄</div>
      </section>
      <section v-else class="champion-grid"><article v-for="champion in filtered" :key="champion.id" class="champion-grid-card"><div class="champion-grid-card__top"><AssetIcon kind="champion" :id="champion.id" :name="champion.name" :fallback-url="champion.iconUrl || championImage(champion.id)" size="xl" /><strong class="champion-tier" :class="tierClass(champion.tier)">{{ champion.tier }}</strong></div><h2>{{ champion.name }}<small>{{ champion.alias }}</small></h2><div class="champion-grid-card__roles"><NTag v-for="item in champion.roles.slice(0, 3)" :key="item" size="small" :bordered="false">{{ roleLabel(item) }}</NTag></div><div class="champion-grid-card__stats"><div><span>胜率</span><strong>{{ percent(champion.winRate) }}</strong><i :class="meterClass(champion.winRate)" /></div><div><span>登场</span><strong>{{ percent(champion.pickRate) }}</strong></div><div><span>禁用</span><strong>{{ percent(champion.banRate) }}</strong></div><div><span>KDA</span><strong>{{ champion.kda.toFixed(2) }}</strong></div></div><footer><span>LCU 基础 + {{ sourceLabel(champion.statsSource || champion.dataStatus.source) }} 统计</span><small v-if="champion.dataStatus.isStale">旧缓存</small></footer></article><div v-if="!filtered.length" class="empty-state">没有匹配的英雄</div></section>
    </template>
  </div>
</template>

<style scoped>
.champions-page--dense { max-width: 1540px; }
.champions-toolbar { display: flex; align-items: center; gap: 5px; }
.champions-toolbar .n-input { width: 190px; }.champions-toolbar .n-base-selection { width: 112px; }.champions-toolbar .champion-sort { width: 150px; }
.view-toggle { display: inline-flex; gap: 2px; padding: 2px; border: 1px solid var(--line); border-radius: 5px; background: var(--surface); }
.view-toggle button { display: grid; place-items: center; width: 28px; height: 26px; border: 0; border-radius: 3px; color: var(--text-secondary); background: transparent; cursor: pointer; }.view-toggle button.active { color: var(--accent); background: var(--accent-soft); }
.champion-data-banner { display: flex; align-items: center; gap: 9px; padding: 11px 13px; margin-bottom: 12px; border: 1px solid var(--line); background: var(--surface-raised); color: var(--text-secondary); }.champion-data-banner > div:first-of-type { flex: 1; min-width: 0; }.champion-data-banner strong, .champion-data-banner span { display: block; }.champion-data-banner strong { color: var(--text-primary); font-size: 11px; }.champion-data-banner span { margin-top: 3px; font-size: 10px; }.champion-data-banner b { color: var(--text-primary); font-size: 11px; font-variant-numeric: tabular-nums; }.champion-data-banner__sources { display: flex; align-items: center; gap: 5px; }.source-chip { display: inline-flex; align-items: center; padding: 3px 5px; border: 1px solid var(--line); border-radius: 3px; font-size: 8px !important; white-space: nowrap; }.source-chip--lcu { color: var(--accent); background: var(--accent-soft); }.source-chip--opgg { color: var(--green); background: var(--green-soft); }
.champion-table-shell { overflow: hidden; border: 1px solid var(--line); background: var(--surface); }.champion-table-head, .champion-table-row { display: grid; grid-template-columns: minmax(190px, 1.8fr) minmax(120px, 1.1fr) 52px 105px 70px 70px 60px 110px; align-items: center; gap: 8px; }.champion-table-head { min-height: 35px; padding: 0 14px; border-bottom: 1px solid var(--line); color: var(--text-muted); font-size: 9px; }.champion-table-row { min-height: 65px; padding: 7px 14px; border-bottom: 1px solid var(--line); font-size: 11px; }.champion-table-row:last-child { border-bottom: 0; }.champion-table-row:hover { background: var(--surface-raised); }
.champion-table-name { display: flex; align-items: center; gap: 9px; min-width: 0; }.champion-table-name div { min-width: 0; }.champion-table-name strong, .champion-table-name small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.champion-table-name strong { color: var(--text-primary); font-size: 12px; }.champion-table-name small { margin-top: 3px; color: var(--text-secondary); font-size: 10px; }.champion-table-roles { display: flex; flex-wrap: wrap; gap: 3px; }.champion-table-roles span { color: var(--text-muted); }.champion-tier { display: inline-grid; place-items: center; width: 28px; height: 24px; border: 1px solid currentColor; font-size: 11px; }.tier-s { color: var(--red); background: var(--red-soft); }.tier-a { color: var(--amber); background: var(--amber-soft); }.tier-b { color: var(--blue); background: var(--blue-soft); }.tier-c { color: var(--text-secondary); }.champion-table-stat strong { display: block; color: var(--text-primary); font-size: 12px; font-variant-numeric: tabular-nums; }.champion-table-stat i, .champion-grid-card__stats i { display: block; height: 4px; margin-top: 5px; background: linear-gradient(to right, var(--accent) var(--meter), var(--line) var(--meter)); }
.champion-meter-0 { --meter: 0%; }.champion-meter-5 { --meter: 5%; }.champion-meter-10 { --meter: 10%; }.champion-meter-15 { --meter: 15%; }.champion-meter-20 { --meter: 20%; }.champion-meter-25 { --meter: 25%; }.champion-meter-30 { --meter: 30%; }.champion-meter-35 { --meter: 35%; }.champion-meter-40 { --meter: 40%; }.champion-meter-45 { --meter: 45%; }.champion-meter-50 { --meter: 50%; }.champion-meter-55 { --meter: 55%; }.champion-meter-60 { --meter: 60%; }.champion-meter-65 { --meter: 65%; }.champion-meter-70 { --meter: 70%; }.champion-meter-75 { --meter: 75%; }.champion-meter-80 { --meter: 80%; }.champion-meter-85 { --meter: 85%; }.champion-meter-90 { --meter: 90%; }.champion-meter-95 { --meter: 95%; }.champion-meter-100 { --meter: 100%; }
.champion-table-number { color: var(--text-primary); font-variant-numeric: tabular-nums; }.champion-abilities { overflow: hidden; color: var(--text-secondary); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }.champion-source { display: inline-flex; align-items: center; gap: 3px; color: var(--green); font-size: 9px; white-space: nowrap; }.champion-source[data-source="fixture"] { color: var(--text-secondary); }.champion-source[data-source="stale"] { color: var(--amber); }.champion-source small { color: var(--accent); font-size: 8px; }.champion-source em { color: var(--amber); font-size: 8px; font-style: normal; }
.champion-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(205px, 1fr)); gap: 6px; }.champion-grid-card { min-height: 214px; padding: 10px; border: 1px solid var(--line); background: var(--surface); }.champion-grid-card:hover { border-color: var(--accent); background: var(--surface-raised); }.champion-grid-card__top { display: flex; align-items: flex-start; justify-content: space-between; }.champion-grid-card h2 { margin: 8px 0 2px; font-size: 14px; }.champion-grid-card h2 small { display: block; margin-top: 2px; color: var(--text-secondary); font-size: 9px; font-weight: 500; }.champion-grid-card__roles { display: flex; gap: 3px; min-height: 20px; }.champion-grid-card__stats { display: grid; grid-template-columns: 1.4fr repeat(3, 1fr); gap: 5px; margin-top: 9px; }.champion-grid-card__stats span, .champion-grid-card footer { color: var(--text-secondary); font-size: 8px; }.champion-grid-card__stats strong { display: block; margin-top: 3px; color: var(--text-primary); font-size: 11px; }.champion-grid-card__abilities { display: grid; gap: 3px; margin-top: 8px; padding-top: 6px; border-top: 1px solid var(--line); }.champion-grid-card__abilities span { color: var(--text-muted); font-size: 8px; }.champion-grid-card__abilities strong { overflow: hidden; color: var(--text-secondary); font-size: 8px; font-weight: 500; text-overflow: ellipsis; white-space: nowrap; }.champion-grid-card footer { display: flex; justify-content: space-between; margin-top: 8px; padding-top: 7px; border-top: 1px solid var(--line); }.champion-grid-card footer small { color: var(--amber); }
@media (max-width: 1100px) { .champion-table-shell { overflow-x: auto; }.champion-table-head, .champion-table-row { min-width: 900px; } }
@media (max-width: 720px) { .champions-toolbar { flex-wrap: wrap; }.champion-data-banner { align-items: flex-start; } }
</style>
