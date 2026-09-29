<script setup lang="ts">
/**
 * 一局的详情：先给结论（首杀 / 击杀比 / 团战数 / 多杀），再是每波团，最后是事件流。
 *
 * 这里**取代**了原来那条经济差曲线——用户明确说曲线那块没用。曲线读的是每分钟
 * 一帧的宏观走势，而「这局发生了什么」其实全在事件里，所以现在以事件为主。
 *
 * 事件流是**跟着选中的团走**的：只列这一波团时间窗里发生的事（团战击杀 + 这期间被
 * 拿掉的大小龙 / 推掉的塔），不是把整局几十条全糊上来——用户原话「只显示当前团战
 * 的事件流，不要把所有的事件流都贴进来」。每行都带上英雄头像：光有「九尾妖狐 击杀
 * 辉夜」这种文字，十个人里有五个是认不出来的。
 *
 * 所有推导都在 `matches/teamfights.ts`（纯函数 + 单测）：团战、多杀、首杀都是
 * **本地推导**出来的，Riot 并没有这些字段。
 */
import { Castle, Flame, Swords, TowerControl } from "@lucide/vue";
import { computed, markRaw } from "vue";
import type { GameRecordingFrame, MatchParticipant, MatchTimeline, MatchTimelineEvent } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import TeamfightList from "./TeamfightList.vue";
import { clockOf, eventDetail, eventTitle, isKill, teamLabel } from "../matches/timeline";
import { deriveMultiKills, deriveTeamfights, firstBlood } from "../matches/teamfights";
import { pairSeatsWithPlayers } from "../matches/lineup";
import { championImage } from "../utils/format";

const props = defineProps<{
  timeline: MatchTimeline;
  championNameOf: (id: number) => string;
  /** 父组件（MatchDeepDetail）已经推导好的每波团——传了就用它，保证与观战面板同一份。 */
  fights?: ReturnType<typeof deriveTeamfights>;
  /** 受控的「当前选中团战」下标；与观战面板共用一个选中态。 */
  selectedFightIndex?: number;
  /** 十人完整详情：团战面板的「全场输出 / 全场承伤」两个指标从这里取。 */
  players?: MatchParticipant[];
  /**
   * 本机录制帧（可选）。有了它，「出装」这一项才画得出**那一波团当时**的装备；
   * 没有就退回这局终局的六件——那时的标签会写清是终局口径，不能含糊。
   */
  recording?: GameRecordingFrame[];
}>();

const emit = defineEmits<{ "select-fight": [index: number]; "seek-time": [seconds: number] }>();

const fights = computed(() => props.fights ?? deriveTeamfights(props.timeline.events, props.timeline.participants));
const multiKills = computed(() => deriveMultiKills(props.timeline.events));
const first = computed(() => firstBlood(props.timeline.events));

/** 事件按时间排好；同一秒的事件保持后端给的原始顺序（稳定排序）。 */
const feed = computed(() => props.timeline.events.map((event, index) => ({ event, index })).sort((left, right) => left.event.seconds - right.event.seconds || left.index - right.index));

/** 当前选中的团（父组件受控；没传或不合法时为 null）。 */
const selectedFight = computed(() => (typeof props.selectedFightIndex === "number" ? fights.value[props.selectedFightIndex] ?? null : null));

/**
 * 大小龙 / 推塔这类**目标物**事件允许比团战窗口早/晚多少秒。
 *
 * 击杀必须严格落在团战窗口里（团战就是从击杀簇推出来的）；但龙和团在时间上是一件事：
 * 抢龙那一秒和第一具尸体之间往往隔着十来秒的开团过程，严格按窗取就会把
 * 「这个团是谁把大龙收了」漏掉——而用户明确要看这个。
 */
const FIGHT_OBJECTIVE_PAD_SECONDS = 15;

/**
 * 事件流的范围：**只列当前这一波团**。
 *
 * 团战击杀严格按窗；地图目标物（大小龙 / 推塔）放宽 ±15 秒（见上面的常量）。
 * 没选中团、或这一局没聚出团战时，退回整局事件流（总得让人看到点什么）。
 */
const visibleFeed = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return feed.value;
  return feed.value.filter(({ event }) => {
    if (event.seconds >= fight.startSeconds && event.seconds <= fight.endSeconds) return true;
    if (event.type === "CHAMPION_KILL") return false;
    return event.seconds >= fight.startSeconds - FIGHT_OBJECTIVE_PAD_SECONDS && event.seconds <= fight.endSeconds + FIGHT_OBJECTIVE_PAD_SECONDS;
  });
});
/** 是否已经缩到某一边波团（模板用它换标题、并去掉多余的「团N」角标）。 */
const scoped = computed(() => Boolean(selectedFight.value));

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

/**
 * 事件行：一次算完（时间 / 标题 / 小字 / 两头的英雄 / 角标），模板里不再重复调函数。
 *
 * `killer` / `victim` 两栏专门给**头像**用：击杀是「谁杀谁」两头都有，拿龙推塔只有
 * 「谁做的」一头。头像 + 文字一起才是可读的——同屏十个人，光看英雄名认不出是谁。
 */
const feedRows = computed(() =>
  visibleFeed.value.map(({ event, index }) => {
    const described = describeEvent(event);
    return {
      key: `${event.type}-${event.seconds}-${index}`,
      event,
      clock: clockOf(event.seconds),
      seconds: event.seconds,
      title: described.title,
      meta: described.meta,
      kind: isKill(event) ? "kill" : event.type,
      killer: event.killerChampionId || 0,
      victim: isKill(event) ? event.victimChampionId || 0 : 0,
      // 已经缩到某一波团时，「团N」角标每行都一样，纯噪音——过滤掉，只留首杀 / 多杀。
      badges: (badges.value.get(event) ?? []).filter((badge) => !(scoped.value && badge.startsWith("团"))),
    };
  }),
);

/**
 * 座位号 → 叫什么。
 *
 * 事件里只有座位号 + 英雄 id，而 `MatchParticipant` **不带座位号**，所以先用
 * `timeline.participants` 把座位号换成「英雄 + 阵营」，再按这两样从十人详情里配对
 * ——和观战面板、每波团面板是同一套配对规则（`matches/lineup.ts`）。
 * 同一屏里同一个人不能有两个叫法。
 *
 * 为什么非要玩家名不可：镜像对局（两边同一个英雄，这套 fixture 里就有）下英雄名会写成
 * 「九尾妖狐 击杀 九尾妖狐」——头像是能认出人，但文字读不出任何信息。
 * 十人详情拿不到（旧缓存的对局）时才退回英雄名。
 */
const seatNames = computed(() => {
  const table = new Map<number, string>();
  for (const [participantId, player] of pairSeatsWithPlayers(props.timeline.participants, props.players)) {
    const name = player.gameName?.trim();
    if (name) table.set(participantId, name);
  }
  return table;
});
const nameOfSeat = (participantId: number, championId: number) =>
  (participantId > 0 ? seatNames.value.get(participantId) : "") || (championId ? props.championNameOf(championId) : "未知英雄");

function describeEvent(event: MatchTimelineEvent) {
  if (isKill(event)) {
    const killer = nameOfSeat(event.killerId, event.killerChampionId);
    const victim = nameOfSeat(event.victimId, event.victimChampionId);
    return {
      title: `${killer} 击杀 ${victim}`,
      meta: `${teamLabel(event.team)} · ${event.assistIds.length ? `${event.assistIds.length} 人助攻` : "单杀"}`,
    };
  }
  // 拿龙 / 推塔也要写清**是谁做的**：只写「大龙 · 蓝方拿到」看不出是哪个人去收的
  // （用户明确要「谁击杀了大小龙」）。
  const actor = event.killerChampionId ? nameOfSeat(event.killerId, event.killerChampionId) : "";
  const verb = event.type === "ELITE_MONSTER_KILL" ? "拿下" : event.type === "BUILDING_KILL" ? "推掉" : "拆掉";
  return { title: actor ? `${actor} ${verb} ${eventTitle(event)}` : eventTitle(event), meta: eventDetail(event) };
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
</script>

<template>
  <div class="match-detail">
    <section class="match-detail__block">
      <h4>每波团 <small>按击杀时间与参与人数聚类，不是官方字段；左边点团号（或观战面板的时间轴），右边换成那一波的数据</small></h4>
      <!-- 左列表 + 右详情；事件流作为右侧内容挂在详情下面（通过插槽）。 -->
      <TeamfightList
        layout="split"
        :fights="fights"
        :champion-name-of="championNameOf"
        :participants="timeline.participants"
        :players="players"
        :frames="timeline.frames"
        :recording="recording"
        :selected-index="selectedFightIndex"
        @select="emit('select-fight', $event)"
      >
        <template #below>
          <section class="match-detail__block">
            <!-- 事件流跟着**选中的团**走：只列这一波时间窗里的事，不再把整局全糊上来。 -->
            <h4>
              事件流
              <small v-if="scoped">团{{ selectedFight?.index }} 这一波 · {{ feedRows.length }} 条（只看这一波）</small>
              <small v-else>{{ feedRows.length }} 条<template v-if="!fights.length"> · 这一局没聚出团战，列的是整局</template></small>
            </h4>
            <ol v-if="feedRows.length" class="match-detail__feed">
              <li v-for="row in feedRows" :key="row.key" class="match-event" :data-kind="row.kind">
                <button type="button" class="match-event__hit" :title="`把观战面板的游标挪到 ${row.clock}`" @click="emit('seek-time', row.seconds)">
                  <time class="match-event__time">{{ row.clock }}</time>
                  <span class="match-event__icon"><component :is="iconOf(row.event)" :size="12" /></span>
                  <!-- 英雄头像：击杀是「谁杀谁」两头都有，拿龙 / 推塔只有「谁做的」一头。 -->
                  <span class="match-event__faces">
                    <AssetIcon v-if="row.killer" kind="champion" :id="row.killer" :name="championNameOf(row.killer)" :fallback-url="championImage(row.killer)" size="xs" />
                    <i v-if="row.killer && row.victim" class="match-event__arrow" aria-hidden="true">›</i>
                    <AssetIcon v-if="row.victim" class="is-victim" kind="champion" :id="row.victim" :name="championNameOf(row.victim)" :fallback-url="championImage(row.victim)" size="xs" />
                  </span>
                  <span class="match-event__body">
                    <b>{{ row.title }}</b>
                    <small>{{ row.meta }}</small>
                  </span>
                  <span v-if="row.badges.length" class="match-event__badges">
                    <i v-for="badge in row.badges" :key="badge">{{ badge }}</i>
                  </span>
                </button>
              </li>
            </ol>
            <p v-else class="match-detail__muted">这一波团里没有事件记录。</p>
          </section>
        </template>
      </TeamfightList>
    </section>
  </div>
</template>

<style scoped>
.match-detail { display: grid; gap: 14px; }
.match-detail__block { display: grid; gap: 9px; }
.match-detail__block h4 { display: flex; align-items: baseline; gap: 7px; margin: 0; font-size: 12px; font-weight: 600; }
.match-detail__block h4 small { color: var(--text-muted); font-size: 9px; font-weight: 400; }
.match-detail__feed { display: grid; gap: 0; max-height: 340px; margin: 0; padding: 0; border: 1px solid var(--line); overflow-y: auto; list-style: none; }
/* 整行是一个按钮：点了把观战面板的游标挪到这一刻（事件流与时间轴联动）。 */
.match-event__hit { display: grid; grid-template-columns: 44px 20px auto minmax(0, 1fr) auto; align-items: center; gap: 8px; width: 100%; padding: 6px 10px; border: 0; border-bottom: 1px solid var(--line); color: inherit; background: transparent; cursor: pointer; font: inherit; text-align: left; }
.match-event:last-child .match-event__hit { border-bottom: 0; }
.match-event__hit:hover { background: var(--surface-raised); }
.match-event__hit:focus-visible { outline: 1px solid var(--accent); outline-offset: -1px; }
.match-event__time { color: var(--text-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
.match-event__icon { display: grid; place-items: center; width: 20px; height: 20px; color: var(--text-secondary); background: var(--surface-muted); }
.match-event[data-kind="kill"] .match-event__icon { color: var(--red); background: var(--red-soft); }
.match-event[data-kind="ELITE_MONSTER_KILL"] .match-event__icon { color: var(--amber); background: var(--amber-soft); }
/* 英雄头像：击杀是「谁杀谁」，中间用小箭头连起来；只有一头时（拿龙 / 推塔）就只画一头。 */
.match-event__faces { display: inline-flex; align-items: center; gap: 2px; }
/* 阵亡者的脸压暗一档——一眼能分出哪张是「被杀的」，不用去读文字。 */
.match-event__faces .is-victim { opacity: .5; filter: grayscale(.6); }
.match-event__arrow { padding: 0 1px; color: var(--text-secondary); font-size: 12px; font-style: normal; line-height: 1; }
.match-event__body { display: flex; align-items: baseline; gap: 7px; min-width: 0; }
.match-event__body b { overflow: hidden; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.match-event__body small { flex: 0 0 auto; color: var(--text-muted); font-size: 9px; }
.match-event__badges { display: inline-flex; gap: 4px; }
.match-event__badges i { padding: 1px 5px; color: var(--accent); background: var(--accent-soft); font-size: 9px; font-style: normal; }
.match-detail__muted { margin: 0; color: var(--text-muted); font-size: 10px; }
@media (max-width: 900px) { .match-event__hit { grid-template-columns: 40px 20px auto minmax(0, 1fr); }.match-event__badges { grid-column: 3 / -1; } }
</style>
