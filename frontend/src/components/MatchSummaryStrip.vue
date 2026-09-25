<script setup lang="ts">
/**
 * 一局的「结论条」：首杀 / 击杀比 / 团战数 / 多杀。
 *
 * 从 `MatchDetailPanel` 里抽出来的：这条是整局的摘要，应该贴在**最上面**当标题行，
 * 而不是夹在观战面板和每波团中间（之前它在那儿，用户扫一眼会以为是团战面板的一部分）。
 * 类名沿用 `.match-detail__summary`，历史页的测试与样式都还对得上。
 */
import { computed } from "vue";
import type { MatchTimeline } from "../types/domain";
import { clockOf, killTally, teamLabel } from "../matches/timeline";
import { deriveMultiKills, deriveTeamfights, firstBlood } from "../matches/teamfights";

const props = defineProps<{
  timeline: MatchTimeline;
  championNameOf: (id: number) => string;
  /** 与观战面板 / 每波团共用同一份推导结果。 */
  fights?: ReturnType<typeof deriveTeamfights>;
}>();

const fights = computed(() => props.fights ?? deriveTeamfights(props.timeline.events, props.timeline.participants));
const multiKills = computed(() => deriveMultiKills(props.timeline.events));
const tally = computed(() => killTally(props.timeline.events));
const first = computed(() => firstBlood(props.timeline.events));

const firstBloodText = computed(() => {
  const event = first.value;
  if (!event) return "本局没有击杀记录";
  const killer = event.killerChampionId ? props.championNameOf(event.killerChampionId) : "未知英雄";
  return `${clockOf(event.seconds)} ${killer}（${teamLabel(event.team)}）`;
});

/** 多杀链：谁、几次、什么级别，压成一行。 */
const multiKillText = computed(() => multiKills.value.filter((item) => item.count >= 2).map((item) => `${item.label}·${props.championNameOf(item.championId)}`));
</script>

<template>
  <div class="match-detail__summary">
    <div class="match-detail__stat">
      <span>首杀</span>
      <strong>{{ firstBloodText }}</strong>
    </div>
    <div class="match-detail__stat">
      <span>击杀</span>
      <strong class="match-detail__tally"><b class="side-blue">{{ tally.blue }}</b><em>:</em><b class="side-red">{{ tally.red }}</b></strong>
    </div>
    <div class="match-detail__stat">
      <span>团战</span>
      <strong>{{ fights.length }} 波</strong>
    </div>
    <div class="match-detail__stat">
      <span>多杀</span>
      <strong v-if="multiKillText.length">{{ multiKillText.join("，") }}</strong>
      <strong v-else class="match-detail__muted">无</strong>
    </div>
  </div>
</template>

<style scoped>
.match-detail__summary { display: flex; flex-wrap: wrap; gap: 8px 22px; padding: 9px 12px; border: 1px solid var(--line); background: var(--surface-muted); }
.match-detail__stat { display: flex; align-items: baseline; gap: 6px; font-size: 11px; }
.match-detail__stat > span { color: var(--text-muted); font-size: 10px; }
.match-detail__stat > strong { font-weight: 600; }
.match-detail__tally { display: inline-flex; align-items: baseline; gap: 3px; font-variant-numeric: tabular-nums; }
.match-detail__tally em { color: var(--text-muted); font-style: normal; }
.side-blue { color: var(--blue); }
.side-red { color: var(--red); }
.match-detail__muted { color: var(--text-muted); font-weight: 400; }
</style>
