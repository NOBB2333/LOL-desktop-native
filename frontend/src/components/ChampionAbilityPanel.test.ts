import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import { beforeEach, describe, expect, it } from "vitest";
import type { ChampionAbilities, ChampionAbilityValues } from "../types/domain";
import ChampionAbilityPanel from "./ChampionAbilityPanel.vue";

/**
 * 技能面板盯的是**真机数据形状**上的几处坑：
 *
 * 1. 技能名和描述来自 LCU 本地文件（`/lol-game-data/assets/v1/champions/{id}.json`），
 *    已经按客户端语言本地化好——所以不该有任何我们自己的翻译表参与。
 * 2. 槽位由 `spellKey`（q/w/e/r）决定，**不能按下标猜**：有的英雄少了某一格
 *    （Yasuo 的 Q 走 wrapper），硬编四个标签会点出一片空白。
 * 3. 冷却/耗蓝/射程是**每级数组**，真机上长度 5 或 6。展示只取前 5 格，而且
 *    0.5 这种小数不能被取整成 0（亚索 E）。
 */

const { abilitiesState, valuesState } = vi.hoisted(() => ({
  abilitiesState: { data: null as ChampionAbilities | null, error: null as Error | null, calls: 0 },
  valuesState: { data: null as ChampionAbilityValues | null, error: null as Error | null, calls: 0, lastAlias: "" },
}));

vi.mock("../services/backend", () => ({
  isTauri: () => false,
  backend: {
    championAbilities: async () => {
      abilitiesState.calls += 1;
      if (abilitiesState.error) throw abilitiesState.error;
      return abilitiesState.data as never;
    },
    championAbilityValues: async (_championId: number, alias: string) => {
      valuesState.calls += 1;
      valuesState.lastAlias = alias;
      if (valuesState.error) throw valuesState.error;
      return valuesState.data as never;
    },
  },
}));

/** 图标桩：真组件会去拉远程图，这里只关心「挂了几个」与路径有没有传下来。 */
const LcuAssetStub = { props: ["path", "alt"], template: '<i class="lcu-stub" :data-path="path" :data-alt="alt" />' };

function abilitiesFixture(overrides: Partial<ChampionAbilities> = {}): ChampionAbilities {
  return {
    championId: 103,
    alias: "Ahri",
    name: "九尾妖狐",
    title: "九尾妖狐",
    passive: {
      name: "摄魂夺魄",
      description: "用技能命中敌人后获得一层<b>摄魂夺魄</b>。",
      iconPath: "/lol-game-data/assets/ASSETS/Characters/Ahri/HUD/Icons2D/Icons_Ahri_Passive.png",
      videoPath: "champion-abilities/0103/ability_0103_P1.webm",
      videoImagePath: "champion-abilities/0103/ability_0103_P1.jpg",
    },
    spells: ["q", "w", "e", "r"].map((slot, index) => ({
      slot,
      name: `技能${slot.toUpperCase()}`,
      description: `技能${slot.toUpperCase()} 的简版说明`,
      dynamicDescription: `造成 <magicDamage>@TotalDamage@ 魔法伤害</magicDamage>`,
      // 真机长度 5 或 6；这里给 6 格来证明**只展示前 5 格**。
      cooldown: [7 + index, 7 + index, 7 + index, 7 + index, 7 + index, 99],
      cost: [55, 65, 75, 85, 95, 95],
      range: [970, 970, 970, 970, 970, 970],
      iconPath: `/lol-game-data/assets/ASSETS/Characters/Ahri/HUD/Icons2D/Icons_Ahri_${slot.toUpperCase()}.png`,
      videoPath: `champion-abilities/0103/ability_0103_${slot.toUpperCase()}1.webm`,
      videoImagePath: `champion-abilities/0103/ability_0103_${slot.toUpperCase()}1.jpg`,
    })),
    ...overrides,
  };
}

function mountPanel(championId = 103) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(ChampionAbilityPanel, {
    props: { championId, championName: "九尾妖狐" },
    global: { plugins: [[VueQueryPlugin, { queryClient }]], stubs: { LcuAssetImage: LcuAssetStub } },
  });
}

/**
 * 每个用例都必须从干净状态开始。
 *
 * `abilitiesState` 是模块级的桩状态，上一个用例塞的 `error` 会漏到下一个——
 * 2026-09-29 正是这么让「换英雄回 Q」那条红了一次（它拿到的是上一个用例的失败态）。
 */
beforeEach(() => {
  abilitiesState.data = null;
  abilitiesState.error = null;
  abilitiesState.calls = 0;
  valuesState.data = null;
  valuesState.error = null;
  valuesState.calls = 0;
  valuesState.lastAlias = "";
});

describe("技能面板：数据形状与口径", () => {
  it("按 spellKey 出标签（被动 + Q/W/E/R），默认停在 Q", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    const labels = wrapper.findAll(".abilities__tabs button b").map((node) => node.text());
    expect(labels).toEqual(["被动", "Q", "W", "E", "R"]);
    // 默认选中 Q（不是被动、也不是列表里第一个任意槽）。
    expect(wrapper.get(".abilities__tabs button.active").text()).toContain("Q");
    expect(wrapper.get(".abilities__body header strong").text()).toBe("技能Q");
    wrapper.unmount();
  });

  it("某一格缺技能时不硬点一个空标签出来", async () => {
    // 真机上有英雄少了某一格。这里只给 Q 和 R → 标签里只该有这两个。
    const only = abilitiesFixture();
    only.spells = only.spells.filter((spell) => spell.slot === "q" || spell.slot === "r");
    abilitiesState.data = only;
    const wrapper = mountPanel();
    await flushPromises();
    const labels = wrapper.findAll(".abilities__tabs button b").map((node) => node.text());
    expect(labels).toEqual(["被动", "Q", "R"]);
    expect(labels).not.toContain("W");
    wrapper.unmount();
  });

  it("每级数组只展示前 5 格（第 6 格不是可点等级）", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    const stats = wrapper.findAll(".abilities__stats dd").map((node) => node.text());
    // 冷却第 6 格是 99（桩里故意的），不许出现在界面上。
    expect(stats[0]).toBe("7 / 7 / 7 / 7 / 7");
    expect(stats[0]).not.toContain("99");
    wrapper.unmount();
  });

  it("冷却里的小数（亚索 E 的 0.5）不被取整成 0", async () => {
    const yasuo = abilitiesFixture({ championId: 157, alias: "Yasuo", name: "疾风剑豪" });
    const e = yasuo.spells.find((spell) => spell.slot === "e")!;
    e.cooldown = [0.5, 0.5, 0.4, 0.3, 0.2, 0.1];
    abilitiesState.data = yasuo;
    const wrapper = mountPanel(157);
    await flushPromises();
    await wrapper.findAll(".abilities__tabs button")[3].trigger("click");
    expect(wrapper.get(".abilities__stats dd").text()).toBe("0.5 / 0.5 / 0.4 / 0.3 / 0.2");
    wrapper.unmount();
  });

  it("射程五级相同就只写一个数，不同才列成数组", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    // Q 的射程五格全是 970 → 只写一个 970。
    expect(wrapper.findAll(".abilities__stats dd")[2].text()).toBe("970");
    wrapper.unmount();
  });

  it("切到被动时显示被动文案与图标（结构不一样，不能复用技能分支）", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    await wrapper.findAll(".abilities__tabs button")[0].trigger("click");
    const body = wrapper.get(".abilities__body");
    expect(body.get("header strong").text()).toBe("摄魂夺魄");
    expect(body.get("header small").text()).toBe("被动");
    // 被动没有等级数组 → 不该出现冷却/耗蓝/射程那一块。
    expect(body.find(".abilities__stats").exists()).toBe(false);
    expect(body.get(".lcu-stub").attributes("data-path")).toContain("Ahri_Passive");
    wrapper.unmount();
  });

  it("官方标记被消费掉：标签变样式、没取到值的变量标出来并说明为什么没数字", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel();
    await flushPromises();
    // 标签不能原样印出来（这是用户 2026-09-30 报的那个渲染问题）。
    const body = wrapper.get(".abilities__body");
    expect(body.text()).not.toContain("<magicDamage>");
    expect(body.html()).toContain('class="ab-magic"');
    // 没取到值的占位符要标出来，不能悄悄消失。
    expect(body.html()).toContain("ab-placeholder");
    expect(body.text()).toContain("@TotalDamage@");
    // 口径说明必须在：不说清，用户会以为是我们没渲染出来。
    expect(wrapper.get(".abilities__note").text()).toContain("变量");
    expect(wrapper.get(".abilities__note").text()).toContain("不替它填数字");
    wrapper.unmount();
  });

  it("拉莫斯 Q 的真机原文：正文完整可读，没有一个裸标签", async () => {
    // 用户 2026-09-30 贴的就是这段，原样搬进来当回归。
    const rammusQ =
      "拉莫斯蜷缩为球状，获得<speed>@MinimumMoveSpeed@移动速度</speed>，并在@RollDuration@秒里持续加速至" +
      "<speed>@MaximumMoveSpeed@移动速度</speed>。拉莫斯会在与一名敌人碰撞后停下，对附近的敌人们造成" +
      "<magicDamage>@PowerBallDamage@魔法伤害</magicDamage>、<status>击退</status>、和持续@SlowDuration@秒的" +
      "@SlowPercent@%<status>减速</status>。<br><br><recast>再次施放</recast>：拉莫斯提前结束这个技能。" +
      "@SpellModifierDescriptionAppend@";
    const data = abilitiesFixture();
    data.spells[0] = { ...data.spells[0], name: "动力冲刺", dynamicDescription: rammusQ };
    abilitiesState.data = data;
    const wrapper = mountPanel();
    await flushPromises();

    const html = wrapper.get(".abilities__body").html();
    for (const tag of ["speed", "magicDamage", "status", "recast"]) {
      expect(html).not.toContain(`<${tag}>`);
    }
    const text = wrapper.get(".abilities__body").text();
    expect(text).toContain("拉莫斯蜷缩为球状");
    expect(text).toContain("再次施放");
    expect(text).toContain("击退");
    // 换行真的渲染了，而不是挤成一行
    expect(html).toContain("<br");
    wrapper.unmount();
  });

  it("只有 @SpellModifierDescriptionAppend@ 时，说明文案不说成「缺数值」", async () => {
    // 这是客户端拼装备/符文加成的位置，本来就应该空——说成「算不出来」会误导。
    const data = abilitiesFixture();
    data.spells[0] = { ...data.spells[0], dynamicDescription: "造成伤害。@SpellModifierDescriptionAppend@" };
    abilitiesState.data = data;
    const wrapper = mountPanel();
    await flushPromises();
    const note = wrapper.get(".abilities__note").text();
    expect(note).toContain("装备与符文");
    expect(note).not.toContain("实时属性");
    wrapper.unmount();
  });

  it("取不到资料时说清「需要开客户端」，而不是笼统的加载失败", async () => {
    abilitiesState.error = new Error("LcuNotRunning");
    const wrapper = mountPanel();
    // 失败态要等两轮 microtask（vue-query 内部先 reject 再置位）。
    await flushPromises();
    await flushPromises();
    const state = wrapper.get(".abilities__state");
    expect(state.text()).toContain("开启《英雄联盟》客户端");
    // 也要说清「不影响别的」——否则用户会以为整个英雄页都坏了。
    expect(state.text()).toContain("不受影响");
    // 出错时不该画标签页（点进去全是空的更迷惑）。
    expect(wrapper.find(".abilities__tabs").exists()).toBe(false);
    wrapper.unmount();
  });

  it("换英雄时回到 Q，不留在上一个英雄的 R 上", async () => {
    abilitiesState.data = abilitiesFixture();
    const wrapper = mountPanel(103);
    await flushPromises();
    await wrapper.findAll(".abilities__tabs button")[4].trigger("click");
    expect(wrapper.get(".abilities__tabs button.active").text()).toContain("R");
    await wrapper.setProps({ championId: 64, championName: "盲僧" });
    await flushPromises();
    expect(wrapper.get(".abilities__tabs button.active").text()).toContain("Q");
    wrapper.unmount();
  });

  it("同一个英雄只拉一次（staleTime 内不重复请求）", async () => {
    abilitiesState.data = abilitiesFixture();
    abilitiesState.calls = 0;
    const wrapper = mountPanel();
    await flushPromises();
    expect(abilitiesState.calls).toBe(1);
    await wrapper.setProps({ championName: "换个显示名" });
    await flushPromises();
    expect(abilitiesState.calls).toBe(1);
    wrapper.unmount();
  });
});

/**
 * 逐级数值那一层。
 *
 * 数据来自 CommunityDragon（**公网**），LCU 那份里系数全是 0。所以它天然是
 * 「可选增强」：拿得到就替换占位符，拿不到就保留原文——绝不能因此把整块面板判成失败。
 */
describe("技能面板：逐级数值（CommunityDragon）", () => {
  /** 拉莫斯 Q 的取值表：三个能取到、一个取不到（随英雄等级插值）。 */
  function rammusValues(): ChampionAbilityValues {
    return {
      alias: "Rammus",
      spells: [
        {
          slot: "q",
          values: {
            PowerBallDamage: { values: [40, 80, 120, 160, 200, 240, 280], ratio: 1, ratioStat: "AP" },
            RollDuration: { values: [6, 6, 6, 6, 6, 6, 6] },
            SlowDuration: { values: [1.5, 1.5, 1.5, 1.5, 1.5] },
            SlowPercent: { values: [30, 40, 50, 60, 70, 80, 90] },
          },
        },
      ],
    };
  }

  const rammusQ =
    "拉莫斯蜷缩为球状，获得<speed>@MinimumMoveSpeed@移动速度</speed>，并在@RollDuration@秒里持续加速至" +
    "<speed>@MaximumMoveSpeed@移动速度</speed>。拉莫斯会在与一名敌人碰撞后停下，对附近的敌人们造成" +
    "<magicDamage>@PowerBallDamage@魔法伤害</magicDamage>、和持续@SlowDuration@秒的@SlowPercent@%" +
    "<status>减速</status>。<br><br><recast>再次施放</recast>：拉莫斯提前结束这个技能。" +
    "@SpellModifierDescriptionAppend@";

  function mountRammus() {
    const data = abilitiesFixture({ championId: 33, alias: "Rammus", name: "披甲龙龟" });
    data.spells[0] = { ...data.spells[0], name: "动力冲刺", dynamicDescription: rammusQ };
    abilitiesState.data = data;
    return mountPanel(33);
  }

  it("取到值的变量换成真实数字，取不到的原样保留", async () => {
    valuesState.data = rammusValues();
    const wrapper = mountRammus();
    await flushPromises();
    await flushPromises();

    const body = wrapper.get(".abilities__body");
    const text = body.text();
    // 逐级数组按 " / " 拼出来，且第 6/7 格也在（技能能点 5 级但数组给到 7 格是官方的）。
    expect(body.html()).toContain("ab-value");
    expect(text).toContain("40 / 80 / 120 / 160 / 200 / 240 / 280");
    expect(text).toContain("30 / 40 / 50 / 60 / 70 / 80 / 90");
    // 取到的整块替换 → 正文里不该再有这几个占位符。
    expect(text).not.toContain("@PowerBallDamage@");
    expect(text).not.toContain("@SlowPercent@");
    // 随**英雄等级**插值的那个取不到 → 必须原样留着，不许编。
    expect(text).toContain("@MinimumMoveSpeed@");
    expect(body.html()).toContain("ab-placeholder");
    wrapper.unmount();
  });

  it("拿不到数值（断网）时退回原文，且不把主面板判成失败", async () => {
    valuesState.error = new Error("AbilityValuesUnavailable");
    const wrapper = mountRammus();
    await flushPromises();
    await flushPromises();

    // 主面板照常：标签、正文、冷却都在。
    expect(wrapper.find(".abilities__state--warn").exists()).toBe(false);
    expect(wrapper.findAll(".abilities__tabs button").length).toBeGreaterThan(0);
    const body = wrapper.get(".abilities__body");
    expect(body.text()).toContain("拉莫斯蜷缩为球状");
    expect(body.text()).toContain("@PowerBallDamage@");
    // 但要明说「这次没取到数值」——否则看起来像我们没渲染。
    expect(wrapper.get(".abilities__note--muted").text()).toContain("没能取到逐级数值");
    wrapper.unmount();
  });

  it("拉数值时把 alias 传下去（CommunityDragon 的目录用英文别名）", async () => {
    valuesState.data = rammusValues();
    const wrapper = mountRammus();
    await flushPromises();
    await flushPromises();
    expect(valuesState.calls).toBe(1);
    expect(valuesState.lastAlias).toBe("Rammus");
    wrapper.unmount();
  });

  it("技能资料没回来之前不去拉数值（那时还不知道 alias）", async () => {
    valuesState.data = rammusValues();
    abilitiesState.error = new Error("LcuNotRunning");
    const wrapper = mountPanel(33);
    await flushPromises();
    await flushPromises();
    expect(valuesState.calls).toBe(0);
    wrapper.unmount();
  });

  it("带加成系数的项单独列一行，并写明乘的是哪个属性", async () => {
    valuesState.data = rammusValues();
    const wrapper = mountRammus();
    await flushPromises();
    await flushPromises();
    const scaling = wrapper.get(".abilities__scaling");
    expect(scaling.text()).toContain("PowerBallDamage");
    // 关键：不是干巴巴的「AP」，而是「法术强度」——用户问的就是「它是什么加成」。
    expect(scaling.text()).toContain("+ 1 法术强度");
    // 正文里的那一格只放基础值，不带系数，否则会被读成一个数。
    expect(wrapper.get(".abilities__text").text()).not.toContain("+ 1 ");
    wrapper.unmount();
  });
});

/**
 * 用户 2026-09-30 报的原文（铸星龙王 Q），逐条钉死。
 *
 * 他贴的就是这一段，里面有三种以前会「漏出原文」的写法：
 * - `<font color='#3458eb'>2 / 2 / … 星尘</font>`（标签被转义成字面量）
 * - `@AOEModifier*100@`（正则不认 `*`，整个漏出）
 * - `@SpellModifierDescriptionAppend@`（客户端拼接位，本来就该空）
 */
describe("技能面板：龙王 Q 的原文（用户报的那段）", () => {
  /** 龙王 Q 原文，照用户贴的一字不改。 */
  const ASOL_Q =
    "奥瑞利安·索尔喷吐星焰，至多持续@MaxChannelDuration@秒，每秒对首个命中的敌人造成" +
    "<magicDamage>@DamagePerSecond@魔法伤害</magicDamage>并对附近的敌人们造成@AOEModifier*100@%此伤害。" +
    "<br><br>对相同敌人每进行一整秒的吐息，就会造成一次爆发性的" +
    "<magicDamage>@BurstDamage@魔法伤害</magicDamage>外加" +
    "<magicDamage>@BurstBonusTrueDamageToChamps@最大生命值的魔法伤害</magicDamage>，并且如果这个敌人是英雄，" +
    "还会吸收<font color='#3458eb'>2 / 2 / 2 / 2 / 2 / 2 / 2星尘</font>。@SpellModifierDescriptionAppend@";

  function mountAsol() {
    const data = abilitiesFixture({ championId: 136, alias: "AurelionSol", name: "铸星龙王" });
    data.spells[0] = { ...data.spells[0], name: "星河冲荡", dynamicDescription: ASOL_Q };
    abilitiesState.data = data;
    valuesState.data = {
      alias: "AurelionSol",
      spells: [
        {
          slot: "q",
          values: {
            MaxChannelDuration: { values: [3.25, 3.25, 3.25, 3.25, 3.25, 9999, 9999] },
            DamagePerSecond: { values: [30, 45, 60, 75, 90], ratio: 0.6, ratioStat: "AP" },
            // 客户端文案写 `@AOEModifier*100@%`，原始值就是 0.5。
            AOEModifier: { values: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], percent: true },
            BurstDamage: { values: [50, 60, 70, 80, 90], ratio: 0.35, ratioStat: "AP" },
          },
        },
      ],
    } as ChampionAbilityValues;
    return mountPanel(136);
  }

  it("`@AOEModifier*100@` 算成 50%，不再把变量名和 `*100` 露在界面上", async () => {
    const wrapper = mountAsol();
    await flushPromises();
    await flushPromises();
    const texts = wrapper.findAll(".abilities__text");
    const text = texts[texts.length - 1].text();
    expect(text).not.toContain("AOEModifier");
    expect(text).not.toContain("*100");
    // 客户端原文是 `@AOEModifier*100@%此伤害`——`%` 由文案自己带，
    // 所以这里必须是 `50%` 而**不是** `50%%`（2026-09-30 实测踩到过双百分号）。
    expect(text).toContain("50%此伤害");
    expect(text).not.toContain("%%");
    wrapper.unmount();
  });

  it("`<font color>` 的星尘按色渲染，不再是可见的标签文本", async () => {
    const wrapper = mountAsol();
    await flushPromises();
    await flushPromises();
    const html = wrapper.get(".abilities__body").html();
    expect(html).not.toContain("&lt;font");
    expect(html).not.toContain("<font");
    expect(html).toContain('style="color:#3458eb"');
    expect(wrapper.get(".abilities__body").text()).toContain("星尘");
    wrapper.unmount();
  });

  it("「+0.6 法术强度」写在面板上——这就是「它是什么加成」的答案", async () => {
    const wrapper = mountAsol();
    await flushPromises();
    await flushPromises();
    const scaling = wrapper.get(".abilities__scaling").text();
    expect(scaling).toContain("DamagePerSecond");
    expect(scaling).toContain("+ 0.6 法术强度");
    // 爆发那一段也是法强加成（客户端文案没写，我们补上）。
    expect(scaling).toContain("BurstDamage");
    expect(scaling).toContain("+ 0.35 法术强度");
    wrapper.unmount();
  });

  it("变量速查表把每个 `@…@` 的取值都列出来（含百分比口径）", async () => {
    const wrapper = mountAsol();
    await flushPromises();
    await flushPromises();
    const values = wrapper.get(".abilities__values").text();
    expect(values).toContain("MaxChannelDuration");
    expect(values).toContain("3.25 / 3.25 / 3.25 / 3.25 / 3.25 / 9999 / 9999");
    // 分数按百分数显示，不能是 0.5。
    expect(values).toContain("AOEModifier");
    expect(values).toContain("50%");
    expect(values).not.toContain("0.5");
    wrapper.unmount();
  });

  it("仍然取不到的变量会明说原因，不会假装全都填上了", async () => {
    const wrapper = mountAsol();
    await flushPromises();
    await flushPromises();
    const note = wrapper.get(".abilities__note").text();
    // `BurstBonusTrueDamageToChamps` 依赖星尘层数，本地算不出来 → 保留原文并说明。
    expect(note).toContain("按英雄等级与");
    // 而已经填上的那几个（含表达式形式）不能被报成缺失。
    expect(note).not.toContain("AOEModifier");
    wrapper.unmount();
  });

  it("只有 `@SpellModifierDescriptionAppend@` 剩下时，解释成「拼接加成的位置」", async () => {
    // 把龙王 Q 里那个依赖星尘层的变量也填上，就只剩拼接位了。
    const data = abilitiesFixture({ championId: 136, alias: "AurelionSol", name: "铸星龙王" });
    data.spells[0] = {
      ...data.spells[0],
      name: "星河冲荡",
      dynamicDescription: "造成@AOEModifier*100@%此伤害。@SpellModifierDescriptionAppend@",
    };
    abilitiesState.data = data;
    valuesState.data = {
      alias: "AurelionSol",
      spells: [{ slot: "q", values: { AOEModifier: { values: [0.5], percent: true } } }],
    } as ChampionAbilityValues;
    const wrapper = mountPanel(136);
    await flushPromises();
    await flushPromises();
    const note = wrapper.get(".abilities__note").text();
    expect(note).toContain("拼接装备与符文加成");
    // 不能退化成那句「取不到值」的泛泛说明。
    expect(note).not.toContain("按英雄等级与");
    wrapper.unmount();
  });
});
