import { afterEach, describe, expect, it, vi } from "vitest";
import {
  hasUnreadAnnouncement,
  loadAnnouncementFromNetwork,
  markAnnouncementSeen,
  parseAnnouncement,
  pickLatestAnnouncementFile,
  type Announcement,
} from "./announcements";

afterEach(() => {
  localStorage.clear();
  vi.unstubAllGlobals();
});

describe("pickLatestAnnouncementFile", () => {
  it("取文件名最大的 .md；README 与非文件不参与", () => {
    expect(pickLatestAnnouncementFile([
      { name: "README.md", type: "file" },
      { name: "2026-09-01-旧公告.md", type: "file" },
      { name: "2026-09-23-新公告.md", type: "file" },
      { name: "announcements", type: "dir" },
    ])).toBe("2026-09-23-新公告.md");
  });

  it("目录为空或没有可用文件时返回 null", () => {
    expect(pickLatestAnnouncementFile([])).toBeNull();
    expect(pickLatestAnnouncementFile([{ name: "notes.txt", type: "file" }])).toBeNull();
  });
});

describe("parseAnnouncement", () => {
  it("标题取正文首个 #；日期从文件名剥出", () => {
    const parsed = parseAnnouncement("2026-09-23-版本更新.md", "引言\n# 2.6.0 版本发布\n\n正文内容");
    expect(parsed.title).toBe("2.6.0 版本发布");
    expect(parsed.date).toBe("2026-09-23");
    expect(parsed.body).toContain("正文内容");
  });

  it("没有 # 标题时退回文件名（剥日期前缀与扩展名）", () => {
    const parsed = parseAnnouncement("2026-10-01-维护通知.md", "今晚维护");
    expect(parsed.title).toBe("维护通知");
    expect(parsed.date).toBe("2026-10-01");
  });
});

describe("loadAnnouncement", () => {
  it("成功路径：取最新文件、写缓存", async () => {
    const fetchStub = vi.fn(async (url: string) => {
      if (url.includes("contents/announcements")) {
        return new Response(JSON.stringify([
          { name: "2026-09-01-旧.md", type: "file", download_url: "https://raw/old" },
          { name: "2026-09-23-新.md", type: "file", download_url: "https://raw/new" },
        ]), { status: 200 });
      }
      return new Response("# 新公告\n内容 A", { status: 200 });
    });
    vi.stubGlobal("fetch", fetchStub);

    const result = await loadAnnouncementFromNetwork();
    expect(result?.title).toBe("新公告");
    expect(fetchStub).toHaveBeenCalledTimes(2);
    expect(fetchStub.mock.calls[1]?.[0]).toBe("https://raw/new");
    // 缓存里就是这份；未读判定基于缓存 id 与 seen id。
    expect(hasUnreadAnnouncement()).toBe(true);
    const cached = JSON.parse(localStorage.getItem("lol-desktop-announcement") ?? "") as Announcement;
    expect(cached.title).toBe("新公告");
  });

  it("网络失败退回上次缓存，不抛错", async () => {
    localStorage.setItem("lol-desktop-announcement", JSON.stringify({
      id: "2026-09-01-旧.md", title: "旧公告", date: "2026-09-01", body: "旧内容",
    }));
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 502 })));

    const result = await loadAnnouncementFromNetwork();
    expect(result?.title).toBe("旧公告");
    expect(hasUnreadAnnouncement()).toBe(true);
  });

  it("看过之后未读消失；换新公告又变未读", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify([
      { name: "2026-09-23-A.md", type: "file", download_url: "https://raw/a" },
    ]), { status: 200 })));
    const raw = vi.fn(async () => new Response("公告 A", { status: 200 }));
    vi.stubGlobal("fetch", vi.fn(async (url: string) =>
      url.includes("contents/announcements")
        ? new Response(JSON.stringify([{ name: "2026-09-23-A.md", type: "file", download_url: "https://raw/a" }]), { status: 200 })
        : raw(),
    ));

    await loadAnnouncementFromNetwork();
    expect(hasUnreadAnnouncement()).toBe(true);
    markAnnouncementSeen("2026-09-23-A.md");
    expect(hasUnreadAnnouncement()).toBe(false);

    // 发布了新文件 → 缓存更新 → 又是未读。
    vi.stubGlobal("fetch", vi.fn(async (url: string) =>
      url.includes("contents/announcements")
        ? new Response(JSON.stringify([{ name: "2026-09-24-B.md", type: "file", download_url: "https://raw/b" }]), { status: 200 })
        : new Response("公告 B", { status: 200 }),
    ));
    await loadAnnouncementFromNetwork();
    expect(hasUnreadAnnouncement()).toBe(true);
  });

  it("HTTP 失败且没有缓存时返回 null", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("", { status: 404 })));
    expect(await loadAnnouncementFromNetwork()).toBeNull();
  });
});
