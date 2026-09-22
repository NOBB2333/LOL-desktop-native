/**
 * 召唤师峡谷（mapId 11）的坐标换算与固定点位。
 *
 * 游戏坐标 → 小地图像素的公式与后端 `jungle_analysis.classifyZone` 共用同一套
 * 域（`0..14820` × `0..14881`），所以两边的分区判定永远落在同一块区域上。
 * 地图图片里蓝色方基地在左下、红色方在右上，而游戏坐标的 y 轴方向相反，
 * 因此换算时必须 `invertY`。
 */

/** 与 `src/backend/jungle_analysis.zig` 的坐标域保持一致。 */
export const LOL_MAP_DOMAINS = {
  11: { minX: 0, minY: 0, maxX: 14820, maxY: 14881 },
} as const;

export type MapId = keyof typeof LOL_MAP_DOMAINS;

export function mapToImagePosition(
  x: number,
  y: number,
  imageWidth: number,
  imageHeight: number,
  mapId: MapId = 11,
) {
  const domain = LOL_MAP_DOMAINS[mapId];
  const rangeX = domain.maxX - domain.minX;
  const rangeY = domain.maxY - domain.minY;
  if (rangeX <= 0 || rangeY <= 0) return { left: 0, top: 0 };
  const normalizedX = (x - domain.minX) / rangeX;
  const normalizedY = (domain.maxY - y) / rangeY;
  return {
    left: Math.min(imageWidth, Math.max(0, normalizedX * imageWidth)),
    top: Math.min(imageHeight, Math.max(0, normalizedY * imageHeight)),
  };
}

export type JungleZone = "top" | "mid" | "bot";
export type JungleCamp = "blue" | "red" | "wolves" | "raptors";
export type JungleSide = "blue" | "red";

/**
 * 八个首清营地坐标。数字必须与后端 `jungle_analysis.detectStartCamp` 的
 * `camps` 表逐字一致——后端只负责计数，落点由这里画。
 */
export const JUNGLE_CAMP_SPOTS: { camp: JungleCamp; side: JungleSide; x: number; y: number }[] = [
  { camp: "blue", side: "blue", x: 3830, y: 7880 },
  { camp: "wolves", side: "blue", x: 3800, y: 6440 },
  { camp: "red", side: "blue", x: 7760, y: 4010 },
  { camp: "raptors", side: "blue", x: 6970, y: 5460 },
  { camp: "blue", side: "red", x: 10990, y: 7000 },
  { camp: "wolves", side: "red", x: 11020, y: 8440 },
  { camp: "red", side: "red", x: 7060, y: 10870 },
  { camp: "raptors", side: "red", x: 7850, y: 9420 },
];

export const JUNGLE_CAMP_LABELS: Record<JungleCamp, string> = {
  blue: "蓝 Buff",
  red: "红 Buff",
  wolves: "三狼",
  raptors: "F6",
};

/**
 * 地图上贴在营地圆圈旁边的短标签。
 *
 * `JUNGLE_CAMP_LABELS` 是给文字面板用的全称，卡片上那张图只有 190px 宽、
 * 圆圈本身才 5~11px，「蓝 Buff」根本放不下。这里给一套一两个字的。
 */
export const JUNGLE_CAMP_SHORT_LABELS: Record<JungleCamp, string> = {
  blue: "蓝",
  red: "红",
  wolves: "三狼",
  raptors: "F6",
};

export const JUNGLE_ZONE_LABELS: Record<JungleZone, string> = {
  top: "上路",
  mid: "中路",
  bot: "下路",
};

/**
 * 地图底图固定是深色的，所以标记颜色按深底挑，不跟随应用主题——
 * 用 `--blue` 这类浅色主题下的深色 token 会糊在图上。
 */
export const JUNGLE_ZONE_COLORS: Record<JungleZone, string> = {
  top: "#ef4444",
  mid: "#f59e0b",
  bot: "#3b82f6",
};

export const JUNGLE_CAMP_SPOT_COLORS: Record<JungleCamp, string> = {
  blue: "#3b82f6",
  red: "#ef4444",
  wolves: "#a3a3a3",
  raptors: "#a3a3a3",
};

/**
 * 固定点位计数 → 圆形标记的直径。样本越多圆越大，但压在一个区间里，
 * 免得一场野怪把整张图盖住。
 */
export function campMarkerSize(count: number, max: number, min = 8, span = 9): number {
  if (count <= 0) return 0;
  if (max <= 0) return min;
  return min + Math.round((count / max) * span);
}

const CAMP_ORDER: JungleCamp[] = ["blue", "red", "wolves", "raptors"];

export function campCountsTotal(counts: Record<JungleCamp, number>): number {
  return CAMP_ORDER.reduce((sum, camp) => sum + (counts[camp] ?? 0), 0);
}

/**
 * 「哪个野怪开得多」——按次数降序取前 `limit` 个，带上占比。
 * 与后端 `writeClearPattern` 的口径一致（占比基数是该组的总次数，不是场次）。
 *
 * 文案对齐 AK 的 `campStart`（`三狼 开 100%`）：带上「开」字才读得懂这是
 * 「这组样本里从哪个野怪起的」，否则就只是几个营地名加百分比，看不出在说什么。
 */
export function describeCamps(counts: Record<JungleCamp, number>, limit = 2): string {
  const total = campCountsTotal(counts);
  if (total <= 0) return "无样本";
  return CAMP_ORDER
    .filter((camp) => (counts[camp] ?? 0) > 0)
    .sort((left, right) => (counts[right] ?? 0) - (counts[left] ?? 0))
    .slice(0, limit)
    .map((camp) => `${JUNGLE_CAMP_LABELS[camp]} 开 ${Math.round(((counts[camp] ?? 0) / total) * 100)}%`)
    .join(" · ");
}

/**
 * 首清营地计数 → 某个半区营地落点上的「常规开 / 入侵开」次数。
 *
 * 后端按「场次所属阵营 × 起始半区」分成四组计数
 * （`blueOwn` = 蓝方场次在自家半区开、`blueInvade` = 蓝方场次在敌方半区开……），
 * 所以**落点在哪一边**决定读哪一组：
 *
 * - 蓝方半区的营地：常规开 = `blueOwn`；被入侵开 = `redInvade`（红方场次跑到蓝方半区来开）。
 * - 红方半区的营地：常规开 = `redOwn`；被入侵开 = `blueInvade`（蓝方场次跑到红方半区来开）。
 *
 * 直接把 `blueInvade` 画在蓝方半区是错的——那组数字记的是**红方半区**的落点。
 * 见 `src/backend/jungle_analysis.zig` 的 `addFrames`（`detectStartCamp` 同时给出
 * 营地的半区，`start.side` 与场次阵营不同才算入侵）。
 */
export function clearCountsAt(
  camps: Record<"blueOwn" | "blueInvade" | "redOwn" | "redInvade", Record<JungleCamp, number>>,
  side: JungleSide,
  camp: JungleCamp,
): { own: number; invade: number } {
  return side === "blue"
    ? { own: camps.blueOwn[camp], invade: camps.redInvade[camp] }
    : { own: camps.redOwn[camp], invade: camps.blueInvade[camp] };
}

/**
 * LCU 的战绩里打野位置有多种写法（`JUNGLE` / `JUG`），与后端
 * `isJunglePosition` 保持同一组可接受值。
 */
export function isJunglePosition(position: string | undefined): boolean {
  const value = (position ?? "").trim().toUpperCase();
  return value === "JUNGLE" || value === "JUG";
}

/** Smite（惩戒）的法术 id。与 `tags/facts.ts` 里那个是同一个值。 */
export const SMITE_SPELL_ID = 11;

/**
 * 本局是不是打野：分路写着打野，或者带着惩戒。
 *
 * 惩戒是更稳的判据——进入对局前后 `assignedPosition` 有一段时间是过期/空的。
 * 与 `tags/facts.isJungler` 同义，区别只在这里额外认 `JUG` 这个写法。
 *
 * 路线图的「只画本局打野」判定必须走这一份：玩家卡（决定要不要画）和
 * 对局页（决定去拉谁的数据）用的是同一个条件，分成两处迟早会走偏。
 */
export function isCurrentJungler(
  player: { assignedPosition?: string; summonerSpells?: { id: number }[] } | null | undefined,
): boolean {
  if (!player) return false;
  if (isJunglePosition(player.assignedPosition)) return true;
  return (player.summonerSpells ?? []).some((spell) => spell.id === SMITE_SPELL_ID);
}
