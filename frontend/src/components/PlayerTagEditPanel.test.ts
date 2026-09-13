import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import { fixtureLobby } from "../fixtures/data";
import PlayerTagEditPanel from "./PlayerTagEditPanel.vue";

const player = fixtureLobby.ally[2];

describe("PlayerTagEditPanel", () => {
  it("把已有备注填进编辑框，每行一条", () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: ["爱打野", "挂机过"] } });

    const input = wrapper.get("[data-testid='player-tag-input']").element as HTMLTextAreaElement;
    expect(input.value).toBe("爱打野\n挂机过");
    wrapper.unmount();
  });

  it("保存时按行切分、去空白后再回传", async () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: [] } });

    await wrapper.get("[data-testid='player-tag-input']").setValue("爱打野\n\n  挂机过  ");
    await wrapper.get("[data-testid='player-tag-save']").trigger("click");

    expect(wrapper.emitted("save")?.[0]?.[0]).toEqual(["爱打野", "挂机过"]);
    wrapper.unmount();
  });

  it("清空后保存会回传空列表（等价于删除标记）", async () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: ["旧备注"] } });

    await wrapper.get("[data-testid='player-tag-input']").setValue("   ");
    await wrapper.get("[data-testid='player-tag-save']").trigger("click");

    expect(wrapper.emitted("save")?.[0]?.[0]).toEqual([]);
    wrapper.unmount();
  });

  it("点击遮罩或取消只关闭，不触发保存", async () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: [] } });

    await wrapper.get(".tag-editor").trigger("click");
    expect(wrapper.emitted("close")).toHaveLength(1);

    await wrapper.get(".tag-editor__button").trigger("click");
    expect(wrapper.emitted("close")).toHaveLength(2);
    expect(wrapper.emitted("save")).toBeUndefined();
    wrapper.unmount();
  });

  it("点击面板内容不会关闭", async () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: [] } });

    await wrapper.get(".tag-editor__card").trigger("click");

    expect(wrapper.emitted("close")).toBeUndefined();
    wrapper.unmount();
  });

  it("保存中禁用按钮并给出提示", () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: [], saving: true } });

    const button = wrapper.get("[data-testid='player-tag-save']");
    expect(button.text()).toContain("保存中");
    expect(button.attributes("disabled")).toBeDefined();
    wrapper.unmount();
  });

  it("错误信息优先于提示文案展示", () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player, notes: [], error: "保存失败" } });

    expect(wrapper.get(".tag-editor__status").text()).toBe("保存失败");
    wrapper.unmount();
  });

  it("没有选中玩家时不渲染", () => {
    const wrapper = mount(PlayerTagEditPanel, { props: { player: null, notes: [] } });

    expect(wrapper.find("[data-testid='player-tag-editor']").exists()).toBe(false);
    wrapper.unmount();
  });
});
