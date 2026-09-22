/**
 * OP.GG 统计口径（区服 / 分段）。
 *
 * 取值**必须在后端白名单里**（`src/backend/assets_ipc.zig` 的 `opgg_regions` /
 * `opgg_tiers`，抄自 AK 的 `RegionType` / `TierType`）：表外的值后端会静默落回默认，
 * 界面这边就白选了。所以选项表和判定都收口在这个文件里，不在视图里各写一份。
 *
 * ⚠️ OP.GG **不提供中国大陆服数据**——AK 自己的 `RegionType` 19 个里也没有 `cn`。
 * 所以国服账号只能落回 `global`（全部地区汇总）。这不是我们没接，是上游就没有，
 * 别去"补"一个 cn 选项，后端白名单会把它拒掉。
 */

/**
 * ⚠️ 必须是 `type` 而不是 `interface`：naive-ui 的 `SelectMixedOption` 带索引签名，
 * 而 TS 的 `interface` **不会**获得隐式索引签名，直接当 `:options` 传会报
 * `Property 'type' is missing`。`type` 别名可以，这是两者唯一的行为差异。
 */
export type ScopeOption = {
  label: string;
  value: string;
};

/** 认不出平台时用的区服。同时也是后端 `default_opgg_region`。 */
export const OPGG_FALLBACK_REGION = "global";
/** 后端 `default_opgg_tier`。 */
export const OPGG_FALLBACK_TIER = "emerald_plus";

export const OPGG_REGION_STORAGE_KEY = "lol-desktop-champion-region";
export const OPGG_TIER_STORAGE_KEY = "lol-desktop-champion-stats-tier";

export const opggRegionOptions: ScopeOption[] = [
  { label: "全球 Global", value: "global" },
  { label: "韩服 KR", value: "kr" },
  { label: "美服 NA", value: "na" },
  { label: "欧服西欧 EUW", value: "euw" },
  { label: "欧服北欧 EUNE", value: "eune" },
  { label: "日服 JP", value: "jp" },
  { label: "巴西 BR", value: "br" },
  { label: "拉美北 LAN", value: "lan" },
  { label: "拉美南 LAS", value: "las" },
  { label: "大洋洲 OCE", value: "oce" },
  { label: "土耳其 TR", value: "tr" },
  { label: "俄服 RU", value: "ru" },
  { label: "东南亚 SG", value: "sg" },
  { label: "印尼 ID", value: "id" },
  { label: "菲律宾 PH", value: "ph" },
  { label: "泰国 TH", value: "th" },
  { label: "越南 VN", value: "vn" },
  { label: "中国台湾 TW", value: "tw" },
  { label: "中东 ME", value: "me" },
];

/**
 * ⚠️ 这是**后端白名单的子集**：后端的 `opgg_tiers` 有 10 个（含 `master`、`ibsg`），
 * 界面上刻意只暴露 8 个——`master`（仅大师）与 `master_plus`（大师以上）并排摆着
 * 只会让人选错。所以 `isKnownOpggTier` 判的是"界面还提不提供这个值"，
 * 存着这类值时会落回默认，而不是照用。
 */
export const opggTierOptions: ScopeOption[] = [
  { label: "翡翠以上", value: "emerald_plus" },
  { label: "钻石以上", value: "diamond_plus" },
  { label: "铂金以上", value: "platinum_plus" },
  { label: "黄金以上", value: "gold_plus" },
  { label: "大师以上", value: "master_plus" },
  { label: "宗师以上", value: "grandmaster" },
  { label: "王者", value: "challenger" },
  { label: "全部段位", value: "all" },
];

/**
 * 平台标识 → OP.GG 区服。
 *
 * 键是 Riot 的 `platformId`（`NA1` / `KR` / `EUW1` …）。同时收下不带数字的写法：
 * LCU 在不同版本里 `platformId` 与 `region` 的形态并不一致（`EUW1` vs `EUW`），
 * 两个字段都可能喂进来，所以两种都认。
 *
 * ⚠️ 拉美北/拉美南（`LA1` / `LA2`）**必须整串精确匹配**，不能先剥数字再查表——
 * `LA1` 和 `LA2` 剥完都成了 `LA`，会把拉美南错认成拉美北。
 */
const PLATFORM_TO_REGION: Record<string, string> = {
  NA1: "na",
  NA: "na",
  KR: "kr",
  EUW1: "euw",
  EUW: "euw",
  EUN1: "eune",
  EUNE: "eune",
  JP1: "jp",
  JP: "jp",
  BR1: "br",
  BR: "br",
  LA1: "lan",
  LAN: "lan",
  LA2: "las",
  LAS: "las",
  OC1: "oce",
  OCE: "oce",
  TR1: "tr",
  TR: "tr",
  RU: "ru",
  SG2: "sg",
  SG: "sg",
  PH2: "ph",
  PH: "ph",
  TH2: "th",
  TH: "th",
  VN2: "vn",
  VN: "vn",
  TW2: "tw",
  TW: "tw",
  ME1: "me",
  ME: "me",
};

/** 认不出的平台（含国服 `TENCENT` / `HN1` 之类）一律落回 `global`。 */
export function platformToOpggRegion(platform: string | null | undefined): string {
  if (!platform) return OPGG_FALLBACK_REGION;
  return PLATFORM_TO_REGION[platform.trim().toUpperCase()] ?? OPGG_FALLBACK_REGION;
}

export function isKnownOpggRegion(value: string | null | undefined): boolean {
  return Boolean(value) && opggRegionOptions.some((option) => option.value === value);
}

export function isKnownOpggTier(value: string | null | undefined): boolean {
  return Boolean(value) && opggTierOptions.some((option) => option.value === value);
}

/**
 * 定默认区服：**用户手动选过就听用户的**，没选过才跟随本机登录大区。
 *
 * 存了值但值已经不合法（比如以后删了某个区服）时按没选过处理，免得卡在一个
 * 后端已经拒掉的取值上。
 */
export function resolveStatsRegion(stored: string | null | undefined, platform: string | null | undefined): string {
  return isKnownOpggRegion(stored) ? (stored as string) : platformToOpggRegion(platform);
}

/** 分段的兜底逻辑与区服一致，只是没有"跟随本机"的语义。 */
export function resolveStatsTier(stored: string | null | undefined): string {
  return isKnownOpggTier(stored) ? (stored as string) : OPGG_FALLBACK_TIER;
}

/** 区服选项里没有的取值（后端表外值）也能显示，说明它落回了默认。 */
export function opggRegionLabel(value: string): string {
  return opggRegionOptions.find((option) => option.value === value)?.label ?? `${value}（未知，已回落默认）`;
}

export function opggTierLabel(value: string): string {
  return opggTierOptions.find((option) => option.value === value)?.label ?? value;
}
