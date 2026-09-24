<script setup lang="ts">
import { ArrowUpRight, CalendarDays, ChevronDown, ClipboardList, Eye, Search, Shield, TrendingUp, UsersRound } from "@lucide/vue";
import { NButton, NInput, NSpin } from "naive-ui";
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { useRouter } from "vue-router";
import AssetIcon from "../components/AssetIcon.vue";
import MatchMetPlayers from "../components/MatchMetPlayers.vue";
import MatchTimelinePanel from "../components/MatchTimelinePanel.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { EncounterRecord, MatchSummary } from "../types/domain";
import { championImage, relativeTime, roleName } from "../utils/format";
import { queueLabel } from "../utils/queue";
import { scorePlayerName } from "../matches/localPlayers";
import { clockOf } from "../matches/timeline";
import { aggregateRelationships, lastSeenLabel, relationLabel } from "../encounters/relationships";

const app = useAppStore();
/**
 * 默认落在「对局时间线」。
 *
 * 这一页的主线是「这一局打成什么样 + 这一局遇到了谁」，其余三个页签（最近对局、
 * 遇到的玩家、BP 记录）是旁支。页签顺序也按这个主次排，中间还加了一条分隔线，
 * 所以默认页签必须与排第一的那个一致，否则「点进来看到的」和「排最前的」不是同一个。
 */
const tab = ref<"matches" | "encounters" | "timeline" | "bp">("timeline");
const bp = useQuery({ queryKey: computed(() => ["bp-history", app.mode]), queryFn: backend.bpHistory, enabled: computed(() => app.initialized) });
const encounters = useQuery({ queryKey: computed(() => ["encounter-history", app.mode]), queryFn: () => backend.encounters(undefined, 100), enabled: computed(() => app.initialized) });
// 这里只把英雄名映射成 id，走默认区服/分段即可（包一层：vue-query 会把查询上下文当第一个参数）。
const champions = useQuery({ queryKey: computed(() => ["champions", app.mode]), queryFn: () => backend.champions(), enabled: computed(() => app.initialized) });
const championIds = computed(() => new Map((champions.data.value ?? []).map((champion) => [champion.name.trim(), champion.id])));
const championIdFor = (name: string, recordedId = 0) => recordedId > 0 ? recordedId : championIds.value.get(name.trim()) ?? 0;
const scoreTone = (ally: number, enemy: number) => ally >= enemy ? "ally" : "enemy";
/**
 * 玩家档案的本地模糊筛选。
 *
 * 只用**已经取回来的**本地记录过一遍，不发请求；判分规则与战绩页的
 * 「本地见过的玩家」兜底完全共用（`matches/localPlayers.ts`），
 * 所以两边「像不像」的标准不会漂。
 */
const playerQuery = ref("");
/**
 * 按玩家聚合的相遇档案。
 *
 * 这里原来列的是「每局每人一行」的原始记录：同一个人打了 8 局就出现 8 次，
 * 既看不出「跟他一共打了多少局」，也没法按交情排序。聚合口径与首页「关系记录」
 * 共用 `encounters/relationships.ts`，两处不会漂。
 *
 * 注意分母：后端相遇记录是从本地保存的战绩现算的，没有终身归档，所以只能说
 * 「最近 N 局里遇到 X 次」，不能写成「一共」。
 */
const aggregates = computed(() => aggregateRelationships(encounters.data.value ?? []));
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
/** 展开的那一位：展开后逐局列出相遇细节，这就是「可以看到对应的信息」。 */
const expandedPuuid = ref("");
function togglePlayer(puuid: string) {
  expandedPuuid.value = expandedPuuid.value === puuid ? "" : puuid;
}
/**
 * 原始记录按对局归堆，给「最近对局」页签用。
 *
 * 战绩页回答的是「我打得怎么样」，这里额外回答「这局是跟谁打的」——
 * 这是本地档案独有的信息，也是这一页存在的理由。
 */
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
const router = useRouter();
/** `名字#标签`；没有标签时退化成只用名字（与战绩页的查询口径一致）。 */
function riotIdOf(record: { gameName: string; tagLine?: string | null }) {
  const tag = record.tagLine?.trim();
  return tag ? `${record.gameName}#${tag}` : record.gameName;
}
/** 跳到战绩页看这位玩家的完整数据（战绩页按 `?summoner=名字#标签` 查询）。 */
function openInMatches(record: { gameName: string; tagLine?: string | null }) {
  void router.push({ path: "/matches", query: { summoner: riotIdOf(record) } });
}
const matchResultTone = (match: MatchSummary) => match.durationMinutes === 0 ? "unfinished" : match.result === "胜利" ? "win" : "loss";
const matchKda = (match: MatchSummary) => `${match.kills}/${match.deaths}/${match.assists}`;

/**
 * 最近对局列表：「对局时间线」与「最近对局」两个页签共用同一份。
 *
 * 取的是**本地账号**最近的对局（不传名字就是自己），也只在这两个页签之一可见时
 * 才请求。注意默认页签就是「对局时间线」，所以现在**打开历史页就会发这一次请求**
 * ——这是有意的：先选一局是这一页的第一步，省掉它反而要多一次点击。列出的只是
 * 对局摘要，不含逐帧明细（明细要选中某一局才拉）。选中的局决定时间线查询的 key。
 */
const historyMatches = useQuery({
  queryKey: computed(() => ["history-matches", app.mode]),
  queryFn: () => backend.matches(undefined, 0, 20),
  enabled: computed(() => app.initialized && (tab.value === "matches" || tab.value === "timeline")),
});
const selectedGameId = ref(0);
// 列表到手后默认选最近一局；用户手动选过就不再覆盖（只在未选时兜底）。
watch(
  () => historyMatches.data.value,
  (list) => {
    if (!list?.length) return;
    if (list.some((match) => match.gameId === selectedGameId.value)) return;
    selectedGameId.value = list[0].gameId;
  },
  { immediate: true },
);
const timelineQuery = useQuery({
  queryKey: computed(() => ["match-timeline", app.mode, selectedGameId.value]),
  queryFn: () => backend.matchTimeline(selectedGameId.value, app.connection.puuid ?? ""),
  enabled: computed(() => tab.value === "timeline" && selectedGameId.value > 0),
});
const championNameById = computed(() => new Map((champions.data.value ?? []).map((champion) => [champion.id, champion.name])));
const championNameOf = (id: number) => championNameById.value.get(id) ?? `英雄 #${id}`;
</script>

<template>
  <div class="page-shell history-page">
    <PageHeader title="历史" eyebrow="LOCAL ARCHIVE" meta="选一局看它的时间线，以及这一局里遇到的人；数据全部来自本地客户端，不保存游戏录像">
      <!--
        页签按主次排：左边两个是这一页的主线（一局打成什么样、这一局遇到谁），
        右边两个是旁支。中间那条竖线就是用来表示这个分组的——不是装饰。
      -->
      <div class="history-tabs">
        <button type="button" :class="{ active: tab === 'timeline' }" @click="tab = 'timeline'">
          <TrendingUp :size="14" />对局时间线
        </button>
        <button type="button" :class="{ active: tab === 'encounters' }" @click="tab = 'encounters'">
          <UsersRound :size="14" />遇到的玩家
        </button>
        <span class="history-tabs__divider" aria-hidden="true" />
        <button type="button" :class="{ active: tab === 'matches' }" @click="tab = 'matches'">
          <CalendarDays :size="14" />最近对局
        </button>
        <button type="button" :class="{ active: tab === 'bp' }" @click="tab = 'bp'">
          <ClipboardList :size="14" />BP 记录
        </button>
      </div>
    </PageHeader>

    <!-- BP 记录 -->
    <section v-if="tab === 'bp'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">BP ARCHIVE</span>
          <h2>每局的禁用、选人与阵容评分</h2>
          <p>记录来源于本地对局监听；当前客户端未提供的数据会明确标注为未记录。</p>
        </div>
        <span class="history-count">{{ bp.data.value?.length ?? 0 }} <small>局</small></span>
      </header>

      <div v-if="!bp.data.value?.length" class="history-empty">
        <ClipboardList :size="24" />
        <strong>还没有 BP 记录</strong>
        <span>完成一次对局后，Ban / Pick / 评分会出现在这里。</span>
      </div>

      <div v-else class="bp-list">
        <article v-for="record in bp.data.value ?? []" :key="record.id" class="bp-card" :data-tone="scoreTone(record.allyScore, record.enemyScore)">
          <!-- 卡片顶部 -->
          <header class="bp-card__header">
            <div class="bp-card__meta">
              <time class="bp-card__date">
                <CalendarDays :size="12" />
                {{ relativeTime(record.createdAt) }}
              </time>
              <strong class="bp-card__mode">{{ queueLabel(record.queueId, record.gameMode) }}</strong>
              <span class="bp-card__id">Queue {{ record.queueId }} · {{ record.id }}</span>
            </div>
            <div class="bp-card__score">
              <span class="bp-card__score-label">阵容评分</span>
              <div class="bp-card__score-value">
                <b :class="scoreTone(record.allyScore, record.enemyScore) === 'ally' ? 'score-win' : 'score-neutral'">
                  {{ record.allyScore.toFixed(0) }}
                </b>
                <span class="score-sep">:</span>
                <b :class="scoreTone(record.allyScore, record.enemyScore) === 'enemy' ? 'score-loss' : 'score-neutral'">
                  {{ record.enemyScore.toFixed(0) }}
                </b>
              </div>
              <span class="bp-card__score-verdict" :class="scoreTone(record.allyScore, record.enemyScore)">
                {{ scoreTone(record.allyScore, record.enemyScore) === 'ally' ? '我方更优' : '敌方更优' }}
              </span>
            </div>
          </header>

          <!-- 阵容 -->
          <div class="bp-card__body">
            <!-- 我方 -->
            <div class="bp-side bp-side--ally">
              <div class="bp-side__head">
                <span>我方 PICK</span>
                <b>{{ record.allyChampions.length }} 位</b>
              </div>
              <div class="bp-champion-list bp-champion-grid">
                <span v-for="(champion, index) in record.allyChampions" :key="`ally-${record.id}-${champion}`" class="bp-champion-entry">
                  <i class="bp-champion-seq">{{ index + 1 }}</i>
                  <AssetIcon kind="champion" :id="championIdFor(champion, record.allyChampionIds[index])" :name="champion" :fallback-url="championImage(championIdFor(champion, record.allyChampionIds[index]))" size="xs" />
                  <b>{{ champion }}</b>
                </span>
              </div>
            </div>

            <!-- 敌方 -->
            <div class="bp-side bp-side--enemy">
              <div class="bp-side__head">
                <span>敌方 PICK</span>
                <b>{{ record.enemyChampions.length }} 位</b>
              </div>
              <div class="bp-champion-list bp-champion-grid">
                <span v-for="(champion, index) in record.enemyChampions" :key="`enemy-${record.id}-${champion}`" class="bp-champion-entry">
                  <i class="bp-champion-seq">{{ index + 1 }}</i>
                  <AssetIcon kind="champion" :id="championIdFor(champion, record.enemyChampionIds[index])" :name="champion" :fallback-url="championImage(championIdFor(champion, record.enemyChampionIds[index]))" size="xs" />
                  <b>{{ champion }}</b>
                </span>
              </div>
            </div>

            <!-- 禁用信息占位 -->
            <div class="bp-ban-placeholder">
              <Shield :size="16" />
              <strong>禁用详情</strong>
              <small>本地记录暂未包含 Ban 详情，后续版本将显示双方禁用顺序</small>
            </div>
          </div>

          <!-- 底部 -->
          <footer class="bp-card__footer">
            <span class="bp-source"><i />本地 BP 记录</span>
            <span class="bp-ai" :class="{ 'bp-ai--empty': !record.aiSummary }">
              {{ record.aiSummary ? `AI：${record.aiSummary}` : 'AI 摘要尚未生成' }}
            </span>
            <NButton size="tiny" secondary disabled>
              <template #icon><Eye :size="12" /></template>查看详情
            </NButton>
          </footer>
        </article>
      </div>
    </section>

    <!-- 玩家档案。注意这里必须是 v-else-if：页签不止一个，用 v-else 会和
         「对局时间线」同时渲染，两个区块一起出现。 -->
    <section v-else-if="tab === 'encounters'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">PLAYER ARCHIVE</span>
          <h2>遇到的玩家</h2>
          <p>按玩家聚合最近遇到过的队友与对手；点一行展开逐局细节，或直接去战绩页看他的完整数据。</p>
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
            <!-- 玩家 -->
            <div class="encounter-player">
              <span class="encounter-player__avatar">{{ aggregate.gameName.slice(0, 1) }}</span>
              <div>
                <strong>{{ aggregate.gameName }}<em v-if="aggregate.tagLine">#{{ aggregate.tagLine }}</em></strong>
                <small class="encounter-player__puuid">{{ relationLabel(aggregate) }}</small>
              </div>
            </div>
            <!-- 相遇次数：这是默认排序口径，也是这一页存在的理由 -->
            <div class="encounter-count"><strong>{{ aggregate.totalGames }}</strong><small>次</small></div>
            <!-- 最近一次用的英雄 -->
            <div class="encounter-champion">
              <AssetIcon kind="champion" :id="championIdFor(aggregate.last.championName, aggregate.last.championId)" :name="aggregate.last.championName || '未记录英雄'" :fallback-url="championImage(championIdFor(aggregate.last.championName, aggregate.last.championId))" size="sm" />
              <span>{{ aggregate.last.championName || '未记录英雄' }}</span>
            </div>
            <!-- 我方视角胜率；没有胜负信息的局不进分母 -->
            <div class="encounter-rate">
              <strong>{{ aggregate.decidedGames ? `${Math.round(aggregate.winRate * 100)}%` : '—' }}</strong>
              <small v-if="aggregate.decidedGames">{{ aggregate.wins }}胜{{ aggregate.decidedGames - aggregate.wins }}负</small>
            </div>
            <!-- 时间 -->
            <time class="encounter-time">{{ lastSeenLabel(aggregate) || relativeTime(aggregate.lastEncounteredAt) }}</time>
            <ChevronDown :size="14" class="encounter-caret" />
          </button>

          <!-- 展开 = 逐局细节：每局的英雄、他的 KDA、我方 KDA、胜负与时间 -->
          <div v-if="expandedPuuid === aggregate.puuid" class="encounter-detail">
            <div v-for="game in aggregate.games" :key="`${aggregate.puuid}-${game.gameId}`" class="encounter-detail__row">
              <span class="encounter-detail__side" :data-side="game.side">{{ game.side === 'ally' ? '队友' : '对手' }}</span>
              <AssetIcon kind="champion" :id="championIdFor(game.championName, game.championId)" :name="game.championName" :fallback-url="championImage(championIdFor(game.championName, game.championId))" size="xs" />
              <b>{{ game.championName || '未记录英雄' }}</b>
              <span class="encounter-detail__kda">他 {{ game.kills }}/{{ game.deaths }}/{{ game.assists }}</span>
              <span class="encounter-detail__self">我 {{ game.selfKills }}/{{ game.selfDeaths }}/{{ game.selfAssists }}</span>
              <span class="encounter-detail__result" :data-win="game.won === null ? 'unknown' : String(game.won)">{{ game.won === null ? '未知' : game.won ? '胜利' : '失败' }}</span>
              <time>{{ relativeTime(game.encounteredAt) }}</time>
            </div>
            <div class="encounter-detail__foot">
              <NButton size="tiny" secondary @click.stop="openInMatches(aggregate)"><template #icon><ArrowUpRight :size="12" /></template>在战绩页查看 {{ riotIdOf(aggregate) }}</NButton>
            </div>
          </div>
        </template>
      </div>
    </section>

    <!-- 对局时间线 -->
    <section v-else-if="tab === 'timeline'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">MATCH TIMELINE</span>
          <h2>经济曲线与关键事件</h2>
          <p>数据来自本地客户端的逐帧记录：双方经济差、野怪、防御塔与镀层。选一局看走势。</p>
        </div>
        <span class="history-count">{{ historyMatches.data.value?.length ?? 0 }} <small>局可选</small></span>
      </header>

      <div v-if="historyMatches.isPending.value" class="history-empty">
        <NSpin size="small" />
        <strong>正在读取最近对局</strong>
        <span>本页只列本地账号的战绩。</span>
      </div>

      <div v-else-if="!historyMatches.data.value?.length" class="history-empty">
        <TrendingUp :size="24" />
        <strong>还没有可回看的对局</strong>
        <span>打完一局后，这里会出现它的经济曲线和关键事件。</span>
      </div>

      <div v-else class="history-timeline-body">
        <div class="timeline-picker" role="tablist" aria-label="选择对局">
          <button
            v-for="match in historyMatches.data.value ?? []"
            :key="match.gameId"
            type="button"
            class="timeline-picker__item"
            :class="{ active: match.gameId === selectedGameId }"
            :data-result="match.result === '胜利' ? 'win' : 'loss'"
            @click="selectedGameId = match.gameId"
          >
            <AssetIcon kind="champion" :id="match.championId" :name="match.championName" :fallback-url="championImage(match.championId)" size="xs" />
            <span class="timeline-picker__body">
              <strong>{{ match.championName || '未知英雄' }}</strong>
              <small>{{ match.kda }} · {{ clockOf((match.durationMinutes || 0) * 60) }}</small>
            </span>
          </button>
        </div>

        <div v-if="timelineQuery.isPending.value" class="history-empty">
          <NSpin size="small" />
          <strong>正在解析逐帧数据</strong>
          <span>首次读取一局需要向客户端取一次明细，之后会走本地缓存。</span>
        </div>

        <div v-else-if="timelineQuery.isError.value" class="history-empty">
          <TrendingUp :size="24" />
          <strong>这一局没有逐帧数据</strong>
          <span>自定义对局、重开局或客户端尚未缓存明细时会拿不到。换一局试试。</span>
        </div>

        <MatchTimelinePanel v-else-if="timelineQuery.data.value" :timeline="timelineQuery.data.value" :champion-name="championNameOf" />

        <!--
          这一局的同场玩家。刻意放在时间线**下面**而不是另开一个页签：看着曲线最自然的
          下一个问题就是「这局是跟谁打的」，这两件事本来就属于同一局。
          数据不依赖时间线是否取到——逐帧拿不到时（自定义局等）这块照样有内容。
        -->
        <div v-if="selectedGameId" class="timeline-met">
          <header class="timeline-met__head">
            <UsersRound :size="13" />
            <strong>这一局遇到的人</strong>
            <small>来自本地相遇档案；点名字去战绩页看他的完整数据</small>
          </header>
          <MatchMetPlayers :allies="metInGame(selectedGameId, 'ally')" :enemies="metInGame(selectedGameId, 'enemy')" @open="openInMatches" />
        </div>
      </div>
    </section>

    <!--
      最近对局：本地档案视角。
      战绩页回答「我打得怎么样」，这里额外回答「这一局是跟谁打的」——同场玩家直接从
      本地相遇记录里取，不再打一次客户端的接口。
    -->
    <section v-else-if="tab === 'matches'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">RECENT GAMES</span>
          <h2>最近的对局与同场玩家</h2>
          <p>对局列表来自本地客户端；每局下面标出本地档案里记到的队友与对手，点名字直接去战绩页看他的完整数据。</p>
        </div>
        <span class="history-count">{{ historyMatches.data.value?.length ?? 0 }} <small>局</small></span>
      </header>

      <div v-if="historyMatches.isPending.value" class="history-empty">
        <NSpin size="small" />
        <strong>正在读取最近对局</strong>
      </div>

      <div v-else-if="!historyMatches.data.value?.length" class="history-empty">
        <CalendarDays :size="24" />
        <strong>还没有最近对局</strong>
        <span>客户端连上并打完一局之后，这里会出现记录。</span>
      </div>

      <div v-else class="history-recent-list">
        <article v-for="match in historyMatches.data.value ?? []" :key="match.gameId" class="history-recent" :data-tone="matchResultTone(match)">
          <header class="history-recent__head">
            <div class="history-recent__main">
              <AssetIcon kind="champion" :id="match.championId" :name="match.championName" :fallback-url="championImage(match.championId)" size="sm" />
              <span>
                <b>{{ match.championName }}</b>
                <small>{{ match.queueName }} · {{ roleName(match.position) }} · {{ relativeTime(match.playedAt) }}</small>
              </span>
            </div>
            <div class="history-recent__stats">
              <strong :data-tone="matchResultTone(match)">{{ matchResultTone(match) === 'win' ? '胜利' : matchResultTone(match) === 'loss' ? '失败' : '未完成' }}</strong>
              <span>{{ matchKda(match) }}</span>
              <span>{{ match.durationMinutes ? `${match.durationMinutes} 分钟` : '—' }}</span>
            </div>
          </header>

          <MatchMetPlayers class="history-recent__met" :allies="metInGame(match.gameId, 'ally')" :enemies="metInGame(match.gameId, 'enemy')" @open="openInMatches" />
        </article>
      </div>
    </section>
  </div>
</template>

<style scoped>
.history-page { max-width: 1200px; }

/* Tab 切换 */
.history-tabs {
  display: inline-flex;
  gap: 4px;
  padding: 4px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface-raised);
}
.history-tabs button {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 30px;
  padding: 0 12px;
  border: 0;
  border-radius: 5px;
  color: var(--text-secondary);
  background: transparent;
  cursor: pointer;
  font-size: 12px;
  font-weight: 500;
  transition: color 0.15s, background 0.15s;
}
.history-tabs button.active { color: var(--accent); background: var(--accent-soft); }
.history-tabs button:not(.active):hover { color: var(--text-primary); background: var(--surface-muted); }
/* 分组竖线：左边是主线页签（时间线 / 遇到的玩家），右边是旁支。 */
.history-tabs__divider { align-self: stretch; width: 1px; margin: 3px 4px; background: var(--line); }

/* Section */
.history-section {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  overflow: hidden;
}
.history-section__header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 20px;
  padding: 18px 20px 15px;
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
}
.history-section__header .eyebrow { display: block; margin-bottom: 4px; }
.history-section__header h2 { margin: 0 0 5px; font-size: 16px; font-weight: 600; }
.history-section__header p { margin: 0; color: var(--text-secondary); font-size: 11px; }
.history-count { flex: 0 0 auto; text-align: right; font-size: 24px; font-weight: 700; color: var(--accent); line-height: 1; font-variant-numeric: tabular-nums; }
.history-count small { font-size: 12px; font-weight: 400; color: var(--text-secondary); margin-left: 3px; }
.history-archive-tools { display: flex; align-items: center; gap: 12px; flex: 0 0 auto; }
.history-archive-tools .n-input { width: min(200px, 34vw); }

/* 空状态 */
.history-empty {
  display: grid;
  place-items: center;
  gap: 8px;
  min-height: 200px;
  padding: 32px;
  color: var(--text-muted);
  text-align: center;
}
.history-empty svg { color: var(--accent); opacity: 0.4; }
.history-empty strong { color: var(--text-primary); font-size: 14px; }
.history-empty span { font-size: 12px; }

/* BP 列表 */
.bp-list { display: grid; gap: 8px; padding: 10px; background: var(--surface-muted); }

/* BP 卡片 */
.bp-card {
  border: 1px solid var(--line);
  border-left: 3px solid var(--blue);
  border-radius: 6px;
  background: var(--surface);
  overflow: hidden;
}
.bp-card[data-tone="enemy"] { border-left-color: var(--red); }

.bp-card__header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  padding: 12px 14px 10px;
  border-bottom: 1px solid var(--line);
}
.bp-card__meta { flex: 1; min-width: 0; }
.bp-card__date {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  color: var(--text-muted);
  font-size: 10px;
  margin-bottom: 5px;
}
.bp-card__mode { display: block; font-size: 13px; font-weight: 600; margin-bottom: 3px; }
.bp-card__id { display: block; color: var(--text-secondary); font-size: 10px; }
.bp-card__score { text-align: right; flex: 0 0 auto; }
.bp-card__score-label { display: block; color: var(--text-muted); font-size: 10px; margin-bottom: 4px; }
.bp-card__score-value { display: flex; align-items: baseline; gap: 5px; justify-content: flex-end; }
.bp-card__score-value b { font-size: 22px; font-weight: 700; font-variant-numeric: tabular-nums; line-height: 1; }
.score-win { color: var(--blue); }
.score-loss { color: var(--red); }
.score-neutral { color: var(--text-secondary); }
.score-sep { color: var(--text-muted); font-size: 16px; font-style: normal; }
.bp-card__score-verdict {
  display: block;
  margin-top: 4px;
  font-size: 11px;
  font-weight: 500;
}
.bp-card__score-verdict.ally { color: var(--blue); }
.bp-card__score-verdict.enemy { color: var(--red); }

.bp-card__body {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) minmax(170px, 0.6fr);
  gap: 10px;
  padding: 12px 14px;
}
.bp-side {
  padding: 10px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface-raised);
}
.bp-side--ally { border-top: 2px solid var(--blue); }
.bp-side--enemy { border-top: 2px solid var(--red); }
.bp-side__head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
  color: var(--text-secondary);
  font-size: 10px;
}
.bp-side__head b { color: var(--text-primary); font-weight: 600; }
.bp-champion-list.bp-champion-grid, .bp-champion-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 4px 8px;
}
.bp-champion-entry {
  display: flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
  font-size: 11px;
  white-space: nowrap;
}
.bp-champion-entry > b { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.bp-champion-seq {
  display: inline-grid;
  flex: 0 0 auto;
  place-items: center;
  width: 14px;
  height: 14px;
  border-radius: 2px;
  color: var(--text-muted);
  background: var(--surface-muted);
  font-size: 9px;
  font-style: normal;
}
.bp-ban-placeholder {
  display: grid;
  place-items: center;
  place-content: center;
  gap: 5px;
  padding: 10px;
  border: 1px dashed var(--line-strong);
  border-radius: 6px;
  text-align: center;
  color: var(--text-muted);
}
.bp-ban-placeholder svg { opacity: 0.4; }
.bp-ban-placeholder strong { font-size: 11px; font-weight: 500; color: var(--text-secondary); }
.bp-ban-placeholder small { font-size: 10px; line-height: 1.4; color: var(--text-muted); }

.bp-card__footer {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 9px 14px;
  border-top: 1px solid var(--line);
  background: var(--surface-muted);
  font-size: 11px;
}
.bp-source {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--text-secondary);
  flex: 0 0 auto;
}
.bp-source i { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); }
.bp-ai { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text-secondary); }
.bp-ai--empty { color: var(--text-muted); font-style: italic; }

/* 遇到玩家 */
.encounter-table { overflow-x: auto; }
.encounter-table__head,
.encounter-table__row {
  display: grid;
  grid-template-columns: minmax(180px, 1.8fr) 74px minmax(130px, 1fr) 96px 104px 24px;
  align-items: center;
  gap: 12px;
  min-width: 720px;
  padding: 0 16px;
}
.encounter-table__head {
  min-height: 38px;
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
  color: var(--text-muted);
  font-size: 11px;
  font-weight: 500;
}
/* 行现在是可点的按钮（点开逐局细节），所以要显式抹掉 button 的默认外观。 */
.encounter-table__row {
  width: 100%;
  min-height: 56px;
  padding-top: 10px;
  padding-bottom: 10px;
  border: 0;
  border-bottom: 1px solid var(--line);
  color: inherit;
  background: transparent;
  cursor: pointer;
  font: inherit;
  font-size: 12px;
  text-align: left;
  transition: background 0.1s;
}
.encounter-table__row:hover { background: var(--surface-muted); }
.encounter-table__row.is-open { background: var(--accent-soft); }
.encounter-player { display: flex; align-items: center; gap: 10px; min-width: 0; }
.encounter-player__avatar {
  display: grid;
  place-items: center;
  width: 30px;
  height: 30px;
  border-radius: 50%;
  border: 1px solid var(--line);
  color: var(--accent);
  background: var(--accent-soft);
  font-size: 13px;
  font-weight: 600;
  flex: 0 0 30px;
}
.encounter-player > div { min-width: 0; }
.encounter-player strong { display: block; font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.encounter-player strong em { color: var(--text-secondary); font-style: normal; font-weight: 400; }
/* 这一行原来放 PUUID——对用户没有任何意义；改成关系摘要（队友/对手各几次）。 */
.encounter-player__puuid {
  display: block;
  margin-top: 2px;
  color: var(--text-muted);
  font-size: 10px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 170px;
}
.encounter-count { display: flex; align-items: baseline; gap: 2px; }
.encounter-count strong { font-size: 15px; font-variant-numeric: tabular-nums; }
.encounter-count small { color: var(--text-secondary); font-size: 10px; }
.encounter-champion { display: flex; align-items: center; gap: 7px; min-width: 0; }
.encounter-champion span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
.encounter-rate strong { display: block; font-size: 13px; font-variant-numeric: tabular-nums; }
.encounter-rate small { color: var(--text-secondary); font-size: 10px; }
.encounter-time { color: var(--text-secondary); font-size: 11px; }
.encounter-caret { color: var(--text-muted); transition: transform 140ms ease; }
.encounter-table__row.is-open .encounter-caret { transform: rotate(180deg); }
/* 展开区：紧跟在那一行下面，读起来仍然属于同一个玩家。 */
.encounter-detail {
  display: grid;
  gap: 6px;
  padding: 10px 16px 12px;
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
}
.encounter-detail__row {
  display: grid;
  grid-template-columns: 50px 22px minmax(96px, 1fr) 100px 100px 50px 86px;
  align-items: center;
  gap: 8px;
  min-width: 720px;
  font-size: 11px;
}
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
.history-archive-note { margin: 0 0 12px; color: var(--text-muted); font-size: 10px; }

/* 「最近对局」：一局一张卡——头部是战绩摘要，下面是本地档案里的同场玩家。 */
.history-recent-list { display: grid; gap: 10px; }
.history-recent { border: 1px solid var(--line); border-left: 3px solid var(--line-strong); background: var(--surface); }
.history-recent[data-tone="win"] { border-left-color: var(--blue); }
.history-recent[data-tone="loss"] { border-left-color: var(--red); }
.history-recent[data-tone="unfinished"] { border-left-color: var(--amber); }
.history-recent__head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 11px 14px; border-bottom: 1px solid var(--line); }
.history-recent__main { display: flex; align-items: center; gap: 10px; min-width: 0; }
.history-recent__main b { display: block; font-size: 13px; }
.history-recent__main small { display: block; margin-top: 2px; color: var(--text-secondary); font-size: 10px; }
.history-recent__stats { display: flex; align-items: center; gap: 12px; color: var(--text-secondary); font-size: 11px; font-variant-numeric: tabular-nums; }
.history-recent__stats strong { font-size: 12px; }
.history-recent__stats strong[data-tone="win"] { color: var(--blue); }
.history-recent__stats strong[data-tone="loss"] { color: var(--red); }
.history-recent__stats strong[data-tone="unfinished"] { color: var(--amber); }
/* 同场玩家的两列圆片现在由 MatchMetPlayers 组件渲染，这里只负责外边距。 */
.history-recent__met { padding: 10px 14px; }

/* 时间线页签的内容区：统一内边距，选局器 / 曲线 / 同场玩家之间交给 grid gap。 */
.history-timeline-body { display: grid; gap: 14px; padding: 14px 16px; }
/* 「这一局遇到的人」：用一条分隔线与上面的曲线分开——上面是走势，下面是名单。 */
.timeline-met { padding-top: 12px; border-top: 1px solid var(--line); }
.timeline-met__head { display: flex; align-items: center; gap: 7px; margin-bottom: 9px; }
.timeline-met__head svg { color: var(--accent); }
.timeline-met__head strong { color: var(--text-primary); font-size: 12px; }
.timeline-met__head small { color: var(--text-muted); font-size: 10px; }
/* 时间线的对局选择器：横向滚动的一排小卡片，选中的那局高亮。 */
.timeline-picker {
  display: flex;
  gap: 6px;
  padding-bottom: 4px;
  overflow-x: auto;
}
.timeline-picker__item {
  display: inline-flex;
  flex: 0 0 auto;
  align-items: center;
  gap: 7px;
  padding: 6px 10px;
  border: 1px solid var(--line);
  border-left-width: 3px;
  border-radius: 7px;
  background: var(--surface);
  color: var(--text-primary);
  cursor: pointer;
  text-align: left;
}
.timeline-picker__item[data-result="win"] { border-left-color: var(--blue); }
.timeline-picker__item[data-result="loss"] { border-left-color: var(--red); }
.timeline-picker__item:hover { background: var(--surface-muted); }
.timeline-picker__item.active { border-color: var(--accent); background: var(--accent-soft); }
.timeline-picker__body { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.timeline-picker__body strong { font-size: 12px; white-space: nowrap; }
.timeline-picker__body small { color: var(--text-secondary); font-size: 10px; font-variant-numeric: tabular-nums; white-space: nowrap; }

@media (max-width: 900px) {
  .bp-card__body { grid-template-columns: 1fr; }
  .bp-ban-placeholder { min-height: 60px; }
  .bp-card__footer { flex-wrap: wrap; }
  .bp-ai { flex-basis: 100%; order: 3; }
}
</style>
