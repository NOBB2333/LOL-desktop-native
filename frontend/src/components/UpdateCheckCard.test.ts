import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import { reactive } from "vue";
import type { ReleaseUpdate } from "../types/domain";
import UpdateCheckCard from "./UpdateCheckCard.vue";

const appStub = reactive({ bootstrap: { appVersion: "2.5.0" } });

vi.mock("../stores/app", () => ({
  useAppStore: () => appStub,
}));

const checkUpdate = vi.fn<() => Promise<ReleaseUpdate | null>>();

vi.mock("../services/backend", () => ({
  backend: {
    checkUpdate: () => checkUpdate(),
  },
}));

vi.mock("naive-ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("naive-ui")>();
  return {
    ...actual,
    NButton: { template: "<button :disabled=\"$attrs.disabled\" @click=\"$emit('click', $event)\"><slot /><slot name=\"icon\" /></button>" },
  };
});

const release: ReleaseUpdate = {
  version: "2.6.0",
  title: "桌上英雄联盟 Native v2.6.0",
  publishedAt: "2026-09-20T12:00:00Z",
  url: "https://github.com/NOBB2333/LOL-desktop-native/releases/tag/v2.6.0",
  notes: "修复若干问题\n新增时间线",
};

afterEach(() => {
  checkUpdate.mockReset();
});

describe("UpdateCheckCard", () => {
  it("挂载时检查一次：没有更新就显示「已是最新」并带当前版本", async () => {
    checkUpdate.mockResolvedValue(null);
    const wrapper = mount(UpdateCheckCard);
    // 挂载即发起检查——这是「打开设置才检查」的落点，不许等用户点按钮。
    expect(checkUpdate).toHaveBeenCalledTimes(1);
    await flushPromises();
    expect(wrapper.find(".update-check__status").text()).toBe("已是最新版本");
    expect(wrapper.text()).toContain("当前版本 v2.5.0");
    expect(wrapper.find(".update-check__release").exists()).toBe(false);
    wrapper.unmount();
  });

  it("发现新版本时展示版本、发布日期、说明与 Release 链接", async () => {
    checkUpdate.mockResolvedValue({ ...release });
    const wrapper = mount(UpdateCheckCard);
    await flushPromises();
    expect(wrapper.find(".update-check__status").text()).toBe("发现新版本 v2.6.0");
    expect(wrapper.text()).toContain("桌上英雄联盟 Native v2.6.0");
    expect(wrapper.text()).toContain("发布于 2026-09-20");
    expect(wrapper.find(".update-check__notes").text()).toContain("新增时间线");
    const link = wrapper.find("a.update-check__link");
    expect(link.attributes("href")).toBe(release.url);
    wrapper.unmount();
  });

  it("检查失败给出重试；点重试重新发起检查", async () => {
    checkUpdate.mockRejectedValueOnce(new Error("offline"));
    const wrapper = mount(UpdateCheckCard);
    await flushPromises();
    expect(wrapper.find(".update-check__status").text()).toContain("检查失败");

    checkUpdate.mockResolvedValue(null);
    await wrapper.find(".update-check__control button").trigger("click");
    await flushPromises();
    expect(checkUpdate).toHaveBeenCalledTimes(2);
    expect(wrapper.find(".update-check__status").text()).toBe("已是最新版本");
    wrapper.unmount();
  });
});
