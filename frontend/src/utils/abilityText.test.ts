import { describe, expect, it } from "vitest";
import {
  flattenAbilityValues,
  formatLevelValues,
  formatPercentValues,
  remainingPlaceholders,
  renderAbilityText,
  statLabel,
} from "./abilityText";

/** 真机上拉莫斯 Q 的原文（用户 2026-09-30 贴的就是这段）。 */
const RAMMUS_Q =
  "拉莫斯蜷缩为球状，获得<speed>@MinimumMoveSpeed@移动速度</speed>，并在@RollDuration@秒里持续加速至" +
  "<speed>@MaximumMoveSpeed@移动速度</speed>。拉莫斯会在与一名敌人碰撞后停下，对附近的敌人们造成" +
  "<magicDamage>@PowerBallDamage@魔法伤害</magicDamage>、<status>击退</status>、和持续@SlowDuration@秒的" +
  "@SlowPercent@%<status>减速</status>。<br><br><recast>再次施放</recast>：拉莫斯提前结束这个技能。" +
  "@SpellModifierDescriptionAppend@";

describe("技能文案：富文本标签", () => {
  it("把官方样式标签换成 span，而不是原样印出来", () => {
    const html = renderAbilityText("<speed>加速</speed>", {});
    expect(html).toBe('<span class="ab-speed">加速</span>');
    expect(html).not.toContain("<speed>");
  });

  it("<br> 变成真换行，不再显示成字面量", () => {
    expect(renderAbilityText("上<br>下")).toBe("上<br />下");
    expect(renderAbilityText("上<br/>下")).toBe("上<br />下");
  });

  it("拉莫斯 Q：标签全部消化，正文一个字不少", () => {
    const html = renderAbilityText(RAMMUS_Q, {});
    for (const tag of ["speed", "magicDamage", "status", "recast"]) {
      expect(html).not.toContain(`<${tag}>`);
      expect(html).not.toContain(`</${tag}>`);
    }
    // 关键措辞必须还在
    expect(html).toContain("拉莫斯蜷缩为球状");
    expect(html).toContain("再次施放");
    expect(html).toContain("击退");
    // 换行真的发生了
    expect(html).toContain("<br /><br />");
  });

  it("标签不闭合也不会把后面的正文吞掉", () => {
    const html = renderAbilityText("开始<speed>一直没关", {});
    expect(html).toContain("开始");
    expect(html).toContain("一直没关");
    // 自动补上闭合
    expect(html.endsWith("</span>")).toBe(true);
  });

  it("白名单外的标签当文本，不执行", () => {
    const html = renderAbilityText('<script>alert(1)</script>伤害 100', {});
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
    expect(html).toContain("伤害 100");
  });

  it("正文里的 < > & 也不会破坏结构", () => {
    const html = renderAbilityText("造成 5 < 10 且 a & b", {});
    expect(html).toContain("&lt;");
    expect(html).toContain("&amp;");
  });
});

describe("技能文案：占位符", () => {
  it("有值的占位符被替换，并带上数值样式", () => {
    const html = renderAbilityText("持续@RollDuration@秒", { values: { RollDuration: "6" } });
    expect(html).toBe('持续<span class="ab-value">6</span>秒');
    expect(html).not.toContain("@RollDuration@");
  });

  it("没有值的占位符保留原样，标成 placeholder（绝不编数字）", () => {
    const html = renderAbilityText("获得@MinimumMoveSpeed@移速", {});
    expect(html).toContain("@MinimumMoveSpeed@");
    expect(html).toContain('class="ab-placeholder"');
  });

  it("一个占位符取值失败不影响它前后的替换", () => {
    const html = renderAbilityText("@A@和@B@", { values: { A: "1" } });
    expect(html).toContain('<span class="ab-value">1</span>');
    expect(html).toContain("@B@");
  });

  it("带命名空间的占位符能用末段名字取到值", () => {
    const html = renderAbilityText("@spell.PowerBall:PowerBallDamage@点伤害", { values: { PowerBallDamage: "40" } });
    expect(html).toContain('<span class="ab-value">40</span>');
  });

  it("单独的 @ 当普通字符（不吞掉邮箱那种写法）", () => {
    const html = renderAbilityText("联系 a@b 就好", {});
    expect(html).toContain("a@b");
  });

  it("remainingPlaceholders 只报没取到值的那些", () => {
    const left = remainingPlaceholders(RAMMUS_Q, { RollDuration: "6", SlowPercent: "30" });
    expect(left).toContain("MinimumMoveSpeed");
    expect(left).toContain("SpellModifierDescriptionAppend");
    expect(left).not.toContain("RollDuration");
    expect(left).not.toContain("SlowPercent");
  });
});

/**
 * 用户 2026-09-30 报的两件事，逐条钉住：
 *
 * 1. 文案里有 `<font color='#3458eb'>星尘</font>`，以前整段被转义成可见文本；
 * 2. 文案里有 `@AOEModifier*100@` 这种**带运算的表达式**，以前因为正则不认 `*`
 *    而整段漏成原文——这才是用户看到「它写了一个变量的名字」的地方。
 */
describe("技能文案：关键词着色（<font color>）", () => {
  it("font 标签不再原样印出来，改成按 color 着色的 span", () => {
    // 龙王被动原文：`<font color='#3458eb'>星尘</font>`
    const html = renderAbilityText("化为<font color='#3458eb'>星尘</font>，星尘可用", {});
    expect(html).not.toContain("<font");
    expect(html).not.toContain("</font>");
    expect(html).toContain("星尘");
    expect(html).toContain('style="color:#3458eb"');
    expect(html).toContain("ab-fontcolor");
  });

  it("单引号 / 双引号 / 无引号三种写法都认", () => {
    for (const raw of ['<font color="#ff0000">红</font>', "<font color='#ff0000'>红</font>", '<font color=#ff0000>红</font>']) {
      const html = renderAbilityText(raw, {});
      expect(html).toContain('style="color:#ff0000"');
      expect(html).not.toContain("<font");
    }
  });

  it("颜色只放行十六进制，其余一律丢弃（防止把任意字符串塞进 style）", () => {
    const html = renderAbilityText("<font color='red;position:fixed'>危险</font>", {});
    expect(html).not.toContain("position:fixed");
    expect(html).not.toContain("red;");
    // 文字还在，只是退回默认色
    expect(html).toContain("危险");
    expect(html).toContain("ab-fontcolor");
    expect(html).not.toContain("style=");
  });

  it("font 里套占位符也能一起工作（龙王 R 就是这么写的）", () => {
    const html = renderAbilityText("吸收<font color='#3458eb'>@MassStolen@星尘</font>", { values: { MassStolen: "2" } });
    // 顺序必须是：开着色 span → 开数值 span → 关数值 → 文字 → 关着色。
    expect(html).toBe('吸收<span class="ab-fontcolor" style="color:#3458eb"><span class="ab-value">2</span>星尘</span>');
    expect(html).not.toContain("@MassStolen@");
  });
});

describe("技能文案：带运算的占位符表达式（@Name*100@）", () => {
  it("*100 的分数被算成百分数（0.5 → 50），不把 `*100` 印出来", () => {
    // 龙王 Q 原文：`@AOEModifier*100@%此伤害`
    const html = renderAbilityText("造成@AOEModifier*100@%此伤害", { values: { AOEModifier: "0.5" } });
    expect(html).toBe('造成<span class="ab-value">50</span>%此伤害');
    expect(html).not.toContain("AOEModifier");
    expect(html).not.toContain("*100");
  });

  it("逐级变化的百分数也对（猴子 Q 破甲 5/10/15%）", () => {
    const html = renderAbilityText("移除目标@ArmorShredPercent*100@%护甲", {
      values: { ArmorShredPercent: "0.05" },
    });
    expect(html).toContain('<span class="ab-value">5</span>%护甲');
  });

  it("`+常数` 的形式也能算（不是只有 *100）", () => {
    const html = renderAbilityText("持续@ShieldDuration+0.4@秒", { values: { ShieldDuration: "2" } });
    expect(html).toContain('<span class="ab-value">2.4</span>秒');
  });

  it("取不到值时保留**完整原文**（含 *100），让人看出这是官方变量", () => {
    const html = renderAbilityText("造成@AOEModifier*100@%此伤害", {});
    expect(html).toContain("@AOEModifier*100@");
    expect(html).toContain('class="ab-placeholder"');
  });

  it("逐级数组遇到 *100 不做整体运算，原样保留（数组没法整体乘）", () => {
    const html = renderAbilityText("@SomeArray*100@", { values: { SomeArray: "1 / 2 / 3" } });
    expect(html).toContain('<span class="ab-value">1 / 2 / 3</span>');
  });

  it("remainingPlaceholders 认表达式：填上了就不该报成缺失", () => {
    // 这是最容易出错的地方——若用含 `*100` 的整串当名字去查，会误报「没取到值」，
    // 界面上就会出现「已填充」和「没取到值」两句自相矛盾的说明。
    const raw = "造成@AOEModifier*100@%此伤害，获得@MinimumMoveSpeed@移速";
    const left = remainingPlaceholders(raw, { AOEModifier: "50" });
    expect(left).not.toContain("AOEModifier");
    expect(left).toContain("MinimumMoveSpeed");
  });

  it("渲染与「剩余占位符」判定用的是同一套解析（不会自相矛盾）", () => {
    const values = { AOEModifier: "0.5" };
    const raw = "造成@AOEModifier*100@%此伤害";
    expect(renderAbilityText(raw, { values })).not.toContain("@");
    expect(remainingPlaceholders(raw, values)).toEqual([]);
  });
});

/**
 * 逐级数值的格式化。
 *
 * 这一层的口径是「**照抄**官方数组，不补齐不截断」：技能能点 5 级但官方数组常给到
 * 7 格（含被动加成），少给一格都会让人以为「5 级就这么多」。整数不带 `.0`——
 * 亚索 E 的 0.5 秒冷却必须留住。
 */
describe("技能数值：逐级数组的格式化", () => {
  it("逐级数组拼成 ' / ' 分隔的一行", () => {
    expect(formatLevelValues([40, 80, 120, 160, 200])).toBe("40 / 80 / 120 / 160 / 200");
  });

  it("整数不带小数点，小数保留（亚索 E 的 0.5）", () => {
    expect(formatLevelValues([6, 6, 6])).toBe("6 / 6 / 6");
    expect(formatLevelValues([0.5, 0.5, 0.4, 0.3, 0.2])).toBe("0.5 / 0.5 / 0.4 / 0.3 / 0.2");
  });

  it("超过 8 格只给首尾，免得把一行撑破", () => {
    const long = Array.from({ length: 12 }, (_, index) => (index + 1) * 10);
    expect(formatLevelValues(long)).toBe("10 … 120");
  });

  it("空数组给空串，而不是 0（0 会被当成真数据）", () => {
    expect(formatLevelValues([])).toBe("");
  });

  it("拍平成渲染用的映射；不回填没有逐级数组的项", () => {
    const flat = flattenAbilityValues({
      PowerBallDamage: { values: [40, 80, 120] },
      OnlyRatio: { values: [] },
    });
    expect(flat.PowerBallDamage).toBe("40 / 80 / 120");
    // 没有逐级数组 → 不进表 → 渲染层保留原文。
    expect(flat.OnlyRatio).toBeUndefined();
  });

  it("默认不把系数拼进同一格（系数是另一个变量）", () => {
    const flat = flattenAbilityValues({ PowerBallDamage: { values: [40, 80], ratio: 1, ratioStat: "AP" } });
    expect(flat.PowerBallDamage).toBe("40 / 80");
    const withRatio = flattenAbilityValues(
      { PowerBallDamage: { values: [40, 80], ratio: 1, ratioStat: "AP" } },
      { withRatio: true },
    );
    expect(withRatio.PowerBallDamage).toBe("40 / 80（+1 法术强度）");
  });
});

/**
 * 「它是什么加成」——用户 2026-09-30 的重点问题。
 *
 * 正文里的 `@BurstBonusTrueDamageToChamps@` 只给了一个变量名，读者没法知道它乘的是
 * 法强、攻击力还是最大生命值。所以后端把系数乘的**属性**单独给出来（`ratioStat`），
 * 前端在这里翻译成人话。
 */
describe("技能数值：加成归属（什么加成）", () => {
  it("属性代码翻成中文", () => {
    expect(statLabel("AP")).toBe("法术强度");
    expect(statLabel("AD")).toBe("攻击力");
    expect(statLabel("MaxHealth")).toBe("最大生命值");
    expect(statLabel("Armor")).toBe("护甲");
    expect(statLabel("MR")).toBe("魔法抗性");
  });

  it("认不出来的代码原样给出，不吞成「加成」", () => {
    // 吞掉会让人以为「这个变量就是固定加成」——不如把原始代码亮出来。
    expect(statLabel("SomeWeirdStat")).toBe("SomeWeirdStat");
    // 真的没有时才说「加成」。
    expect(statLabel(undefined)).toBe("加成");
  });

  it("带系数时写出「+0.6 法术强度」（龙王 Q 的真实形状）", () => {
    const flat = flattenAbilityValues(
      { DamagePerSecond: { values: [30, 45, 60, 75, 90], ratio: 0.6, ratioStat: "AP" } },
      { withRatio: true },
    );
    expect(flat.DamagePerSecond).toBe("30 / 45 / 60 / 75 / 90（+0.6 法术强度）");
  });

  it("攻击力加成的也认得（金克丝 Q → RocketTAD）", () => {
    const flat = flattenAbilityValues(
      { RocketDamage: { values: [10, 20], ratio: 1.1, ratioStat: "AD" } },
      { withRatio: true },
    );
    expect(flat.RocketDamage).toBe("10 / 20（+1.1 攻击力）");
  });
});

/**
 * 分数按百分比显示。
 *
 * 后端标了 `percent` 的项（`SlowAmount` = 0.2…0.8、`AOEModifier` = 0.5）不能照抄成
 * `0.5`——那会被读成「0.5 点减速」。用户看到的客户端文案是 `50%`。
 */
describe("技能数值：分数按百分比显示", () => {
  it("0.5 → 50%", () => {
    expect(formatPercentValues([0.5])).toBe("50%");
  });

  it("逐级的 0.2…0.8 → 20 / 30 / … / 80%（百分号只写一次，和客户端一致）", () => {
    // 客户端原文是 `@SlowAmount*100@%`——`%` 在占位符**外面**，所以这里也只补一次。
    expect(formatPercentValues([0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])).toBe("20 / 30 / 40 / 50 / 60 / 70 / 80%");
  });

  it("浮点误差不会漏出来（0.07×100 不能变成 7.000000000000001）", () => {
    expect(formatPercentValues([0.07, 0.08, 0.09])).toBe("7 / 8 / 9%");
  });

  it("带 percent 标记的项走百分比；喂给正文时**不带**百分号（文案自己带）", () => {
    const flat = flattenAbilityValues({
      AOEModifier: { values: [0.5], percent: true },
      QBaseDamage: { values: [40, 80] },
    });
    // 客户端原文是 `@AOEModifier*100@%`——`%` 在占位符外面，所以这里**必须**不带，
    // 否则正文会渲染成 `50%%`（2026-09-30 实测踩到过）。
    expect(flat.AOEModifier).toBe("50");
    // 40/80 是伤害点数，不是分数——绝不能被乘 100
    expect(flat.QBaseDamage).toBe("40 / 80");
  });

  it("带 percent 标记的项在取值表里**要**带百分号（孤立的数字看不出是百分数）", () => {
    expect(formatPercentValues([0.5], { withSign: true })).toBe("50%");
    expect(formatPercentValues([0.5], { withSign: false })).toBe("50");
    // 默认带
    expect(formatPercentValues([0.5])).toBe("50%");
  });
});
