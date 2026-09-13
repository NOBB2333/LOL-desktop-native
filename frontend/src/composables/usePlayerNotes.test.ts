import { flushPromises } from "@vue/test-utils";
import { nextTick, ref } from "vue";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { usePlayerNotes } from "./usePlayerNotes";

const mocks = vi.hoisted(() => ({ playerTags: vi.fn(), updatePlayerTag: vi.fn() }));

vi.mock("../services/backend", () => ({
  backend: { playerTags: mocks.playerTags, updatePlayerTag: mocks.updatePlayerTag },
}));

async function settle() {
  await nextTick();
  await flushPromises();
}

describe("usePlayerNotes", () => {
  beforeEach(() => {
    mocks.playerTags.mockReset();
    mocks.updatePlayerTag.mockReset();
    mocks.playerTags.mockResolvedValue({});
  });

  it("按 puuid 批量读取，后端没返回的玩家补空数组", async () => {
    mocks.playerTags.mockResolvedValue({ a: ["爱打野"] });
    const controller = usePlayerNotes(ref(["a", "b", "c"]), () => "self");
    await settle();

    expect(mocks.playerTags).toHaveBeenCalledWith(["a", "b", "c"], "self");
    expect(controller.notesFor("a")).toEqual(["爱打野"]);
    expect(controller.notesFor("b")).toEqual([]);
    expect(controller.notesFor("c")).toEqual([]);
    expect(controller.error.value).toBeNull();
  });

  it("没有玩家时完全不发请求", async () => {
    const controller = usePlayerNotes(ref([]), () => "self");
    await settle();

    expect(mocks.playerTags).not.toHaveBeenCalled();
    expect(controller.notes.value).toEqual({});
  });

  it("只有别人的备注可以编辑", async () => {
    const controller = usePlayerNotes(ref(["self", "other"]), () => "self");
    await settle();

    expect(controller.canEdit("self")).toBe(false);
    expect(controller.canEdit("other")).toBe(true);
    expect(controller.canEdit("")).toBe(false);
    expect(controller.canEdit(null)).toBe(false);
  });

  it("保存后就地更新缓存，不必重新拉取", async () => {
    const controller = usePlayerNotes(ref(["a"]), () => "self");
    await settle();
    mocks.updatePlayerTag.mockResolvedValue({ puuid: "a", notes: ["新备注"], updatedAt: 1 });

    await controller.save("a", ["新备注"]);

    expect(mocks.updatePlayerTag).toHaveBeenCalledWith("a", ["新备注"], "self");
    expect(controller.notesFor("a")).toEqual(["新备注"]);
    expect(mocks.playerTags).toHaveBeenCalledTimes(1);
  });

  it("读取失败时记录错误并停止加载态", async () => {
    mocks.playerTags.mockRejectedValue(new Error("玩家标记暂不可用"));
    const controller = usePlayerNotes(ref(["a"]), () => "self");
    await settle();

    expect(controller.error.value).toBe("玩家标记暂不可用");
    expect(controller.loading.value).toBe(false);
  });

  it("puuid 集合变化时重新拉取", async () => {
    const puuids = ref(["a"]);
    usePlayerNotes(puuids, () => "self");
    await settle();
    expect(mocks.playerTags).toHaveBeenCalledTimes(1);

    puuids.value = ["a", "b"];
    await settle();
    expect(mocks.playerTags).toHaveBeenCalledTimes(2);
    expect(mocks.playerTags).toHaveBeenLastCalledWith(["a", "b"], "self");
  });
});
