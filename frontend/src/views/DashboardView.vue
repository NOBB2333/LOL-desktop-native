<script setup lang="ts">
import { ArrowUpRight, RefreshCw, UsersRound } from "@lucide/vue";
import { NButton, NPopover, useMessage } from "naive-ui";
import { computed, ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import AssetIcon from "../components/AssetIcon.vue";
import LoadingState from "../components/LoadingState.vue";
import MatchDetailCard from "../components/MatchDetailCard.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { RankQueueSummary } from "../types/domain";
import { championImage, percent, platformRegionGuide, platformRegionName, platformRegionOverview, rankName, relativeTime } from "../utils/format";
import { isHiddenMatch } from "../utils/matchFilters";

const app = useAppStore();
const message = useMessage();
const matches = useQuery({ queryKey: computed(() => ["dashboard-matches", app.mode, app.connection.platformId, app.connection.gameName, app.connection.tagLine, app.config.providers.hideUnfinishedMatches]), queryFn: () => backend.matches(), enabled: computed(() => app.initialized), staleTime: 20_000, refetchInterval: computed(() => app.initialized && app.mode === "live" ? 15_000 : false) });
const encounters = useQuery({ queryKey: computed(() => ["dashboard-encounters", app.mode, app.connection.platformId, app.connection.gameName, app.connection.tagLine]), queryFn: () => backend.encounters(undefined, 20), enabled: computed(() => app.initialized), staleTime: 20_000, refetchInterval: computed(() => app.initialized && app.mode === "live" ? 15_000 : false) });
const rawRows = computed(() => {
  // The native bridge can legitimately return an empty page while LCU is
  // reconnecting. Keep the bootstrap snapshot visible until a non-empty page
  // arrives so the dashboard never collapses into a blank history panel.
  const fetched = matches.data.value;
  return fetched?.length ? fetched : app.bootstrap.dashboard.recentMatches;
});
const rows = computed(() => {
  const visible = app.config.providers.hideUnfinishedMatches ? rawRows.value.filter((match) => !isHiddenMatch(match)) : rawRows.value;
  return visible.slice(0, 10);
});
const relationRows = computed(() => {
  const fetched = encounters.data.value;
  return fetched?.length ? fetched : app.bootstrap.dashboard.recentEncounters;
});
const account = computed(() => app.connection);
const regionValue = computed(() => account.value.platformId || account.value.region);
const regionDisplay = computed(() => platformRegionName(regionValue.value));
const regionOverview = computed(() => platformRegionOverview(regionValue.value));
const expandedMatchId = ref<number | null>(null);
const source = computed(() => rows.value[0]?.dataStatus);
const sourceLabel = computed(() => {
  if (!source.value && app.connection.status === "connected") return "客户端已连接 · 正在同步";
  if (!source.value && app.connection.status === "error") return "客户端连接失败 · 等待重试";
  if (!source.value) return app.connection.status === "disconnected" ? "等待连接" : "等待数据";
  if (source.value.isStale) return "本地旧快照";
  if (source.value.source === "fixture") return "预览测试数据";
  if (source.value.source === "lcu") return "客户端实时数据";
  if (source.value.source === "opgg") return "OP.GG 数据";
  return "缓存数据";
});
const syncLabel = computed(() => source.value?.isStale ? "缓存" : source.value?.source === "fixture" ? "预览" : source.value ? "实时" : app.connection.status === "connected" ? "同步中" : "等待");
const completedRows = computed(() => rows.value.filter((match) => match.durationMinutes > 0 && !["未完成", "待定"].includes(match.result)));
const wins = computed(() => completedRows.value.filter((match) => match.result === "胜利").length);
const losses = computed(() => completedRows.value.length - wins.value);
const winRate = computed(() => completedRows.value.length ? Math.round(wins.value / completedRows.value.length * 100) : 0);
const averageKda = computed(() => completedRows.value.length ? (completedRows.value.reduce((sum, match) => sum + (match.kills + match.assists) / Math.max(1, match.deaths), 0) / completedRows.value.length).toFixed(2) : "--");
const averageDamage = computed(() => completedRows.value.length ? `${(completedRows.value.reduce((sum, match) => sum + match.damageDealt, 0) / completedRows.value.length / 1000).toFixed(1)}k` : "--");
const averageParticipation = computed(() => completedRows.value.length ? percent(completedRows.value.reduce((sum, match) => sum + match.killParticipation, 0) / completedRows.value.length) : "--");
const streak = computed(() => {
  const first = completedRows.value[0]?.result;
  if (!first) return "--";
  let count = 0;
  for (const match of completedRows.value) {
    if (match.result !== first) break;
    count += 1;
  }
  return `${first === "胜利" ? "胜" : "负"}${count}`;
});
const commonChampions = computed(() => {
  const usage = new Map<string, { championId: number; championName: string; games: number; wins: number }>();
  // 统计口径与首页下方“最近对局”保持一致：只使用当前返回的最近 10 条，
  // 是否排除训练/自定义由同一个设置过滤器决定。
  for (const match of rows.value) {
    // Champion names can differ between LCU locale/patch responses. The ID is
    // the stable key, otherwise one champion can occupy two "common" slots.
    const key = match.championId > 0
      ? String(match.championId)
      : match.championName.trim().toLocaleLowerCase();
    const current = usage.get(key) ?? { championId: match.championId, championName: match.championName, games: 0, wins: 0 };
    current.games += 1;
    current.wins += match.result === "胜利" ? 1 : 0;
    usage.set(key, current);
  }
  return [...usage.values()].sort((a, b) => b.games - a.games || b.wins - a.wins).slice(0, 3);
});

function rankText(rank: RankQueueSummary | null) {
  if (!rank || !rank.tier) return "未定级";
  return `${rankName(rank.tier)} ${rank.division}`.trim();
}

function rankRate(rank: RankQueueSummary | null) {
  if (!rank || rank.wins + rank.losses === 0) return "--";
  return percent(rank.wins / (rank.wins + rank.losses));
}

async function refresh() {
  await Promise.all([matches.refetch(), encounters.refetch()]);
  message.success("已请求最新数据");
}

function toggleMatch(gameId: number) {
  expandedMatchId.value = expandedMatchId.value === gameId ? null : gameId;
}
</script>

<template>
  <div class="dashboard">
    <!-- Header -->
    <header class="dashboard-header">
      <div>
        <div class="header-kicker">账号工作台</div>
        <h1>首页</h1>
        <p>你的账号、战绩与实时对局状态</p>
      </div>

      <div class="header-actions">
        <div class="connection-status">
          <span
            class="status-dot"
            :data-stale="source?.isStale"
          />
          <span>
            {{
              sourceLabel
            }}
          </span>
        </div>

        <NButton
          quaternary
          size="small"
          :loading="matches.isFetching.value"
          @click="refresh"
        >
          <template #icon>
            <RefreshCw :size="15" />
          </template>
          刷新
        </NButton>

        <RouterLink to="/game" class="game-button">
          <span>进入对局</span>
          <ArrowUpRight :size="15" />
        </RouterLink>
      </div>
    </header>

    <LoadingState
    v-if="matches.isLoading.value && !rows.length && app.connection.status !== 'connected'"
      label="正在整理账号和最近对局"
    />

    <template v-else>
      <!-- ========================================================= -->
      <!-- Hero -->
      <!-- ========================================================= -->

      <section class="hero-grid">

        <!-- Account -->
        <div class="account-card">
          <div class="account-layout">
            <div class="account-profile">
              <div class="account-top">
                <div class="avatar-wrap">
                  <AssetIcon
                    kind="profile"
                    :id="account.profileIconId ?? 0"
                    :name="account.gameName || account.summonerName || '测试召唤师'"
                    fallback-url="./fixtures/champions/Ahri.png"
                    size="xl"
                  />
                  <span
                    class="online-indicator"
                    :data-online="account.presence === 'online' || app.mode === 'fixture'"
                  />
                </div>

                <div class="account-main">
                  <div class="account-label">当前账号</div>
                  <div class="account-name">
                    {{ account.gameName || account.summonerName || "测试召唤师" }}
                    <span v-if="account.tagLine">#{{ account.tagLine }}</span>
                  </div>
                  <div class="account-meta">
                    <span>Lv.{{ account.summonerLevel ?? 0 }}</span>
                    <i />
                    <NPopover trigger="hover" placement="bottom-start" :show-arrow="false">
                      <template #trigger><span class="account-region" :aria-label="platformRegionGuide(regionValue)" tabindex="0">{{ regionDisplay }}</span></template>
                      <div class="region-tooltip">
                        <div class="region-tooltip__current" :data-known="Boolean(regionOverview.current)">
                          <span>当前大区</span>
                          <strong>{{ regionOverview.current ? `${regionOverview.current.id} · ${regionOverview.current.name}` : regionDisplay }}</strong>
                          <small>{{ regionOverview.current ? `${regionOverview.current.group} · ${regionOverview.current.servers}` : "客户端暂未返回可识别的大区编号" }}</small>
                        </div>
                        <div class="region-tooltip__catalog">
                          <section v-for="group in regionOverview.groups" :key="group.label">
                            <header>{{ group.label }}</header>
                            <div>
                              <p v-for="region in group.regions" :key="region.id" :data-current="region.id === regionOverview.current?.id">
                                <strong>{{ region.id }} · {{ region.name }}</strong><span>{{ region.servers }}</span>
                              </p>
                            </div>
                          </section>
                        </div>
                      </div>
                    </NPopover>
                    <i />
                    <span class="online-text">{{ account.presence === "online" || app.mode === "fixture" ? "在线" : account.phase || "等待客户端" }}</span>
                  </div>
                </div>
              </div>

              <div class="common-champions">
                <div class="account-section-label">常用英雄 <span>按最近 {{ rows.length }} 场对局</span></div>
                <div class="common-champion-list">
                  <div v-for="champion in commonChampions" :key="champion.championId" class="common-champion">
                    <AssetIcon kind="champion" :id="champion.championId" :name="champion.championName" :fallback-url="championImage(champion.championId)" size="sm" />
                    <div><strong>{{ champion.championName }}</strong><span>{{ champion.games }} 场 · {{ champion.wins }} 胜</span></div>
                  </div>
                  <span v-if="!commonChampions.length" class="common-champion-empty">等待最近战绩</span>
                </div>
              </div>
            </div>

            <div class="account-performance">
              <div class="performance-heading">
                <div><span>近期状态</span><strong>最近表现</strong></div>
                <div class="performance-source"><i />{{ syncLabel }} · {{ rows.length }} 场</div>
              </div>

              <div class="performance-grid">
                <div class="performance-metric performance-metric--record">
                  <span>近期战绩</span>
                  <strong><b>{{ wins }}胜</b> {{ losses }}负</strong>
                  <small>{{ winRate }}% 胜率</small>
                </div>
                <div class="performance-metric"><span>平均 KDA</span><strong>{{ averageKda }}</strong><small>击杀贡献</small></div>
                <div class="performance-metric"><span>平均输出</span><strong>{{ averageDamage }}</strong><small>英雄伤害</small></div>
                <div class="performance-metric"><span>平均参团</span><strong>{{ averageParticipation }}</strong><small>团战参与</small></div>
                <div class="performance-metric"><span>连续状态</span><strong class="performance-streak" :data-win="streak.startsWith('胜')">{{ streak }}</strong><small>按最新场次</small></div>
              </div>

              <div class="form-strip" aria-label="最近比赛结果">
                <span>近况</span>
                <i v-for="match in rows.slice(0, 10)" :key="match.gameId" :data-result="match.durationMinutes === 0 ? 'unfinished' : match.result === '胜利' ? 'win' : 'loss'">{{ match.durationMinutes === 0 ? "U" : match.result === "胜利" ? "W" : "L" }}</i>
              </div>
            </div>
          </div>
        </div>

        <!-- Rank -->
        <div class="rank-card">
          <div class="rank-card-header">
            <span>排位状态</span>
            <span class="rank-season">当前赛季</span>
          </div>

          <div class="rank-list">

            <article class="rank-item">
              <div class="rank-icon rank-icon--solo">
                S
              </div>

              <div class="rank-info">
                <span>单双排</span>
                <strong>{{ rankText(account.soloRank) }}</strong>
                <div class="rank-sub"><b>{{ account.soloRank?.wins ?? 0 }} 胜</b><em>{{ account.soloRank?.losses ?? 0 }} 负</em><strong>{{ rankRate(account.soloRank) }} 胜率</strong></div>
              </div>

              <div class="rank-points">
                <strong>
                  {{ account.soloRank?.leaguePoints ?? 0 }}
                </strong>
                <span>LP</span>

                <small>当前胜点</small>
              </div>
            </article>

            <article class="rank-item rank-item--flex">
              <div class="rank-icon rank-icon--flex">
                F
              </div>

              <div class="rank-info">
                <span>灵活组排</span>
                <strong>{{ rankText(account.flexRank) }}</strong>
                <div class="rank-sub"><b>{{ account.flexRank?.wins ?? 0 }} 胜</b><em>{{ account.flexRank?.losses ?? 0 }} 负</em><strong>{{ rankRate(account.flexRank) }} 胜率</strong></div>
              </div>

              <div class="rank-points">
                <strong>
                  {{ account.flexRank?.leaguePoints ?? 0 }}
                </strong>
                <span>LP</span>

                <small>当前胜点</small>
              </div>
            </article>

          </div>
        </div>
      </section>

      <!-- ========================================================= -->
      <!-- Matches -->
      <!-- ========================================================= -->

      <section class="content-card matches-card">

        <header class="content-header">
          <div>
            <div class="section-kicker">
              最近对局
            </div>

            <h2>最近对局</h2>

            <p>
              最近 10 场比赛的完整表现
            </p>
          </div>

          <RouterLink
            to="/matches"
            class="view-all"
          >
            查看全部
            <ArrowUpRight :size="14" />
          </RouterLink>
        </header>

        <div class="match-list">
          <MatchDetailCard
            v-for="match in rows.slice(0, 10)"
            :key="match.gameId"
            :match="match"
            :expanded="expandedMatchId === match.gameId"
            @toggle="toggleMatch(match.gameId)"
            compact
          />
          <div v-if="!rows.length" class="empty-state">
            暂无最近战绩
          </div>
        </div>
      </section>

      <!-- ========================================================= -->
      <!-- Bottom -->
      <!-- ========================================================= -->

      <section class="bottom-grid">

        <!-- Relationships -->
        <div class="content-card">

          <header class="content-header content-header--small">
            <div>
              <div class="section-kicker">
                关系记录
              </div>

              <h2>常见队友与对手</h2>
            </div>

            <RouterLink
              to="/history"
              class="view-all"
            >
              历史
              <ArrowUpRight :size="14" />
            </RouterLink>
          </header>

          <div class="relationship-list">

            <div
              v-for="record in relationRows.slice(0, 6)"
              :key="record.puuid"
              class="relationship-row"
            >

              <div class="relationship-avatar">
                {{ record.gameName.slice(0, 1) }}
              </div>

              <div class="relationship-info">
                <strong>
                  {{ record.gameName }}
                </strong>

                <span>
                  {{
                    record.side === "ally"
                      ? "常见队友"
                      : "曾经遇到"
                  }}
                  ·
                  {{ record.championName }}
                  ·
                  {{ relativeTime(record.encounteredAt) }}
                </span>
              </div>

              <div
                class="relationship-result"
                :data-result="
                  record.result === '胜利'
                    ? 'win'
                    : 'loss'
                "
              >
                {{ record.result || "--" }}
              </div>

            </div>

            <div
              v-if="!relationRows.length"
              class="empty-state"
            >
              暂无关系记录
            </div>

          </div>
        </div>

        <!-- System -->
        <div class="content-card system-card">

          <header class="content-header content-header--small">
            <div>
              <div class="section-kicker">
                系统状态
              </div>

              <h2>运行状态</h2>
            </div>
          </header>

          <div class="system-list">

            <div class="system-row">
              <span>数据来源</span>
              <strong>
                {{ sourceLabel }}
              </strong>
            </div>

            <div class="system-row">
              <span>最近数据</span>
              <strong>
                {{ rows.length }} 场
              </strong>
            </div>

            <div class="system-row">
              <span>客户端</span>

              <strong class="system-online">
                <i />
                {{
                  account.status === "connected" ||
                  app.mode === "fixture"
                    ? "已连接"
                    : "等待连接"
                }}
              </strong>
            </div>

            <div class="system-row">
              <span>对局入口</span>

              <RouterLink
                to="/game"
                class="system-action"
              >
                <UsersRound :size="13" />
                查看实时对局
                <ArrowUpRight :size="13" />
              </RouterLink>
            </div>

          </div>
        </div>

      </section>
    </template>
  </div>
</template>

<style scoped>
/* =========================================================
   Dashboard
   Apple / Premium Game Client
   ========================================================= */

.dashboard {
  box-sizing: border-box;
  width: 100%;
  max-width: 1600px;
  margin: 0 auto;
  padding: clamp(20px, 2.2vw, 32px) clamp(14px, 2vw, 28px) 60px;
}

/* =========================================================
   Header
   ========================================================= */

.dashboard-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 32px;
  margin-bottom: 24px;
}

.header-kicker,
.section-kicker,
.account-label {
  color: var(--text-muted);
  font-size: 10px;
  font-weight: 600;
  letter-spacing: .12em;
}

.dashboard-header h1 {
  margin: 5px 0 3px;
  font-size: 27px;
  font-weight: 650;
  letter-spacing: 0;
}

.dashboard-header p {
  margin: 0;
  color: var(--text-secondary);
  font-size: 12px;
}

.header-actions {
  display: flex;
  align-items: center;
  gap: 9px;
}

.connection-status {
  display: flex;
  align-items: center;
  gap: 7px;
  margin-right: 5px;
  color: var(--text-secondary);
  font-size: 10px;
}

.status-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--green);
  box-shadow: 0 0 0 3px color-mix(
    in srgb,
    var(--green) 12%,
    transparent
  );
}

.status-dot[data-stale="true"] {
  background: var(--amber);
}

.game-button {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  height: 34px;
  padding: 0 13px;
  border-radius: 6px;
  color: #fff;
  background: var(--accent);
  font-size: 11px;
  font-weight: 600;
  text-decoration: none;
  transition:
    transform .15s ease,
    opacity .15s ease;
}

.game-button:hover {
  opacity: .9;
  transform: translateY(-1px);
}

/* =========================================================
   Hero
   ========================================================= */

.hero-grid {
  display: grid;
  grid-template-columns: minmax(0, 2fr) minmax(320px, .78fr);
  gap: 14px;
  margin-bottom: 14px;
}

.account-card,
.rank-card,
.content-card {
  border: 1px solid var(--line);
  background: var(--surface);
  box-shadow:
    0 1px 2px rgba(0, 0, 0, .025),
    0 8px 30px rgba(0, 0, 0, .025);
}

/* Account */

.account-card {
  min-width: 0;
  border-radius: 8px;
  padding: 20px;
}

.account-layout {
  display: grid;
  grid-template-columns: minmax(260px, .8fr) minmax(410px, 1.35fr);
  gap: 20px;
  min-height: 194px;
}

.account-profile {
  display: flex;
  flex-direction: column;
  min-width: 0;
  padding-right: 20px;
  border-right: 1px solid var(--line);
}

.account-top {
  display: flex;
  align-items: center;
  gap: 14px;
}

.avatar-wrap {
  position: relative;
  flex: none;
}

.avatar-wrap :deep(img) {
  border-radius: 8px;
}

.online-indicator {
  position: absolute;
  right: -2px;
  bottom: -2px;
  width: 12px;
  height: 12px;
  border: 3px solid var(--surface);
  border-radius: 50%;
  background: var(--text-muted);
}

.online-indicator[data-online="true"] {
  background: var(--green);
}

.account-main {
  min-width: 0;
}

.account-label {
  font-size: 9px;
}

.account-name {
  margin-top: 7px;
  overflow: hidden;
  font-size: 22px;
  font-weight: 650;
  letter-spacing: 0;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.account-name span {
  color: var(--text-muted);
  font-size: 12px;
  font-weight: 450;
  letter-spacing: 0;
}

.account-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 8px;
  color: var(--text-secondary);
  font-size: 11px;
}

.account-meta i {
  width: 2px;
  height: 2px;
  border-radius: 50%;
  background: var(--text-muted);
}

.online-text {
  color: var(--green);
}

.common-champions {
  margin-top: auto;
  padding-top: 15px;
}

.account-section-label {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  color: var(--text-secondary);
  font-size: 9px;
  font-weight: 700;
}

.account-section-label span {
  color: var(--text-muted);
  font-weight: 500;
}

.common-champion-list {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 6px;
  margin-top: 8px;
}

.common-champion {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  padding: 5px;
  border: 1px solid var(--line);
  border-radius: 5px;
  background: var(--surface-raised);
}

.account-region {
  overflow: hidden;
  max-width: 160px;
  border-bottom: 1px dotted var(--text-muted);
  cursor: help;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.account-region:focus-visible {
  border-color: var(--accent);
  outline: 2px solid var(--accent-soft);
  outline-offset: 2px;
}

.region-tooltip {
  display: grid;
  width: min(620px, calc(100vw - 40px));
  gap: 9px;
  color: var(--text-primary);
}

.region-tooltip__current {
  display: grid;
  gap: 2px;
  padding: 8px 10px;
  border-left: 3px solid var(--accent);
  border-radius: 4px;
  background: var(--accent-soft);
}

.region-tooltip__current > span {
  color: var(--accent);
  font-size: 9px;
  font-weight: 700;
}

.region-tooltip__current > strong {
  font-size: 13px;
}

.region-tooltip__current > small {
  color: var(--text-secondary);
  font-size: 10px;
  line-height: 1.4;
}

.region-tooltip__catalog {
  display: grid;
  gap: 7px;
}

.region-tooltip__catalog section {
  display: grid;
  grid-template-columns: 68px minmax(0, 1fr);
  gap: 8px;
}

.region-tooltip__catalog header {
  padding-top: 3px;
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 700;
}

.region-tooltip__catalog section > div {
  display: grid;
  gap: 1px;
}

.region-tooltip__catalog p {
  display: grid;
  grid-template-columns: 112px minmax(0, 1fr);
  gap: 7px;
  margin: 0;
  padding: 3px 5px;
  border-left: 2px solid transparent;
  font-size: 10px;
  line-height: 1.35;
}

.region-tooltip__catalog p[data-current="true"] {
  border-left-color: var(--accent);
  background: var(--accent-soft);
}

.region-tooltip__catalog p strong {
  white-space: nowrap;
}

.region-tooltip__catalog p span {
  color: var(--text-secondary);
}

.common-champion :deep(.asset-icon__fallback) {
  font-size: 0;
}

.common-champion > div {
  min-width: 0;
}

.common-champion strong,
.common-champion span {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.common-champion strong {
  font-size: 9px;
}

.common-champion span,
.common-champion-empty {
  margin-top: 2px;
  color: var(--text-muted);
  font-size: 8px;
}

.account-performance {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.performance-heading {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
}

.performance-heading span,
.performance-heading strong {
  display: block;
}

.performance-heading span {
  color: var(--text-muted);
  font-size: 8px;
  font-weight: 700;
}

.performance-heading strong {
  margin-top: 3px;
  font-size: 13px;
}

.performance-source {
  display: flex;
  align-items: center;
  gap: 5px;
  color: var(--text-muted);
  font-size: 8px;
}

.performance-source i {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: var(--green);
}

.performance-grid {
  display: grid;
  grid-template-columns: 1.3fr repeat(4, minmax(72px, 1fr));
  gap: 1px;
  margin-top: 14px;
  border: 1px solid var(--line);
  background: var(--line);
}

.performance-metric {
  min-width: 0;
  padding: 11px 10px;
  background: var(--surface-raised);
}

.performance-metric > span,
.performance-metric > strong,
.performance-metric > small {
  display: block;
}

.performance-metric > span {
  color: var(--text-muted);
  font-size: 8px;
}

.performance-metric > strong {
  margin-top: 6px;
  overflow: hidden;
  font-size: 17px;
  font-variant-numeric: tabular-nums;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.performance-metric > strong b {
  color: var(--green);
  font-weight: 700;
}

.performance-metric > small {
  margin-top: 4px;
  color: var(--text-muted);
  font-size: 8px;
}

.performance-streak {
  color: var(--red);
}

.performance-streak[data-win="true"] {
  color: var(--green);
}

.form-strip {
  display: grid;
  grid-template-columns: auto repeat(10, minmax(16px, 1fr));
  align-items: center;
  gap: 4px;
  margin-top: auto;
  padding-top: 12px;
}

.form-strip > span {
  margin-right: 3px;
  color: var(--text-muted);
  font-size: 8px;
}

.form-strip i {
  display: grid;
  place-items: center;
  height: 19px;
  border-radius: 3px;
  color: var(--green);
  background: var(--green-soft);
  font-size: 8px;
  font-style: normal;
  font-weight: 800;
}

.form-strip i[data-result="loss"] {
  color: var(--red);
  background: var(--red-soft);
}

.form-strip i[data-result="unfinished"] {
  color: var(--amber);
  background: var(--amber-soft);
}

/* Rank */

.rank-card {
  border-radius: 8px;
  overflow: hidden;
}

.rank-card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 17px 19px;
  border-bottom: 1px solid var(--line);
  color: var(--text-primary);
  font-size: 12px;
  font-weight: 600;
}

.rank-season {
  color: var(--text-muted);
  font-size: 9px;
  font-weight: 500;
}

.rank-list {
  padding: 4px 8px 8px;
}

.rank-item {
  display: grid;
  grid-template-columns: 39px minmax(0, 1fr) auto;
  align-items: center;
  gap: 12px;
  min-height: 91px;
  padding: 12px 10px;
  border-bottom: 1px solid var(--line);
}

.rank-item:last-child {
  border-bottom: 0;
}

.rank-icon {
  display: grid;
  place-items: center;
  width: 37px;
  height: 37px;
  border-radius: 6px;
  color: #fff;
  font-size: 12px;
  font-weight: 700;
  background: var(--accent);
  box-shadow: 0 5px 15px color-mix(
    in srgb,
    var(--accent) 20%,
    transparent
  );
}

.rank-icon--flex {
  background: var(--blue);
}

.rank-info span {
  display: block;
  color: var(--text-muted);
  font-size: 9px;
}

.rank-info strong {
  display: block;
  margin-top: 4px;
  font-size: 14px;
  font-weight: 650;
}

.rank-sub {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 3px 7px;
  margin-top: 6px;
  font-size: 9px;
}

.rank-sub b {
  color: var(--green);
  font-weight: 650;
}

.rank-sub em {
  color: var(--red);
  font-style: normal;
}

.rank-sub strong {
  color: var(--text-primary);
  font-size: 9px;
  font-weight: 700;
}

.rank-points {
  text-align: right;
}

.rank-points strong {
  font-size: 16px;
  font-variant-numeric: tabular-nums;
}

.rank-points span {
  margin-left: 2px;
  color: var(--text-muted);
  font-size: 9px;
}

.rank-points small {
  display: block;
  margin-top: 3px;
  color: var(--text-muted);
  font-size: 9px;
}

/* =========================================================
   Content
   ========================================================= */

.content-card {
  overflow: hidden;
  border-radius: 8px;
}

.matches-card {
  margin-bottom: 14px;
}

.content-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 20px;
  padding: 18px 20px 15px;
  border-bottom: 1px solid var(--line);
}

.content-header--small {
  padding-bottom: 14px;
}

.content-header h2 {
  margin: 5px 0 0;
  font-size: 16px;
  font-weight: 650;
  letter-spacing: 0;
}

.content-header p {
  margin: 4px 0 0;
  color: var(--text-secondary);
  font-size: 10px;
}

.view-all {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex: none;
  color: var(--accent);
  font-size: 10px;
  text-decoration: none;
}

.view-all:hover {
  text-decoration: underline;
}

.match-list {
  display: grid;
  gap: 7px;
  padding: 9px;
  overflow-x: auto;
}

/* =========================================================
   Bottom
   ========================================================= */

.bottom-grid {
  display: grid;
  grid-template-columns: 1.25fr .75fr;
  gap: 14px;
}

.relationship-list {
  padding: 4px 18px 8px;
}

.relationship-row {
  display: grid;
  grid-template-columns: 34px minmax(0, 1fr) auto;
  align-items: center;
  gap: 10px;
  min-height: 54px;
  border-bottom: 1px solid var(--line);
}

.relationship-row:last-child {
  border-bottom: 0;
}

.relationship-avatar {
  display: grid;
  place-items: center;
  width: 30px;
  height: 30px;
  border-radius: 6px;
  color: var(--accent);
  background: var(--accent-soft);
  font-size: 11px;
  font-weight: 700;
}

.relationship-info strong {
  display: block;
  font-size: 11px;
  font-weight: 600;
}

.relationship-info span {
  display: block;
  margin-top: 3px;
  color: var(--text-muted);
  font-size: 9px;
}

.relationship-result {
  font-size: 9px;
  font-weight: 600;
}

.relationship-result[data-result="win"] {
  color: var(--green);
}

.relationship-result[data-result="loss"] {
  color: var(--red);
}

.system-list {
  padding: 5px 20px 10px;
}

.system-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  min-height: 45px;
  border-bottom: 1px solid var(--line);
}

.system-row:last-child {
  border-bottom: 0;
}

.system-row > span {
  color: var(--text-secondary);
  font-size: 10px;
}

.system-row > strong {
  font-size: 10px;
  font-weight: 600;
}

.system-online {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--green) !important;
}

.system-online i {
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: currentColor;
}

.system-action {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  color: var(--accent);
  font-size: 10px;
  text-decoration: none;
}

.empty-state {
  padding: 25px 0;
  text-align: center;
  color: var(--text-muted);
  font-size: 10px;
}

/* =========================================================
   Responsive
   ========================================================= */

@media (max-width: 1180px) {
  .hero-grid {
    grid-template-columns: 1fr;
  }

  .rank-list {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .rank-item {
    border-right: 1px solid var(--line);
    border-bottom: 0;
  }

  .rank-item:last-child {
    border-right: 0;
  }
}

@media (max-width: 850px) {
  .dashboard {
    width: 100%;
    padding: 22px 14px 48px;
  }

  .dashboard-header {
    align-items: flex-start;
    flex-direction: column;
    gap: 15px;
  }

  .header-actions {
    width: 100%;
  }

  .connection-status {
    margin-right: auto;
  }

  .account-layout {
    grid-template-columns: 1fr;
  }

  .account-profile {
    padding: 0 0 16px;
    border-right: 0;
    border-bottom: 1px solid var(--line);
  }

  .bottom-grid {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 560px) {
  .dashboard {
    padding-inline: 10px;
  }

  .account-card {
    padding: 15px;
  }

  .account-top {
    align-items: flex-start;
  }

  .account-name {
    font-size: 21px;
  }

  .common-champion-list {
    grid-template-columns: repeat(3, minmax(72px, 1fr));
  }

  .performance-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .performance-metric--record {
    grid-column: 1 / -1;
  }

  .form-strip {
    grid-template-columns: auto repeat(5, minmax(16px, 1fr));
  }

  .form-strip i:nth-of-type(n + 6) {
    display: none;
  }

  .rank-list {
    grid-template-columns: 1fr;
  }

  .rank-item {
    min-height: 82px;
    border-right: 0;
    border-bottom: 1px solid var(--line);
  }

  .content-header {
    padding: 15px;
  }
}
</style>
