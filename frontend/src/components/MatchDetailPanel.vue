<script setup lang="ts">
/**
 * 一局的详情：先给结论（首杀 / 击杀比 / 团战数 / 多杀），再是每波团，最后是事件流。
 *
 * 这里**取代**了原来那条经济差曲线——用户明确说曲线那块没用。曲线读的是每分钟
 * 一帧的宏观走势，而「这局发生了什么」其实全在事件里，所以现在以事件为主。
 *
 * 所有推导都在 `matches/teamfights.ts`（纯函数 + 单测）：团战、多杀、首杀都是
 * **本地推导**出来的，Riot 并没有这些字段。
 */
import { Castle, Flame, Swords, TowerControl } from "@lucide/vue";
import { computed, markRaw } from "vue";
import type { MatchTimeline, MatchTimelineEvent } from "../types/domain";
import TeamfightList from "./TeamfightList.vue";
import { clockOf, eventDetail, eventTitle, isKill, killTally, teamLabel } from "../matches/timeline";
import { deriveMultiKills, deriveTeamfights, firstBlood } from "../matches/teamfights";

const props = defineProps<{
  timeline: MatchTimeline;
  championNameOf: (id: number) => string;
}>();

const fights = computed(() => deriveTeamfights(props.timeline.events, props.timeline.participants));
const multiKills = computed(() => deriveMultiKills(props.timeline.events));
const first = computed(() => firstBlood(props.timeline.events));
const tally = computed(() => killTally(props.timeline.events));

/** 事件按时间排好；同一秒的事件保持后端给的原始顺序（稳定排序）。 */
const feed = computed(() => props.timeline.events.map((event, index) => ({ event, index })).sort((left, right) => left.event.seconds - right.event.seconds || left.index - right.index));

/**
 * 每条事件挂的标记（首杀 / 三杀 / 团战编号）。
 *
 * 用**对象引用**做键是安全的：团战、多杀、首杀都是从同一个 `events` 数组里挑出来的
 * 引用，不是拷贝。换成按时间戳匹配反而会因为同一秒多条事件而串味。
 */
const badges = computed(() => {
  const map = new Map<MatchTimelineEvent, string[]>();
  const push = (event: MatchTimelineEvent, text: string) => map.set(event, [...(map.get(event) ?? []), text]);
  if (first.value) push(first.value, "首杀");
  for (const item of multiKills.value) {
    // 只标多杀链的最后一杀，中途每杀都标反而看不出这串是「一次」多杀。
    const last = props.timeline.events.filter((event) => isKill(event) && event.killerId === item.killerId && event.seconds === item.endSeconds)[0];
    if (last) push(last, item.label);
  }
  for (const fight of fights.value) for (const kill of fight.kills) push(kill, `团${fight.index}`);
  return map;
});

function describeEvent(event: MatchTimelineEvent) {
  if (isKill(event)) {
    const killer = event.killerChampionId ? props.championNameOf(event.killerChampionId) : "未知英雄";
    const victim = event.victimChampionId ? props.championNameOf(event.victimChampionId) : "未知英雄";
    return {
      title: `${killer} 击杀 ${victim}`,
      meta: `${teamLabel(event.team)} · ${event.assistIds.length ? `${event.assistIds.length} 人助攻` : "单杀"}`,
    };
  }
  return { title: eventTitle(event), meta: eventDetail(event) };
}

/**
 * 图标查表。`markRaw` 是必须的：这些组件对象会被 `<component :is>` 拿到，
 * 不加会在开发模式下报「Component was made a reactive object」。
 */
const EVENT_ICONS = {
  kill: markRaw(Swords),
  monster: markRaw(Flame),
  building: markRaw(Castle),
  other: markRaw(TowerControl),
} as const;

function iconOf(event: MatchTimelineEvent) {
  if (isKill(event)) return EVENT_ICONS.kill;
  if (event.type === "ELITE_MONSTER_KILL") return EVENT_ICONS.monster;
  if (event.type === "BUILDING_KILL") return EVENT_ICONS.building;
  return EVENT_ICONS.other;
}

const firstBloodText = computed(() => {
  const event = first.value;
  if (!event) return "本局没有击杀记录";
  const killer = event.killerChampionId ? props.championNameOf(event.killerChampionId) : "未知英雄";
  return `${clockOf(event.seconds)} ${killer}（${teamLabel(event.team)}）`;
});
</script>

<template>
  <div class="match-detail">
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
        <strong v-if="multiKills.length">{{ multiKills.map((item) => `${item.label}·${championNameOf(item.championId)}`).join("，") }}</strong>
        <strong v-else class="match-detail__muted">无</strong>
      </div>
    </div>

    <section class="match-detail__block">
      <h4>每波团 <small>按击杀时间与参与人数聚类，不是官方字段</small></h4>
      <TeamfightList :fights="fights" :champion-name-of="championNameOf" />
    </section>

    <section class="match-detail__block">
      <h4>事件流 <small>{{ timeline.events.length }} 条</small></h4>
      <ol v-if="feed.length" class="match-detail__feed">
        <li v-for="item in feed" :key="`${item.event.type}-${item.event.seconds}-${item.index}`" class="match-event" :data-kind="isKill(item.event) ? 'kill' : item.event.type">
          <time class="match-event__time">{{ clockOf(item.event.seconds) }}</time>
          <span class="match-event__icon"><component :is="iconOf(item.event)" :size="12" /></span>
          <span class="match-event__body">
            <b>{{ describeEvent(item.event).title }}</b>
            <small>{{ describeEvent(item.event).meta }}</small>
          </span>
          <span v-if="badges.get(item.event)?.length" class="match-event__badges">
            <i v-for="badge in badges.get(item.event)" :key="badge">{{ badge }}</i>
          </span>
        </li>
      </ol>
      <p v-else class="match-detail__muted">这一局没有可展示的事件。</p>
    </section>
  </div>
</template>

<style scoped>
.match-detail { display: grid; gap: 14px; }
.match-detail__summary { display: flex; flex-wrap: wrap; gap: 8px 22px; padding: 9px 12px; border: 1px solid var(--line); background: var(--surface-muted); }
.match-detail__stat { display: flex; align-items: baseline; gap: 6px; font-size: 11px; }
.match-detail__stat > span { color: var(--text-muted); font-size: 10px; }
.match-detail__stat > strong { font-weight: 600; }
.match-detail__tally { display: inline-flex; align-items: baseline; gap: 3px; font-variant-numeric: tabular-nums; }
.match-detail__tally em { color: var(--text-muted); font-style: normal; }
.side-blue { color: var(--blue); }
.side-red { color: var(--red); }
.match-detail__muted { color: var(--text-muted); font-weight: 400; }
.match-detail__block { display: grid; gap: 9px; }
.match-detail__block h4 { display: flex; align-items: baseline; gap: 7px; margin: 0; font-size: 12px; font-weight: 600; }
.match-detail__block h4 small { color: var(--text-muted); font-size: 9px; font-weight: 400; }
.match-detail__feed { display: grid; gap: 0; max-height: 340px; margin: 0; padding: 0; border: 1px solid var(--line); overflow-y: auto; list-style: none; }
.match-event { display: grid; grid-template-columns: 44px 20px minmax(0, 1fr) auto; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid var(--line); }
.match-event:last-child { border-bottom: 0; }
.match-event:hover { background: var(--surface-raised); }
.match-event__time { color: var(--text-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
.match-event__icon { display: grid; place-items: center; width: 20px; height: 20px; color: var(--text-secondary); background: var(--surface-muted); }
.match-event[data-kind="kill"] .match-event__icon { color: var(--red); background: var(--red-soft); }
.match-event[data-kind="ELITE_MONSTER_KILL"] .match-event__icon { color: var(--amber); background: var(--amber-soft); }
.match-event__body { display: flex; align-items: baseline; gap: 7px; min-width: 0; }
.match-event__body b { overflow: hidden; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.match-event__body small { flex: 0 0 auto; color: var(--text-muted); font-size: 9px; }
.match-event__badges { display: inline-flex; gap: 4px; }
.match-event__badges i { padding: 1px 5px; color: var(--accent); background: var(--accent-soft); font-size: 9px; font-style: normal; }
@media (max-width: 900px) { .match-event { grid-template-columns: 40px 20px minmax(0, 1fr); }.match-event__badges { grid-column: 2 / -1; } }
</style>
