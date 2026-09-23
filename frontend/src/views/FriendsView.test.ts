import { flushPromises, mount } from "@vue/test-utils";
import type { DOMWrapper, VueWrapper } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import FriendsView from "./FriendsView.vue";

/**
 * 这一层只盯好友页新加的两件事：
 * 1. 回收站（删除前存到本地的存档）能展开、能列出、能划掉；
 * 2. 「加回好友」的提示必须说清是**发好友申请**，不是好友已经回来了。
 * 好友列表本身的内容由 fixture / 后端覆盖，这里给最小的一份就够。
 */
const notices: string[] = [];
let deletedRecords: Array<Record<string, unknown>> = [];
let restoreCalls: Array<{ id: string; addBack: boolean }> = [];
let restoreOutcome: (id: string, addBack: boolean) => { ok: boolean; reason: string; added: boolean; gameName: string; gameTag: string };

vi.mock("../stores/app", () => ({
  useAppStore: () => ({ mode: "fixture", initialized: true, connection: { status: "connected" } }),
}));

vi.mock("naive-ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("naive-ui")>();
  return {
    ...actual,
    // 确认弹层的正文与触发器都不影响这一层要验的东西，但「确定」必须能点到，
    // 所以把它摊成一个真实按钮；NButton 保持原样（点它要真的触发 @click）。
    NPopconfirm: {
      inheritAttrs: false,
      template: '<span><slot name="trigger" /><button class="popconfirm-yes" @click="$emit(\'positive-click\')">yes</button></span>',
    },
    useMessage: () => ({
      info: (text: string) => notices.push(`info:${text}`),
      success: (text: string) => notices.push(`success:${text}`),
      warning: (text: string) => notices.push(`warning:${text}`),
      error: (text: string) => notices.push(`error:${text}`),
    }),
  };
});

vi.mock("../services/backend", () => ({
  isTauri: () => false,
  backend: {
    friends: async () => ({
      groups: [{ id: 1, name: "**Default", priority: 10 }],
      friends: [
        { id: "friend-1", puuid: "puuid-1", summonerId: 101, gameName: "还在的好友", gameTag: "233", icon: 0, groupId: 1, availability: "chat", gameStatus: "", canSpectate: false, friendsSince: null, lastGameAt: null },
      ],
    }),
    friendLastGame: async (puuid: string) => ({ puuid, lastGameAt: null }),
    deletedFriends: async () => ({ friends: structuredClone(deletedRecords) }),
    restoreFriend: async (id: string, addBack: boolean) => {
      restoreCalls.push({ id, addBack });
      const outcome = restoreOutcome(id, addBack);
      if (outcome.ok) deletedRecords = deletedRecords.filter((record) => record.id !== id);
      return outcome;
    },
  },
}));

const record = (id: string, gameName: string, gameTag: string) => ({
  id,
  puuid: `puuid-${id}`,
  summonerId: 201,
  gameName,
  gameTag,
  // 0 是「好友没设过头像」的常见值：这里刻意用它，顺带盯住 id 兜底那条规则。
  icon: 0,
  groupId: 1,
  deletedAt: new Date(Date.now() - 3600_000).toISOString(),
});

beforeEach(() => {
  notices.length = 0;
  restoreCalls = [];
  deletedRecords = [record("deleted-1", "手滑删掉的队友", "HN1"), record("deleted-2", "Long Name", "233")];
  restoreOutcome = (id, addBack) => {
    const found = deletedRecords.find((item) => item.id === id);
    return { ok: true, reason: "", added: addBack, gameName: String(found?.gameName ?? ""), gameTag: String(found?.gameTag ?? "") };
  };
});

async function mountView() {
  const wrapper = mount(FriendsView);
  await flushPromises();
  return wrapper;
}

/** 按可见文字找按钮，别靠下标——同一个行里按钮的顺序以后可能会变。 */
/// 按文字找按钮：行内按钮的顺序会随样式调整变动，按下标取很容易点错。
/// 作用域既可能是整页 wrapper，也可能是一行 `<li>`（DOMWrapper），所以收成联合类型。
function buttonByText(scope: VueWrapper | DOMWrapper<Element>, text: string) {
  const found = scope.findAll("button").find((item) => item.text().includes(text));
  if (!found) throw new Error(`没有找到按钮：${text}`);
  return found;
}

describe("FriendsView 回收站", () => {
  it("默认收起，展开后列出被删记录，并给头像一个 29 号兜底", async () => {
    const wrapper = await mountView();
    const bin = wrapper.get(".friends-bin");
    expect(bin.attributes("open")).toBeUndefined();
    expect(bin.get("summary span").text()).toBe("2 条");

    const rows = wrapper.findAll(".friends-bin__body li");
    expect(rows.length).toBe(2);
    expect(rows[0].text()).toContain("手滑删掉的队友");
    expect(rows[0].text()).toContain("删除于");
    // icon 为 0 时必须退到 29 号默认头像，而不是首字母——那正是「头像认不出来」的来源。
    expect(rows[0].get("img").attributes("src")).toContain("/v1/profile-icons/29.jpg");
    wrapper.unmount();
  });

  it("「移除记录」只划掉本地存档，并把它从列表里去掉", async () => {
    const wrapper = await mountView();
    const row = wrapper.findAll(".friends-bin__body li")[0];
    await row.get(".popconfirm-yes").trigger("click");
    await flushPromises();

    expect(restoreCalls).toEqual([{ id: "deleted-1", addBack: false }]);
    expect(wrapper.findAll(".friends-bin__body li").length).toBe(1);
    expect(notices.some((item) => item.startsWith("success:") && item.includes("已从回收站移除"))).toBe(true);
    wrapper.unmount();
  });

  it("「加回好友」的提示说明这是好友申请，需要对方同意", async () => {
    const wrapper = await mountView();
    const row = wrapper.findAll(".friends-bin__body li")[1];
    await buttonByText(row, "加回好友").trigger("click");
    await flushPromises();

    expect(restoreCalls).toEqual([{ id: "deleted-2", addBack: true }]);
    const success = notices.find((item) => item.startsWith("success:"));
    expect(success).toContain("Long Name#233");
    expect(success).toContain("需要对方同意");
    wrapper.unmount();
  });

  it("失败时保留记录并把原因说出来", async () => {
    restoreOutcome = () => ({ ok: false, reason: "没连上客户端", added: false, gameName: "手滑删掉的队友", gameTag: "HN1" });
    const wrapper = await mountView();
    await buttonByText(wrapper.findAll(".friends-bin__body li")[0], "加回好友").trigger("click");
    await flushPromises();

    expect(wrapper.findAll(".friends-bin__body li").length).toBe(2);
    expect(notices.some((item) => item === "warning:没连上客户端")).toBe(true);
    wrapper.unmount();
  });
});
