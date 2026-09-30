import { describe, expect, it } from "vitest";
import { flattenAbilityValues, formatLevelValues, remainingPlaceholders, renderAbilityText } from "./abilityText";

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
    expect(withRatio.PowerBallDamage).toBe("40 / 80（+1 AP）");
  });
});
