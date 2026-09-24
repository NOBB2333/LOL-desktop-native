<script setup lang="ts">
import { ArrowUpRight, CalendarDays, ChevronDown, Swords, Search, UsersRound } from "@lucide/vue";
import { NButton, NInput, NSpin } from "naive-ui";
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { useRoute, useRouter } from "vue-router";
import AssetIcon from "../components/AssetIcon.vue";
import MatchDetailPanel from "../components/MatchDetailPanel.vue";
import MatchMetPlayers from "../components/MatchMetPlayers.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { EncounterRecord, MatchSummary } from "../types/domain";
import { aggregateRelationships, lastSeenLabel, relationLabel } from "../encounters/relationships";
import { scorePlayerName } from "../matches/localPlayers";
import { championImage, relativeTime, roleName } from "../utils/format";

/**
 * 历史页只有两件事：**对局**和**人**。
 *
 * 这里原来有四个页签（最近对局 / 遇到的玩家 / 对局时间线 / BP 记录）。按用户要求收成两个：
 * - 「对局」= 原来的「最近对局」+「对局时间线」合并，展开一局就能看到这一局**发生了什么**
 *   （首杀 / 每波团 / 事件流）以及**跟谁打的**。原来那半页经济差曲线被去掉了——
 *   每分钟一帧的宏观走势回答不了「这局发生了什么」，事件才回答得了。
 * - 「人」= 首页「关系记录」那批人的详细版（同一套聚合口径，见 `encounters/relationships.ts`）。
 *
 * 换句话说：「那一局」和「那个人」是两个入口，点进去都能查到对局细节。
 */
const app = useAppStore();
const route = useRoute();
const router = useRouter();

/**
 * 页签来自 URL，不是本地状态——因为首页的「关系记录」是带 query 链过来的
 * （`/history?player=<puuid>&tab=players`），不读它就等于那个链接是死的。
 * 兼容 `players`（首页先写下的名字）与 `people` 两种写法，别为了统一把已发出去的链接改死。
 */
function tabFromQuery(value: unknown): "matches" | "people" {
  const raw = Array.isArray(value) ? value[0] : value;
  return raw === "players" || raw === "people" ? "people" : "matches";
}
const tab = ref<"matches" | "people">(tabFromQuery(route.query.tab));

const encounters = useQuery({ queryKey: computed(() => ["encounter-history", app.mode]), queryFn: () => backend.encounters(undefined, 100), enabled: computed(() => app.initialized) });
// 这里只把英雄名映射成 id，走默认区服/分段即可（包一层：vue-query 会把查询上下文当第一个参数）。
const champions = useQuery({ queryKey: computed(() => ["champions", app.mode]), queryFn: () => backend.champions(), enabled: computed(() => app.initialized) });
const championIds = computed(() => new Map((champions.data.value ?? []).map((champion) => [champion.name.trim(), champion.id])));
const championIdFor = (name: string, recordedId = 0) => recordedId > 0 ? recordedId : championIds.value.get(name.trim()) ?? 0;
const championNameById = computed(() => new Map((champions.data.value ?? []).map((champion) => [champion.id, champion.name])));
const championNameOf = (id: number) => championNameById.value.get(id) ?? `英雄 #${id}`;

/**
 * 最近对局列表：「对局」页签与展开后的详情共用同一份。
 * 默认页签就是「对局」，所以打开这一页会发这一次请求——这是有意的：选一局是第一步。
 */
const historyMatches = useQuery({
  queryKey: computed(() => ["history-matches", app.mode]),
  queryFn: () => backend.matches(undefined, 0, 20),
  enabled: computed(() => app.initialized && tab.value === "matches"),
});
const matches = computed(() => historyMatches.data.value ?? []);

/** 展开的那一局。0 = 全部收起（同一时间只展开一局，避免长列表滚不动）。 */
const expandedGameId = ref(0);
function toggleMatch(gameId: number) {
  expandedGameId.value = expandedGameId.value === gameId ? 0 : gameId;
}

/**
 * 逐帧明细按需拉：**只有展开的那一局**才请求，并且逐局落盘缓存（后端 `matchTimeline`）。
 * 详情里的事件与团战都从这份数据算出来，所以没有它就没有详情可看。
 */
const detailQuery = useQuery({
  queryKey: computed(() => ["match-timeline", app.mode, expandedGameId.value]),
  queryFn: () => backend.matchTimeline(expandedGameId.value, app.connection.puuid ?? ""),
  enabled: computed(() => expandedGameId.value > 0),
});

/** 原始相遇记录按对局归堆，给「这一局跟谁打的」用。 */
const encountersByGame = computed(() => {
  const map = new Map<number, EncounterRecord[]>();
  for (const record of encounters.data.value ?? []) {
    if (record.liveSnapshot || !(record.gameId > 0)) continue;
    const list = map.get(record.gameId);
    if (list) list.push(record);
    else map.set(record.gameId, [record]);
  }
  return map;
});
const metInGame = (gameId: number, side: "ally" | "enemy") =>
  (encountersByGame.value.get(gameId) ?? []).filter((record) => (side === "ally" ? record.side === "ally" : record.side !== "ally"));

const matchResultTone = (match: MatchSummary) => match.durationMinutes === 0 ? "unfinished" : match.result === "胜利" ? "win" : "loss";
const matchKda = (match: MatchSummary) => `${match.kills}/${match.deaths}/${match.assists}`;

/**
 * 按玩家聚合的相遇档案。口径与首页「关系记录」共用 `encounters/relationships.ts`，两处不会漂。
 *
 * 注意分母：后端相遇记录是从本地保存的战绩现算的，没有终身归档，所以只能说
 * 「最近 N 局里遇到 X 次」，不能写成「一共」。
 */
const aggregates = computed(() => aggregateRelationships(encounters.data.value ?? []));
const playerQuery = ref("");
const visibleAggregates = computed(() => {
  const query = playerQuery.value.trim();
  if (!query) return aggregates.value;
  return aggregates.value.filter((item) => scorePlayerName(query, item.gameName, item.tagLine) !== null);
});
/** 排序口径：按相遇次数（聚合模块的默认顺序）或按最近相遇。 */
const sortMode = ref<"count" | "recent">("count");
const sortedAggregates = computed(() => {
  if (sortMode.value === "count") return visibleAggregates.value;
  return [...visibleAggregates.value].sort((left, right) => Date.parse(right.lastEncounteredAt) - Date.parse(left.lastEncounteredAt));
});
const expandedPuuid = ref("");
function togglePlayer(puuid: string) {
  expandedPuuid.value = expandedPuuid.value === puuid ? "" : puuid;
}

/** `名字#标签`；没有标签时退化成只用名字（与战绩页的查询口径一致）。 */
function riotIdOf(record: { gameName: string; tagLine?: string | null }) {
  const tag = record.tagLine?.trim();
  return tag ? `${record.gameName}#${tag}` : record.gameName;
}
/** 跳到战绩页看这位玩家的完整数据（战绩页按 `?summoner=名字#标签` 查询）。 */
function openInMatches(record: { gameName: string; tagLine?: string | null }) {
  void router.push({ path: "/matches", query: { summoner: riotIdOf(record) } });
}

/**
 * 响应 URL 变化。首页「关系记录」点进来时既要切到「人」，也要把那一行**直接展开**
 * ——否则用户点了某个名字，落到的是一张按相遇次数排序的表，还得自己再找一遍。
 */
watch(
  () => [route.query.tab, route.query.player],
  ([rawTab, rawPlayer]) => {
    tab.value = tabFromQuery(rawTab);
    if (typeof rawPlayer === "string" && rawPlayer) expandedPuuid.value = rawPlayer;
  },
  { immediate: true },
);
</script>

<template>
  <div class="page-shell history-page">
    <PageHeader title="历史" eyebrow="LOCAL ARCHIVE" meta="两件事：这一局发生了什么（首杀、每波团、事件流），以及跟谁打过（首页关系记录的详细版）">
      <div class="history-tabs">
        <button type="button" :class="{ active: tab === 'matches' }" @click="tab = 'matches'">
          <Swords :size="14" />对局
        </button>
        <button type="button" :class="{ active: tab === 'people' }" @click="tab = 'people'">
          <UsersRound :size="14" />人
        </button>
      </div>
    </PageHeader>

    <!-- ── 对局 ─────────────────────────────────────────────────────────── -->
    <section v-if="tab === 'matches'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">MATCHES</span>
          <h2>最近的对局</h2>
          <p>点一局展开：这一局的首杀、每波团与完整事件流，以及同场的是谁。</p>
        </div>
        <span class="history-count">{{ matches.length }} <small>局</small></span>
      </header>

      <div v-if="historyMatches.isPending.value" class="history-empty">
        <NSpin size="small" />
        <strong>正在读取最近对局</strong>
        <span>只列本地账号的战绩。</span>
      </div>

      <div v-else-if="!matches.length" class="history-empty">
        <CalendarDays :size="24" />
        <strong>还没有最近对局</strong>
        <span>客户端连上并打完一局之后，这里会出现记录。</span>
      </div>

      <div v-else class="match-list">
        <article v-for="match in matches" :key="match.gameId" class="match-card" :data-tone="matchResultTone(match)" :class="{ 'is-open': expandedGameId === match.gameId }">
          <button type="button" class="match-card__head" :aria-expanded="expandedGameId === match.gameId" @click="toggleMatch(match.gameId)">
            <AssetIcon kind="champion" :id="match.championId" :name="match.championName" :fallback-url="championImage(match.championId)" size="sm" />
            <span class="match-card__title">
              <b>{{ match.championName }}</b>
              <small>{{ match.queueName }} · {{ roleName(match.position) }} · {{ relativeTime(match.playedAt) }}</small>
            </span>
            <span class="match-card__result" :data-tone="matchResultTone(match)">{{ matchResultTone(match) === 'win' ? '胜利' : matchResultTone(match) === 'loss' ? '失败' : '未完成' }}</span>
            <span class="match-card__kda">{{ matchKda(match) }}</span>
            <span class="match-card__duration">{{ match.durationMinutes ? `${match.durationMinutes} 分钟` : '—' }}</span>
            <ChevronDown :size="14" class="match-card__caret" />
          </button>

          <!-- 展开才是重点：默认只给一行摘要，细节按需加载（逐帧数据要走一次客户端）。 -->
          <div v-if="expandedGameId === match.gameId" class="match-card__body">
            <section class="match-card__met">
              <h4>同场的人 <small>来自本地相遇档案</small></h4>
              <MatchMetPlayers :allies="metInGame(match.gameId, 'ally')" :enemies="metInGame(match.gameId, 'enemy')" @open="openInMatches" />
            </section>

            <div v-if="detailQuery.isPending.value" class="match-card__state">
              <NSpin size="small" />
              <span>正在解析逐帧数据（第一次读一局要向客户端取一次明细）</span>
            </div>
            <div v-else-if="detailQuery.isError.value" class="match-card__state">
              <span>这一局拿不到逐帧数据：自定义对局、重开局、或客户端还没缓存明细时会这样。上面「同场的人」不受影响。</span>
            </div>
            <MatchDetailPanel v-else-if="detailQuery.data.value" :timeline="detailQuery.data.value" :champion-name-of="championNameOf" />
          </div>
        </article>
      </div>
    </section>

    <!-- ── 人 ───────────────────────────────────────────────────────────── -->
    <section v-else class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">PEOPLE</span>
          <h2>遇到过的人</h2>
          <p>与首页「关系记录」同一批人、同一套口径；点一行展开逐局细节，或直接去战绩页看他的完整数据。</p>
        </div>
        <div class="history-archive-tools">
          <NInput v-model:value="playerQuery" size="small" clearable placeholder="按名字模糊筛选"><template #prefix><Search :size="14" /></template></NInput>
          <div class="history-sort" role="group" aria-label="排序方式">
            <button type="button" :class="{ active: sortMode === 'count' }" @click="sortMode = 'count'">相遇次数</button>
            <button type="button" :class="{ active: sortMode === 'recent' }" @click="sortMode = 'recent'">最近相遇</button>
          </div>
          <span class="history-count">{{ sortedAggregates.length }} <small>/ {{ aggregates.length }} 人</small></span>
        </div>
      </header>

      <!--
        分母必须说清楚：本地相遇记录是从保存下来的战绩现算的，没有终身归档。
        写成「一共打了多少局」就是在撒谎，所以只说「最近 N 局里遇到几次」。
      -->
      <p v-if="aggregates.length" class="history-archive-note">
        分母是最近 {{ aggregates[0]?.windowGames ?? 0 }} 局：本地只保存战绩现算的相遇记录，没有终身归档。
      </p>

      <div v-if="!encounters.data.value?.length" class="history-empty">
        <UsersRound :size="24" />
        <strong>还没有遇到玩家记录</strong>
        <span>对局页获取到十人阵容后，会自动保存玩家摘要。</span>
      </div>

      <div v-else-if="!sortedAggregates.length" class="history-empty">
        <Search :size="24" />
        <strong>本地档案里没有匹配的玩家</strong>
        <span>这里只搜你已经遇到过的人，不会去查其他大区的同名账号。</span>
      </div>

      <div v-else class="encounter-table">
        <div class="encounter-table__head">
          <span>玩家</span>
          <span>相遇</span>
          <span>最近英雄</span>
          <span>我方胜率</span>
          <span>最近相遇</span>
          <span />
        </div>
        <template v-for="aggregate in sortedAggregates" :key="aggregate.puuid">
          <button type="button" class="encounter-table__row" :class="{ 'is-open': expandedPuuid === aggregate.puuid }" @click="togglePlayer(aggregate.puuid)">
            <div class="encounter-player">
              <span class="encounter-player__avatar">{{ aggregate.gameName.slice(0, 1) }}</span>
              <div>
                <strong>{{ aggregate.gameName }}<em v-if="aggregate.tagLine">#{{ aggregate.tagLine }}</em></strong>
                <small class="encounter-player__relation">{{ relationLabel(aggregate) }}</small>
              </div>
            </div>
            <div class="encounter-count"><strong>{{ aggregate.totalGames }}</strong><small>次</small></div>
            <div class="encounter-champion">
              <AssetIcon kind="champion" :id="championIdFor(aggregate.last.championName, aggregate.last.championId)" :name="aggregate.last.championName || '未记录英雄'" :fallback-url="championImage(championIdFor(aggregate.last.championName, aggregate.last.championId))" size="sm" />
              <span>{{ aggregate.last.championName || '未记录英雄' }}</span>
            </div>
            <div class="encounter-rate">
              <strong>{{ aggregate.decidedGames ? `${Math.round(aggregate.winRate * 100)}%` : '—' }}</strong>
              <small v-if="aggregate.decidedGames">{{ aggregate.wins }}胜{{ aggregate.decidedGames - aggregate.wins }}负</small>
            </div>
            <time class="encounter-time">{{ lastSeenLabel(aggregate) || relativeTime(aggregate.lastEncounteredAt) }}</time>
            <ChevronDown :size="14" class="encounter-caret" />
          </button>

          <!-- 展开 = 逐局细节：和他的、我的 KDA 并排，外加胜负、模式与时间。 -->
          <div v-if="expandedPuuid === aggregate.puuid" class="encounter-detail">
            <div class="encounter-detail__head">
              <span />
              <span />
              <span>英雄</span>
              <span>他</span>
              <span>我</span>
              <span>结果</span>
              <span>模式 / 时间</span>
            </div>
            <div v-for="game in aggregate.games" :key="`${aggregate.puuid}-${game.gameId}`" class="encounter-detail__row">
              <span class="encounter-detail__side" :data-side="game.side">{{ game.side === 'ally' ? '队友' : '对手' }}</span>
              <AssetIcon kind="champion" :id="championIdFor(game.championName, game.championId)" :name="game.championName" :fallback-url="championImage(championIdFor(game.championName, game.championId))" size="xs" />
              <b>{{ game.championName || '未记录英雄' }}</b>
              <span class="encounter-detail__kda">他 {{ game.kills }}/{{ game.deaths }}/{{ game.assists }}</span>
              <span class="encounter-detail__self">我 {{ game.selfKills }}/{{ game.selfDeaths }}/{{ game.selfAssists }}</span>
              <span class="encounter-detail__result" :data-win="game.won === null ? 'unknown' : String(game.won)">{{ game.won === null ? '未知' : game.won ? '胜利' : '失败' }}</span>
              <time>{{ game.queueName || '未知模式' }} · {{ relativeTime(game.encounteredAt) }}</time>
            </div>
            <div class="encounter-detail__foot">
              <NButton size="tiny" secondary @click.stop="openInMatches(aggregate)"><template #icon><ArrowUpRight :size="12" /></template>在战绩页查看 {{ riotIdOf(aggregate) }}</NButton>
            </div>
          </div>
        </template>
      </div>
    </section>
  </div>
</template>

<style scoped>
.history-page { max-width: 1200px; }

/* Tab 切换 */
.history-tabs { display: inline-flex; gap: 4px; padding: 4px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-raised); }
.history-tabs button { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 14px; border: 0; border-radius: 5px; color: var(--text-secondary); background: transparent; cursor: pointer; font-size: 12px; font-weight: 500; transition: color .15s, background .15s; }
.history-tabs button.active { color: var(--accent); background: var(--accent-soft); }
.history-tabs button:not(.active):hover { color: var(--text-primary); background: var(--surface-muted); }

/* Section */
.history-section { border: 1px solid var(--line); border-radius: 8px; background: var(--surface); overflow: hidden; }
.history-section__header { display: flex; align-items: flex-start; justify-content: space-between; gap: 20px; padding: 18px 20px 15px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.history-section__header .eyebrow { display: block; margin-bottom: 4px; }
.history-section__header h2 { margin: 0 0 5px; font-size: 16px; font-weight: 600; }
.history-section__header p { margin: 0; color: var(--text-secondary); font-size: 11px; }
.history-count { flex: 0 0 auto; text-align: right; font-size: 24px; font-weight: 700; color: var(--accent); line-height: 1; font-variant-numeric: tabular-nums; }
.history-count small { font-size: 12px; font-weight: 400; color: var(--text-secondary); margin-left: 3px; }
.history-archive-tools { display: flex; align-items: center; gap: 12px; flex: 0 0 auto; }
.history-archive-tools .n-input { width: min(200px, 34vw); }
.history-archive-note { margin: 12px 16px 0; color: var(--text-muted); font-size: 10px; }

/* 空状态 */
.history-empty { display: grid; place-items: center; gap: 8px; min-height: 200px; padding: 32px; color: var(--text-muted); text-align: center; }
.history-empty svg { color: var(--accent); opacity: .4; }
.history-empty strong { color: var(--text-primary); font-size: 14px; }
.history-empty span { font-size: 12px; }

/* ── 对局列表：一行摘要，点开才是细节 ─────────────────────────────── */
.match-list { display: grid; gap: 8px; padding: 10px; background: var(--surface-muted); }
.match-card { border: 1px solid var(--line); border-left: 3px solid var(--line-strong); background: var(--surface); }
.match-card[data-tone="win"] { border-left-color: var(--blue); }
.match-card[data-tone="loss"] { border-left-color: var(--red); }
.match-card[data-tone="unfinished"] { border-left-color: var(--amber); }
.match-card.is-open { border-color: var(--accent); }
.match-card__head { display: grid; grid-template-columns: 30px minmax(0, 1fr) 48px 76px 66px 18px; align-items: center; gap: 10px; width: 100%; padding: 9px 12px; border: 0; color: inherit; background: transparent; cursor: pointer; font: inherit; text-align: left; transition: background .1s; }
.match-card__head:hover { background: var(--surface-raised); }
.match-card__title { min-width: 0; }
.match-card__title b { display: block; overflow: hidden; font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.match-card__title small { display: block; margin-top: 2px; overflow: hidden; color: var(--text-secondary); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.match-card__result { font-size: 12px; font-weight: 600; }
.match-card__result[data-tone="win"] { color: var(--blue); }
.match-card__result[data-tone="loss"] { color: var(--red); }
.match-card__result[data-tone="unfinished"] { color: var(--amber); }
.match-card__kda, .match-card__duration { color: var(--text-secondary); font-size: 11px; font-variant-numeric: tabular-nums; }
.match-card__caret { color: var(--text-muted); transition: transform .15s; }
.match-card.is-open .match-card__caret { transform: rotate(180deg); }
.match-card__body { display: grid; gap: 14px; padding: 12px 14px 14px; border-top: 1px solid var(--line); background: var(--surface); }
.match-card__met h4 { display: flex; align-items: baseline; gap: 7px; margin: 0 0 8px; font-size: 12px; font-weight: 600; }
.match-card__met h4 small { color: var(--text-muted); font-size: 9px; font-weight: 400; }
.match-card__state { display: flex; align-items: center; gap: 8px; padding: 12px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }

/* 遇到玩家 */
.encounter-table { overflow-x: auto; }
.encounter-table__head, .encounter-table__row { display: grid; grid-template-columns: minmax(180px, 1.8fr) 74px minmax(130px, 1fr) 96px 104px 24px; align-items: center; gap: 12px; min-width: 720px; padding: 0 16px; }
.encounter-table__head { min-height: 38px; border-bottom: 1px solid var(--line); background: var(--surface-muted); color: var(--text-muted); font-size: 11px; font-weight: 500; }
/* 行现在是可点的按钮（点开逐局细节），所以要显式抹掉 button 的默认外观。 */
.encounter-table__row { width: 100%; min-height: 56px; padding-top: 10px; padding-bottom: 10px; border: 0; border-bottom: 1px solid var(--line); color: inherit; background: transparent; cursor: pointer; font: inherit; font-size: 12px; text-align: left; transition: background .1s; }
.encounter-table__row:hover { background: var(--surface-muted); }
.encounter-table__row.is-open { background: var(--accent-soft); }
.encounter-player { display: flex; align-items: center; gap: 10px; min-width: 0; }
.encounter-player__avatar { display: grid; place-items: center; width: 30px; height: 30px; border-radius: 50%; border: 1px solid var(--line); color: var(--accent); background: var(--accent-soft); font-size: 13px; font-weight: 600; flex: 0 0 30px; }
.encounter-player > div { min-width: 0; }
.encounter-player strong { display: block; font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.encounter-player strong em { color: var(--text-secondary); font-style: normal; font-weight: 400; }
/* 这一行原来放 PUUID——对用户没有任何意义；改成关系摘要（队友/对手各几次）。 */
.encounter-player__relation { display: block; margin-top: 2px; color: var(--text-muted); font-size: 10px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 170px; }
.encounter-count { display: flex; align-items: baseline; gap: 2px; }
.encounter-count strong { font-size: 15px; font-variant-numeric: tabular-nums; }
.encounter-count small { color: var(--text-secondary); font-size: 10px; }
.encounter-champion { display: flex; align-items: center; gap: 7px; min-width: 0; }
.encounter-champion span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
.encounter-rate strong { display: block; font-size: 13px; font-variant-numeric: tabular-nums; }
.encounter-rate small { color: var(--text-secondary); font-size: 10px; }
.encounter-time { color: var(--text-secondary); font-size: 11px; }
.encounter-caret { color: var(--text-muted); transition: transform .15s; }
.encounter-table__row.is-open .encounter-caret { transform: rotate(180deg); }
/* 展开区：紧跟在那一行下面，读起来仍然属于同一个玩家。 */
.encounter-detail { display: grid; gap: 6px; padding: 10px 16px 12px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.encounter-detail__head, .encounter-detail__row { display: grid; grid-template-columns: 50px 22px minmax(96px, 1fr) 100px 100px 50px minmax(120px, 1fr); align-items: center; gap: 8px; min-width: 720px; font-size: 11px; }
/* 表头只在展开区里出现一次，说明每一列是什么（否则「他/我」两列 KDA 要猜）。 */
.encounter-detail__head { color: var(--text-muted); font-size: 10px; }
.encounter-detail__side { padding: 1px 6px; border-radius: 3px; background: var(--surface); color: var(--text-secondary); font-size: 10px; text-align: center; }
.encounter-detail__side[data-side="ally"] { color: var(--blue); }
.encounter-detail__side[data-side="enemy"] { color: var(--red); }
.encounter-detail__kda, .encounter-detail__self { color: var(--text-secondary); font-variant-numeric: tabular-nums; white-space: nowrap; }
.encounter-detail__result[data-win="true"] { color: var(--blue); }
.encounter-detail__result[data-win="false"] { color: var(--red); }
.encounter-detail__result[data-win="unknown"] { color: var(--text-muted); }
.encounter-detail__row time { color: var(--text-muted); }
.encounter-detail__foot { display: flex; justify-content: flex-end; }

/* 排序切换：两个小按钮，选中的那个用强调色。 */
.history-sort { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
.history-sort button { padding: 4px 10px; border: 0; color: var(--text-secondary); background: var(--surface); cursor: pointer; font-size: 11px; }
.history-sort button + button { border-left: 1px solid var(--line); }
.history-sort button.active { color: var(--accent); background: var(--accent-soft); font-weight: 600; }

@media (max-width: 900px) {
  .match-card__head { grid-template-columns: 30px minmax(0, 1fr) 48px 18px; }
  .match-card__kda, .match-card__duration { display: none; }
  .history-archive-tools { flex-wrap: wrap; }
}
</style>
