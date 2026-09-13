const roleMap: Record<string, string> = {
  TOP: "上路", JUNGLE: "打野", MIDDLE: "中路", MID: "中路", BOTTOM: "下路", BOT: "下路", ADC: "下路", UTILITY: "辅助", SUPPORT: "辅助",
};
const rankMap: Record<string, string> = {
  CHALLENGER: "王者", GRANDMASTER: "宗师", MASTER: "大师", DIAMOND: "钻石", EMERALD: "翡翠", PLATINUM: "铂金", GOLD: "黄金", SILVER: "白银", BRONZE: "青铜", IRON: "黑铁", UNRANKED: "未定级",
};
const championAlias: Record<number, string> = {
  266: "Aatrox", 64: "LeeSin", 103: "Ahri", 222: "Jinx", 412: "Thresh", 164: "Camille", 76: "Nidalee", 7: "Leblanc", 145: "Kaisa", 111: "Nautilus",
};
type PlatformRegionGroup = "独立大区" | "联盟大区";
type PlatformRegion = { name: string; group: PlatformRegionGroup; servers: string };

export interface PlatformRegionItem extends PlatformRegion {
  id: string;
}

export interface PlatformRegionOverview {
  current: PlatformRegionItem | null;
  groups: { label: PlatformRegionGroup; regions: PlatformRegionItem[] }[];
}

// 国服 LCU 的 platformId 与展示名称并不是一一按字面对应。
// 这些值与 rank-analysis 项目的已验证 SGP 映射保持一致：HN1 是艾欧尼亚，
// 合并后的联盟一区使用 NJ100。部分 LCU 返回 TENCENT_ 前缀，查询时统一处理。
const platformRegions: Record<string, PlatformRegion> = {
  HN1: { name: "艾欧尼亚", group: "独立大区", servers: "艾欧尼亚" },
  HN10: { name: "黑色玫瑰", group: "独立大区", servers: "黑色玫瑰" },
  BGP2: { name: "峡谷之巅", group: "独立大区", servers: "峡谷之巅" },
  NJ100: { name: "联盟一区", group: "联盟大区", servers: "祖安、皮尔特沃夫、巨神峰、教育网、男爵领域、均衡教派、影流、守望之海" },
  GZ100: { name: "联盟二区", group: "联盟大区", servers: "卡拉曼达、暗影岛、征服之海、诺克萨斯、战争学院、雷瑟守备" },
  CQ100: { name: "联盟三区", group: "联盟大区", servers: "班德尔城、裁决之地、水晶之痕、钢铁烈阳、皮城警备" },
  TJ100: { name: "联盟四区", group: "联盟大区", servers: "比尔吉沃特、弗雷尔卓德、扭曲丛林" },
  TJ101: { name: "联盟五区", group: "联盟大区", servers: "德玛西亚、无畏先锋、恕瑞玛、巨龙之巢" },
};
const platformRegionOrder = ["HN1", "HN10", "BGP2", "NJ100", "GZ100", "CQ100", "TJ100", "TJ101"];

function platformRegionId(value?: string | null) {
  const raw = value?.trim().toUpperCase() ?? "";
  const withoutPrefix = raw.replace(/^TENCENT[_-]/, "");
  if (platformRegions[withoutPrefix]) return withoutPrefix;
  // Some account payloads put the human label and platform ID together,
  // e.g. "峡谷之巅 / HN1". Prefer the stable ID when it is present.
  const embedded = withoutPrefix.match(/\b(?:HN\d+|NJ100|GZ100|CQ100|TJ10\d|BGP2)\b/);
  return embedded?.[0] && platformRegions[embedded[0]] ? embedded[0] : withoutPrefix;
}

// LCU 在不同阶段可能返回带空格、空值或尚未分配的位置；显示层始终给出稳定的中文值。
export const roleName = (role?: string | null) => roleMap[role?.trim().toUpperCase() ?? ""] ?? "待定";
export const rankName = (tier?: string | null) => {
  const value = tier?.trim() ?? "";
  return rankMap[value.toUpperCase()] ?? value;
};
export const platformRegionName = (value?: string | null) => {
  const id = platformRegionId(value);
  if (id && platformRegions[id]) return `${id} · ${platformRegions[id].name}`;
  return value?.trim() || "未连接大区";
};
export const platformRegionOverview = (value?: string | null): PlatformRegionOverview => {
  const currentId = platformRegionId(value);
  const regions = platformRegionOrder.map((id) => ({ id, ...platformRegions[id] }));
  return {
    current: regions.find((region) => region.id === currentId) ?? null,
    groups: (["独立大区", "联盟大区"] as const).map((label) => ({
      label,
      regions: regions.filter((region) => region.group === label),
    })),
  };
};
export const platformRegionGuide = (value?: string | null) => {
  const overview = platformRegionOverview(value);
  const lines = overview.current
    ? [
        `当前大区：${overview.current.id} · ${overview.current.name}`,
        `${overview.current.group}：${overview.current.servers}`,
        "",
      ]
    : [`当前大区：${platformRegionName(value)}`, "",];
  for (const group of overview.groups) {
    lines.push(group.label);
    lines.push(...group.regions.map((region) => `${region.id} · ${region.name}：${region.servers}`));
    lines.push("");
  }
  return lines.slice(0, -1).join("\n");
};
export const percent = (value: number) => `${Math.round(value * 100)}%`;
export const meterClass = (value: number) => `meter-${Math.min(100, Math.max(0, Math.round(value / 5) * 5))}`;
// Native production pages are served from zero://app. Keep fallback assets
// relative so a leading slash cannot escape the bundled frontend directory.
export const championImage = (id: number) => championAlias[id] ? `./fixtures/champions/${championAlias[id]}.png` : "";
function parseTimestamp(value: string) {
  const direct = Date.parse(value);
  if (Number.isFinite(direct)) return direct;
  // Native builds before 2.0.0 emitted `.+123Z` for positive milliseconds.
  // Accept those cached records while the backend rewrites them in the next
  // history refresh.
  const repaired = value.replace(/\.\+(\d{1,3})Z$/, (_, millis: string) => `.${millis.padStart(3, "0")}Z`);
  const fallback = Date.parse(repaired);
  return Number.isFinite(fallback) ? fallback : NaN;
}
export const shortDay = (value: string) => {
  const timestamp = parseTimestamp(value);
  return Number.isFinite(timestamp) ? new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric" }).format(timestamp) : "时间未知";
};
export const shortDate = (value: string) => {
  const timestamp = parseTimestamp(value);
  return Number.isFinite(timestamp) ? new Intl.DateTimeFormat("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).format(timestamp) : "时间未知";
};
export const relativeTime = (value: string) => {
  const timestamp = parseTimestamp(value);
  if (!Number.isFinite(timestamp)) return "时间未知";
  const hours = Math.max(1, Math.round((Date.now() - timestamp) / 3600000));
  return hours < 24 ? `${hours} 小时前` : `${Math.floor(hours / 24)} 天前`;
};

/** 精确到分钟的日期时间，用于共同对局表格。 */
export const dateTime = (value: string) => {
  const timestamp = parseTimestamp(value);
  if (!Number.isFinite(timestamp)) return "时间未知";
  const date = new Date(timestamp);
  const pad = (input: number) => input.toString().padStart(2, "0");
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
};

/** 相对当前时间的自然语言描述（对齐 LeagueAkari 的 dayjs.fromNow）。 */
export const fromNow = (value: string) => {
  const timestamp = parseTimestamp(value);
  if (!Number.isFinite(timestamp)) return "时间未知";
  const seconds = Math.round((Date.now() - timestamp) / 1000);
  if (seconds < 60) return "刚刚";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days} 天前`;
  const months = Math.round(days / 30);
  if (months < 12) return `${months} 个月前`;
  return `${Math.round(months / 12)} 年前`;
};
