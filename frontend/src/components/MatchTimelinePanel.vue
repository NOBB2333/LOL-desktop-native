<script setup lang="ts">
/**
 * 对局时间线：上半部分是「谁领先多少」的双色经济差曲线，下半部分是关键事件轴。
 *
 * 只做展示，不自己取数——数据由父级按 gameId 拉好（历史页里选一局就发一次请求）。
 * 曲线按零轴切成蓝/红两段，颜色只表示**当时哪边经济领先**，与观战者视角无关。
 */
import { Castle, Flame, Swords, TowerControl } from "@lucide/vue";
import { computed } from "vue";
import type { MatchTimeline, MatchTimelineEvent } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import { clockOf, compactGold, eventDetail, eventTitle, isKill, killTally, pathFrom, signedGold, splitBySign, TEAM_BLUE } from "../matches/timeline";

const props = withDefaults(
  defineProps<{
    timeline: MatchTimeline;
    /** 英雄 id → 名字；父级已有英雄目录，不必在这里再拉一次。 */
    championName?: (id: number) => string;
  }>(),
  { championName: (id: number) => `英雄 #${id}` },
);

const chartWidth = 640;
const chartHeight = 150;
const padX = 10;
const axisWidth = 34;
const plotLeft = padX + axisWidth;
const plotRight = chartWidth - padX;
const plotTop = 8;
const plotBottom = chartHeight - 14;
const zeroY = (plotTop + plotBottom) / 2;

const frames = computed(() => props.timeline.frames);
const maxMinute = computed(() => Math.max(1, frames.value[frames.value.length - 1]?.minute ?? 1));
/// 上限向上取整到 1k，保证零轴永远在正中、两侧刻度对称。
const peak = computed(() => {
  const maxAbs = frames.value.reduce((highest, frame) => Math.max(highest, Math.abs(frame.goldDiff)), 0);
  return Math.max(1000, Math.ceil(maxAbs / 1000) * 1000);
});

const xFor = (minute: number) => plotLeft + (minute / maxMinute.value) * (plotRight - plotLeft);
const yFor = (value: number) => zeroY - (value / peak.value) * ((plotBottom - plotTop) / 2);

const points = computed(() => frames.value.map((frame) => ({ x: xFor(frame.minute), y: yFor(frame.goldDiff), value: frame.goldDiff })));
const runs = computed(() => splitBySign(points.value, zeroY));
const areaPath = computed(() => {
  const list = points.value;
  if (!list.length) return "";
  const first = list[0];
  const last = list[list.length - 1];
  return `${pathFrom([{ x: first.x, y: zeroY }, ...list, { x: last.x, y: zeroY }])} Z`;
});

/// 每 5 分钟一条竖线；最后一分钟不是整 5 也补一条，右端不会看起来没刻度。
const minuteTicks = computed(() => {
  const ticks: number[] = [];
  for (let minute = 0; minute <= maxMinute.value; minute += 5) ticks.push(minute);
  if (ticks[ticks.length - 1] !== maxMinute.value) ticks.push(maxMinute.value);
  return ticks;
});

const killScore = computed(() => killTally(props.timeline.events));
const finalFrame = computed(() => frames.value[frames.value.length - 1] ?? null);
const events = computed(() => props.timeline.events);
const championName = (id: number) => (id > 0 ? props.championName(id) : "未知");

function eventIcon(event: MatchTimelineEvent) {
  if (event.type === "CHAMPION_KILL") return Swords;
  if (event.type === "ELITE_MONSTER_KILL") return Flame;
  if (event.type === "TURRET_PLATE_DESTROYED") return TowerControl;
  return Castle;
}
</script>

<template>
  <div class="timeline-panel">
    <div class="timeline-summary">
      <div class="timeline-summary__item">
        <span>时长</span>
        <strong>{{ clockOf(timeline.durationSeconds) }}</strong>
      </div>
      <div class="timeline-summary__item">
        <span>击杀</span>
        <strong class="timeline-score">
          <b class="side-blue">{{ killScore.blue }}</b>
          <em>:</em>
          <b class="side-red">{{ killScore.red }}</b>
        </strong>
      </div>
      <div class="timeline-summary__item">
        <span>最终经济</span>
        <strong v-if="finalFrame" class="timeline-score">
          <b class="side-blue">{{ compactGold(finalFrame.blueGold) }}</b>
          <em>:</em>
          <b class="side-red">{{ compactGold(finalFrame.redGold) }}</b>
        </strong>
        <strong v-else>—</strong>
      </div>
      <div class="timeline-summary__item">
        <span>结束时经济差</span>
        <strong :class="(finalFrame?.goldDiff ?? 0) >= 0 ? 'side-blue' : 'side-red'">
          {{ signedGold(finalFrame?.goldDiff ?? 0) }}
        </strong>
      </div>
      <div class="timeline-summary__item">
        <span>关键事件</span>
        <strong>{{ events.length }} 个</strong>
      </div>
    </div>

    <div v-if="frames.length" class="timeline-chart">
      <svg :viewBox="`0 0 ${chartWidth} ${chartHeight}`" role="img" aria-label="经济差曲线">
        <defs>
          <clipPath id="timeline-above">
            <rect :x="plotLeft" :y="plotTop" :width="plotRight - plotLeft" :height="zeroY - plotTop" />
          </clipPath>
          <clipPath id="timeline-below">
            <rect :x="plotLeft" :y="zeroY" :width="plotRight - plotLeft" :height="plotBottom - zeroY" />
          </clipPath>
        </defs>

        <line v-for="tick in minuteTicks" :key="`tick-${tick}`" class="timeline-chart__grid" :x1="xFor(tick)" :x2="xFor(tick)" :y1="plotTop" :y2="plotBottom" />
        <line class="timeline-chart__grid" :x1="plotLeft" :x2="plotRight" :y1="zeroY" :y2="zeroY" />
        <line class="timeline-chart__grid timeline-chart__grid--edge" :x1="plotLeft" :x2="plotRight" :y1="yFor(peak)" :y2="yFor(peak)" />
        <line class="timeline-chart__grid timeline-chart__grid--edge" :x1="plotLeft" :x2="plotRight" :y1="yFor(-peak)" :y2="yFor(-peak)" />

        <text class="timeline-chart__label" :x="padX" :y="yFor(peak) + 3">+{{ compactGold(peak) }}</text>
        <text class="timeline-chart__label" :x="padX" :y="zeroY + 3">0</text>
        <text class="timeline-chart__label" :x="padX" :y="yFor(-peak) + 3">-{{ compactGold(peak) }}</text>

        <path v-if="areaPath" class="timeline-chart__area timeline-chart__area--blue" :d="areaPath" clip-path="url(#timeline-above)" />
        <path v-if="areaPath" class="timeline-chart__area timeline-chart__area--red" :d="areaPath" clip-path="url(#timeline-below)" />
        <path
          v-for="(run, index) in runs"
          :key="`run-${index}`"
          class="timeline-chart__line"
          :class="run.leading ? 'timeline-chart__line--blue' : 'timeline-chart__line--red'"
          :d="pathFrom(run.points)"
        />

        <text v-for="tick in minuteTicks" :key="`tick-label-${tick}`" class="timeline-chart__tick" :x="xFor(tick)" :y="chartHeight - 3" text-anchor="middle">
          {{ tick }}'
        </text>
      </svg>
      <div class="timeline-chart__legend">
        <span class="timeline-chart__legend-item side-blue">蓝方领先</span>
        <span class="timeline-chart__legend-item side-red">红方领先</span>
      </div>
    </div>
    <p v-else class="timeline-empty">这一局没有可用的逐帧数据。</p>

    <ul v-if="events.length" class="timeline-events">
      <li v-for="(event, index) in events" :key="`${event.type}-${event.seconds}-${index}`" class="timeline-event" :data-side="event.team === TEAM_BLUE ? 'blue' : 'red'">
        <time class="timeline-event__time">{{ clockOf(event.seconds) }}</time>
        <span class="timeline-event__icon" :data-kind="event.type"><component :is="eventIcon(event)" :size="13" /></span>
        <div class="timeline-event__body">
          <div class="timeline-event__head">
            <strong>{{ eventTitle(event) }}</strong>
            <template v-if="isKill(event)">
              <AssetIcon kind="champion" :id="event.killerChampionId" :name="championName(event.killerChampionId)" size="xs" />
              <span class="timeline-event__arrow">→</span>
              <AssetIcon kind="champion" :id="event.victimChampionId" :name="championName(event.victimChampionId)" size="xs" />
            </template>
          </div>
          <small class="timeline-event__detail">{{ eventDetail(event) }}</small>
        </div>
      </li>
    </ul>
    <p v-else class="timeline-empty timeline-empty--inline">这一局没有记录到关键事件。</p>
  </div>
</template>

<style scoped>
.timeline-panel {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.timeline-summary {
  display: flex;
  flex-wrap: wrap;
  gap: 8px 20px;
  padding: 8px 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface-muted);
}
.timeline-summary__item {
  display: flex;
  align-items: baseline;
  gap: 6px;
  font-size: 12px;
}
.timeline-summary__item > span {
  color: var(--text-secondary);
}
.timeline-summary__item strong {
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}
.timeline-score {
  display: inline-flex;
  align-items: baseline;
  gap: 3px;
}
.timeline-score em {
  color: var(--text-muted);
  font-style: normal;
}
.side-blue {
  color: #3b82f6;
}
.side-red {
  color: #ef4444;
}

.timeline-chart {
  position: relative;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  padding: 4px 6px 0;
}
.timeline-chart svg {
  display: block;
  width: 100%;
  height: auto;
}
.timeline-chart__grid {
  stroke: var(--line);
  stroke-width: 1;
}
.timeline-chart__grid--edge {
  stroke-dasharray: 3 4;
}
.timeline-chart__label,
.timeline-chart__tick {
  fill: var(--text-muted);
  font-size: 9px;
  font-variant-numeric: tabular-nums;
}
.timeline-chart__area {
  stroke: none;
  opacity: 0.16;
}
.timeline-chart__area--blue {
  fill: #3b82f6;
}
.timeline-chart__area--red {
  fill: #ef4444;
}
.timeline-chart__line {
  fill: none;
  stroke-width: 2;
  stroke-linejoin: round;
  stroke-linecap: round;
}
.timeline-chart__line--blue {
  stroke: #3b82f6;
}
.timeline-chart__line--red {
  stroke: #ef4444;
}
.timeline-chart__legend {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
  padding: 2px 4px 4px;
  font-size: 11px;
}
.timeline-chart__legend-item {
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.timeline-chart__legend-item::before {
  content: "";
  width: 10px;
  height: 2px;
  border-radius: 1px;
  background: currentColor;
}

.timeline-events {
  display: grid;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.timeline-event {
  display: grid;
  grid-template-columns: 42px 22px minmax(0, 1fr);
  align-items: center;
  gap: 8px;
  padding: 6px 10px;
  border: 1px solid var(--line);
  border-left-width: 3px;
  border-radius: 6px;
  background: var(--surface);
}
.timeline-event[data-side="blue"] {
  border-left-color: #3b82f6;
}
.timeline-event[data-side="red"] {
  border-left-color: #ef4444;
}
.timeline-event__time {
  color: var(--text-secondary);
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}
.timeline-event__icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  border-radius: 5px;
  background: var(--surface-muted);
  color: var(--text-secondary);
}
.timeline-event__icon[data-kind="CHAMPION_KILL"] {
  color: #ef4444;
}
.timeline-event__icon[data-kind="ELITE_MONSTER_KILL"] {
  color: var(--amber);
}
.timeline-event__body {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.timeline-event__head {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
}
.timeline-event__head strong {
  font-size: 12px;
  white-space: nowrap;
}
.timeline-event__arrow {
  color: var(--text-muted);
  font-size: 11px;
}
.timeline-event__detail {
  color: var(--text-secondary);
  font-size: 11px;
  white-space: nowrap;
}
.timeline-empty {
  margin: 0;
  padding: 14px;
  border: 1px dashed var(--line);
  border-radius: 8px;
  color: var(--text-secondary);
  font-size: 12px;
  text-align: center;
}
.timeline-empty--inline {
  padding: 10px;
}
</style>
