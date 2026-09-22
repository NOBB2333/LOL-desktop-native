<script setup lang="ts">
/**
 * 打野路线图：把「近期打野局的前 15 分钟落点 / 参战位置 / 首清营地」画在召唤师峡谷底图上。
 *
 * 数据来自后端 `lol.get_jungle_path`（逐帧解析 SGP DETAILS / LCU timeline），
 * 这里只做投影和绘制，不做任何统计判断——分区、营地归属都是后端算好的，
 * 所以地图上的结论和快捷消息里的「打野偏好」是同一套口径。
 *
 * 两种排布：
 * - `full`：固定尺寸地图 + 右侧图例/分区权重/首清营地/抓人面板（玩家详情抽屉用）。
 * - `inline`：宽度自适应、正方形，地图下面压几行文字（对局界面的玩家卡用）——
 *   卡片宽度只有 180~260px，塞不下右侧那些面板。
 *
 * 两处都**必须带文字**，光有图没人看得懂：营地圆圈旁边贴着短名字（蓝/红/三狼/F6），
 * `inline` 因为丢掉了侧栏，还得自己补一份图例 + 「首清 / 前期抓人 / 分区」几行。
 * 这几行是卡片版能被看懂的前提，不是装饰——删了就退回「一堆没有含义的色块」。
 *
 * 覆盖物一律用百分比定位，所以地图尺寸完全交给 CSS，JS 不需要知道像素。
 * 底图恒为深色，因此标记配色不跟随应用主题，见 `live/gameMap.ts`。
 */
import { computed } from "vue";
import map11 from "../assets/map11.png";
import type { JungleCampCounts, JunglePathMap, JunglePathPoint } from "../types/domain";
import {
  JUNGLE_CAMP_LABELS,
  JUNGLE_CAMP_SHORT_LABELS,
  JUNGLE_CAMP_SPOT_COLORS,
  JUNGLE_CAMP_SPOTS,
  JUNGLE_ZONE_COLORS,
  JUNGLE_ZONE_LABELS,
  campCountsTotal,
  campMarkerSize,
  clearCountsAt,
  describeCamps,
  mapToImagePosition,
  type JungleZone,
} from "../live/gameMap";

const props = withDefaults(defineProps<{
  path: JunglePathMap | null;
  variant?: "full" | "inline";
  /** 仅 `full` 用：地图边长（px）。 */
  stageSize?: number;
}>(), { variant: "full", stageSize: 232 });

const zones: JungleZone[] = ["top", "mid", "bot"];
const isInline = computed(() => props.variant === "inline");

/** 归一化到 0~1，交给模板写成百分比。 */
function project(points: JunglePathPoint[] | undefined) {
  return (points ?? []).map((point) => {
    const { left, top } = mapToImagePosition(point.x, point.y, 1, 1);
    return { left, top, zone: point.zone } as const;
  });
}

const minutePoints = computed(() => project(props.path?.minutePoints));
const gankPoints = computed(() => project(props.path?.gankPoints));
const level3Points = computed(() => project(props.path?.level3Points));
const level4Points = computed(() => project(props.path?.level4Points));

/**
 * 首清营地落点。
 *
 * 后端只给「蓝方常规开 / 蓝方入侵开 / 红方常规开 / 红方入侵开」四组计数，
 * 某个具体点位属于哪一组由它自己的半区决定——读哪一组见 `clearCountsAt`
 * （入侵那一组在**对面**半区，不能顺着 index 直接取）。
 */
const campSpots = computed(() => {
  const path = props.path;
  if (!path) return [];
  const spots = JUNGLE_CAMP_SPOTS.map((spot) => {
    const { own, invade } = clearCountsAt(path.camps, spot.side, spot.camp);
    const { left, top } = mapToImagePosition(spot.x, spot.y, 1, 1);
    return { ...spot, left, top, own, invade, total: own + invade };
  });
  const max = spots.reduce((best, spot) => Math.max(best, spot.total), 0);
  const min = isInline.value ? 5 : 8;
  return spots
    .filter((spot) => spot.total > 0)
    .map((spot) => ({ ...spot, diameter: campMarkerSize(spot.total, max, min, min + 1) }));
});

const zoneShares = computed(() => {
  const zone = props.path?.zone;
  return zones.map((key) => ({ key, ratio: zone ? zone[key] : 0 }));
});

/** 首清四行；占比分母是各自阵营的场次，和后端 `writeClearPattern` 一致。 */
const clearRows = computed(() => {
  const path = props.path;
  if (!path) return [];
  const rows: { key: string; label: string; counts: JungleCampCounts; games: number; invade: boolean }[] = [
    { key: "blue-own", label: "蓝方常规开", counts: path.camps.blueOwn, games: path.blueGames, invade: false },
    { key: "blue-invade", label: "蓝方入侵开", counts: path.camps.blueInvade, games: path.blueGames, invade: true },
    { key: "red-own", label: "红方常规开", counts: path.camps.redOwn, games: path.redGames, invade: false },
    { key: "red-invade", label: "红方入侵开", counts: path.camps.redInvade, games: path.redGames, invade: true },
  ];
  return rows.map((row) => {
    const total = campCountsTotal(row.counts);
    const ratio = row.games > 0 ? total / row.games : 0;
    return { ...row, ratio, detail: total > 0 ? describeCamps(row.counts) : "无样本" };
  });
});

const gankRows = computed(() => {
  const path = props.path;
  if (!path || path.games <= 0) return [];
  return [
    { key: "level3", label: "3 级抓", count: path.level3, ratio: path.level3 / path.games },
    { key: "level4", label: "4 级抓", count: path.level4, ratio: path.level4 / path.games },
  ];
});

/**
 * 卡片上的首清文字。
 *
 * 口径照抄 AK 的 `FirstClearAndGankSummary`：`常规开 {占比}%（{营地} 开 {营地内占比}%）`
 * ——两个占比的分母不同，外层是「该阵营的场次」，内层是「这组营地的总次数」。
 * 蓝红必须分开算：同一个「三狼」在两个半区的位置是镜像的，两组混在一起会把
 * 「自家 Buff 开」说成「一半蓝 Buff 一半红 Buff」。
 *
 * 卡片只有一列宽，只列样本更多的那一侧；另一侧去抽屉里看完整四行。
 */
const clearTextLines = computed(() => {
  const path = props.path;
  if (!path) return [];
  const sides = [
    { label: "蓝方", games: path.blueGames, own: path.camps.blueOwn, invade: path.camps.blueInvade },
    { label: "红方", games: path.redGames, own: path.camps.redOwn, invade: path.camps.redInvade },
  ].filter((side) => side.games > 0);
  if (!sides.length) return [];
  const picked = sides.reduce((best, side) => (side.games > best.games ? side : best), sides[0]);
  const lines: string[] = [];
  const own = campCountsTotal(picked.own);
  if (own > 0) lines.push(`${picked.label} 常规开 ${percentText(own / picked.games)}（${describeCamps(picked.own)}）`);
  const invade = campCountsTotal(picked.invade);
  if (invade > 0) lines.push(`${picked.label} 入侵开 ${percentText(invade / picked.games)}（${describeCamps(picked.invade)}）`);
  return lines.length ? lines : [`${picked.label} 无首清样本`];
});

const percentText = (ratio: number) => `${Math.round(ratio * 100)}%`;
const pct = (value: number) => `${(value * 100).toFixed(3)}%`;
</script>

<template>
  <div class="jungle-map" :class="{ 'jungle-map--inline': isInline }" data-testid="jungle-route-map">
    <div
      class="jungle-map__stage"
      :style="isInline ? undefined : { width: `${stageSize}px`, height: `${stageSize}px` }"
    >
      <img class="jungle-map__plate" :src="map11" alt="召唤师峡谷地图" />
      <svg class="jungle-map__guide" viewBox="0 0 100 100" aria-hidden="true">
        <polygon points="0,0 100,100 0,100" fill="rgba(59,130,246,0.10)" />
        <polygon points="0,0 100,100 100,0" fill="rgba(239,68,68,0.10)" />
        <line x1="0" y1="0" x2="100" y2="100" stroke="rgba(255,255,255,0.42)" stroke-width="0.7" stroke-dasharray="4,3" />
      </svg>

      <!-- 两个半区各标一个角：图上的斜向底色只是色块，不写字看不出哪半边是谁的。
           注意这里说的是「蓝方 / 红方半区」，与观战者的敌我无关——打野会换边。 -->
      <span class="jungle-map__side-label jungle-map__side-label--blue">蓝方半区</span>
      <span class="jungle-map__side-label jungle-map__side-label--red">红方半区</span>

      <span
        v-for="(point, index) in minutePoints"
        :key="`minute-${index}`"
        class="jungle-map__dot"
        :style="{ left: pct(point.left), top: pct(point.top), background: JUNGLE_ZONE_COLORS[point.zone] }"
      />

      <!-- 首清营地：圆圈 + 紧挨着的短名字。只画圆不写名字的话，图上就是几个
           没有含义的色块，这正是「看不懂」的主因。 -->
      <template v-for="(spot, index) in campSpots" :key="`camp-${index}`">
        <span
          class="jungle-map__camp"
          data-testid="jungle-camp-marker"
          :title="`${JUNGLE_CAMP_LABELS[spot.camp]}（${spot.side === 'blue' ? '蓝方' : '红方'}半区）：常规开 ${spot.own} 次 / 入侵开 ${spot.invade} 次`"
          :style="{
            left: pct(spot.left),
            top: pct(spot.top),
            width: `${spot.diameter}px`,
            height: `${spot.diameter}px`,
            background: JUNGLE_CAMP_SPOT_COLORS[spot.camp],
            borderColor: spot.invade > 0 ? '#fbbf24' : 'rgba(255,255,255,0.55)',
          }"
        />
        <span
          class="jungle-map__camp-label"
          :class="{ 'jungle-map__camp-label--invade': spot.invade > 0 }"
          :style="{ left: pct(spot.left), top: pct(spot.top) }"
        >
          {{ JUNGLE_CAMP_SHORT_LABELS[spot.camp] }}
        </span>
      </template>

      <span v-for="(point, index) in level3Points" :key="`l3-${index}`" class="jungle-map__cross jungle-map__cross--level3" :style="{ left: pct(point.left), top: pct(point.top) }" />
      <span v-for="(point, index) in level4Points" :key="`l4-${index}`" class="jungle-map__cross jungle-map__cross--level4" :style="{ left: pct(point.left), top: pct(point.top) }" />
      <span v-for="(point, index) in gankPoints" :key="`gank-${index}`" class="jungle-map__cross" :style="{ left: pct(point.left), top: pct(point.top), '--cross-color': JUNGLE_ZONE_COLORS[point.zone] }" />
    </div>

    <!-- inline：卡片只有一列宽，侧栏放不下，所以把「图例 → 首清 → 前期抓人 → 分区」
         压成几行贴在图下面。**这几行不是装饰**：没有图例，图上那些圆点十字就是一堆
         没有含义的色块，光看图看不懂。 -->
    <div v-if="isInline" class="jungle-map__brief">
      <ul class="jungle-map__legend jungle-map__legend--inline">
        <li>
          <span class="jungle-map__legend-dots">
            <i v-for="key in zones" :key="`il-dot-${key}`" class="jungle-map__legend-dot" :style="{ background: JUNGLE_ZONE_COLORS[key] }" />
          </span>
          每分钟位置
        </li>
        <li>
          <span class="jungle-map__legend-dots">
            <i v-for="key in zones" :key="`il-cross-${key}`" class="jungle-map__legend-cross" :style="{ '--cross-color': JUNGLE_ZONE_COLORS[key] }" />
          </span>
          参与击杀
        </li>
        <li>
          <span class="jungle-map__legend-dots">
            <i class="jungle-map__legend-cross jungle-map__legend-cross--level3" />
            <i class="jungle-map__legend-cross jungle-map__legend-cross--level4" />
          </span>
          3 / 4 级抓
        </li>
        <li>
          <span class="jungle-map__legend-dots">
            <i class="jungle-map__legend-camp" />
            <i class="jungle-map__legend-camp jungle-map__legend-camp--invade" />
          </span>
          常规开 / 入侵开
        </li>
      </ul>
      <p class="jungle-map__brief-line">
        <b>首清</b>
        <span v-for="(line, index) in clearTextLines" :key="`brief-clear-${index}`">{{ line }}</span>
      </p>
      <p class="jungle-map__brief-line">
        <span v-for="row in gankRows" :key="`brief-gank-${row.key}`"><b>{{ row.label }}</b> {{ row.count }} / {{ path?.games ?? 0 }} 局</span>
      </p>
      <p class="jungle-map__brief-line">
        <span v-for="share in zoneShares" :key="`brief-zone-${share.key}`" class="jungle-map__brief-zone">
          <i :style="{ background: JUNGLE_ZONE_COLORS[share.key] }" />{{ JUNGLE_ZONE_LABELS[share.key] }} {{ percentText(share.ratio) }}
        </span>
      </p>
    </div>

    <div v-else class="jungle-map__side">
      <ul class="jungle-map__legend">
        <li>
          <span class="jungle-map__legend-dots">
            <i v-for="key in zones" :key="`legend-dot-${key}`" class="jungle-map__legend-dot" :style="{ background: JUNGLE_ZONE_COLORS[key] }" />
          </span>
          每分钟位置（{{ JUNGLE_ZONE_LABELS.top }} / {{ JUNGLE_ZONE_LABELS.mid }} / {{ JUNGLE_ZONE_LABELS.bot }}）
        </li>
        <li>
          <span class="jungle-map__legend-dots">
            <i v-for="key in zones" :key="`legend-cross-${key}`" class="jungle-map__legend-cross" :style="{ '--cross-color': JUNGLE_ZONE_COLORS[key] }" />
          </span>
          参与击杀位置（前 14 分钟）
        </li>
        <li>
          <span class="jungle-map__legend-dots">
            <i class="jungle-map__legend-camp" />
            <i class="jungle-map__legend-camp jungle-map__legend-camp--invade" />
          </span>
          首清营地：常规开 / 带入侵
        </li>
        <li>
          <span class="jungle-map__legend-dots">
            <i class="jungle-map__legend-cross jungle-map__legend-cross--level3" />
            <i class="jungle-map__legend-cross jungle-map__legend-cross--level4" />
          </span>
          3 级抓 / 4 级抓（前 4 分钟参战）
        </li>
      </ul>

      <div class="jungle-map__panel">
        <strong>分区权重</strong>
        <div v-for="share in zoneShares" :key="`zone-${share.key}`" class="jungle-map__zone">
          <span>{{ JUNGLE_ZONE_LABELS[share.key] }}</span>
          <i :style="{ transform: `scaleX(${Math.max(0, Math.min(1, share.ratio))})`, background: JUNGLE_ZONE_COLORS[share.key] }" />
          <b>{{ percentText(share.ratio) }}</b>
        </div>
      </div>

      <div class="jungle-map__panel">
        <strong>首清营地</strong>
        <div v-for="row in clearRows" :key="`clear-${row.key}`" class="jungle-map__clear">
          <span :data-invade="row.invade">{{ row.label }}</span>
          <b>{{ percentText(row.ratio) }}</b>
          <small>{{ row.detail }}</small>
        </div>
      </div>

      <div class="jungle-map__panel">
        <strong>前期抓人（{{ path?.games ?? 0 }} 场样本）</strong>
        <div class="jungle-map__gank">
          <span v-for="row in gankRows" :key="`gank-row-${row.key}`"><b>{{ row.label }}</b><em>{{ row.count }} 场 · {{ percentText(row.ratio) }}</em></span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.jungle-map { display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: start; gap: 12px; }
.jungle-map__stage { position: relative; flex: 0 0 auto; border: 1px solid var(--line); background: #0b1020; }
.jungle-map--inline { grid-template-columns: minmax(0, 1fr); gap: 6px; }
.jungle-map--inline .jungle-map__stage { width: 100%; max-width: 190px; aspect-ratio: 1 / 1; }
.jungle-map__plate, .jungle-map__guide { position: absolute; inset: 0; width: 100%; height: 100%; }
/* 半区角标：底图是深色的，白字也要加黑描边才压得住。 */
.jungle-map__side-label { position: absolute; z-index: 1; color: rgba(255,255,255,.75); font-size: 7px; font-weight: 700; line-height: 1; letter-spacing: .04em; white-space: nowrap; text-shadow: 0 0 2px #000, 0 0 3px #000; pointer-events: none; }
.jungle-map__side-label--blue { bottom: 3%; left: 4%; }
.jungle-map__side-label--red { top: 3%; right: 4%; }
.jungle-map__dot { position: absolute; width: 5px; height: 5px; border-radius: 50%; opacity: .62; transform: translate(-50%, -50%); }
.jungle-map__camp { position: absolute; border: 2px solid rgba(255,255,255,.55); border-radius: 50%; opacity: .82; transform: translate(-50%, -50%); }
/* 营地短名字贴在圆圈右侧。底图是深色照片感的图，纯白小字会糊，所以加一圈黑描边。 */
.jungle-map__camp-label { position: absolute; z-index: 1; transform: translate(9px, -50%); color: #f8fafc; font-size: 7px; font-weight: 600; line-height: 1; white-space: nowrap; text-shadow: 0 0 2px #000, 0 0 3px #000; pointer-events: none; }
.jungle-map__camp-label--invade { color: #fbbf24; }
.jungle-map__cross { position: absolute; width: 11px; height: 11px; transform: translate(-50%, -50%); }
.jungle-map__cross::before, .jungle-map__cross::after { position: absolute; top: 50%; left: 50%; width: 100%; height: 2px; border-radius: 2px; background: var(--cross-color, #fff); content: ""; }
.jungle-map__cross::before { transform: translate(-50%, -50%) rotate(45deg); }
.jungle-map__cross::after { transform: translate(-50%, -50%) rotate(-45deg); }
.jungle-map__cross--level3 { --cross-color: #f97316; }
.jungle-map__cross--level4 { --cross-color: #a855f7; }
.jungle-map__side { display: grid; gap: 9px; min-width: 0; }
.jungle-map__brief { display: grid; gap: 3px; min-width: 0; }
.jungle-map__brief p { display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 7px; margin: 0; color: var(--text-secondary); font-size: 8px; line-height: 1.5; }
.jungle-map__brief-zone { display: inline-flex; align-items: center; gap: 3px; }
.jungle-map__brief-zone i { width: 5px; height: 5px; border-radius: 50%; }
.jungle-map__brief b { color: var(--text-muted); font-weight: 500; }
/* 卡片版把侧栏那份图例压成一行一行的，不用 40px 的图标列——照搬侧栏会把这一块撑太高。 */
.jungle-map__brief .jungle-map__legend--inline { display: flex; flex-wrap: wrap; gap: 3px 9px; }
.jungle-map__brief .jungle-map__legend--inline li { display: inline-flex; align-items: center; gap: 4px; color: var(--text-muted); font-size: 8px; }
.jungle-map__legend { display: grid; gap: 4px; margin: 0; padding: 0; color: var(--text-secondary); font-size: 9px; line-height: 1.5; list-style: none; }
.jungle-map__legend li { display: grid; grid-template-columns: 40px minmax(0, 1fr); align-items: center; gap: 6px; }
.jungle-map__legend-dots { display: inline-grid; grid-auto-flow: column; place-items: center; gap: 2px; }
.jungle-map__legend-dot { display: block; width: 5px; height: 5px; border-radius: 50%; }
.jungle-map__legend-cross { position: relative; display: block; width: 10px; height: 10px; }
.jungle-map__legend-cross::before, .jungle-map__legend-cross::after { position: absolute; top: 50%; left: 50%; width: 100%; height: 2px; border-radius: 2px; background: var(--cross-color, #fff); content: ""; }
.jungle-map__legend-cross::before { transform: translate(-50%, -50%) rotate(45deg); }
.jungle-map__legend-cross::after { transform: translate(-50%, -50%) rotate(-45deg); }
.jungle-map__legend-cross--level3 { --cross-color: #f97316; }
.jungle-map__legend-cross--level4 { --cross-color: #a855f7; }
.jungle-map__legend-camp { display: block; width: 9px; height: 9px; border: 2px solid rgba(255,255,255,.55); border-radius: 50%; background: #a3a3a3; }
.jungle-map__legend-camp--invade { border-color: #fbbf24; background: rgba(251,191,36,.35); }
.jungle-map__panel { display: grid; gap: 5px; padding-top: 8px; border-top: 1px solid var(--line); }
.jungle-map__panel > strong { color: var(--text-primary); font-size: 9px; }
.jungle-map__zone { display: grid; grid-template-columns: 32px minmax(0, 1fr) 34px; align-items: center; gap: 6px; color: var(--text-secondary); font-size: 9px; }
.jungle-map__zone i { display: block; height: 5px; background: var(--accent); transform-origin: left; }
.jungle-map__zone b { text-align: right; color: var(--text-primary); font-variant-numeric: tabular-nums; }
.jungle-map__clear { display: grid; grid-template-columns: 58px 34px minmax(0, 1fr); align-items: center; gap: 6px; color: var(--text-secondary); font-size: 9px; }
.jungle-map__clear span[data-invade="true"] { color: var(--amber); }
.jungle-map__clear b { color: var(--text-primary); font-variant-numeric: tabular-nums; }
.jungle-map__clear small { overflow: hidden; color: var(--text-muted); font-size: 8px; text-overflow: ellipsis; white-space: nowrap; }
.jungle-map__gank { display: flex; flex-wrap: wrap; gap: 6px; }
.jungle-map__gank > span { display: grid; gap: 2px; padding: 5px 7px; border: 1px solid var(--line); background: var(--surface-raised); }
.jungle-map__gank b { color: var(--text-primary); font-size: 9px; }
.jungle-map__gank em { color: var(--text-secondary); font-size: 8px; font-style: normal; font-variant-numeric: tabular-nums; }
@media (max-width: 720px) { .jungle-map:not(.jungle-map--inline) { grid-template-columns: 1fr; } }
</style>
