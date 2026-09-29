<script setup lang="ts">
/**
 * 每波团：一行一团的**可选中摘要** + 一张共用的对位详情表。
 *
 * 为什么改成「点哪波、表显示哪波」：原来每波团各渲染一整块（位置 + 时间 + 比分 +
 * 双方十来个头像），三波团就把半页占完了，而且三块长得一样、扫不出重点。
 * 现在列表只给一行摘要（编号 / 位置 / 时间 / 比分），点击选中某波，下面**同一张表**
 * 就换成那一波的数据：表里是这一波**每个参战者**的击杀 / 死亡 / 助攻（从这波的
 * 击杀事件现算，不是官方字段），没参团的人也会出现在表里——「这波为什么 3 打 5」一眼能看出来。
 *
 * 团战落点地图与走位点都搬进了上方的观战面板（那里有可拖的时间轴，点时间轴上的
 * 团战段 / 地图钉同样选中这一波）——本组件保留摘要条 + **这一波的伤害柱状图** +
 * 团战前后经济（文字），选中态由父组件持有（受控），与观战面板永远同步。
 *
 * 伤害从哪来：分钟帧里每人的「累计对英雄伤害」，团后帧减团前帧就是这波的实际输出
 * （LCU 帧没有该字段时全部是 0，回退成原来的 K/D/A 对位表，不会出现一张全零的图）。
 */
import { computed, ref, watch } from "vue";
import AssetIcon from "./AssetIcon.vue";
import type { GameRecordingFrame, MatchParticipant, MatchTimelineFrame, MatchTimelineParticipant } from "../types/domain";
import { clockOf, framesHaveDamage, interpolatedDamage, interpolatedGold, interpolatedTaken, TEAM_BLUE, TEAM_RED, teamLabel } from "../matches/timeline";
import { describeLocation, type Teamfight } from "../matches/teamfights";
import { sameTeamAsSeat } from "../matches/lineup";
import { buildRecordedSeatLookup, recordedFrameAt, recordedPlayerForSeat } from "../matches/recordingLineup";
import { championImage, recordingItemImage } from "../utils/format";

const props = defineProps<{
  fights: Teamfight[];
  championNameOf: (id: number) => string;
  /** 本局十人名单：对位表按它补齐两侧、没参团的人弱化显示；也算阵营经济。 */
  participants?: MatchTimelineParticipant[];
  /** 十人完整详情（含全场伤害/承伤）：「全场」那两个指标从这里取。 */
  players?: MatchParticipant[];
  /** 每分钟帧（含十人 totalGold / 累计伤害 / 累计承伤）。缺失时对应指标自动降级。 */
  frames?: MatchTimelineFrame[];
  /**
   * 本机录制帧（可选）。
   *
   * 有它，「出装」这一项画的是**那一波团当时**的装备（按团战开始的秒数取最近一帧）；
   * 没有就退回这局终局的六件。**两条口径必须在界面上分开写**——同一个位置在两套口径
   * 下含义不同，不写清楚就会被当成算错了（这也是用户报「每波团的出装是不是没做」的原因：
   * 标签写着「团战时刻的出装」，画的却是终局那六件）。
   */
  recording?: GameRecordingFrame[];
  /** 受控选中下标（父组件持有）；不传则组件内部自持。 */
  selectedIndex?: number;
  /** `split` = 左边团列表、右边详情（默认上下堆叠）。 */
  layout?: "stack" | "split";
}>();

const emit = defineEmits<{ select: [index: number] }>();

const toneOf = (fight: Teamfight) =>
  fight.winningTeam === TEAM_BLUE ? "blue" : fight.winningTeam === TEAM_RED ? "red" : "even";

/** 当前选中的团：受控优先；非受控时内部自持，fights 变化（换了一局）回落到第一波。 */
const internalIndex = ref(0);
watch(
  () => props.fights.map((fight) => fight.index).join(","),
  () => {
    internalIndex.value = 0;
  },
);
const selectedIndex = computed(() => (typeof props.selectedIndex === "number" ? props.selectedIndex : internalIndex.value));
const selectedFight = computed(() => props.fights[selectedIndex.value] ?? null);
function select(fight: Teamfight) {
  const index = props.fights.indexOf(fight);
  if (typeof props.selectedIndex === "number") emit("select", index);
  else internalIndex.value = index;
}

function scoreOf(fight: Teamfight) {
  return `${teamLabel(TEAM_BLUE)} ${fight.killsByTeam[TEAM_BLUE] ?? 0} : ${fight.killsByTeam[TEAM_RED] ?? 0} ${teamLabel(TEAM_RED)}`;
}
/** 列表里的紧凑比分（详细比分在详情表头给全称）。 */
function chipScoreOf(fight: Teamfight) {
  return `${fight.killsByTeam[TEAM_BLUE] ?? 0}:${fight.killsByTeam[TEAM_RED] ?? 0}`;
}
const winnerLabel = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return "";
  return fight.winningTeam ? `${teamLabel(fight.winningTeam)}赢下这波` : "双方互交";
});

/**
 * 这一波里每个人的 K/D/A。全部从 `fight.kills` 现算——击杀者 +1 击杀、
 * 阵亡者 +1 死亡、助攻名单 +助攻。人数以座位号（participantId）对齐。
 */
interface FightStatRow {
  participantId: number;
  championId: number;
  team: number;
  involved: boolean;
  kills: number;
  deaths: number;
  assists: number;
}

/** 座位号 → 阵营。事件本身不带「阵亡方的阵营」，用十人名单查（缺了按座位号兜底）。 */
const teamById = computed(() => new Map((props.participants ?? []).map((participant) => [participant.participantId, participant.team])));

/** 时刻 t 的十人金币：按分钟帧线性插值（插值原语与观战面板共用 `matches/timeline`）。 */
const goldAt = (seconds: number) => interpolatedGold(props.frames ?? [], seconds);

const teamGoldAt = (seconds: number, team: number) => {
  const gold = goldAt(seconds);
  if (!gold) return null;
  const total = (props.participants ?? []).reduce((sum, participant) => sum + (participant.team === team ? gold[participant.participantId - 1] ?? 0 : 0), 0);
  // 插值会产生小数，经济差按整数金币展示。
  return Math.round(total);
};

/**
 * 团战前后的双方经济：团开打那一刻 vs 打完那一刻，两边阵营总金币各多少、
 * 差多少。差值的变化量就是「这波团在经济上赚了多少」——击杀入账、阵亡损失都揉在这里。
 * 帧数据缺失（旧缓存的对局没有 frames）时为 null，界面就不显示这块。
 */
const goldStory = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return null;
  const beforeBlue = teamGoldAt(fight.startSeconds, TEAM_BLUE);
  const afterBlue = teamGoldAt(fight.endSeconds, TEAM_BLUE);
  const beforeRed = teamGoldAt(fight.startSeconds, TEAM_RED);
  const afterRed = teamGoldAt(fight.endSeconds, TEAM_RED);
  if (beforeBlue == null || afterBlue == null || beforeRed == null || afterRed == null) return null;
  return { beforeBlue, afterBlue, beforeRed, afterRed, diffBefore: beforeBlue - beforeRed, diffAfter: afterBlue - afterRed };
});

const compact = (value: number) => new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 1 }).format(value ?? 0);
/** 双方总经济用一位小数会四舍五入成同一个数（2.1万 / 2万 却写着领先 235），这里留两位。 */
const compact2 = (value: number) => new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 2 }).format(value ?? 0);
const leadText = (diff: number) => (diff > 0 ? `蓝方领先 ${compact(diff)}` : diff < 0 ? `红方领先 ${compact(-diff)}` : "经济持平");
const swingText = computed(() => {
  const story = goldStory.value;
  if (!story) return "";
  const swing = story.diffAfter - story.diffBefore;
  if (Math.round(swing) === 0) return "经济没变化";
  return swing > 0 ? `这波蓝方拉开 ${compact(swing)}` : `这波红方拉开 ${compact(-swing)}`;
});

/** 这一波里每个人的 K/D/A（击杀者+1杀、阵亡者+1死、助攻名单+助攻），对位表用。 */
const tableRows = computed<FightStatRow[]>(() => {
  const fight = selectedFight.value;
  if (!fight) return [];
  const stats = new Map<number, FightStatRow>();
  const rowOf = (participantId: number, championId: number, team: number) => {
    const existing = stats.get(participantId);
    if (existing) return existing;
    const row: FightStatRow = { participantId, championId, team, involved: false, kills: 0, deaths: 0, assists: 0 };
    stats.set(participantId, row);
    return row;
  };
  for (const kill of fight.kills) {
    if (kill.killerId > 0) rowOf(kill.killerId, kill.killerChampionId, kill.team).kills += 1;
    if (kill.victimId > 0) {
      const team = teamById.value.get(kill.victimId) ?? (kill.victimId <= 5 ? TEAM_BLUE : TEAM_RED);
      rowOf(kill.victimId, kill.victimChampionId, team).deaths += 1;
    }
    for (const assistId of kill.assistIds ?? []) {
      if (assistId > 0) rowOf(assistId, 0, 0).assists += 1;
    }
  }
  // 命中表里的 involved 标记与英雄/阵营（事件里只有座位号，权威数据在 involved 名单）。
  for (const member of fight.involved) {
    const row = rowOf(member.participantId, member.championId, member.team);
    row.championId = member.championId;
    row.team = member.team;
    row.involved = true;
  }
  const list = [...stats.values()];
  // 十人名单传进来时，把没参团的人也补进表里（0/0/0，弱化显示）——不然看不出「3 打 5」。
  for (const participant of props.participants ?? []) {
    if (participant.participantId > 0 && !stats.has(participant.participantId)) {
      list.push({ participantId: participant.participantId, championId: participant.championId, team: participant.team, involved: false, kills: 0, deaths: 0, assists: 0 });
    }
  }
  return list.sort((left, right) => left.team - right.team || left.participantId - right.participantId);
});

/**
 * 对位行：蓝方一列、红方一列，按座位号配对（蓝 1 对红 6……），跟上面「十人对位」
 * 一个布局语言。两边人数不齐就空着。
 */
const duelSides = computed(() => {
  const blue = tableRows.value.filter((row) => row.team === TEAM_BLUE);
  const red = tableRows.value.filter((row) => row.team === TEAM_RED);
  return Array.from({ length: Math.max(blue.length, red.length) }, (_, index) => ({ blue: blue[index] ?? null, red: red[index] ?? null }));
});
/** 中线那格只在中间一行显示比分，别每行都塞一个数字。 */
const midIndex = computed(() => Math.floor((duelSides.value.length - 1) / 2));
const kdaText = (row: FightStatRow) => (row.involved ? `${row.kills}/${row.deaths}/${row.assists}` : "—");

// ── 这一波的伤害柱状图 ────────────────────────────────────────────────
/** 时刻 t 的十人累计对英雄伤害（与金币同一个插值原语）。 */
const damageAt = (seconds: number) => interpolatedDamage(props.frames ?? [], seconds);
/** 时刻 t 的十人累计承受伤害。 */
const takenAt = (seconds: number) => interpolatedTaken(props.frames ?? [], seconds);

/** 选中这波的十人伤害差值（团后帧 − 团前帧）。帧或字段缺失时为 null。 */
const fightDamage = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return null;
  const before = damageAt(fight.startSeconds);
  const after = damageAt(fight.endSeconds);
  if (!before || !after) return null;
  return after.map((value, index) => Math.max(0, value - (before[index] ?? value)));
});

/** 选中这波的十人**承伤**差值（同构）。 */
const fightTaken = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return null;
  const before = takenAt(fight.startSeconds);
  const after = takenAt(fight.endSeconds);
  if (!before || !after) return null;
  return after.map((value, index) => Math.max(0, value - (before[index] ?? value)));
});

/**
 * 对比指标（右上角那组按钮）——原来「十人对位」面板上的四指标切换，
 * 面板被观战面板替掉时一起没了，这里按团战场景重新挂上：
 * 本波两项（帧差值，这才是「这波团打了多少」）+ 全场两项（对局总账）+ 出装。
 *
 * 「本波」那两项依赖分钟帧里的逐分钟伤害。LCU 本地那份帧里**没有**这个字段，
 * 是后端去同一局的 SGP `DETAILS` 里把那半份完整时间线拿回来合并的
 * （见 `matches/timeline.ts` 的 `framesHaveDamage`）。所以这里的可用性判断是个
 * **真判断**、不是历史包袱：合并失败（离线 / 区服不在 SGP 白名单 / 对局太新）
 * 时这两项仍然会置灰，并把原因写在下面那行说明里 —— 不是把功能删掉，
 * 是别让人对着一张全零的图猜「是不是坏了」。
 *
 * 「出装」放在团战里：团战是**一个时间点**，装备不会在这几秒里换。有本机录制时取的是
 * **团战开始那一刻**最近的一帧（真正的「当时出装」）；没有录制才退回这局终局那六件，
 * 并且副标题会写明是终局口径——同一个格子两套含义，不写清就会被当成算错了。
 * 反过来说，想在可拖时间轴的面板上看「任意时刻的出装」已经由观战面板的录制口径做到了。
 */
type MetricKey = "fightDamage" | "fightTaken" | "totalDamage" | "totalTaken" | "items";
const framesWithDamage = computed(() => framesHaveDamage(props.frames ?? []));
const METRICS = computed<{ key: MetricKey; label: string; needsFrames: boolean }[]>(() => [
  { key: "fightDamage", label: "本波输出", needsFrames: true },
  { key: "fightTaken", label: "本波承伤", needsFrames: true },
  { key: "totalDamage", label: "全场输出", needsFrames: false },
  { key: "totalTaken", label: "全场承伤", needsFrames: false },
  { key: "items", label: "出装", needsFrames: false },
]);
/** 这一项现在能不能看（「本波」两项要帧里真的有伤害才可用）。 */
const metricUsable = (item: { key: MetricKey; needsFrames: boolean }) => !item.needsFrames || framesWithDamage.value;
function selectMetric(item: { key: MetricKey; needsFrames: boolean }) {
  if (metricUsable(item)) metric.value = item.key;
}
const metric = ref<MetricKey>("fightDamage");
/** 帧里没有伤害数据时，别把默认停在「本波输出」那张全零的图上，自动落到「全场输出」。 */
watch(
  framesWithDamage,
  (available) => {
    if (!available && (metric.value === "fightDamage" || metric.value === "fightTaken")) metric.value = "totalDamage";
  },
  { immediate: true },
);
const metricLabel = computed(() => METRICS.value.find((item) => item.key === metric.value)?.label ?? "");
/** 「出装」那一项画的是图标不是柱子，行模板要换一套。 */
const itemsMetric = computed(() => metric.value === "items");

/**
 * 「这一波团当时」的十人出装——只有本机录到这一局才拿得到。
 *
 * 取团战**开始那一刻**最近的一帧录制（`recordedFrameAt`，不插值：装备是离散事件）。
 * 存不下来的对局返回空 Map，`barSides` 会自动退回终局口径。
 */
const recordedItems = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return null;
  const frame = recordedFrameAt(props.recording, fight.startSeconds);
  if (!frame) return null;
  const lookup = buildRecordedSeatLookup(frame);
  return { frame, lookup };
});

/** 这一项现在画的是「当时」还是「终局」——标签必须说实话。 */
const itemsAreAtFight = computed(() => itemsMetric.value && recordedItems.value !== null);

/**
 * 「出装」这一项的副标题。**两套口径必须写出差别**：
 * - 有录制 → 明确是「这一波当时」；
 * - 没录制 → 必须说清是**终局**，否则会被当成「团战时刻的出装算错了」。
 */
const itemsCaption = computed(() =>
  itemsAreAtFight.value ? `团战时刻的出装（本机录制 · ${clockOf(selectedFight.value?.startSeconds ?? 0)}）` : "本局终局出装（这一局没有本机录制）",
);

/** 座位号 → 完整十人详情（全场伤害/承伤在这里）。配对规则与观战面板共用 `matches/lineup.ts`。 */
const fullGameRows = computed(() => {
  const pool = [...(props.players ?? [])];
  return new Map(
    tableRows.value
      .map((row) => {
        const index = pool.findIndex((player) => player.championId === row.championId && sameTeamAsSeat(player, row.team));
        return [row.participantId, index >= 0 ? pool.splice(index, 1)[0] : undefined] as const;
      })
      .filter((entry) => entry[1]),
  );
});

/**
 * 座位号 → 叫什么。
 *
 * 用**玩家名**当标签、英雄名放到悬浮说明里——这不是随便选的：上方观战面板的行也是
 * 「头像 + 玩家名」，bar 上写英雄名的话，同一屏里同一个人有两个叫法，看图的人得靠
 * 头像把两边对起来。十人详情拿不到（旧缓存对局）时才退回英雄名。
 *
 * 镜像对局（两边同一个英雄）时这一点尤其关键：英雄名会写「九尾妖狐 击杀 九尾妖狐」。
 */
const nameOfSeat = (participantId: number, championId: number) => fullGameRows.value.get(participantId)?.gameName?.trim() || props.championNameOf(championId);
const nameOfRow = (row: FightStatRow) => nameOfSeat(row.participantId, row.championId);

/** 一行某指标的值。帧里没有该项（老数据）时是 0，界面会给出「这项没用数据」的提示。 */
const valueOf = (row: FightStatRow, key: MetricKey = metric.value) => {
  if (key === "items") return 0;
  if (key === "fightDamage") return fightDamage.value?.[row.participantId - 1] ?? 0;
  if (key === "fightTaken") return fightTaken.value?.[row.participantId - 1] ?? 0;
  const player = fullGameRows.value.get(row.participantId);
  return (key === "totalDamage" ? player?.damageDealt : player?.damageTaken) ?? 0;
};

/** 整局有没有分钟帧（旧缓存的对局没有）：没有就退回 K/D/A 对位表。 */
const hasFrames = computed(() => (props.frames?.length ?? 0) >= 2);
/** 这一波十人的值全为 0 = 该指标没数据（帧里缺字段 / 这一项没变化）。 */
const metricTotal = computed(() => tableRows.value.reduce((sum, row) => sum + valueOf(row), 0));
/**
 * 这一项有没有非零值。
 *
 * **不再**拿它决定「画不画柱状图」：用户明确说过四个指标「按道理来说都应该是柱状图」，
 * 而之前某项整列是 0 时整块图会被换成对位表，看起来就是「柱状图时有时无」。现在图恒在
 * （0 值也画轨道，只是柱子 0 宽），另外用一句话说明为什么全列都是 0。
 */
const metricHasData = computed(() => itemsMetric.value || metricTotal.value > 0);
const maxValue = computed(() => Math.max(1, ...tableRows.value.map((row) => valueOf(row))));

/**
 * 座位 → 出装。优先「这一波当时」（本机录制），没有就退回这局终局。
 *
 * 配对走 `recordedPlayerForSeat`（按 rid → 只比名字 → 同阵营 + 同英雄，**绝不能按 puuid**：
 * 录制帧里那个字段恒为空字符串，按它比 100% 配不上）。`lookup` 里的 `claimed` 集合
 * 保证两个座位不会抢同一个人——所以整张表要**共用同一个 lookup**，这里直接在闭包里取。
 */
function itemsOfSeat(participantId: number, championId: number, team: number): { id: number; name: string; iconUrl?: string }[] {
  const recording = recordedItems.value;
  if (recording) {
    const player = fullGameRows.value.get(participantId);
    const identity = player ? { team, championId, gameName: player.gameName } : null;
    const recorded = recordedPlayerForSeat(team, participantId, identity, recording.lookup);
    if (recorded) return recorded.items.map((id) => ({ id, name: "", iconUrl: recordingItemImage(id) }));
  }
  return fullGameRows.value.get(participantId)?.items ?? [];
}

/**
 * 柱状图数据：蓝方一组、红方一组；柱状图按当前指标降序，「出装」保持座位顺序
 * （按值排序对一排图标没有意义，而且会把对位顺序打乱）。
 */
const barSides = computed(() =>
  [TEAM_BLUE, TEAM_RED].map((team) => {
    const rows = tableRows.value
      .filter((row) => row.team === team)
      .map((row) => ({ ...row, value: valueOf(row), items: itemsOfSeat(row.participantId, row.championId, row.team) }));
    if (!itemsMetric.value) rows.sort((left, right) => right.value - left.value);
    return { team, rows, total: rows.reduce((sum, row) => sum + row.value, 0) };
  }),
);
const barWidth = (value: number) => `${value > 0 ? Math.max(3, (value / maxValue.value) * 100) : 0}%`;

/** 这一波的击杀顺序（「这团怎么打的」一句话一行）。人名口径与上面的柱子一致。 */
const killLines = computed(() => {
  const fight = selectedFight.value;
  if (!fight) return [];
  return fight.kills
    .slice()
    .sort((left, right) => left.seconds - right.seconds)
    .map((kill) => {
      const killer = kill.killerChampionId ? nameOfSeat(kill.killerId, kill.killerChampionId) : "未知英雄";
      const victim = kill.victimChampionId ? nameOfSeat(kill.victimId, kill.victimChampionId) : "未知英雄";
      return {
        key: `${kill.seconds}-${kill.killerId}-${kill.victimId}`,
        clock: clockOf(kill.seconds),
        text: `${killer} 击杀 ${victim}`,
        assists: kill.assistIds.length ? `${kill.assistIds.length} 助攻` : "单杀",
        team: kill.team,
      };
    });
});
</script>

<template>
  <!-- `split`：左边是每波团的列表，右边是选中那一波的详情（+ 通过插槽挂在详情下面的内容）。 -->
  <div v-if="fights.length" class="teamfights" :data-layout="layout ?? 'stack'">
    <div class="teamfights__panel">
      <!-- 一行一波的摘要：点它（或点地图钉）切换右边那份共用的详情。 -->
      <div class="teamfights__chips" role="tablist" aria-label="团战列表">
        <button
          v-for="fight in fights"
          :key="fight.index"
          type="button"
          class="teamfights__chip"
          :class="{ 'is-active': selectedFight === fight }"
          :data-tone="toneOf(fight)"
          role="tab"
          :aria-selected="selectedFight === fight"
          @click="select(fight)"
        >
          <b>团{{ fight.index }}</b>
          <span class="teamfights__chip-place">{{ describeLocation(fight.center) }}</span>
          <time>{{ clockOf(fight.startSeconds) }}–{{ clockOf(fight.endSeconds) }}</time>
          <span class="teamfights__chip-score">{{ chipScoreOf(fight) }}</span>
        </button>
      </div>
    </div>

    <div class="teamfights__body">
      <!-- 共用详情：永远是「当前选中的那一波」的数据。 -->
      <div v-if="selectedFight" class="teamfight-detail" :data-tone="toneOf(selectedFight)">
        <header class="teamfight-detail__head">
          <strong>团{{ selectedFight.index }} · {{ describeLocation(selectedFight.center) }}</strong>
          <time>{{ clockOf(selectedFight.startSeconds) }}–{{ clockOf(selectedFight.endSeconds) }}</time>
          <span class="teamfight-detail__score">{{ scoreOf(selectedFight) }}</span>
          <span class="teamfight-detail__winner" :data-tone="toneOf(selectedFight)">{{ winnerLabel }}</span>
          <!-- 右上角：对比指标切换（原来十人对位面板上那组按钮）。
               「本波」两项在没有逐分钟伤害的客户端上置灰——具体原因写在同一行的说明里。 -->
          <div class="teamfight-detail__metrics" role="group" aria-label="对比指标">
            <button
              v-for="item in METRICS"
              :key="item.key"
              type="button"
              :class="{ active: metric === item.key }"
              :disabled="!metricUsable(item)"
              :title="metricUsable(item) ? undefined : '客户端这一局的逐分钟帧里没有伤害字段，算不出「本波」；这里给出的是全场总账'"
              @click="selectMetric(item)"
            >{{ item.label }}</button>
          </div>
        </header>

        <!-- 为什么「本波」不能用：这不是没数据，是客户端压根不提供（别让人以为是 bug）。 -->
        <p v-if="hasFrames && !framesWithDamage" class="teamfight-detail__metricnote">
          这一局没拿到<b>逐分钟伤害</b>：客户端本地的分钟帧里只有金币 / 等级 / 补刀 / 位置，
          伤害要去同一局的 SGP 时间线里取，这次没取到（离线 / 区服不在白名单内 / 对局太新）。
          所以「本波输出 / 本波承伤」算不出来（已置灰），下面给的是这一局的<b>全场总账</b>。
        </p>

        <!-- 团战前后的双方经济：按分钟帧插值（LCU 帧里就有每人每分钟 totalGold，不是猜的）。 -->
        <p v-if="goldStory" class="teamfight-detail__gold">
          <span>团前 <b data-team="100">蓝 {{ compact2(goldStory.beforeBlue) }}</b> · <b data-team="200">红 {{ compact2(goldStory.beforeRed) }}</b>（{{ leadText(goldStory.diffBefore) }}）</span>
          <span class="teamfight-detail__gold-arrow" aria-hidden="true">→</span>
          <span>团后 <b data-team="100">蓝 {{ compact2(goldStory.afterBlue) }}</b> · <b data-team="200">红 {{ compact2(goldStory.afterRed) }}</b>（{{ leadText(goldStory.diffAfter) }}）</span>
          <b class="teamfight-detail__gold-swing">{{ swingText }}</b>
        </p>
        <p v-else class="teamfight-detail__gold teamfight-detail__gold--missing">这一局没有分钟帧数据，算不出团战前后的经济。</p>

        <!-- 十人柱状图：按右上角选的指标画，分队两组；KDA 与「未参团」收成小字。
             图**恒在**——之前某项整列是 0 时整块会被换成对位表，看起来就是「柱状图时有时无」。 -->
        <div v-if="hasFrames" class="teamfight-detail__bars">
          <section v-for="side in barSides" :key="side.team" class="teamfight-bars" :class="{ 'teamfight-bars--items': itemsMetric }" :data-team="side.team">
            <header class="teamfight-bars__head">
              <b>{{ teamLabel(side.team) }}</b>
              <span>{{ itemsMetric ? itemsCaption : `${metricLabel}合计 ${compact(side.total)}` }}</span>
            </header>
            <div v-for="row in side.rows" :key="row.participantId" class="teamfight-bars__row" :data-idle="!row.involved" :title="`${nameOfRow(row)} · ${championNameOf(row.championId)} · ${kdaText(row)}`">
              <AssetIcon kind="champion" :id="row.championId" :name="championNameOf(row.championId)" :fallback-url="championImage(row.championId)" size="xs" />
              <b class="teamfight-bars__name">{{ nameOfRow(row) }}</b>
              <!-- 出装：有本机录制时是**这一波当时**的六件（按团战开始秒数取最近一帧，
                   装备是离散事件所以不插值）；没有录制才退回这局终局那六件。 -->
              <span v-if="itemsMetric" class="teamfight-bars__items">
                <AssetIcon v-for="item in row.items.slice(0, 6)" :key="item.id" kind="item" :id="item.id" :name="item.name" :fallback-url="item.iconUrl" size="xs" />
                <small v-if="!row.items.length">—</small>
              </span>
              <template v-else>
                <span class="teamfight-bars__track"><i :style="{ width: barWidth(row.value) }" /></span>
                <span class="teamfight-bars__value">{{ compact(row.value) }}</span>
              </template>
              <small class="teamfight-bars__kda">{{ kdaText(row) }}<template v-if="!row.involved"> · 未参团</template></small>
            </div>
          </section>
        </div>

        <!-- 整列都是 0：图还是画（轨道在，只是柱子 0 宽），但得说清为什么没有非零值。 -->
        <p v-if="hasFrames && !metricHasData" class="teamfight-detail__nodata">「{{ metricLabel }}」十个人都是 0——这一项在这局的数据里没有非零值（帧里没变化，或这局的十人详情没取到）。换一个指标看。</p>

        <!-- 整局没有分钟帧（旧缓存的对局）：退回 K/D/A 对位表；不装没事，得说清为什么。 -->
        <div v-if="!hasFrames" class="teamfight-detail__duel" role="table" aria-label="这一波的参战者对位">
          <p class="teamfight-detail__duelnote">这一局没有分钟帧数据（LCU 未提供），下面按击杀事件列出这波的对位成绩。</p>
          <div class="teamfight-detail__row teamfight-detail__row--head" role="row">
            <span class="teamfight-detail__teamlabel" data-team="100">蓝方</span>
            <span>击/死/助攻</span>
            <span class="teamfight-detail__mid">比分</span>
            <span>击/死/助攻</span>
            <span class="teamfight-detail__teamlabel" data-team="200">红方</span>
          </div>
          <div v-for="(pairRow, index) in duelSides" :key="index" class="teamfight-detail__row" role="row">
            <span class="teamfight-detail__champ" data-team="100">
              <template v-if="pairRow.blue">
                <AssetIcon kind="champion" :id="pairRow.blue.championId" :name="championNameOf(pairRow.blue.championId)" :fallback-url="championImage(pairRow.blue.championId)" size="xs" />
                <b :title="championNameOf(pairRow.blue.championId)">{{ nameOfRow(pairRow.blue) }}</b>
                <small v-if="!pairRow.blue.involved">未参团</small>
              </template>
              <template v-else><span class="teamfight-detail__empty">—</span></template>
            </span>
            <span class="teamfight-detail__kda" :data-idle="pairRow.blue && !pairRow.blue.involved">{{ pairRow.blue ? kdaText(pairRow.blue) : "" }}</span>
            <span class="teamfight-detail__mid" :class="{ 'is-score': index === midIndex }">{{ index === midIndex && selectedFight ? chipScoreOf(selectedFight) : "" }}</span>
            <span class="teamfight-detail__kda" :data-idle="pairRow.red && !pairRow.red.involved">{{ pairRow.red ? kdaText(pairRow.red) : "" }}</span>
            <span class="teamfight-detail__champ" data-team="200">
              <template v-if="pairRow.red">
                <AssetIcon kind="champion" :id="pairRow.red.championId" :name="championNameOf(pairRow.red.championId)" :fallback-url="championImage(pairRow.red.championId)" size="xs" />
                <b :title="championNameOf(pairRow.red.championId)">{{ nameOfRow(pairRow.red) }}</b>
                <small v-if="!pairRow.red.involved">未参团</small>
              </template>
              <template v-else><span class="teamfight-detail__empty">—</span></template>
            </span>
          </div>
        </div>

        <ol v-if="killLines.length" class="teamfight-detail__kills">
          <li v-for="line in killLines" :key="line.key" :data-team="line.team">
            <time>{{ line.clock }}</time>
            <span>{{ line.text }}</span>
            <small>{{ line.assists }}</small>
          </li>
        </ol>
      </div>

      <!-- 父组件挂进来的内容：事件流就落在「这一波详情」下面（左右布局时在右列）。 -->
      <slot name="below" />
    </div>
  </div>
  <div v-else class="teamfights__none">
    <p>Riot 的数据里<b>没有团战事件</b>，「团战」是按击杀聚类算出来的；这一局没有聚出符合条件的击杀簇。</p>
    <slot name="below" />
  </div>
</template>

<style scoped>
/* 团战落点地图搬进了上方观战面板；这里剩：团列表 + 选中详情 + 前后经济 + 十人柱状图。 */
.teamfights { display: grid; gap: 10px; }
/* split = 左列表右详情；stack 是默认的上下堆叠（窄屏也走它）。 */
.teamfights[data-layout="split"] { grid-template-columns: minmax(170px, 220px) minmax(0, 1fr); align-items: start; }
.teamfights__body { display: grid; gap: 10px; min-width: 0; }

.teamfights__panel { display: grid; gap: 8px; min-width: 0; }
/* 一行一波的摘要按钮：选中态用主题强调色，比分按胜负着色。 */
.teamfights__chips { display: grid; gap: 4px; }
.teamfights__chip { display: grid; grid-template-columns: 34px minmax(0, 1fr) auto auto; align-items: center; gap: 8px; width: 100%; padding: 5px 9px; border: 1px solid var(--line); border-left: 3px solid var(--line-strong); color: inherit; background: var(--surface); cursor: pointer; font: inherit; font-size: 11px; text-align: left; transition: border-color .1s, background .1s; }
.teamfights__chip[data-tone="blue"] { border-left-color: var(--blue); }
.teamfights__chip[data-tone="red"] { border-left-color: var(--red); }
.teamfights__chip[data-tone="even"] { border-left-color: var(--amber); }
.teamfights__chip:hover { background: var(--surface-raised); }
.teamfights__chip.is-active { border-color: var(--accent); background: var(--accent-soft); }
.teamfights__chip b { font-size: 11px; }
.teamfights__chip-place { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.teamfights__chip time { color: var(--text-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
.teamfights__chip-score { color: var(--text-secondary); font-size: 11px; font-variant-numeric: tabular-nums; }
.teamfights__chip[data-tone="blue"] .teamfights__chip-score { color: var(--blue); font-weight: 700; }
.teamfights__chip[data-tone="red"] .teamfights__chip-score { color: var(--red); font-weight: 700; }
/* 左右分栏时列表只有 170~220px：一行塞四段会挤成一团，改成两行（团号+比分 / 点位+时间）。 */
.teamfights[data-layout="split"] .teamfights__chip { grid-template-columns: minmax(0, 1fr) auto; grid-template-areas: "no score" "place time"; gap: 1px 8px; padding: 6px 9px; }
.teamfights[data-layout="split"] .teamfights__chip b { grid-area: no; }
.teamfights[data-layout="split"] .teamfights__chip-place { grid-area: place; color: var(--text-secondary); }
.teamfights[data-layout="split"] .teamfights__chip time { grid-area: time; }
.teamfights[data-layout="split"] .teamfights__chip-score { grid-area: score; text-align: right; }

.teamfight-detail { display: grid; gap: 8px; padding: 10px 12px; border: 1px solid var(--line); border-top: 2px solid var(--line-strong); background: var(--surface); }
.teamfight-detail[data-tone="blue"] { border-top-color: var(--blue); }
.teamfight-detail[data-tone="red"] { border-top-color: var(--red); }
.teamfight-detail[data-tone="even"] { border-top-color: var(--amber); }
.teamfight-detail__head { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
.teamfight-detail__head strong { font-size: 12px; }
.teamfight-detail__head time { color: var(--text-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
.teamfight-detail__score { margin-left: auto; color: var(--text-secondary); font-size: 11px; font-variant-numeric: tabular-nums; }
.teamfight-detail__winner { font-size: 10px; }
.teamfight-detail__winner[data-tone="blue"] { color: var(--blue); }
.teamfight-detail__winner[data-tone="red"] { color: var(--red); }
.teamfight-detail__winner[data-tone="even"] { color: var(--text-muted); }

/* 右上角的指标切换（输出/承伤 × 本波/全场），与其它分段的按钮组同一语言。 */
.teamfight-detail__metrics { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
.teamfight-detail__metrics button { padding: 3px 9px; border: 0; color: var(--text-secondary); background: var(--surface); cursor: pointer; font: inherit; font-size: 10px; transition: color .12s, background .12s; }
.teamfight-detail__metrics button + button { border-left: 1px solid var(--line); }
.teamfight-detail__metrics button:hover { background: var(--surface-raised); }
.teamfight-detail__metrics button.active { color: var(--accent); background: var(--accent-soft); font-weight: 600; }
/* 置灰的指标（客户端不提供逐分钟伤害时的「本波」两项）：明确画成「不可用」，
   而不是让人点了半天发现是一张全零的图。 */
.teamfight-detail__metrics button:disabled { color: var(--text-muted); background: var(--surface-muted); cursor: not-allowed; text-decoration: line-through; }
/* 「本波」为什么不可用：一句实话，别让人对着空柱子猜。 */
.teamfight-detail__metricnote { margin: 0; padding: 6px 10px; border: 1px solid var(--line); border-left: 3px solid var(--amber); color: var(--text-secondary); background: var(--surface-muted); font-size: 10px; line-height: 1.6; }
.teamfight-detail__metricnote b { color: var(--text-primary); }
/* 「该项没有逐帧数据」的提示，别装没事。 */
.teamfight-detail__nodata { margin: 0; padding: 8px 10px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }

/* 团战前后经济：一行说清「打之前谁领先、打完之后谁领先、这波拉开了多少」。 */
.teamfight-detail__gold { display: flex; align-items: baseline; gap: 7px; flex-wrap: wrap; margin: 0; padding: 6px 10px; border: 1px dashed var(--line); color: var(--text-secondary); font-size: 10px; }
.teamfight-detail__gold b { font-weight: 600; font-variant-numeric: tabular-nums; }
.teamfight-detail__gold b[data-team="100"] { color: var(--blue); }
.teamfight-detail__gold b[data-team="200"] { color: var(--red); }
.teamfight-detail__gold-arrow { color: var(--text-muted); }
.teamfight-detail__gold-swing { color: var(--text-primary); }
.teamfight-detail__gold--missing { color: var(--text-muted); }

/* 这一波的伤害柱状图：队色描边分组 + 队色柱子，伤害与 KDA 右对齐成排。 */
.teamfight-detail__bars { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 8px; }
.teamfight-bars { display: grid; gap: 3px; align-content: start; padding: 8px 10px; border: 1px solid var(--line); border-top: 2px solid var(--line-strong); }
.teamfight-bars[data-team="100"] { border-top-color: var(--blue); }
.teamfight-bars[data-team="200"] { border-top-color: var(--red); }
.teamfight-bars__head { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 2px; font-size: 10px; }
.teamfight-bars__head b { font-size: 11px; }
.teamfight-bars[data-team="100"] .teamfight-bars__head b { color: var(--blue); }
.teamfight-bars[data-team="200"] .teamfight-bars__head b { color: var(--red); }
.teamfight-bars__head span { color: var(--text-muted); font-variant-numeric: tabular-nums; }
/* 名字这列要装玩家名（比英雄名长：「野区巡逻员」5 字），给宽一点再省略。 */
.teamfight-bars__row { display: grid; grid-template-columns: auto minmax(52px, 88px) minmax(0, 1fr) 44px 76px; align-items: center; gap: 6px; font-size: 10px; }
/* 红方整行镜像（头像在外侧、柱子从右往左长）：两队对着一看就是一张对位图。 */
.teamfight-bars[data-team="200"] .teamfight-bars__row { direction: rtl; }
.teamfight-bars[data-team="200"] .teamfight-bars__row > * { direction: ltr; }
.teamfight-bars[data-team="200"] .teamfight-bars__track i { inset: 0 0 0 auto; }
.teamfight-bars[data-team="200"] .teamfight-bars__name,
.teamfight-bars[data-team="200"] .teamfight-bars__value { text-align: right; }
.teamfight-bars[data-team="200"] .teamfight-bars__kda { text-align: left; }
.teamfight-bars__row[data-idle="true"] { opacity: .55; }
.teamfight-bars__name { overflow: hidden; font-weight: 500; text-overflow: ellipsis; white-space: nowrap; }
.teamfight-bars__track { position: relative; height: 10px; border-radius: 2px; background: var(--surface-raised); overflow: hidden; }
.teamfight-bars__track i { position: absolute; inset: 0 auto 0 0; border-radius: 2px; }
.teamfight-bars[data-team="100"] .teamfight-bars__track i { background: var(--blue); }
.teamfight-bars[data-team="200"] .teamfight-bars__track i { background: var(--red); }
.teamfight-bars__value { text-align: right; font-variant-numeric: tabular-nums; }
.teamfight-bars__kda { overflow: hidden; color: var(--text-secondary); text-align: right; font-size: 9px; text-overflow: ellipsis; white-space: nowrap; font-variant-numeric: tabular-nums; }
/* 「出装」指标：把「轨道 + 数值」这两列换成六个装备格子，行网格跟着少一列。
   红方镜像沿用上面那套 direction 规则，所以这里只需要管对齐方向。 */
.teamfight-bars--items .teamfight-bars__row { grid-template-columns: auto minmax(52px, 88px) minmax(0, 1fr) 76px; }
.teamfight-bars__items { display: flex; align-items: center; gap: 3px; min-width: 0; }
.teamfight-bars[data-team="200"] .teamfight-bars__items { justify-content: flex-end; }
.teamfight-bars__items small { color: var(--text-muted); font-size: 9px; }

/* 「跟上面一样的对位」：蓝方一列、红方一列，中线只标一次比分。 */
.teamfight-detail__duel { display: grid; gap: 0; border: 1px solid var(--line); }
/* 「这一局没有分钟帧」的说明：压在对位表最上面，别让人以为这是一张主数据表。 */
.teamfight-detail__duelnote { margin: 0; padding: 6px 10px; border-bottom: 1px solid var(--line); color: var(--text-muted); background: var(--surface-muted); font-size: 9px; line-height: 1.6; }
.teamfight-detail__row { display: grid; grid-template-columns: minmax(0, 1fr) 76px 56px 76px minmax(0, 1fr); align-items: center; gap: 6px; padding: 4px 10px; border-bottom: 1px solid var(--line); font-size: 11px; font-variant-numeric: tabular-nums; }
.teamfight-detail__row:last-child { border-bottom: 0; }
.teamfight-detail__row--head { color: var(--text-muted); background: var(--surface-muted); font-size: 10px; }
.teamfight-detail__teamlabel { font-weight: 600; }
.teamfight-detail__teamlabel[data-team="100"] { color: var(--blue); }
.teamfight-detail__teamlabel[data-team="200"] { color: var(--red); text-align: right; }
.teamfight-detail__champ { display: flex; align-items: center; gap: 6px; min-width: 0; }
.teamfight-detail__champ[data-team="100"] { box-shadow: inset 2px 0 0 var(--blue); padding-left: 7px; }
.teamfight-detail__champ[data-team="200"] { box-shadow: inset -2px 0 0 var(--red); padding-right: 7px; flex-direction: row-reverse; text-align: right; }
.teamfight-detail__champ b { overflow: hidden; font-weight: 500; text-overflow: ellipsis; white-space: nowrap; }
.teamfight-detail__champ small { flex: 0 0 auto; color: var(--text-muted); font-size: 9px; }
.teamfight-detail__kda { color: var(--text-secondary); text-align: center; }
.teamfight-detail__kda[data-idle="true"] { color: var(--text-muted); }
.teamfight-detail__mid { color: var(--text-muted); font-size: 9px; text-align: center; }
.teamfight-detail__mid.is-score { color: var(--text-primary); font-size: 12px; font-weight: 700; }
.teamfight-detail__empty { color: var(--text-muted); }

.teamfight-detail__kills { display: grid; gap: 2px; margin: 0; padding: 0; list-style: none; }
.teamfight-detail__kills li { display: flex; align-items: baseline; gap: 7px; color: var(--text-secondary); font-size: 10px; }
.teamfight-detail__kills li time { color: var(--text-muted); font-variant-numeric: tabular-nums; }
.teamfight-detail__kills li small { color: var(--text-muted); }

.teamfights__none { display: grid; gap: 10px; }
.teamfights__none p { margin: 0; padding: 12px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }
.teamfights__none b { color: var(--text-secondary); }

/* 窄屏放不下左右分栏，退回上下堆叠（列表在上、详情在下）。 */
@media (max-width: 760px) { .teamfights[data-layout="split"] { grid-template-columns: minmax(0, 1fr); } }
</style>
