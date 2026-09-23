/**
 * 公告：GitHub 仓库根目录 `announcements/` 文件夹里**文件名排序最大的 .md** 就是当前公告。
 *
 * 为什么选这个方案：发公告 = 往仓库推一个文本文件，不需要 Release、不需要 CI、
 * 手机上都能改。文件名约定 `YYYY-MM-DD-标题.md`，日期前缀保证字典序就是时间序。
 *
 * 网络因素（用户明确担心过）：GitHub 直连在国内不稳定，所以这里**三层兜底**——
 * 1. 成功取到 → 写 localStorage 缓存；
 * 2. 取失败 → 用缓存里上次成功的那份（可能略旧，但绝不是空白）；
 * 3. 连缓存都没有 → 返回 null，界面只显示「暂时拿不到公告」，不报错误横幅。
 *
 * 走 WebView 的 fetch 而不是原生 HTTP：api.github.com / raw.githubusercontent.com
 * 都带 `Access-Control-Allow-Origin: *`，而且 WebView 走系统代理（mihomo 全局代理
 * 对它生效），对国内用户来说这条路比原生直连更容易通。
 *
 * README.md 不算公告（仓库说明用），其余 `.md` 都参与排序。
 */

export interface Announcement {
  /** 文件名（如 `2026-09-23-版本更新说明.md`），未读判定与缓存键都用它。 */
  id: string;
  /** 正文首个 `# ` 标题；没有就用文件名（剥掉日期前缀和扩展名）。 */
  title: string;
  /** 从文件名剥出的 `YYYY-MM-DD`；没写日期就是空串。 */
  date: string;
  /** 正文全文（Markdown 源码，按纯文本渲染，保留换行）。 */
  body: string;
}

import { usesFixtureData } from "./browserBackend";

const CONTENTS_API = "https://api.github.com/repos/NOBB2333/LOL-desktop-native/contents/announcements";
const CACHE_KEY = "lol-desktop-announcement";
const SEEN_KEY = "lol-desktop-announcement-seen";

interface ContentEntry {
  name?: unknown;
  type?: unknown;
  download_url?: unknown;
}

/** 从目录清单里挑出当前公告的文件名。公开给测试：排序规则是纯逻辑。 */
export function pickLatestAnnouncementFile(entries: ContentEntry[]): string | null {
  const names = entries
    .filter((entry) => entry.type === "file" && typeof entry.name === "string")
    .map((entry) => entry.name as string)
    .filter((name) => name.toLowerCase().endsWith(".md") && name.toLowerCase() !== "readme.md");
  if (!names.length) return null;
  // 字典序最大 = 日期最新（依赖 YYYY-MM-DD 前缀约定）。
  return names.sort((left, right) => (left < right ? 1 : left > right ? -1 : 0))[0];
}

/** 把「文件名 + Markdown 全文」解析成公告。公开给测试：标题/日期的提取规则都在这。 */
export function parseAnnouncement(name: string, text: string): Announcement {
  const date = /^(\d{4}-\d{2}-\d{2})/.exec(name)?.[1] ?? "";
  // 正文里的第一个 `# 标题` 优先；没有就退回文件名（剥日期前缀与 .md）。
  const heading = /^#\s+(.+)$/m.exec(text)?.[1]?.trim() ?? "";
  const fallbackTitle = name.replace(/^\d{4}-\d{2}-\d{2}-?/, "").replace(/\.md$/i, "") || name;
  return { id: name, title: heading || fallbackTitle, date, body: text.trim() };
}

function readCache(): Announcement | null {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Announcement;
    return parsed && typeof parsed.id === "string" && typeof parsed.body === "string" ? parsed : null;
  } catch {
    return null;
  }
}

function writeCache(announcement: Announcement) {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(announcement));
  } catch {
    // 隐私模式写不进就算了，缓存只是兜底不是必须。
  }
}

/** 上次成功拉到的公告（可能略旧）；没有就是 null。 */
export function cachedAnnouncement(): Announcement | null {
  return readCache();
}

export function seenAnnouncementId(): string {
  try {
    return localStorage.getItem(SEEN_KEY) ?? "";
  } catch {
    return "";
  }
}

export function markAnnouncementSeen(id: string) {
  try {
    localStorage.setItem(SEEN_KEY, id);
  } catch {
    // 同上，读不回大不了下次再弹一次点开。
  }
}

/** 有没有未读公告：以「缓存里那份」为准，不发起网络请求。 */
export function hasUnreadAnnouncement(): boolean {
  const cached = readCache();
  return Boolean(cached && cached.id !== seenAnnouncementId());
}

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, { headers: { Accept: "text/plain" } });
  if (!response.ok) throw new Error(`公告下载失败（HTTP ${response.status}）`);
  return response.text();
}

/**
 * 拉当前公告。失败时**不抛错**、退回缓存——调用方不需要为网络波动写分支，
 * 只需要区分「有内容」和「没内容」。返回 null = 网络失败且无缓存，或仓库还没有公告。
 */
export async function loadAnnouncement(): Promise<Announcement | null> {
  // 浏览器预览不发真网络：固定给一份示例，保证预览里能看到完整交互。
  if (usesFixtureData()) {
    return {
      id: "2026-09-23-预览公告.md",
      title: "欢迎使用桌上英雄联盟",
      date: "2026-09-23",
      body: "这是浏览器预览模式下的示例公告。\n真实公告发布在 GitHub 仓库的 announcements/ 目录：文件名最大的 .md 就是当前公告。",
    };
  }
  return loadAnnouncementFromNetwork();
}

/** 真实网络路径（fixture 分支之外）。单独导出：测试环境没有原生桥，会被判成 fixture。 */
export async function loadAnnouncementFromNetwork(): Promise<Announcement | null> {
  try {
    const response = await fetch(CONTENTS_API, { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) throw new Error(`公告列表获取失败（HTTP ${response.status}）`);
    const listing = (await response.json()) as ContentEntry[];
    const name = pickLatestAnnouncementFile(Array.isArray(listing) ? listing : []);
    if (!name) return null;
    const entry = listing.find((item) => item.name === name);
    const url = typeof entry?.download_url === "string" ? entry.download_url : "";
    const text = await fetchText(url || `https://raw.githubusercontent.com/NOBB2333/LOL-desktop-native/main/announcements/${encodeURIComponent(name)}`);
    const announcement = parseAnnouncement(name, text);
    writeCache(announcement);
    return announcement;
  } catch {
    // 网络不通：用上次成功的缓存撑住界面（可能旧一两版，但比报错好）。
    return readCache();
  }
}
