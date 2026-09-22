<script setup lang="ts">
/**
 * 对决分析面板（对局页右栏）。
 *
 * 定位：**左栏是「每个人怎么样」，这里是「这局会怎么样」**。所以这里不重复个人卡片
 * 上的明细，只做三件卡片做不到的事——把十个人横向比出高下、算一个本局胜率估算、
 * 把该重点盯的人和路点出来。
 *
 * 所有结论来自 `../live/matchup` 的纯函数，权重与阈值都在那边，这里只负责画。
 * 结论一律配数字：「敌方占优」后面必须跟着是凭什么（段位/胜率/熟练度）。
 */
import { computed } from "vue";
import AssetIcon from "./AssetIcon.vue";
import type { PlayerProfile, TeamSummary } from "../types/domain";
import { aggregateTeam, estimateWinRate, focusPoints, hasLaneCoverage, laneMatchups, matchVerdict } from "../live/matchup";
import { AKARI_MAX_SCORE } from "../tags/akari";
import { championImage } from "../utils/format";

const props = defineProps<{
  allies: PlayerProfile[];
  enemies: PlayerProfile[];
  allySummary: TeamSummary | null;
  enemySummary: TeamSummary | null;
}>();

const matchups = computed(() => laneMatchups(props.allies, props.enemies));
const covered = computed(() => hasLaneCoverage(matchups.value));
const estimate = computed(() => estimateWinRate(matchups.value));
const verdict = computed(() => matchVerdict(matchups.value, estimate.value));
const points = computed(() => focusPoints(props.allies, props.enemies, matchups.value));
const allyAggregate = computed(() => aggregateTeam(props.allies));
const enemyAggregate = computed(() => aggregateTeam(props.enemies));

const pct = (value: number) => `${Math.round(value * 100)}%`;
const lean = computed(() => (estimate.value.ally > 0.55 ? "ally" : estimate.value.ally < 0.45 ? "enemy" : "even"));
const leanLabel = computed(() => (lean.value === "ally" ? "我方占优" : lean.value === "enemy" ? "敌方占优" : "势均力敌"));

/** 队伍对比的三行：段位 / 胜率 / Akari。缺数据的显示「—」，不显示 0。 */
const compareRows = computed(() => {
  const ally = allyAggregate.value;
  const enemy = enemyAggregate.value;
  return [
    { key: "rank", label: "平均段位", ally: ally.averageRankScore === null ? "—" : ally.averageRankLabel, enemy: enemy.averageRankScore === null ? "—" : enemy.averageRankLabel, better: leanOf(ally.averageRankScore, enemy.averageRankScore) },
    { key: "win", label: "平均胜率", ally: ally.averageWinRate === null ? "—" : pct(ally.averageWinRate), enemy: enemy.averageWinRate === null ? "—" : pct(enemy.averageWinRate), better: leanOf(ally.averageWinRate, enemy.averageWinRate) },
    // ⚠️ Akari 分是 0..17 的量，必须把分母写出来。只写「0.98」会被当成百分制，
    // 看的人无从判断 0.98 是好是坏（优异档是 6.5，通天代是 8）。
    { key: "akari", label: "平均 Akari", ally: akariText(ally.averageAkari), enemy: akariText(enemy.averageAkari), better: leanOf(ally.averageAkari, enemy.averageAkari) },
  ];
});

/** 带上满分，让「0.98」这种小数值也能被读懂。 */
function akariText(value: number | null): string {
  return value === null ? "—" : `${value.toFixed(2)} / ${AKARI_MAX_SCORE}`;
}

function leanOf(ally: number | null, enemy: number | null): "ally" | "enemy" | "even" {
  if (ally === null || enemy === null) return "even";
  if (ally - enemy > 0.0001) return "ally";
  if (enemy - ally > 0.0001) return "enemy";
  return "even";
}

const VERDICT_LABELS = { ally: "我方占优", enemy: "敌方占优", even: "均势", unknown: "数据不足" } as const;

function laneTitle(matchup: (typeof matchups.value)[number]) {
  const reason = matchup.reasons[0];
  return reason ? `${reason.label}：我方 ${reason.ally} / 敌方 ${reason.enemy}` : "可用数据不足";
}
</script>

<template>
  <div class="game-matchup">
    <!-- 本局胜率估算 -->
    <section class="game-matchup__block">
      <header class="game-matchup__head">
        <span>本局胜率估算</span>
        <em :data-lean="lean">{{ leanLabel }}</em>
      </header>
      <div class="prob-bar" :title="`依据五路对位（段位 34% / 近期胜率 22% / 本位置 16% / 英雄熟练 12% / 状态 6% / Akari 10%）加权估算，不是预测模型`">
        <i class="prob-bar__ally" :style="{ width: pct(estimate.ally) }" />
        <i class="prob-bar__enemy" :style="{ width: pct(estimate.enemy) }" />
      </div>
      <div class="prob-legend">
        <b class="prob-legend__ally">{{ pct(estimate.ally) }}</b>
        <span>我方 / 敌方</span>
        <b class="prob-legend__enemy">{{ pct(estimate.enemy) }}</b>
      </div>
      <p class="game-matchup__verdict">{{ verdict }}</p>
    </section>

    <!-- 队伍对比 -->
    <section class="game-matchup__block">
      <header class="game-matchup__head">
        <span>队伍对比</span>
        <em>{{ allyAggregate.rankedCount }} / {{ enemyAggregate.rankedCount }} 人有段位</em>
      </header>
      <div class="team-compare">
        <div class="team-compare__head">
          <span />
          <b data-side="ally">我方</b>
          <b data-side="enemy">敌方</b>
        </div>
        <div v-for="row in compareRows" :key="row.key" class="team-compare__row">
          <span>{{ row.label }}</span>
          <b :data-better="row.better === 'ally'">{{ row.ally }}</b>
          <b :data-better="row.better === 'enemy'">{{ row.enemy }}</b>
        </div>
      </div>
    </section>

    <!-- 逐路对位 -->
    <section class="game-matchup__block">
      <header class="game-matchup__head">
        <span>逐路对位</span>
        <em v-if="covered">{{ estimate.lanes }} 路可比</em>
        <em v-else>位置不全</em>
      </header>
      <ul v-if="covered" class="lane-list">
        <li v-for="matchup in matchups" :key="matchup.lane" class="lane-row" :data-verdict="matchup.verdict">
          <div class="lane-row__top">
            <span class="lane-row__pos">{{ matchup.label }}</span>
            <span class="lane-row__side" data-side="ally">
              <AssetIcon v-if="matchup.ally" kind="champion" :id="matchup.ally.championId" :name="matchup.ally.championName" :fallback-url="championImage(matchup.ally.championId)" size="xs" />
              <small :title="matchup.ally?.gameName">{{ matchup.ally?.gameName ?? "—" }}</small>
            </span>
            <span class="lane-row__vs">vs</span>
            <span class="lane-row__side" data-side="enemy">
              <AssetIcon v-if="matchup.enemy" kind="champion" :id="matchup.enemy.championId" :name="matchup.enemy.championName" :fallback-url="championImage(matchup.enemy.championId)" size="xs" />
              <small :title="matchup.enemy?.gameName">{{ matchup.enemy?.gameName ?? "—" }}</small>
            </span>
          </div>
          <div class="lane-row__bottom" :title="laneTitle(matchup)">
            <span class="lane-row__verdict">{{ VERDICT_LABELS[matchup.verdict] }}</span>
            <template v-if="matchup.reasons[0]">
              <span class="lane-row__metric">{{ matchup.reasons[0].label }}</span>
              <span class="lane-row__pair">{{ matchup.reasons[0].ally }} ↔ {{ matchup.reasons[0].enemy }}</span>
            </template>
          </div>
        </li>
      </ul>
      <p v-else class="game-matchup__note">
        这一局的位置信息不完整（大乱斗或数据源没给位置），逐路对位跳过——上面的队伍对比和重点仍然有效。
      </p>
    </section>

    <!-- 重点关注 -->
    <section class="game-matchup__block">
      <header class="game-matchup__head">
        <span>重点关注</span>
        <em>{{ points.length }} 条</em>
      </header>
      <ul class="focus-list">
        <li v-for="point in points" :key="point.key" :data-tone="point.tone">
          <strong>{{ point.title }}</strong>
          <p>{{ point.detail }}</p>
        </li>
      </ul>
    </section>
  </div>
</template>

<style scoped>
/* 排版与右栏其它块（`.game-quick-filter` / `.game-automation-quick`）同一套字号刻度，
   整块用一条上边线与自动化开关区分开。 */
.game-matchup {
  display: grid;
  gap: 10px;
  margin-top: 10px;
  padding-top: 8px;
  border-top: 1px solid var(--line);
}
.game-matchup__block {
  display: grid;
  gap: 5px;
}
.game-matchup__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
}
.game-matchup__head > span {
  color: var(--text-muted);
  font-size: 9px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.game-matchup__head > em {
  color: var(--text-muted);
  font-size: 9px;
  font-style: normal;
}
.game-matchup__head > em[data-lean="ally"] {
  color: var(--blue);
}
.game-matchup__head > em[data-lean="enemy"] {
  color: var(--red);
}

/* 胜率条：左蓝右红，与「我方 / 敌方」的配色保持一致。 */
.prob-bar {
  display: flex;
  height: 8px;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 4px;
  background: var(--surface-muted);
}
.prob-bar__ally {
  background: var(--blue);
}
.prob-bar__enemy {
  background: var(--red);
}
.prob-legend {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  color: var(--text-muted);
  font-size: 9px;
}
.prob-legend b {
  font-size: 15px;
  font-variant-numeric: tabular-nums;
}
.prob-legend__ally {
  color: var(--blue);
}
.prob-legend__enemy {
  color: var(--red);
}
.game-matchup__verdict {
  margin: 0;
  color: var(--text-secondary);
  font-size: 10px;
  line-height: 1.6;
}
.game-matchup__note {
  margin: 0;
  color: var(--text-muted);
  font-size: 9px;
  line-height: 1.6;
}

/* 队伍对比：三段式，中间那列是我方。 */
.team-compare {
  display: grid;
  gap: 2px;
}
.team-compare__head,
.team-compare__row {
  display: grid;
  /* 右两列要放得下「0.98 / 17」这种 9 字符的值，所以比纯百分比宽一点。 */
  grid-template-columns: minmax(0, 1fr) 72px 72px;
  align-items: center;
  gap: 4px;
}
.team-compare__head b {
  font-size: 9px;
  text-align: right;
}
.team-compare__head b[data-side="ally"] {
  color: var(--blue);
}
.team-compare__head b[data-side="enemy"] {
  color: var(--red);
}
.team-compare__row > span {
  color: var(--text-muted);
  font-size: 9px;
}
.team-compare__row > b {
  overflow: hidden;
  color: var(--text-secondary);
  font-size: 10px;
  font-weight: 600;
  text-align: right;
  font-variant-numeric: tabular-nums;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* 占优的一侧加粗提亮：一眼能看出谁高谁低，不用自己比数字。 */
.team-compare__row > b[data-better="true"] {
  color: var(--text-primary);
  font-weight: 800;
}

/* 逐路对位：一行人名，一行证据 + 结论。 */
.lane-list,
.focus-list {
  display: grid;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.lane-row {
  display: grid;
  gap: 2px;
  padding: 4px 5px;
  border: 1px solid var(--line);
  border-left: 2px solid var(--line);
  border-radius: 4px;
  background: var(--surface);
}
.lane-row[data-verdict="ally"] {
  border-left-color: var(--blue);
}
.lane-row[data-verdict="enemy"] {
  border-left-color: var(--red);
}
.lane-row__top {
  display: grid;
  grid-template-columns: 26px minmax(0, 1fr) 14px minmax(0, 1fr);
  align-items: center;
  gap: 3px;
}
.lane-row__pos {
  color: var(--text-muted);
  font-size: 9px;
}
.lane-row__side {
  display: flex;
  align-items: center;
  gap: 3px;
  min-width: 0;
}
.lane-row__side small {
  overflow: hidden;
  color: var(--text-secondary);
  font-size: 9px;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.lane-row__side[data-side="ally"] small {
  color: var(--text-primary);
}
.lane-row__vs {
  color: var(--faint);
  font-size: 8px;
  text-align: center;
}
.lane-row__bottom {
  display: flex;
  align-items: baseline;
  gap: 5px;
  min-width: 0;
}
.lane-row__verdict {
  flex: 0 0 auto;
  padding: 1px 5px;
  border-radius: 7px;
  color: var(--text-muted);
  background: var(--surface-muted);
  font-size: 8px;
}
.lane-row[data-verdict="ally"] .lane-row__verdict {
  color: var(--blue);
  background: var(--blue-soft);
}
.lane-row[data-verdict="enemy"] .lane-row__verdict {
  color: var(--red);
  background: var(--red-soft);
}
.lane-row__metric {
  flex: 0 0 auto;
  color: var(--text-muted);
  font-size: 8px;
}
.lane-row__pair {
  overflow: hidden;
  color: var(--text-secondary);
  font-size: 9px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* 重点关注：每条都必须带数字，所以 detail 不截断，允许换行。 */
.focus-list li {
  display: grid;
  gap: 2px;
  padding: 4px 6px;
  border-left: 2px solid var(--line);
  background: var(--surface-muted);
}
.focus-list li[data-tone="danger"] {
  border-left-color: var(--red);
}
.focus-list li[data-tone="warning"] {
  border-left-color: var(--amber);
}
.focus-list li[data-tone="good"] {
  border-left-color: var(--green);
}
.focus-list strong {
  color: var(--text-primary);
  font-size: 10px;
  font-weight: 600;
}
.focus-list li[data-tone="danger"] strong {
  color: var(--red);
}
.focus-list li[data-tone="good"] strong {
  color: var(--green);
}
.focus-list p {
  margin: 0;
  color: var(--text-secondary);
  font-size: 9px;
  line-height: 1.55;
}
</style>
