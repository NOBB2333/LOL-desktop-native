<script setup lang="ts">
/**
 * 观战式面板——照着比赛转播 HUD 摆的：
 *
 * ┌──────────────────────────────────────────────────────────────┐
 * │ 塔2 · 龙 火龙海龙 │  26:00   54k  7 : 4  44k  │ 塔1 · 大龙1 │ ← 顶部比分条
 * │ 大龙1            │      经济差 +9.8k            │ 龙 土龙     │   （比分/经济/时间同一块）
 * ├──────────────────────────────────────────────────────────────┤
 * │ 十人第二行 [输出][承伤][推塔][装备]  全场输出 · 蓝 12.3万 / 红 9.8万 │ ← 口径通栏
 * ├──────────────────┬──────────────────────────────┬────────────┤
 * │ 蓝 5 人           │  小地图：英雄头像 + 防御塔/水晶 │ 红 5 人     │
 * │ ①名字 KDA 金币    │  + 团战编号钉（塔掉了会变灰）   │ ①名字 …    │
 * │ ②由通栏选择器决定  │                              │ ②同左       │
 * ├──────────────────┴──────────────────────────────┴────────────┤
 * │ 经济差面积图（全宽，蓝领先填蓝 / 红领先填红；**也能按住拖动**）    │
 * │ 时间轴（击杀│野怪│推塔刻度 + 团战段 + 可拖游标，全宽）            │
 * │ 回放控制 + 刻度图例                                             │
 * └──────────────────────────────────────────────────────────────┘
 *
 * 为什么这样摆：转播画面的信息锚点是「顶部比分 + 中间地图 + 底部时间」。比分、双方
 * 经济、游标时间挤在同一块（看比赛时这三个数就是要一起读的），目标物（塔/大小龙、
 * 拿了什么龙）分到两翼，不再和比分抢注意力。
 *
 * 游标（scrub）是核心：分钟帧是 60 秒一拍，按帧插值后拖到任意一秒都能给出
 * 「这时候谁几级、身上多少钱、站在图里哪里、双方经济差多少」。时间轴与经济差图
 * **两处都能拖**——那张图横轴本来就是分钟，能看却不能拖反而别扭（用户明确要求）。
 *
 * 十人行的第二行是**可切换**的：输出 / 承伤 / 推塔 / 装备。切换器长在十人列**正上方**
 * 那条通栏里（不是地图角上、也不是底部控制条里）——它管的就是下面那十行，摆远一点
 * 就变成「不容易找到」（用户反馈过两次）。口径也会写在通栏里。
 * 仍然拿不到的是**逐技能伤害**、**任一时刻的出装**与**对塔伤害的时间曲线**：
 * 前两者只有 SGP DETAILS 有（未开工），第三个 LCU 帧里根本没有该字段；
 * 更要紧的是真机的分钟帧里**连对英雄伤害都没有**，所以「输出/承伤」会自动降级成
 * 全场总账并把口径写出来（见 `matches/timeline.ts` 的 `framesHaveDamage`）。
 */
import { computed, ref, watch } from "vue";
import map11 from "../assets/map11.png";
import AssetIcon from "./AssetIcon.vue";
import { mapToImagePosition } from "../live/gameMap";
import type { MatchParticipant, MatchSummary, MatchTimeline } from "../types/domain";
import { TEAM_BLUE, TEAM_RED, clockOf, compactGold, eventTitle, framesHaveDamage, interpolatedDamage, interpolatedGold, interpolatedLevel, interpolatedPositions, interpolatedTaken, isKill, monsterLabel, pathFrom, signedGold, splitBySign } from "../matches/timeline";
import { describeLocation, type Teamfight } from "../matches/teamfights";
import { pairSeatsWithPlayers, realSeats } from "../matches/lineup";
import { structureStatesAt } from "../matches/structures";
import { championImage } from "../utils/format";

const props = defineProps<{
  /** 完整十人详情：名字 / 终局 KDA / 终局装备都从这里来。 */
  detail: MatchSummary;
  timeline: MatchTimeline;
  championNameOf: (id: number) => string;
  fights: Teamfight[];
  /** 当前选中的团战（受控值，父组件持有，与下面「每波团」面板共用）。 */
  selectedFightIndex: number;
  selfPuuid?: string;
  encounterCounts?: Record<string, number>;
  /** 外部（点事件流、点团战条）要求把游标挪到这一秒。 */
  seekSeconds?: number | null;
}>();

const emit = defineEmits<{ "select-fight": [index: number]; "seek-consumed": [] }>();

/** 游标时刻（秒）。默认停在终局，换了一局回到终局。 */
const seconds = ref(props.timeline.durationSeconds);
watch(
  () => props.timeline.gameId,
  () => {
    seconds.value = props.timeline.durationSeconds;
  },
);
// 外部要求定位（点事件流 / 点某一波团）：直接落在那秒上，不做动画——观战里就是要「跳过去」。
// 落位后通知父组件把请求清掉：`seekSeconds` 是不变就触发不了 watch 的值，不清掉的话
// 「拖走游标 → 再点同一条事件」会一点反应都没有（值没变）。
watch(
  () => props.seekSeconds,
  (value) => {
    if (typeof value !== "number" || value < 0) return;
    seconds.value = Math.min(value, props.timeline.durationSeconds);
    emit("seek-consumed");
  },
);

/** 座位号（participantId）→ 完整十人名单。配对规则见 `matches/lineup.ts`（英雄 + 绝对阵营）。 */
const seatPairing = computed(() => pairSeatsWithPlayers(props.timeline.participants, props.detail.participants));
const seatPlayers = computed(() =>
  realSeats(props.timeline.participants).map((seat) => ({ seat, player: seatPairing.value.get(seat.participantId) ?? null })),
);
const bluePlayers = computed(() => seatPlayers.value.filter((entry) => entry.seat.team === TEAM_BLUE));
const redPlayers = computed(() => seatPlayers.value.filter((entry) => entry.seat.team === TEAM_RED));

/** 游标时刻的插值快照：等级 / 金币 / 走位 / 累计输出 / 累计承伤。帧缺失时为 null，界面按「没有这帧数据」降级。 */
const levelsAt = computed(() => interpolatedLevel(props.timeline.frames, seconds.value));
const goldAt = computed(() => interpolatedGold(props.timeline.frames, seconds.value));
const positionsAt = computed(() => interpolatedPositions(props.timeline.frames, seconds.value));
/** 累计对英雄伤害——拖游标就能看它一路涨上去（LCU 分钟帧里本来就有这个字段）。 */
const damageAt = computed(() => interpolatedDamage(props.timeline.frames, seconds.value));
/** 累计承受伤害，同一批帧里也有。 */
const takenAt = computed(() => interpolatedTaken(props.timeline.frames, seconds.value));

const levelOf = (participantId: number) => levelsAt.value?.[participantId - 1] ?? 0;
const goldOf = (participantId: number) => goldAt.value?.[participantId - 1] ?? 0;
const damageOf = (participantId: number) => damageAt.value?.[participantId - 1] ?? 0;
const takenOf = (participantId: number) => takenAt.value?.[participantId - 1] ?? 0;
/** 座位号 → 这一局的完整十人详情（「推塔」「装备」两项只有总账，逐帧里没有）。 */
const playerOf = (participantId: number) => seatPlayers.value.find((entry) => entry.seat.participantId === participantId)?.player ?? null;

/** 击杀比随游标累计——拖回 5 分钟就看到 5 分钟时的比分。 */
const tallyAt = computed(() => {
  let blue = 0;
  let red = 0;
  for (const event of props.timeline.events) {
    if (!isKill(event) || event.seconds > seconds.value) continue;
    if (event.team === TEAM_BLUE) blue += 1;
    else if (event.team === TEAM_RED) red += 1;
  }
  return { blue, red };
});
const teamGoldAt = computed(() => {
  const totals: Record<number, number> = { [TEAM_BLUE]: 0, [TEAM_RED]: 0 };
  for (const seat of props.timeline.participants) totals[seat.team] = (totals[seat.team] ?? 0) + goldOf(seat.participantId);
  return totals;
});
const goldDiffAt = computed(() => (teamGoldAt.value[TEAM_BLUE] ?? 0) - (teamGoldAt.value[TEAM_RED] ?? 0));

// ── 十人行的第二行：可由切换器切换的四个指标 ──────────────────────
/**
 * 行指标。
 *
 * 前两项想要的口径是「**到游标这一刻**的累计值」（拖时间轴会涨），这要求分钟帧里有
 * 逐分钟伤害——但真机上**没有**（见 `matches/timeline.ts` 的 `framesHaveDamage`）。
 * 所以这两项要能降级：有帧内伤害就走「到此刻累计」，没有就退回十人详情里的
 * **全场总账**，并把口径如实写进子标题与悬浮说明。硬画一张全零的图，用户看到的就是
 * 「柱状图没渲染」，而不是「这份数据不存在」。
 *
 * 后两项本来就只有整局总账——LCU 既没有「对塔伤害」的逐分钟曲线，也没有逐次出装。
 */
type RowMetricKey = "damage" | "taken" | "tower" | "items";
const framesWithDamage = computed(() => framesHaveDamage(props.timeline.frames));
const ROW_METRICS = computed<{ key: RowMetricKey; label: string; caption: string; kind: "bar" | "items" }[]>(() => [
  { key: "damage", label: "输出", caption: framesWithDamage.value ? "到此刻累计输出" : "全场输出", kind: "bar" },
  { key: "taken", label: "承伤", caption: framesWithDamage.value ? "到此刻累计承伤" : "全场承伤", kind: "bar" },
  { key: "tower", label: "推塔", caption: "全场对塔伤害", kind: "bar" },
  { key: "items", label: "装备", caption: "终局出装", kind: "items" },
]);
const rowMetric = ref<RowMetricKey>("damage");
const rowMetricDef = computed(() => ROW_METRICS.value.find((item) => item.key === rowMetric.value) ?? ROW_METRICS.value[0]);
const rowMetricCaption = computed(() => rowMetricDef.value.caption);

/** 某一个座位在当前指标下的值。柱状图三项都走这里，「装备」不走（画的是图标）。 */
const rowValueOf = (participantId: number) => {
  const player = playerOf(participantId);
  if (rowMetric.value === "damage") return framesWithDamage.value ? damageOf(participantId) : player?.damageDealt ?? 0;
  if (rowMetric.value === "taken") return framesWithDamage.value ? takenOf(participantId) : player?.damageTaken ?? 0;
  return player?.towerDamage ?? 0;
};
/**
 * 柱子归一化基准：**两队共用同一基准**，否则两边各按各的最高值算，长度就没法横向比。
 *
 * 「到此刻累计」那两项（输出 / 承伤）的基准必须取**终局那一帧**，不能取「当前游标下
 * 十人的最高值」。后者会踩一个很隐蔽的坑：累计值随游标一起长，基准也跟着长，比值几乎
 * 不变 —— 拖时间轴时数字在涨（`b` 里那个数），**柱子的长度却几乎不动**，看起来就跟
 * 「伤害这一项没数据 / 没渲染」一模一样。取终局做分母，柱子才是「此刻已经打了终局的
 * 百分之多少」，拖动时从 0 一路长到满格。
 *
 * 「推塔」是整局总账、跟游标无关，继续按十人详情的当前值取最大值即可。
 */
const rowMetricMax = computed(() => {
  // 只有在「帧里真的有伤害」时才用帧做分母：降级路径下 `rowValueOf` 取的是十人详情的
  // 全场总账（那个数很大），帧却是全 0，拿帧当分母会算出几十万个百分点。
  if (framesWithDamage.value && (rowMetric.value === "damage" || rowMetric.value === "taken")) {
    const frames = props.timeline.frames;
    const last = frames.length > 0 ? frames[frames.length - 1] : undefined;
    const series = last ? (rowMetric.value === "damage" ? last.damage : last.taken) : undefined;
    const peak = series && series.length > 0 ? Math.max(...series) : 0;
    if (peak > 0) return peak;
  }
  return Math.max(1, ...realSeats(props.timeline.participants).map((seat) => rowValueOf(seat.participantId)));
});
const rowPercent = (value: number) => `${value > 0 ? Math.max(2, (value / rowMetricMax.value) * 100) : 0}%`;

/** 队伍合计（柱状图的「合计」写在两翼的称号里）。 */
const rowMetricTotal = computed(() => {
  const totals: Record<number, number> = { [TEAM_BLUE]: 0, [TEAM_RED]: 0 };
  for (const seat of realSeats(props.timeline.participants)) totals[seat.team] = (totals[seat.team] ?? 0) + rowValueOf(seat.participantId);
  return totals;
});

// ── 顶部比分条：目标物（塔 / 大小龙，含龙种）──────────────────────────
/**
 * 到游标这一刻各方的目标物。大龙和小龙分开数，小龙再按**龙种**归类——
 * 「拿了几条」和「拿的哪几条」是两个问题，转播里都会说。
 */
const objectivesAt = computed(() => {
  const blank = () => ({ towers: 0, dragons: [] as string[], barons: 0, heralds: 0 });
  const tally: Record<number, ReturnType<typeof blank>> = { [TEAM_BLUE]: blank(), [TEAM_RED]: blank() };
  for (const event of props.timeline.events) {
    if (event.seconds > seconds.value) continue;
    const side = tally[event.team];
    if (!side) continue;
    // 「塔」只数**防御塔**：水晶也是 BUILDING_KILL，一起算进去会把塔数虚报 1 座
    // （fixture 里就有一座中路水晶）。水晶在时间轴上是灰色刻度、事件流里写「中路水晶」，不会丢。
    if (event.type === "BUILDING_KILL") {
      if (event.buildingType === "TOWER_BUILDING") side.towers += 1;
    } else if (event.type === "ELITE_MONSTER_KILL") {
      if (event.monsterType === "DRAGON") side.dragons.push(monsterLabel(event));
      else if (event.monsterType === "BARON_NASHOR") side.barons += 1;
      else if (event.monsterType === "RIFTHERALD") side.heralds += 1;
    }
  }
  return tally;
});

/**
 * 龙种汇总：同一种拿了两条就写「火龙×2」。
 *
 * 只写条数看不出「拿的什么龙」（火龙和海龙对推塔的影响完全不同），只写龙种又看不出
 * 拿了几条——所以两边都要有。
 */
const dragonTextOf = (team: number) => {
  const counts = new Map<string, number>();
  for (const label of objectivesAt.value[team]?.dragons ?? []) counts.set(label, (counts.get(label) ?? 0) + 1);
  return [...counts].map(([label, count]) => (count > 1 ? `${label}×${count}` : label)).join(" · ");
};

// ── 时间轴 ────────────────────────────────────────────────────────────
const duration = computed(() => Math.max(1, props.timeline.durationSeconds));
const percentOf = (eventSeconds: number) => `${Math.min(100, Math.max(0, (eventSeconds / duration.value) * 100))}%`;
/** 游标时间气泡贴边时要改对齐方向，不然会溢出到面板外（右端尤其明显）。 */
const playheadEdge = computed(() => {
  const ratio = seconds.value / duration.value;
  return ratio < 0.07 ? "start" : ratio > 0.93 ? "end" : "mid";
});
/** 全场的最大领先：给面积图一个量级参照，光看颜色块不知道差了多少。 */
const maxLead = computed(() => {
  let best = 0;
  for (const frame of props.timeline.frames) if (Math.abs(frame.goldDiff) > Math.abs(best)) best = frame.goldDiff;
  return best;
});

const killMarkers = computed(() => props.timeline.events.filter(isKill).map((event) => ({ event, tone: event.team === TEAM_BLUE ? "blue" : "red" })));
const monsterMarkers = computed(() => props.timeline.events.filter((event) => event.type === "ELITE_MONSTER_KILL"));
const buildingMarkers = computed(() => props.timeline.events.filter((event) => event.type === "BUILDING_KILL"));

const fightSegments = computed(() =>
  props.fights.map((fight, index) => ({
    fight,
    index,
    left: (fight.startSeconds / duration.value) * 100,
    width: Math.max(0.8, ((fight.endSeconds - fight.startSeconds) / duration.value) * 100),
  })),
);
function selectFight(index: number) {
  emit("select-fight", index);
}

/** 上一波 / 下一波：换选中团**并且**把游标带到那一波开打的那一刻（看回放就是这个动作）。 */
function stepFight(delta: number) {
  if (!props.fights.length) return;
  const next = Math.min(props.fights.length - 1, Math.max(0, props.selectedFightIndex + delta));
  selectFight(next);
}
const canStepBack = computed(() => props.selectedFightIndex > 0);
const canStepForward = computed(() => props.selectedFightIndex < props.fights.length - 1);
/** 回到终局（默认视角）。 */
function resetCursor() {
  seconds.value = props.timeline.durationSeconds;
}

/**
 * 把一个指针位置换算成游标秒数。时间轴与经济差图共用同一套换算——两处都要能擦洗，
 * 各写一份迟早会漂（一处按 padding 算、一处按 border 算，两端就差几个像素）。
 */
function scrubTo(event: PointerEvent, element: HTMLElement | null) {
  if (!element) return;
  const rect = element.getBoundingClientRect();
  const ratio = Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width));
  seconds.value = Math.round(ratio * duration.value);
}

/** 拖动游标：按住时间轴任意位置即可来回擦洗。 */
const scrubbing = ref(false);
const barRef = ref<HTMLElement | null>(null);
function onBarDown(event: PointerEvent) {
  scrubbing.value = true;
  (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  scrubTo(event, barRef.value);
}
function onBarMove(event: PointerEvent) {
  if (scrubbing.value) scrubTo(event, barRef.value);
}
function onBarUp() {
  scrubbing.value = false;
}

/**
 * 经济差图是**第二个擦洗面**。
 *
 * 用户原话：「我希望在经济的那个上边也能拖动时间轴，这样的话人也看着比较易于操作」——
 * 那张图本来就是全宽的时间轴（横轴就是分钟），游标竖线也画在上面，能看却不能拖反而别扭。
 * 键盘可达性仍然由下面那条 `role="slider"` 的时间轴负责，这里只加指针擦洗。
 */
const sparkScrubbing = ref(false);
const sparkRef = ref<HTMLElement | null>(null);
function onSparkDown(event: PointerEvent) {
  sparkScrubbing.value = true;
  (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  scrubTo(event, sparkRef.value);
}
function onSparkMove(event: PointerEvent) {
  if (sparkScrubbing.value) scrubTo(event, sparkRef.value);
}
function onSparkUp() {
  sparkScrubbing.value = false;
}

/** 键盘擦洗：既然声明了 role=slider，方向键就得能用——←/→ 5 秒、Shift 30 秒、Home/End 到两端。 */
function nudge(delta: number) {
  seconds.value = Math.min(duration.value, Math.max(0, seconds.value + delta));
}

// ── 经济差折线（全宽）─────────────────────────────────────────────────
const SPARK_W = 100;
const SPARK_H = 34;
/**
 * 经济差画成**面积图**：零轴以上填蓝、以下填红。
 *
 * 上一版是逐段描线，一局里金币差来回穿零轴十几次，画出来就是一团互相压着的
 * 乱线（用户原话「线条渲染得很诡异」）。面积图把「谁领先、领先多少」直接变成
 * 上下两块色块，穿零轴的次数再多也只是色块交界，不会糊成一团。
 */
const sparkline = computed(() => {
  const frames = props.timeline.frames;
  if (frames.length < 2) return null;
  const maxAbs = Math.max(1000, ...frames.map((frame) => Math.abs(frame.goldDiff)));
  const baseline = SPARK_H / 2;
  const points = frames.map((frame) => ({
    x: (frame.minute * 60 / duration.value) * SPARK_W,
    y: baseline - (frame.goldDiff / maxAbs) * (baseline - 2),
    value: frame.goldDiff,
  }));
  const runs = splitBySign(points, baseline).map((run) => {
    const first = run.points[0];
    const last = run.points[run.points.length - 1];
    // 面积 = 折线 + 回零轴的两段直边；线本身单独描一条（面积只填充不描边）。
    const area = `${pathFrom(run.points)} L${last.x.toFixed(1)},${baseline.toFixed(1)} L${first.x.toFixed(1)},${baseline.toFixed(1)} Z`;
    return { leading: run.leading, line: pathFrom(run.points), area };
  });
  return { runs, baseline, playheadX: (seconds.value / duration.value) * SPARK_W, maxAbs };
});

// ── 小地图 ────────────────────────────────────────────────────────────
/**
 * 地图上的十个点：**画英雄头像**而不是纯色圆点。
 *
 * 纯点只能看出「这儿有个人」，认人得靠颜色和位置反推；换成头像 + 阵营色外圈之后，
 * 「谁在哪」一眼就能读出来（这也是观战界面里唯一能同时看到双方站位的地方）。
 */
const dots = computed(() => {
  const positions = positionsAt.value;
  if (!positions) return [];
  return seatPlayers.value
    .map(({ seat, player }) => {
      const position = positions[seat.participantId - 1];
      if (!position || (position.x <= 0 && position.y <= 0)) return null;
      const { left, top } = mapToImagePosition(position.x, position.y, 1, 1);
      return {
        key: seat.participantId,
        championId: seat.championId,
        tone: seat.team === TEAM_BLUE ? "blue" : "red",
        style: { left: `${left * 100}%`, top: `${top * 100}%` },
        // 悬浮说明给「谁在哪儿」的完整信息；头像自身的可读名（aria-label / title）走英雄名——
        // 那是一张英雄头像，读屏把它念成「玩家名 · 时间」是错的。
        title: player ? `${player.gameName} · ${props.championNameOf(seat.championId)} · ${clockOf(seconds.value)}` : `座位 ${seat.participantId}`,
      };
    })
    .filter(Boolean) as { key: number; championId: number; tone: string; style: Record<string, string>; title: string }[];
});

/**
 * 地图上的**建筑**（22 座防御塔 + 6 座水晶），以及「到游标这一刻还在不在」。
 *
 * 塔是「这一路推穿了没有」的唯一读数：只有英雄头像的话，塔掉没掉完全看不出来。
 * 被推掉的**仍然画**（空心灰）而不是直接删掉——「这波团开打前右下的二塔还在不在」
 * 正是要看的东西。坐标表与推导在 `matches/structures.ts`（含水晶 5 分钟重生）。
 */
const structureMarkers = computed(() =>
  structureStatesAt(props.timeline.events, seconds.value).map(({ spot, destroyed }) => {
    const { left, top } = mapToImagePosition(spot.x, spot.y, 1, 1);
    const owner = spot.team === TEAM_BLUE ? "蓝方" : "红方";
    const kind = spot.kind === "inhibitor" ? "水晶" : "防御塔";
    const tier = spot.tier === "NEXUS_TURRET" ? "门牙塔" : spot.tier === "OUTER_TURRET" ? "一塔" : spot.tier === "INNER_TURRET" ? "二塔" : spot.tier === "BASE_TURRET" ? "高地塔" : "";
    return {
      key: spot.id,
      destroyed,
      kind: spot.kind,
      tone: spot.team === TEAM_BLUE ? "blue" : "red",
      style: { left: `${left * 100}%`, top: `${top * 100}%` },
      title: `${owner}${tier}${kind}${destroyed ? "（已推掉）" : "（还在）"}`,
    };
  }),
);

/**
 * 地图上的团战编号钉。
 *
 * 注意 `index` 必须取**原数组下标**（选中态和 `select-fight` 都吃它）：
 * 团战落点算不出来时 `center` 是 null，先 filter 再 map 会让下标整体前移，
 * 点「团 7」变成选中「团 6」（1-based 的显示号 `fight.index` 就对不上了）。
 */
const fightPins = computed(() =>
  props.fights
    .map((fight, index) => ({ fight, index }))
    .filter((entry) => entry.fight.center)
    .map((entry) => {
      const { left, top } = mapToImagePosition(entry.fight.center!.x, entry.fight.center!.y, 1, 1);
      return {
        fight: entry.fight,
        index: entry.index,
        style: { left: `${left * 100}%`, top: `${top * 100}%` },
        tone: entry.fight.winningTeam === TEAM_BLUE ? "blue" : entry.fight.winningTeam === TEAM_RED ? "red" : "even",
      };
    }),
);

const metBadgeOf = (puuid?: string) => {
  if (!puuid) return "";
  if (puuid === props.selfPuuid) return "我";
  const count = props.encounterCounts?.[puuid] ?? 0;
  return count > 0 ? `遇到过 ${count}` : "";
};
const isSelf = (puuid?: string) => Boolean(puuid && puuid === props.selfPuuid);

const compactNumber = (value: number) => new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 1 }).format(value ?? 0);
/**
 * 行里只放得下「KDA · 经济」两枚胶囊（用户明确要求两行封顶：名字+数字一行、第二行一项数据），
 * 补刀 / 视野这些放不下的就挂到悬浮说明上，别硬塞第三行。
 * 第二行那项的数值不再写进来——那条柱子/那排图标已经把它表达完了。
 */
const statTitle = (player?: MatchParticipant | null) => {
  if (!player) return "这一局没有该玩家的十人详情";
  const parts = [`KDA ${player.kills}/${player.deaths}/${player.assists}`, `补刀 ${player.cs}`];
  if (player.visionScore != null) parts.push(`视野 ${player.visionScore}`);
  return parts.join(" · ");
};

/**
 * 第二行那项的悬浮说明。**必须写明是「到此刻」还是「全场」**：真机的分钟帧里没有伤害
 * 字段（那两项会降级成全场总账），推塔也只有整局总账——跟会随游标涨的柱子摆在一起，
 * 不写清就会被当成同一口径。
 */
const rowValueTitle = (participantId: number) => {
  if (rowMetric.value === "items") return "终局出装（LCU 拿不到任意时刻的出装）";
  const value = compactNumber(rowValueOf(participantId));
  if (rowMetric.value === "tower") return `全场对防御塔造成的伤害 ${value}`;
  const kind = rowMetric.value === "damage" ? "对英雄伤害" : "承受伤害";
  if (!framesWithDamage.value) return `全场累计${kind} ${value}（客户端逐分钟帧不含伤害字段，这里退到全场总账）`;
  return `到 ${clockOf(seconds.value)} 为止，累计${kind} ${value}`;
};

/** 鼠标停在某个玩家行上，就让地图上他的那个点亮起来——十个人挤在图上时靠这个认人。 */
const hoveredSeat = ref<number | null>(null);
</script>

<template>
  <div class="spectate">
    <!-- 顶部对局面板：**两块阵营面板夹一块记分牌**。左右各一块，带自己阵营的底色与描边，
         阵营名 / 队伍经济 / 目标物各归自己那一块；时间、比分、经济差收在正中（转播画面就是
         这三个数一起读）。目标物做成胶囊，「标签 / 数量 / 龙种」三段的层级才分得开。
         金币数字前面都挂金币图标——面板上还有一组伤害数字，不标出来分不清谁是谁。 -->
    <header class="spectate__score">
      <section class="spectate__side" data-team="100">
        <p class="spectate__sidehead">
          <span class="spectate__sidename">蓝方</span>
          <span class="spectate__sidegold"><i class="coin" aria-hidden="true" />{{ compactGold(teamGoldAt[TEAM_BLUE] ?? 0) }}</span>
        </p>
        <div class="spectate__objs">
          <span class="spectate__obj"><b>塔</b>{{ objectivesAt[TEAM_BLUE]?.towers ?? 0 }}</span>
          <span v-if="objectivesAt[TEAM_BLUE]?.dragons.length" class="spectate__obj" :title="`拿到的龙：${dragonTextOf(TEAM_BLUE)}`">
            <b>小龙</b>{{ objectivesAt[TEAM_BLUE].dragons.length }}
            <small>{{ dragonTextOf(TEAM_BLUE) }}</small>
          </span>
          <span v-if="objectivesAt[TEAM_BLUE]?.barons" class="spectate__obj is-epic" title="大龙（纳什男爵）"><b>大龙</b>{{ objectivesAt[TEAM_BLUE].barons }}</span>
          <span v-if="objectivesAt[TEAM_BLUE]?.heralds" class="spectate__obj" title="峡谷先锋"><b>先锋</b>{{ objectivesAt[TEAM_BLUE].heralds }}</span>
        </div>
      </section>

      <!-- 中间记分牌：时间在上、比分居中最大、经济差在下，一条竖轴。 -->
      <section class="spectate__center">
        <span class="spectate__clock"><strong>{{ clockOf(seconds) }}</strong><small>/ {{ clockOf(duration) }}</small></span>
        <span class="spectate__tally">
          <b data-team="100">{{ tallyAt.blue }}</b>
          <i>:</i>
          <b data-team="200">{{ tallyAt.red }}</b>
        </span>
        <span class="spectate__diff" :data-lead="goldDiffAt > 0 ? 'blue' : goldDiffAt < 0 ? 'red' : 'even'">
          <i class="coin" aria-hidden="true" /><span>经济差</span><b>{{ signedGold(goldDiffAt) }}</b>
        </span>
      </section>

      <!-- 右翼红方：镜像（阵营名贴外边、金币贴中线、目标物从右往左排）。 -->
      <section class="spectate__side" data-team="200">
        <p class="spectate__sidehead">
          <span class="spectate__sidegold"><i class="coin" aria-hidden="true" />{{ compactGold(teamGoldAt[TEAM_RED] ?? 0) }}</span>
          <span class="spectate__sidename">红方</span>
        </p>
        <div class="spectate__objs">
          <span v-if="objectivesAt[TEAM_RED]?.heralds" class="spectate__obj" title="峡谷先锋"><b>先锋</b>{{ objectivesAt[TEAM_RED].heralds }}</span>
          <span v-if="objectivesAt[TEAM_RED]?.barons" class="spectate__obj is-epic" title="大龙（纳什男爵）"><b>大龙</b>{{ objectivesAt[TEAM_RED].barons }}</span>
          <span v-if="objectivesAt[TEAM_RED]?.dragons.length" class="spectate__obj" :title="`拿到的龙：${dragonTextOf(TEAM_RED)}`">
            <b>小龙</b>{{ objectivesAt[TEAM_RED].dragons.length }}
            <small>{{ dragonTextOf(TEAM_RED) }}</small>
          </span>
          <span class="spectate__obj"><b>塔</b>{{ objectivesAt[TEAM_RED]?.towers ?? 0 }}</span>
        </div>
      </section>
    </header>

    <!-- 十人行的第二行显示什么：这是**读数口径**的开关，跟地图、跟回放都无关，所以单独
         一条通栏压在那十行上面。原来塞在底部回放控制条里，用户反馈「不容易找到、不容易
         看到」——它管的是下面十行，就该长在下面十行的头上。 -->
    <div class="spectate__rowbar">
      <span class="spectate__rowbar-label">十人第二行</span>
      <div class="spectate__rowswitch" role="group" aria-label="十人第二行的指标">
        <button
          v-for="item in ROW_METRICS"
          :key="item.key"
          type="button"
          :class="{ 'is-active': rowMetric === item.key }"
          :aria-pressed="rowMetric === item.key"
          @click="rowMetric = item.key"
        >{{ item.label }}</button>
      </div>
      <span class="spectate__rowbar-caption">{{ rowMetricDef.caption }}<template v-if="rowMetricDef.kind === 'bar'"> · 蓝 {{ compactNumber(rowMetricTotal[TEAM_BLUE] ?? 0) }} / 红 {{ compactNumber(rowMetricTotal[TEAM_RED] ?? 0) }}</template></span>
      <!-- 降级要说出来：这一局没拿到逐分钟伤害，这两项给的是全场总账。 -->
      <span v-if="!framesWithDamage" class="spectate__rowbar-note" title="这一局没取到逐分钟伤害：客户端本地的分钟帧里没有伤害字段，要去同一局的 SGP 时间线里拿，这次没拿到">输出 / 承伤为全场总账</span>
    </div>

    <!-- 舞台：蓝队列 | 小地图（常驻）| 红队列 -->
    <div class="spectate__stage">
      <div class="spectate__team" data-team="100">
        <p class="spectate__teamlabel" data-team="100">蓝方 <small>{{ rowMetricCaption }}<template v-if="rowMetricDef.kind === 'bar'"> · 合计 {{ compactNumber(rowMetricTotal[TEAM_BLUE] ?? 0) }}</template></small></p>
        <div v-for="entry in bluePlayers" :key="entry.seat.participantId" class="spectate-player" @mouseenter="hoveredSeat = entry.seat.participantId" @mouseleave="hoveredSeat = null">
          <span class="spectate-player__portrait">
            <AssetIcon kind="champion" :id="entry.seat.championId" :name="championNameOf(entry.seat.championId)" :fallback-url="championImage(entry.seat.championId)" size="sm" />
            <i v-if="levelOf(entry.seat.participantId)" class="spectate-player__level" :title="`英雄等级 ${levelOf(entry.seat.participantId)}`">{{ levelOf(entry.seat.participantId) }}</i>
          </span>
          <div class="spectate-player__body" :class="{ 'is-self': isSelf(entry.player?.puuid) }">
            <p class="spectate-player__line">
              <b :title="championNameOf(entry.seat.championId)">{{ entry.player?.gameName ?? championNameOf(entry.seat.championId) }}<i v-if="metBadgeOf(entry.player?.puuid)">{{ metBadgeOf(entry.player?.puuid) }}</i></b>
              <span class="spectate-player__stats" :title="statTitle(entry.player)">
                <span class="spectate-kda"><b>{{ entry.player?.kills ?? 0 }}</b><i>/</i><b class="is-death">{{ entry.player?.deaths ?? 0 }}</b><i>/</i><b class="is-assist">{{ entry.player?.assists ?? 0 }}</b></span>
                <span class="spectate-gold"><i class="coin" aria-hidden="true" />{{ compactGold(goldOf(entry.seat.participantId)) }}</span>
              </span>
            </p>
            <!-- 第二行：柱状图（输出/承伤/推塔）或终局出装，由上方通栏的切换器决定。 -->
            <span v-if="rowMetricDef.kind === 'bar'" class="spectate-player__damage" :title="rowValueTitle(entry.seat.participantId)">
              <span class="spectate-player__damage-track"><i :style="{ width: rowPercent(rowValueOf(entry.seat.participantId)) }" /></span>
              <b>{{ compactNumber(rowValueOf(entry.seat.participantId)) }}</b>
            </span>
            <span v-else class="spectate-player__items" :title="rowValueTitle(entry.seat.participantId)">
              <AssetIcon v-for="item in (entry.player?.items ?? []).slice(0, 6)" :key="item.id" kind="item" :id="item.id" :name="item.name" :fallback-url="item.iconUrl" size="xs" />
              <small v-if="!entry.player?.items?.length">—</small>
            </span>
          </div>
        </div>
      </div>

      <!-- 中间列：小地图常驻（不再有「地图 / 实时伤害」切换）。英雄头像压在建筑层之上。 -->
      <div class="spectate__map">
        <img class="spectate__plate" :src="map11" alt="召唤师峡谷地图" />
        <!-- 建筑层：22 座塔 + 6 座水晶；被推掉的画成空心灰，拖时间轴就能看着它们一座座掉。 -->
        <span v-for="structure in structureMarkers" :key="structure.key" class="spectate__structure" :class="{ 'is-down': structure.destroyed }" :data-kind="structure.kind" :data-tone="structure.tone" :style="structure.style" :title="structure.title" />
        <span v-for="dot in dots" :key="dot.key" class="spectate__dot" :class="{ 'is-hot': hoveredSeat === dot.key }" :data-tone="dot.tone" :style="dot.style" :title="dot.title">
          <AssetIcon kind="champion" round :id="dot.championId" :name="championNameOf(dot.championId)" :fallback-url="championImage(dot.championId)" size="xs" />
        </span>
        <button
          v-for="pin in fightPins"
          :key="`pin-${pin.index}`"
          type="button"
          class="spectate__pin"
          :class="{ 'is-active': selectedFightIndex === pin.index }"
          :data-tone="pin.tone"
          :style="pin.style"
          :title="`团${pin.fight.index} ${describeLocation(pin.fight.center)}（点击查看这一波）`"
          @click.stop="selectFight(pin.index)"
        >{{ pin.fight.index }}</button>
      </div>

      <div class="spectate__team" data-team="200">
        <p class="spectate__teamlabel" data-team="200"><small>{{ rowMetricCaption }}<template v-if="rowMetricDef.kind === 'bar'"> · 合计 {{ compactNumber(rowMetricTotal[TEAM_RED] ?? 0) }}</template></small> 红方</p>
        <div v-for="entry in redPlayers" :key="entry.seat.participantId" class="spectate-player" @mouseenter="hoveredSeat = entry.seat.participantId" @mouseleave="hoveredSeat = null">
          <div class="spectate-player__body" :class="{ 'is-self': isSelf(entry.player?.puuid) }">
            <p class="spectate-player__line">
              <b :title="championNameOf(entry.seat.championId)"><i v-if="metBadgeOf(entry.player?.puuid)">{{ metBadgeOf(entry.player?.puuid) }}</i>{{ entry.player?.gameName ?? championNameOf(entry.seat.championId) }}</b>
              <span class="spectate-player__stats" :title="statTitle(entry.player)">
                <span class="spectate-kda"><b>{{ entry.player?.kills ?? 0 }}</b><i>/</i><b class="is-death">{{ entry.player?.deaths ?? 0 }}</b><i>/</i><b class="is-assist">{{ entry.player?.assists ?? 0 }}</b></span>
                <span class="spectate-gold"><i class="coin" aria-hidden="true" />{{ compactGold(goldOf(entry.seat.participantId)) }}</span>
              </span>
            </p>
            <!-- 第二行：与蓝方同构，只是红方把数字放内侧、柱子朝外（镜像语言）。 -->
            <span v-if="rowMetricDef.kind === 'bar'" class="spectate-player__damage" :title="rowValueTitle(entry.seat.participantId)">
              <b>{{ compactNumber(rowValueOf(entry.seat.participantId)) }}</b>
              <span class="spectate-player__damage-track"><i :style="{ width: rowPercent(rowValueOf(entry.seat.participantId)) }" /></span>
            </span>
            <span v-else class="spectate-player__items" :title="rowValueTitle(entry.seat.participantId)">
              <small v-if="!entry.player?.items?.length">—</small>
              <AssetIcon v-for="item in (entry.player?.items ?? []).slice(0, 6)" :key="item.id" kind="item" :id="item.id" :name="item.name" :fallback-url="item.iconUrl" size="xs" />
            </span>
          </div>
          <span class="spectate-player__portrait">
            <AssetIcon kind="champion" :id="entry.seat.championId" :name="championNameOf(entry.seat.championId)" :fallback-url="championImage(entry.seat.championId)" size="sm" />
            <i v-if="levelOf(entry.seat.participantId)" class="spectate-player__level" :title="`英雄等级 ${levelOf(entry.seat.participantId)}`">{{ levelOf(entry.seat.participantId) }}</i>
          </span>
        </div>
      </div>
    </div>

    <!-- 经济差面积图：零轴以上蓝方领先、以下红方领先，游标竖线同步。
         它横轴就是时间，所以**同样可以按住拖动擦洗**（与下面的时间轴同一套换算）。 -->
    <div
      ref="sparkRef"
      class="spectate__spark"
      title="按住拖动可以擦洗时间轴"
      @pointerdown="onSparkDown"
      @pointermove="onSparkMove"
      @pointerup="onSparkUp"
      @pointercancel="onSparkUp"
    >
      <svg v-if="sparkline" :viewBox="`0 0 ${SPARK_W} ${SPARK_H}`" preserveAspectRatio="none" aria-hidden="true">
        <template v-for="(run, index) in sparkline.runs" :key="index">
          <path class="spectate__spark-area" :class="run.leading ? 'is-blue' : 'is-red'" :d="run.area" />
          <path class="spectate__spark-line" :class="run.leading ? 'is-blue' : 'is-red'" :d="run.line" />
        </template>
        <!-- 零轴画在面积**上面**：画在下面会被半透明填充盖住，等于没有参照线。 -->
        <line :x1="0" :x2="SPARK_W" :y1="sparkline.baseline" :y2="sparkline.baseline" class="spectate__spark-zero" />
        <line :x1="sparkline.playheadX" :x2="sparkline.playheadX" :y1="0" :y2="SPARK_H" class="spectate__spark-head" />
      </svg>
      <span class="spectate__spark-legend">
        <i data-tone="blue" />蓝方领先<i data-tone="red" />红方领先
        <b>最大 {{ signedGold(maxLead) }}</b>
      </span>
    </div>

    <!-- 底部全宽时间轴：事件标记 + 团战高亮段 + 可拖游标（带时间气泡），像视频进度条。 -->
    <div class="spectate__timeline-wrap">
      <span class="spectate__edge">0:00</span>
      <div
        ref="barRef"
        class="spectate__timeline"
        role="slider"
        tabindex="0"
        aria-label="对局时间轴"
        :aria-valuenow="Math.round(seconds)"
        :aria-valuemin="0"
        :aria-valuemax="duration"
        :aria-valuetext="`${clockOf(seconds)} / ${clockOf(duration)}`"
        @pointerdown="onBarDown"
        @pointermove="onBarMove"
        @pointerup="onBarUp"
        @pointercancel="onBarUp"
        @keydown.left.prevent="nudge($event.shiftKey ? -30 : -5)"
        @keydown.right.prevent="nudge($event.shiftKey ? 30 : 5)"
        @keydown.home.prevent="nudge(-duration)"
        @keydown.end.prevent="nudge(duration)"
      >
        <span
          v-for="segment in fightSegments"
          :key="`fight-${segment.index}`"
          class="spectate__fight"
          :class="{ 'is-active': selectedFightIndex === segment.index }"
          :style="{ left: `${segment.left}%`, width: `${segment.width}%` }"
          :title="`团${segment.fight.index} ${describeLocation(segment.fight.center)} · ${clockOf(segment.fight.startSeconds)}–${clockOf(segment.fight.endSeconds)}（点击查看这一波）`"
          @click.stop="selectFight(segment.index)"
          @pointerdown.stop
        >团{{ segment.fight.index }}</span>
        <i v-for="marker in buildingMarkers" :key="`b-${marker.seconds}-${marker.laneType}`" class="spectate__mark spectate__mark--building" :style="{ left: percentOf(marker.seconds) }" :title="eventTitle(marker)" />
        <i v-for="marker in monsterMarkers" :key="`m-${marker.seconds}-${marker.monsterType}`" class="spectate__mark spectate__mark--monster" :style="{ left: percentOf(marker.seconds) }" :title="eventTitle(marker)" />
        <i v-for="marker in killMarkers" :key="`k-${marker.event.seconds}-${marker.event.killerId}-${marker.event.victimId}`" class="spectate__mark spectate__mark--kill" :data-tone="marker.tone" :style="{ left: percentOf(marker.event.seconds) }" :title="eventTitle(marker.event)" />
        <i class="spectate__playhead" :class="`is-${playheadEdge}`" :style="{ left: percentOf(seconds) }">
          <em class="spectate__playhead-time">{{ clockOf(seconds) }}</em>
        </i>
      </div>
      <span class="spectate__edge">{{ clockOf(duration) }}</span>
    </div>

    <!-- 回放控制：观战里最常做的三件事——看上一波/下一波、回到终局。
         十人第二行的切换器已经挪到十人列上方那条通栏（这里只剩回放动作）。 -->
    <div class="spectate__controls">
      <button type="button" :disabled="!canStepBack" @click="stepFight(-1)">◀ 上一波</button>
      <button type="button" :disabled="!canStepForward" @click="stepFight(1)">下一波 ▶</button>
      <button type="button" @click="resetCursor">回到终局</button>
      <!-- 时间轴上的标记有三种形状（细刻度 / 菱形 / 圆环），不写图例没人知道哪个是哪个。
           图例里的形状和时间轴共用同一套 `data-kind`，改一边必须改另一边。 -->
      <span class="spectate__controls-legend" aria-hidden="true">
        <span><i data-kind="kill" data-tone="blue" /><i data-kind="kill" data-tone="red" />击杀</span>
        <span><i data-kind="monster" />野怪</span>
        <span><i data-kind="building" />推塔</span>
      </span>
      <span class="spectate__controls-hint">时间轴与经济差图都能按住拖动擦洗；点事件流里的某条也能跳到那一刻</span>
    </div>
  </div>
</template>

<style scoped>
.spectate {
  display: grid; gap: 8px; min-width: 0;
  /* 金币图标 = 三层同心圆（外圈实 / 中圈挖空 / 圆心实）走 evenodd 挖出来，
     做成 mask 之后靠 currentColor 上色：深浅主题、蓝红两队、金币底色下都不用改。 */
  --coin-glyph: url("data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2016%2016'%3E%3Cpath%20fill-rule='evenodd'%20d='M8%201a7%207%200%201%200%200%2014a7%207%200%201%200%200-14ZM8%203.2a4.8%204.8%200%201%200%200%209.6a4.8%204.8%200%201%200%200-9.6ZM8%205.5a2.5%202.5%200%201%200%200%205a2.5%202.5%200%201%200%200-5Z'/%3E%3C/svg%3E");
}

/* ── 顶部对局面板 ──────────────────────────────────────────────────
   结构 = 「阵营面板 │ 记分牌 │ 阵营面板」。左右两块各带自己阵营的底色和一道队色描边，
   阵营名贴外边、队伍经济贴中线、目标物排在下面 —— 两块对称，一眼看出这是两队对阵。
   中间收着时间 / 比分 / 经济差：转播画面里这三个数本来就要一起读，挤进同一块不用来回找。 */
.spectate__score { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); align-items: stretch; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); overflow: hidden; }

.spectate__side { display: grid; gap: 6px; align-content: center; padding: 8px 12px; min-width: 0; }
.spectate__side[data-team="100"] { border-left: 3px solid var(--blue); background: linear-gradient(90deg, var(--blue-soft), transparent 78%); }
.spectate__side[data-team="200"] { border-right: 3px solid var(--red); background: linear-gradient(270deg, var(--red-soft), transparent 78%); }

.spectate__sidehead { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; margin: 0; }
.spectate__sidename { font-size: 11px; font-weight: 700; letter-spacing: .04em; }
.spectate__side[data-team="100"] .spectate__sidename { color: var(--blue); }
.spectate__side[data-team="200"] .spectate__sidename { color: var(--red); }
/* 队伍经济：一定要带金币图标。面板上金币和伤害两组数字长得一样，不标就分不清谁是谁。 */
.spectate__sidegold { display: inline-flex; align-items: center; gap: 3px; color: var(--gold); font-size: 13px; font-weight: 700; font-variant-numeric: tabular-nums; }

/* 目标物做成胶囊：「标签 / 数量 / 龙种」三段的层级才分得开，比一串裸文字好扫。 */
.spectate__objs { display: flex; align-items: center; flex-wrap: wrap; gap: 4px; min-width: 0; }
.spectate__side[data-team="200"] .spectate__objs { justify-content: flex-end; }
.spectate__obj { display: inline-flex; align-items: baseline; gap: 3px; padding: 1px 7px; border: 1px solid var(--line); border-radius: 999px; background: var(--surface-raised); font-size: 11px; font-weight: 700; font-variant-numeric: tabular-nums; white-space: nowrap; }
.spectate__obj b { color: var(--text-muted); font-size: 9px; font-weight: 600; }
.spectate__side[data-team="100"] .spectate__obj { color: var(--blue); }
.spectate__side[data-team="200"] .spectate__obj { color: var(--red); }
/* 龙种写成「火龙 · 海龙」跟在条数后面，小一号——别把条数淹了。 */
.spectate__obj small { color: var(--text-secondary); font-size: 9px; font-weight: 500; }
/* 大龙是全局目标，转播里喊的就是它，给个更重的底把优先级抬起来。 */
.spectate__obj.is-epic { border-color: transparent; background: var(--gold-soft); color: var(--gold); }
.spectate__obj.is-epic b { color: var(--gold); }

/* 中间记分牌：时间 / 比分 / 经济差，自上而下一条竖轴。 */
.spectate__center { display: grid; justify-items: center; align-content: center; gap: 3px; padding: 8px 18px; background: var(--surface-muted); border-left: 1px solid var(--line); border-right: 1px solid var(--line); min-width: 0; }
.spectate__clock { display: inline-flex; align-items: baseline; gap: 4px; font-variant-numeric: tabular-nums; white-space: nowrap; }
/* 当前时间比总时长重：一个是「现在看的是第几分钟」，一个是参照值。 */
.spectate__clock strong { color: var(--text-primary); font-size: 14px; font-weight: 700; }
.spectate__clock small { color: var(--text-muted); font-size: 10px; }
.spectate__tally { display: inline-flex; align-items: baseline; gap: 7px; font-variant-numeric: tabular-nums; }
.spectate__tally b { font-size: 26px; font-weight: 800; line-height: 1; }
.spectate__tally b[data-team="100"] { color: var(--blue); }
.spectate__tally b[data-team="200"] { color: var(--red); }
.spectate__tally i { color: var(--text-muted); font-size: 15px; font-style: normal; }
/* 经济差也是一笔钱，配金币图标；领先方用自己的队色，别和比分的颜色混在一起。 */
.spectate__diff { display: inline-flex; align-items: center; gap: 3px; padding: 1px 8px; border: 1px solid var(--line); border-radius: 999px; background: var(--surface-raised); font-size: 10px; font-variant-numeric: tabular-nums; }
.spectate__diff span { color: var(--text-muted); }
.spectate__diff .coin { color: var(--gold); }
.spectate__diff b { color: var(--text-secondary); font-weight: 700; }
.spectate__diff[data-lead="blue"] b { color: var(--blue); }
.spectate__diff[data-lead="red"] b { color: var(--red); }

/* 金币图标：mask + currentColor —— 颜色跟着所在位置的文字色走，深浅主题都对。
   三层同心圆（外圈实 / 中圈挖空 / 圆心实）在 10px 下仍读得出是「硬币」而不是「圆点」。 */
.coin { display: inline-block; width: 10px; height: 10px; flex: none; background: currentColor; -webkit-mask: var(--coin-glyph) center / contain no-repeat; mask: var(--coin-glyph) center / contain no-repeat; }

/* ── 舞台：蓝队列 | 小地图 | 红队列 ──────────────────────────────── */
.spectate__stage { display: grid; grid-template-columns: minmax(0, 1fr) minmax(240px, 320px) minmax(0, 1fr); gap: 10px; align-items: stretch; }
.spectate__team { display: grid; gap: 4px; min-width: 0; align-content: space-between; }
/* 两列的阵营标签：没有它就得靠颜色猜哪边是蓝。顺带说明第二行那排数字是什么。 */
.spectate__teamlabel { margin: 0 0 1px; font-size: 10px; font-weight: 600; }
.spectate__teamlabel[data-team="100"] { color: var(--blue); }
.spectate__teamlabel[data-team="200"] { color: var(--red); text-align: right; }
.spectate__teamlabel small { margin-left: 4px; color: var(--text-muted); font-size: 9px; font-weight: 400; }
.spectate-player { display: flex; align-items: center; gap: 7px; padding: 4px 6px; border: 1px solid var(--line); border-radius: 5px; background: var(--surface); min-width: 0; transition: border-color .12s, background .12s; }
.spectate-player:hover { border-color: var(--line-strong); background: var(--surface-raised); }
.spectate-player__portrait { position: relative; display: grid; place-items: center; flex: 0 0 auto; }
/* 等级角标压在头像上：跟全 app 的徽章同一语言（`--surface-muted` 面 + `--line` 细边 + 次级文字色），
   这里必须**不透明**——底下是彩色英雄原画，半透明会直接糊掉。 */
.spectate-player__level { position: absolute; right: -4px; bottom: -4px; display: grid; place-items: center; min-width: 15px; height: 14px; padding: 0 2px; border: 1px solid var(--line); border-radius: 3px; color: var(--text-secondary); background: var(--surface-muted); font-size: 9px; font-style: normal; font-weight: 700; font-variant-numeric: tabular-nums; }
/* 红方头像是右对齐的，角标跟着镜像到内侧，否则会顶到卡片的右边框上。 */
.spectate__team[data-team="200"] .spectate-player__level { right: auto; left: -4px; }
.spectate-player__body { display: grid; gap: 2px; min-width: 0; flex: 1 1 auto; }
/* 一行装下「名字 + 战绩·经济」：名字弹性收缩，数字钉在另一头（红方镜像）。 */
.spectate-player__line { display: flex; align-items: center; gap: 6px; margin: 0; min-width: 0; }
/* 红方镜像：靠**行内**的 flex 反向 + auto margin 把内容推到两端，**不能**在这里写
   `justify-items: end`——那会让 grid item 变成 shrink-to-fit，第二行的伤害柱
   （靠 `flex: 1 1 auto` 吃掉剩余宽度）直接塌成 0px，红方那半边的柱子整条消失。 */
.spectate__team[data-team="200"] .spectate-player__line { flex-direction: row-reverse; }
/* 名字是 `<b>`，但胶囊里的 KDA 数字也是 `<b>`——这里必须**只命中名字**（直接子级），
   否则 `.spectate-player__body.is-self b` 的权重会压过 `.spectate-kda b`，
   把「我」那一行的击杀数字也染成 accent 色（阵亡/助攻色还在，只有第一个数字不对，很容易漏）。 */
.spectate-player__line > b { display: flex; align-items: center; gap: 4px; min-width: 0; max-width: 100%; overflow: hidden; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.spectate-player__line > b i { flex: 0 0 auto; padding: 0 4px; border-radius: 6px; color: var(--accent); background: var(--accent-soft); font-size: 8px; font-style: normal; font-weight: 500; }
.spectate-player__body.is-self .spectate-player__line > b { color: var(--accent); }

/* 战绩与经济：原来是一行 9px 次级色文字「3/4/5 · 12k」，糊在名字后面根本读不出来。
   拆成两枚独立胶囊——KDA 数字加粗（阵亡/助攻按语义上色）、金币走琥珀色，扫一眼就能读。 */
.spectate-player__stats { display: inline-flex; flex: 0 0 auto; align-items: center; gap: 4px; margin-left: auto; }
.spectate__team[data-team="200"] .spectate-player__stats { margin-right: auto; margin-left: 0; }
.spectate-kda,
.spectate-gold { display: inline-flex; align-items: center; gap: 1px; border: 1px solid var(--line); border-radius: 4px; background: var(--surface-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
.spectate-kda { padding: 1px 5px; }
.spectate-kda b { font-size: 10px; font-weight: 700; color: var(--text-primary); }
.spectate-kda b.is-death { color: var(--red); }
.spectate-kda b.is-assist { color: var(--blue); }
.spectate-kda i { color: var(--line-strong); font-style: normal; }
/* 金币胶囊：队色之外唯一带自己颜色的读数 —— 全 app 只有它用 `--gold`，配上金币图标
   一眼就能和旁边的伤害数字（柱状图 + 无图标）区分开。 */
.spectate-gold { padding: 1px 6px; gap: 3px; border-color: var(--gold-soft); background: var(--gold-soft); color: var(--gold); font-weight: 700; }

/* 第二行：到当前游标时刻的**累计对英雄伤害**（原来的 6 件装备腾出来的位置）。
   柱长与数字同排；红方把数字放内侧、柱子朝外，跟上面一排的镜像语言一致。 */
.spectate-player__damage { display: flex; align-items: center; gap: 5px; min-width: 0; }
/* 数字列必须**定宽**：柱长 = 数值 / 全场最高 × 轨道宽，轨道宽要是被「2万」比「2.7万」
   少一个字而撑宽 7px，同行相减就失真了（10 行的柱子要能横向比才叫排行榜）。 */
.spectate-player__damage b { flex: 0 0 auto; min-width: 32px; overflow: visible; color: var(--text-secondary); font-size: 9px; font-weight: 700; font-variant-numeric: tabular-nums; text-align: right; }
/* 红方数字在内侧（左），跟着改对齐方向，让数字始终贴着地图那一侧。 */
.spectate__team[data-team="200"] .spectate-player__damage b { text-align: left; }
.spectate-player__damage-track { position: relative; flex: 1 1 auto; height: 8px; border-radius: 2px; background: var(--surface-muted); overflow: hidden; }
.spectate-player__damage-track i { position: absolute; inset: 0 auto 0 0; border-radius: 2px; transition: width .12s linear; }
.spectate__team[data-team="100"] .spectate-player__damage-track i { background: var(--blue); }
.spectate__team[data-team="200"] .spectate-player__damage-track i { inset: 0 0 0 auto; background: var(--red); }

/* 小地图**常驻**舞台正中（再没有「地图 / 实时伤害」那种切换）：英雄头像随游标跑、
   建筑层显示每座塔还活着没有、编号钉是团战落点。 */
.spectate__map { position: relative; align-self: center; width: 100%; aspect-ratio: 1; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; background: #0b1210; }
.spectate__plate { display: block; width: 100%; height: 100%; object-fit: cover; }
/* 地图上的建筑：22 座防御塔（方块）+ 6 座水晶（菱形），坐标与推导在 `matches/structures.ts`。
   底图是深色，所以写死亮色（主题 token 会糊进底图里）。**活着的**画实心 + 白描边；
   **被推掉的**画成空心灰——不是直接删掉，因为「这波团开打前右下的二塔还在不在」
   正是要看的东西，删了就等于读不出来。拖时间轴能看到它们一座座地空掉。 */
.spectate__structure { position: absolute; z-index: 0; width: 9px; height: 9px; margin: -4.5px 0 0 -4.5px; border: 1.5px solid #fff; border-radius: 2px; box-shadow: 0 1px 2px rgba(0, 0, 0, .5); }
.spectate__structure[data-tone="blue"] { background: #57b4ff; }
.spectate__structure[data-tone="red"] { background: #ff7a7a; }
/* 水晶比塔大一圈、转 45° 成正菱形：形状本身就能把「塔」和「水晶」分开。 */
.spectate__structure[data-kind="inhibitor"] { width: 11px; height: 11px; margin: -5.5px 0 0 -5.5px; border-radius: 1px; transform: rotate(45deg); }
.spectate__structure.is-down { border-color: rgba(255, 255, 255, .34); border-style: dashed; background: transparent; box-shadow: none; opacity: .72; }
/* 地图上的十个点画**英雄头像**：纯色圆点只能看出「这儿有人」，认人得靠反推。
   底图是深色，所以外圈用写死的亮色（主题 token 会糊进底图），头像本身裁成圆。 */
.spectate__dot { position: absolute; z-index: 1; display: grid; place-items: center; width: 24px; height: 24px; margin: -12px 0 0 -12px; border: 2px solid #57b4ff; border-radius: 50%; background: #0b1210; box-shadow: 0 1px 3px rgba(0, 0, 0, .55); transition: transform .12s, box-shadow .12s; }
.spectate__dot[data-tone="red"] { border-color: #ff7a7a; }
.spectate__dot :deep(.asset-icon) { border: 0; border-radius: 50%; }
.spectate__dot.is-hot { z-index: 3; transform: scale(1.3); box-shadow: 0 0 0 3px rgba(255, 255, 255, .6); }

/* 第二行的第二个选项是**终局出装**：六个格子平铺，红方镜像靠右。
   LCU 只在 SGP DETAILS 里给逐次购买，拿不到任意时刻的出装，所以这里就是终局那六件；
   悬浮说明里写明了这一点——跟旁边会随游标涨的柱子摆在一起，不说清就会被当成同一口径。 */
.spectate__items { display: flex; align-items: center; gap: 3px; min-height: 16px; min-width: 0; }
.spectate__team[data-team="200"] .spectate__items { justify-content: flex-end; }
.spectate__items small { color: var(--text-muted); font-size: 9px; }
/* 深色底图上的钉子用写死的亮色（主题 token 在浅色主题下会糊进底图）。
   `z-index` 必须高于英雄头像（`.spectate__dot` 是 1）：团战落点常常正好压在人堆里
   （中路团就是这个样子），不抬起来的话钉子的数字会被十张脸盖住，等于点不到也看不见。 */
.spectate__pin { position: absolute; z-index: 2; display: grid; place-items: center; width: 18px; height: 18px; margin: -9px 0 0 -9px; padding: 0; border: 1px solid rgba(255, 255, 255, .55); border-radius: 50%; color: #08201a; background: #ffd166; font-size: 10px; font-weight: 700; cursor: pointer; }
.spectate__pin[data-tone="blue"] { background: #57b4ff; }
.spectate__pin[data-tone="red"] { background: #ff7a7a; }
.spectate__pin.is-active { z-index: 4; border-color: #fff; box-shadow: 0 0 0 3px rgba(255, 255, 255, .38); }

/* ── 经济差折线（全宽）────────────────────────────────────────────── */
.spectate__spark { position: relative; border: 1px solid var(--line); border-radius: 5px; background: var(--surface); cursor: ew-resize; touch-action: none; }
.spectate__spark svg { display: block; width: 100%; height: 68px; }
.spectate__spark-zero { stroke: var(--line-strong); stroke-width: 0.5; }
/* 面积只负责「谁领先」的色块，折线单独描一条，避免线被填充盖住。 */
.spectate__spark-area { stroke: none; opacity: .5; }
.spectate__spark-area.is-blue { fill: var(--blue); }
.spectate__spark-area.is-red { fill: var(--red); }
.spectate__spark-line { fill: none; stroke-width: 1.4; }
.spectate__spark-line.is-blue { stroke: var(--blue); }
.spectate__spark-line.is-red { stroke: var(--red); }
.spectate__spark-head { stroke: var(--accent); stroke-width: 0.8; }
/* 图例浮在面积图上，必须自带不透明底 —— 否则蓝/红填充一铺过来，8px 的次级色文字直接糊掉
   （实测截图里「最大 +9.8k」就完全读不出来）。 */
.spectate__spark-legend { position: absolute; top: 4px; right: 6px; display: inline-flex; align-items: center; gap: 4px; padding: 1px 6px; border: 1px solid var(--line); border-radius: 4px; color: var(--text-secondary); background: var(--surface); font-size: 9px; pointer-events: none; }
.spectate__spark-legend i { width: 7px; height: 7px; border-radius: 2px; }
.spectate__spark-legend i[data-tone="blue"] { background: var(--blue); }
.spectate__spark-legend i[data-tone="red"] { background: var(--red); }
.spectate__spark-legend b { margin-left: 4px; color: var(--text-secondary); font-weight: 600; }

/* ── 底部全宽时间轴（视频进度条那样）──────────────────────────────── */
.spectate__timeline-wrap { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 6px; }
.spectate__edge { color: var(--text-muted); font-size: 9px; font-variant-numeric: tabular-nums; }
.spectate__timeline { position: relative; height: 28px; border: 1px solid var(--line); border-radius: 5px; background: var(--surface-muted); cursor: ew-resize; touch-action: none; }
/* 键盘擦洗要有可见焦点，不然方向键改了时间也不知道焦点在哪。 */
.spectate__timeline:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
/* 事件标记靠**形状**分辨，不再只靠颜色。早先只有「细刻度」一种形态、用高度和颜色区分
   （怕圆点在 28px 高的条里挤成一片）；但三根宽度不到 4px 的竖条只有颜色不同，扫一眼
   根本分不出哪根是推塔哪根是击杀。
   现在的语言：击杀 = 细竖刻度（事件流的主线，保持细）、野怪 = 实心菱形、推塔 = 空心圆环。
   菱形和圆环本身仍是小图形，密集重叠时也只是压在一起，不会像大圆点那样糊掉整条轴。
   形状中心统一用 translateX(-50%) 对到时间戳上；不这么做的话宽度一变大就会整体偏右，
   和它下面的团战高亮段对不上。 */
.spectate__mark { position: absolute; top: 50%; transform: translateX(-50%); pointer-events: auto; }
.spectate__mark--kill { width: 2px; height: 12px; margin-top: -6px; border-radius: 1px; background: var(--blue); box-shadow: 0 0 0 .5px var(--surface-muted); }
.spectate__mark--kill[data-tone="red"] { background: var(--red); }
.spectate__mark--monster { width: 7px; height: 7px; margin-top: -3.5px; border-radius: 1px; background: var(--amber); transform: translateX(-50%) rotate(45deg); }
/* 空心圆环：外圈描边 + 底色填充，压在彩色刻度之间也能一眼认出是「建筑」而不是一次击杀。 */
.spectate__mark--building { width: 8px; height: 8px; margin-top: -4px; border: 1.5px solid var(--text-secondary); border-radius: 50%; background: var(--surface); }
.spectate__fight { position: absolute; top: 2px; bottom: 2px; display: grid; place-items: center; border-radius: 4px; color: var(--accent); background: var(--accent-soft); font-size: 8px; font-weight: 700; cursor: pointer; }
.spectate__fight.is-active { color: var(--accent); outline: 1px solid var(--accent); }
.spectate__playhead { position: absolute; top: 0; bottom: 0; width: 2px; margin-left: -1px; background: var(--accent); pointer-events: none; }
.spectate__playhead-time { position: absolute; bottom: calc(100% + 2px); padding: 0 4px; border-radius: 4px; color: var(--accent-text, #fff); background: var(--accent); font-size: 8px; font-style: normal; font-variant-numeric: tabular-nums; white-space: nowrap; }
/* 时间气泡贴边时改对齐方向：居中会让它在 0:00 / 终局两端溢出面板。 */
.spectate__playhead.is-mid .spectate__playhead-time { left: 50%; transform: translateX(-50%); }
.spectate__playhead.is-start .spectate__playhead-time { left: 0; }
.spectate__playhead.is-end .spectate__playhead-time { right: 0; }

/* 回放控制条：三个动作 + 时间轴刻度图例 + 一句操作提示。 */
.spectate__controls { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; }
.spectate__controls button { padding: 3px 10px; border: 1px solid var(--line); border-radius: 5px; color: var(--text-secondary); background: var(--surface); cursor: pointer; font: inherit; font-size: 10px; transition: color .12s, background .12s, border-color .12s; }
.spectate__controls button:hover:not(:disabled) { color: var(--text-primary); background: var(--surface-raised); }
.spectate__controls button:disabled { opacity: .45; cursor: default; }
/* ── 十人第二行：口径开关（通栏）─────────────────────────────────────
   这条通栏压在十人列的正上方。它管的就是下面那十行的第二行显示什么，所以必须
   紧挨着内容、并且**整条通栏**都拿来放它——原来塞在底部回放控制条里，用户反馈
   「不容易找到、不容易看到」。开关同时也是「现在看的是哪一项 + 两队合计」的读数，
   扫一眼就知道柱子在量什么。 */
.spectate__rowbar { display: flex; align-items: center; flex-wrap: wrap; gap: 4px 10px; padding: 5px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--surface-muted); }
.spectate__rowbar-label { color: var(--text-secondary); font-size: 10px; font-weight: 600; }
.spectate__rowbar-caption { color: var(--text-secondary); font-size: 10px; font-variant-numeric: tabular-nums; }
/* 降级说明：真机的分钟帧里没有伤害字段，那两项给的是全场总账——写在读数旁边，别藏进 tooltip。 */
.spectate__rowbar-note { padding: 0 6px; border-radius: 4px; color: var(--amber); background: var(--amber-soft); font-size: 9px; }
.spectate__rowswitch { display: inline-flex; align-items: center; gap: 2px; padding: 2px; border: 1px solid var(--line); border-radius: 6px; background: var(--surface); }
.spectate__rowswitch button { padding: 3px 12px; border: 0; border-radius: 4px; color: var(--text-secondary); background: transparent; cursor: pointer; font: inherit; font-size: 11px; transition: color .12s, background .12s; }
.spectate__rowswitch button:hover:not(.is-active) { color: var(--text-primary); background: var(--surface-raised); }
.spectate__rowswitch button.is-active { color: var(--accent); background: var(--accent-soft); font-weight: 600; }
.spectate__controls-hint { margin-left: auto; color: var(--text-muted); font-size: 9px; }
/* 刻度图例：色块形状跟时间轴上的真刻度一致（击杀 2px、野怪 3px 高一点、推塔更短）。 */
.spectate__controls-legend { display: inline-flex; align-items: center; gap: 10px; margin-left: 2px; color: var(--text-muted); font-size: 9px; }
.spectate__controls-legend > span { display: inline-flex; align-items: center; gap: 3px; }
/* 图例必须和时间轴用同一套形状，否则图例本身就成了误导：写了「野怪」却画一根竖条，
   用户会以为野怪就是竖条里偏黄的那根。 */
.spectate__controls-legend i { width: 2px; height: 9px; border-radius: 1px; flex: none; }
.spectate__controls-legend i[data-kind="kill"][data-tone="blue"] { background: var(--blue); }
.spectate__controls-legend i[data-kind="kill"][data-tone="red"] { background: var(--red); }
.spectate__controls-legend i[data-kind="monster"] { width: 6px; height: 6px; border-radius: 1px; background: var(--amber); transform: rotate(45deg); }
.spectate__controls-legend i[data-kind="building"] { width: 7px; height: 7px; border: 1.5px solid var(--text-secondary); border-radius: 50%; background: var(--surface); }

@media (max-width: 980px) {
  .spectate__stage { grid-template-columns: 1fr 1fr; }
  /* 窄屏改成「地图横跨一整行摆在最上」，两队分列下面。 */
  .spectate__map { grid-column: 1 / -1; order: -1; max-width: 340px; margin: 0 auto; }
}
</style>
