import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as announcements from "../services/announcements";
import type { Announcement } from "../services/announcements";
import AnnouncementBell from "./AnnouncementBell.vue";

vi.mock("../services/announcements", async (importOriginal) => await importOriginal<typeof import("../services/announcements")>());

const loadSpy = vi.spyOn(announcements, "loadAnnouncement");
const markSeenSpy = vi.spyOn(announcements, "markAnnouncementSeen");

const release: Announcement = {
  id: "2026-09-23-新公告.md",
  title: "新公告",
  date: "2026-09-23",
  body: "内容行一\n内容行二",
};

afterEach(() => {
  loadSpy.mockReset();
  markSeenSpy.mockClear();
  localStorage.clear();
});

function mountBell() {
  return mount(AnnouncementBell, { attachTo: document.body });
}

describe("AnnouncementBell", () => {
  it("挂载时静默拉取公告；未看过则显示红点", async () => {
    loadSpy.mockResolvedValue({ ...release });
    const wrapper = mountBell();
    await flushPromises();
    expect(loadSpy).toHaveBeenCalledTimes(1);
    expect(wrapper.find(".announcement-bell__dot").exists()).toBe(true);
    // 展开面板 = 看过：红点消失并记录 seen id。
    // jsdom 不实现 <details> 的原生 toggle，只能手动置 open 再派发事件（真浏览器会自己走）。
    const details = wrapper.find("details").element as HTMLDetailsElement;
    details.open = true;
    await wrapper.find("details").trigger("toggle");
    expect(markSeenSpy).toHaveBeenCalledWith(release.id);
    expect(wrapper.find(".announcement-bell__dot").exists()).toBe(false);
    expect(wrapper.text()).toContain("新公告");
    wrapper.unmount();
  });

  it("没有公告时显示空态文案而不是报错", async () => {
    loadSpy.mockResolvedValue(null);
    const wrapper = mountBell();
    await flushPromises();
    expect(wrapper.find(".announcement-bell__empty").exists()).toBe(true);
    expect(wrapper.find(".announcement-bell__dot").exists()).toBe(false);
    wrapper.unmount();
  });
});
