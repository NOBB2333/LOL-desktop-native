<script setup lang="ts">
import { CalendarDays, ClipboardList, Eye, Search, Shield, TrendingUp, UsersRound } from "@lucide/vue";
import { NButton, NInput, NSpin, NTag } from "naive-ui";
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import AssetIcon from "../components/AssetIcon.vue";
import MatchTimelinePanel from "../components/MatchTimelinePanel.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import { championImage, relativeTime } from "../utils/format";
import { queueLabel } from "../utils/queue";
import { scorePlayerName } from "../matches/localPlayers";
import { clockOf } from "../matches/timeline";

const app = useAppStore();
const tab = ref<"bp" | "encounters" | "timeline">("bp");
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
const visibleEncounters = computed(() => {
  const list = encounters.data.value ?? [];
  const query = playerQuery.value.trim();
  if (!query) return list;
  return list.filter((record) => scorePlayerName(query, record.gameName, record.tagLine ?? "") !== null);
});

/**
 * 时间线页签的对局选择器。
 *
 * 取的是**本地账号**最近的对局（不传名字就是自己），只在这个页签可见时才请求，
 * 免得历史页一打开就多打一次 LCU。选中的局决定时间线查询的 key。
 */
const timelineMatches = useQuery({
  queryKey: computed(() => ["timeline-matches", app.mode]),
  queryFn: () => backend.matches(undefined, 0, 20),
  enabled: computed(() => app.initialized && tab.value === "timeline"),
});
const selectedGameId = ref(0);
// 列表到手后默认选最近一局；用户手动选过就不再覆盖（只在未选时兜底）。
watch(
  () => timelineMatches.data.value,
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
    <PageHeader title="历史" eyebrow="LOCAL ARCHIVE" meta="把 BP 决策和遇到的玩家沉淀成可检索的本地记录；这里不保存游戏录像">
      <div class="history-tabs">
        <button type="button" :class="{ active: tab === 'bp' }" @click="tab = 'bp'">
          <ClipboardList :size="14" />BP 记录
        </button>
        <button type="button" :class="{ active: tab === 'encounters' }" @click="tab = 'encounters'">
          <UsersRound :size="14" />玩家档案
        </button>
        <button type="button" :class="{ active: tab === 'timeline' }" @click="tab = 'timeline'">
          <TrendingUp :size="14" />对局时间线
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

    <!-- 玩家档案。注意这里必须是 v-else-if：页签有三个，用 v-else 会和
         「对局时间线」同时渲染，两个区块一起出现。 -->
    <section v-else-if="tab === 'encounters'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">PLAYER ARCHIVE</span>
          <h2>遇到的玩家</h2>
          <p>按 PUUID 记录最近遇到的队友和对手，点击战绩页可以继续查看完整数据。</p>
        </div>
        <div class="history-archive-tools">
          <NInput v-model:value="playerQuery" size="small" clearable placeholder="按名字模糊筛选"><template #prefix><Search :size="14" /></template></NInput>
          <span class="history-count">{{ visibleEncounters.length }} <small>/ {{ encounters.data.value?.length ?? 0 }} 条</small></span>
        </div>
      </header>

      <div v-if="!encounters.data.value?.length" class="history-empty">
        <UsersRound :size="24" />
        <strong>还没有遇到玩家记录</strong>
        <span>对局页获取到十人阵容后，会自动保存玩家摘要。</span>
      </div>

      <div v-else-if="!visibleEncounters.length" class="history-empty">
        <Search :size="24" />
        <strong>本地档案里没有匹配的玩家</strong>
        <span>这里只搜你已经遇到过的人，不会去查其他大区的同名账号。</span>
      </div>

      <div v-else class="encounter-table">
        <div class="encounter-table__head">
          <span>玩家</span>
          <span>位置</span>
          <span>英雄</span>
          <span>结果</span>
          <span>时间</span>
        </div>
        <div
          v-for="record in visibleEncounters"
          :key="`${record.gameId}-${record.puuid}`"
          class="encounter-table__row"
        >
          <!-- 玩家 -->
          <div class="encounter-player">
            <span class="encounter-player__avatar">{{ record.gameName.slice(0, 1) }}</span>
            <div>
              <strong>{{ record.gameName }}</strong>
              <small class="encounter-player__puuid" :title="record.puuid">{{ record.puuid }}</small>
            </div>
          </div>
          <!-- 位置 -->
          <div>
            <NTag size="small" :bordered="false" :type="record.side === 'ally' ? 'info' : 'warning'">
              {{ record.side === 'ally' ? '我方' : '敌方' }}
            </NTag>
          </div>
          <!-- 英雄 -->
          <div class="encounter-champion">
            <AssetIcon kind="champion" :id="championIdFor(record.championName, record.championId)" :name="record.championName || '未记录英雄'" :fallback-url="championImage(championIdFor(record.championName, record.championId))" size="sm" />
            <span>{{ record.championName || '未记录英雄' }}</span>
          </div>
          <!-- 结果 -->
          <div>
            <NTag size="small" :bordered="false" :type="record.result === '胜利' ? 'success' : 'error'">
              {{ record.result ?? '未知' }}
            </NTag>
          </div>
          <!-- 时间 -->
          <time class="encounter-time">{{ relativeTime(record.encounteredAt) }}</time>
        </div>
      </div>
    </section>

    <!-- 对局时间线 -->
    <section v-if="tab === 'timeline'" class="history-section">
      <header class="history-section__header">
        <div>
          <span class="eyebrow">MATCH TIMELINE</span>
          <h2>经济曲线与关键事件</h2>
          <p>数据来自本地客户端的逐帧记录：双方经济差、野怪、防御塔与镀层。选一局看走势。</p>
        </div>
        <span class="history-count">{{ timelineMatches.data.value?.length ?? 0 }} <small>局可选</small></span>
      </header>

      <div v-if="timelineMatches.isPending.value" class="history-empty">
        <NSpin size="small" />
        <strong>正在读取最近对局</strong>
        <span>本页只列本地账号的战绩。</span>
      </div>

      <div v-else-if="!timelineMatches.data.value?.length" class="history-empty">
        <TrendingUp :size="24" />
        <strong>还没有可回看的对局</strong>
        <span>打完一局后，这里会出现它的经济曲线和关键事件。</span>
      </div>

      <template v-else>
        <div class="timeline-picker" role="tablist" aria-label="选择对局">
          <button
            v-for="match in timelineMatches.data.value ?? []"
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
      </template>
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
.encounter-table__head {
  display: grid;
  grid-template-columns: minmax(180px, 1.8fr) 90px minmax(130px, 1fr) 70px 110px;
  align-items: center;
  gap: 12px;
  min-width: 640px;
  padding: 0 16px;
  min-height: 38px;
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
  color: var(--text-muted);
  font-size: 11px;
  font-weight: 500;
}
.encounter-table__row {
  display: grid;
  grid-template-columns: minmax(180px, 1.8fr) 90px minmax(130px, 1fr) 70px 110px;
  align-items: center;
  gap: 12px;
  min-width: 640px;
  padding: 10px 16px;
  min-height: 56px;
  border-bottom: 1px solid var(--line);
  font-size: 12px;
  transition: background 0.1s;
}
.encounter-table__row:last-child { border-bottom: 0; }
.encounter-table__row:hover { background: var(--surface-muted); }
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
.encounter-player__puuid {
  display: block;
  margin-top: 2px;
  color: var(--text-muted);
  font-size: 10px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 150px;
}
.encounter-champion { display: flex; align-items: center; gap: 7px; min-width: 0; }
.encounter-champion span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
.encounter-time { color: var(--text-secondary); font-size: 11px; }

/* 时间线的对局选择器：横向滚动的一排小卡片，选中的那局高亮。 */
.timeline-picker {
  display: flex;
  gap: 6px;
  margin-bottom: 12px;
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
