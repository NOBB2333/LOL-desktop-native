import { describe, expect, it } from "vitest";
import {
  abilityRatioItems,
  detectUnitFromText,
  flattenAbilityValues,
  formatAbilityRatios,
  formatEntryValues,
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
    expect(left).not.toContain("RollDuration");
    expect(left).not.toContain("SlowPercent");
    // 引擎散文占位符仍然**要**报出来：技能面板正是靠它判断「剩下的全是拼接位」，
    // 从而显示「末尾没有显示内容的那一处是拼接装备与符文加成的位置」那句说明。
    // 渲染时它会被抹掉（见 `PROSE_PLACEHOLDERS`），但这里不能跟着一起消失。
    expect(left).toContain("SpellModifierDescriptionAppend");
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
 * 跨技能引用：`@spell.<短名>:<变量>@`。
 *
 * 2026-09-30 全英雄扫描：**22 个英雄**这么写（斯莫德的 Q/W/E 加成写在被动里、
 * 拉莫斯 R 指向 Q、慧指向 HweiQE…）。后端现在按**完整名字**落值，
 * 所以这里必须能用完整名字查到；同时保留「只给短名」的降级。
 */
describe("技能文案：跨技能引用（@spell.X:Y@）", () => {
  const SMOLDER_Q =
    "斯莫德喷出烈焰，造成@TotalDamage@物理伤害 + @spell.SmolderP:Passive_QDamageIncrease@魔法伤害。";

  it("按完整名字查到值时替换掉（后端就是这么落值的）", () => {
    const html = renderAbilityText(SMOLDER_Q, {
      values: {
        TotalDamage: "50 / 60 / 70 / 80 / 90 / 100 / 110",
        "spell.SmolderP:Passive_QDamageIncrease": "0.25 / 0.25 / 0.25 / 0.25 / 0.25 / 0.25 / 0.25",
      },
    });
    expect(html).not.toContain("spell.SmolderP");
    expect(html).not.toContain("@");
    expect(html).toContain("0.25 / 0.25");
  });

  it("后端只给短名时也能查到（降级到冒号后的部分）", () => {
    const html = renderAbilityText(SMOLDER_Q, {
      values: {
        TotalDamage: "50 / 60",
        Passive_QDamageIncrease: "0.25",
      },
    });
    expect(html).not.toContain("spell.SmolderP");
    expect(html).toContain("0.25");
  });

  it("查不到时保留完整原文，不能悄悄吞掉", () => {
    const html = renderAbilityText(SMOLDER_Q, { values: { TotalDamage: "50" } });
    expect(html).toContain("ab-placeholder");
    expect(html).toContain("@spell.SmolderP:Passive_QDamageIncrease@");
  });

  it("remainingPlaceholders 与渲染同口径：完整名字给了值就不报缺失", () => {
    // 若这里只比短名，跨技能引用就会一边显示 0.25、一边说「取不到值」。
    const values = { "spell.SmolderP:Passive_QDamageIncrease": "0.25" };
    expect(remainingPlaceholders(SMOLDER_Q, values)).toEqual(["TotalDamage"]);
  });
});

/**
 * 国服文案的列表与重点标记：`<li>` + `<keywordMajor>`。
 *
 * 2026-09-30 全英雄扫描：`<li>` 出现在 **8 个英雄**、`keywordMajor` 出现在
 * **108 个英雄**（超过三分之一个英雄池）。斯莫德 Q 的三档进化就是这么写的——
 * 不处理就会挤成一整段并印出标签字面量（用户报的正是这个）。
 */
describe("技能文案：<li> 列表与 <keywordMajor> 重点标记", () => {
  const SMOLDER_Q_TIERS =
    "获得以下效果：<li><keywordMajor>@StackTier1@层</keywordMajor>：对目标周围的所有敌人造成伤害。" +
    "<li><keywordMajor>@StackTier2@层</keywordMajor>：在目标后侧引发@Tier2_NumberOfBlowback@次爆炸。" +
    "<li><keywordMajor>@StackTier3@层</keywordMajor>：灼烧目标。@SpellModifierDescriptionAppend@";

  it("`<li>` 变成块级行，三档不再挤成一句话", () => {
    const html = renderAbilityText(SMOLDER_Q_TIERS, {
      values: { StackTier1: "25 / 25", StackTier2: "125 / 125", StackTier3: "225 / 225", Tier2_NumberOfBlowback: "2" },
    });
    expect(html).not.toContain("<li>");
    expect(html).not.toContain("</li>");
    // 三档各占一行 → 至少两个块级 listitem
    expect(html.match(/ab-listitem/g)?.length ?? 0).toBeGreaterThanOrEqual(3);
    expect(html).toContain("25 / 25");
    expect(html).toContain("125 / 125");
    expect(html).toContain("225 / 225");
  });

  it("`<keywordMajor>` 不再原样印出来，且内容保留", () => {
    const html = renderAbilityText(SMOLDER_Q_TIERS, {});
    expect(html).not.toContain("keywordMajor");
    expect(html).not.toContain("<keywordMajor>");
    expect(html).toContain("ab-keyword");
    expect(html).toContain("层");
    expect(html).toContain("对目标周围的所有敌人造成伤害");
  });

  it("`<li>` 不闭合也不会把后面的内容吞掉（客户端常常只开不闭）", () => {
    // 斯莫德三档就是连着写 `<li>` 而中间不闭合的。
    const html = renderAbilityText("<li>第一档<li>第二档<li>第三档", {});
    expect(html).toContain("第一档");
    expect(html).toContain("第二档");
    expect(html).toContain("第三档");
    expect(html.match(/ab-listitem/g)?.length ?? 0).toBeGreaterThanOrEqual(3);
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
    expect(withRatio.PowerBallDamage).toBe("40 / 80 + 100% 法术强度");
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

  it("带系数时写出「+60% 法术强度」（龙王 Q 的真实形状）", () => {
    const flat = flattenAbilityValues(
      { DamagePerSecond: { values: [30, 45, 60, 75, 90], ratio: 0.6, ratioStat: "AP" } },
      { withRatio: true },
    );
    expect(flat.DamagePerSecond).toBe("30 / 45 / 60 / 75 / 90 + 60% 法术强度");
  });

  it("攻击力加成的也认得（金克丝 Q → RocketTAD）", () => {
    const flat = flattenAbilityValues(
      { RocketDamage: { values: [10, 20], ratio: 1.1, ratioStat: "AD" } },
      { withRatio: true },
    );
    expect(flat.RocketDamage).toBe("10 / 20 + 110% 攻击力");
  });

  it("系数逐级不同时按级展开（金克丝 W → AD 系数 1.4 涨到 1.8）", () => {
    // 只印第 0 格会让「升到 5 级」的加成看上去和 1 级一样。
    const flat = flattenAbilityValues(
      {
        TotalDamage: {
          values: [10, 45, 80, 115, 150],
          ratio: 1.4,
          ratios: [1.4, 1.5, 1.6, 1.7, 1.8],
          ratioStat: "AD",
        },
      },
      { withRatio: true },
    );
    expect(flat.TotalDamage).toBe("10 / 45 / 80 / 115 / 150 + 140 / 150 / 160 / 170 / 180% 攻击力");
  });

  it("系数全等时只写一个数（后端不写 `ratios`，别退化成逐级重复）", () => {
    const flat = flattenAbilityValues(
      { DamagePerSecond: { values: [30, 45, 60], ratio: 0.55, ratioStat: "AP" } },
      { withRatio: true },
    );
    expect(flat.DamagePerSecond).toBe("30 / 45 / 60 + 55% 法术强度");
  });

  it("只有属性、没有系数时不编系数（龙王 Q 的最大生命值那段）", () => {
    // `BurstBonusTrueDamageToChamps` 只有 `ratioStat`：它是「按最大生命值算」，
    // 但没有「基础值 + 系数」的形状。**不能**凭空写一个系数出来。
    const flat = flattenAbilityValues(
      { BurstBonusTrueDamageToChamps: { values: [2, 2], ratioStat: "MaxHealth" } },
      { withRatio: true },
    );
    // 值照常给（星尘层数 2），但不带任何「+ N 最大生命值」。
    expect(flat.BurstBonusTrueDamageToChamps).toBe("2 / 2");
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

/**
 * 单位必须**以客户端原文为准**，不能靠「值像不像分数」猜。
 *
 * 用户 2026-10-03 报的「怎么可能击飞 50 秒」就是这个：CDragon 的
 * `KnockupDurationTOOLTIPONLY = 0.5` 落在 `[0,1]`，被当成百分数乘了 100。
 * 而客户端原文明明写着「击飞敌人@KnockupDuration@秒」——单位就在占位符后面。
 */
describe("技能数值：单位以正文声明为准（击飞 0.5 秒不是 50 秒）", () => {
  /** 真机原文（瑟庄妮 Q，2026-10-03 从国服客户端抓的）。 */
  const SEJUANI_Q =
    "瑟庄妮向前冲锋，将敌人<status>击飞</status>@KnockupDuration@秒。" +
    "冲锋会对敌人造成<magicDamage>@TotalDamage@魔法伤害</magicDamage>，" +
    "并@StunDuration@秒<status>击退</status>敌人，" +
    "同时施加持续@SlowDuration@秒的@SlowAmount*100@%<status>减速</status>。";

  it("detectUnitFromText 从占位符后面读出单位", () => {
    expect(detectUnitFromText(SEJUANI_Q, "KnockupDuration")).toBe("number");
    expect(detectUnitFromText(SEJUANI_Q, "StunDuration")).toBe("number");
    expect(detectUnitFromText(SEJUANI_Q, "SlowDuration")).toBe("number");
    // ⚠️ `%` **不**返回 "percent"：它只是单位符号，不代表值是 0~1 的分数。
    // `@SlowAmount*100@` 的 0.25 要靠占位符里的 `*100` 换算，不是靠这里。
    expect(detectUnitFromText(SEJUANI_Q, "SlowAmount*100")).toBeNull();
    // 正文里没出现的变量判不出来（返回 null，交给上层退回后端的 unit）
    expect(detectUnitFromText(SEJUANI_Q, "MinimumMoveSpeed")).toBeNull();
  });

  it("`%` 不会被当成「这是分数」——SlowPercent 的 30 就是 30，不是 3000", () => {
    // `@SlowPercent@%` 的取值本来就是 30/40/…（已是百分数），乘 100 会变成 3000%。
    // 这条守着 2026-10-03 引入 detectUnitFromText 时差点踩进去的坑。
    const text = "造成<magicDamage>@TotalDamage@魔法伤害</magicDamage>，并造成@SlowPercent@%<status>减速</status>。";
    expect(detectUnitFromText(text, "SlowPercent")).toBeNull();
    const flat = flattenAbilityValues(
      { SlowPercent: { values: [30, 40, 50, 60, 70, 80, 90] } },
      { text },
    );
    expect(flat.SlowPercent).toBe("30 / 40 / 50 / 60 / 70 / 80 / 90");
  });

  it("击飞时长 0.5 秒不再被印成 50 秒（后端仍标 percent 也能纠正）", () => {
    // ⚠️ 故意喂 `percent: true`——老后端就是按值域判的，会标成 true。
    // 正文的「秒」必须能**覆盖**它，这就是修复的全部意义。
    const flat = flattenAbilityValues(
      {
        KnockupDuration: { values: [0.5, 0.5, 0.5], percent: true },
        StunDuration: { values: [1, 1, 1], percent: true },
        TotalDamage: { values: [40, 90, 140] },
      },
      { text: SEJUANI_Q },
    );
    // 0.5 秒，不是 50 秒
    expect(flat.KnockupDuration).toBe("0.5 / 0.5 / 0.5");
    expect(flat.StunDuration).toBe("1 / 1 / 1");
    // 伤害不受影响
    expect(flat.TotalDamage).toBe("40 / 90 / 140");
  });

  it("真正的百分数仍然是百分数（别把这个功能一起改坏）", () => {
    // `SlowAmount` 是 0~1 的分数，后端会标 `percent: true` → 渲染成 25 / 30 / 35。
    // 正文里的 `%` 不参与判断（它只是符号），所以这里必须靠后端标记。
    const flat = flattenAbilityValues(
      { SlowAmount: { values: [0.25, 0.3, 0.35], percent: true } },
      { text: SEJUANI_Q },
    );
    expect(flat.SlowAmount).toBe("25 / 30 / 35");
  });

  it("正文渲染出来的击飞时长确实是 0.5 秒", () => {
    const values = flattenAbilityValues(
      { KnockupDuration: { values: [0.5, 0.5, 0.5], percent: true } },
      { text: SEJUANI_Q },
    );
    const html = renderAbilityText(SEJUANI_Q, { values });
    expect(html).toContain("击飞</span>");
    expect(html).toMatch(/0\.5 \/ 0\.5 \/ 0\.5<\/span>秒/);
    // 绝不能出现 50
    expect(html).not.toMatch(/50 \/ 50/);
  });

  it("同一个变量在正文里两种单位都出现时判不出来，退回后端的标记", () => {
    // `CooldownRefund`：有的文案写「缩短@CooldownRefund@秒」，有的写「减少@CooldownRefund@%」。
    const text = "冷却将缩短@CooldownRefund@秒，或减少@CooldownRefund@%。";
    expect(detectUnitFromText(text, "CooldownRefund")).toBeNull();
  });

  it("跨技能引用写法也能读出单位（@spell.PowerBall:KnockupDuration@）", () => {
    const text = "击飞@spell.PowerBall:KnockupDuration@秒。";
    expect(detectUnitFromText(text, "spell.PowerBall:KnockupDuration")).toBe("number");
    // 只写短名也认（前端查找本来就支持这一级降级）
    expect(detectUnitFromText(text, "KnockupDuration")).toBe("number");
  });

  it("formatEntryValues 优先看正文，没有正文才看后端标记", () => {
    const entry = { values: [0.5, 0.5], percent: true };
    // 有正文 → 听正文的（秒）
    expect(formatEntryValues("KnockupDuration", entry, "持续@KnockupDuration@秒。", true)).toBe("0.5 / 0.5");
    // 没正文 → 听后端的（百分数，带 %）
    expect(formatEntryValues("Something", entry, undefined, true)).toBe("50 / 50%");
  });
});

/**
 * 2026-10-03 用户报「技能里有些信息没识别出来」：客户端文案里确实还写着一批
 * 我们的白名单没收的标签。这一组盯的是**全量扫描 245 个英雄**得到的那张清单，
 * 以及跨技能引用的大小写、图标占位符这几个具体形状。
 */
describe("技能文案：国服实际出现过的标签与占位符", () => {
  it("spellActive / spellPassive 是「主动：」「被动：」的标签，不能印成字面量", () => {
    // 全量扫描：spellPassive 264 处、spellActive 212 处——是国服最常见的标签之一。
    expect(renderAbilityText("<spellActive>主动：</spellActive>释放一次魔爆")).toBe(
      '<span class="ab-active">主动：</span>释放一次魔爆',
    );
    expect(renderAbilityText("<spellPassive>被动：</spellPassive>x")).toBe('<span class="ab-passive">被动：</span>x');
  });

  it("attackSpeed / cooldown 这类「带单位的数值」按数值标签上色", () => {
    expect(renderAbilityText("<attackSpeed>275%攻击速度</attackSpeed>")).toBe('<span class="ab-speed">275%攻击速度</span>');
    // 名字大小写不固定，统一小写后匹配。
    expect(renderAbilityText("<Cooldown>10秒</Cooldown>")).toBe('<span class="ab-speed">10秒</span>');
  });

  it("词汇型标签（keywordStealth / onHit / evolve / scaleHealth…）不再印成字面量", () => {
    expect(renderAbilityText("<keywordStealth>真实视野</keywordStealth>")).toBe('<span class="ab-keyword">真实视野</span>');
    expect(renderAbilityText("<evolve>进化</evolve>")).toBe('<span class="ab-keyword">进化</span>');
    expect(renderAbilityText("<onHit>攻击特效</onHit>")).toBe('<span class="ab-keyword">攻击特效</span>');
    expect(renderAbilityText("<scaleHealth>@HPPerKill@最大生命值</scaleHealth>", { values: { HPPerKill: "4" } })).toBe(
      '<span class="ab-scale"><span class="ab-value">4</span>最大生命值</span>',
    );
  });

  it("阶段标签（charge / release / tap / hold）和「再次施放：」同款", () => {
    expect(renderAbilityText("<charge>开始蓄力：</charge>减伤")).toBe('<span class="ab-recast">开始蓄力：</span>减伤');
    expect(renderAbilityText("<hold>蓄力：</hold>x")).toBe('<span class="ab-recast">蓄力：</span>x');
  });

  it("<hr> 变成真分隔线（凯隐两种形态之间）", () => {
    expect(renderAbilityText("上<hr>下")).toBe('上<hr class="ab-separator" />下');
  });

  it("<ul> / <p> 既不印字面量，也不产生非法嵌套", () => {
    // 渲染结果本身塞在一个 <p> 里，再嵌一层 <p> 会被浏览器自动补闭合、挤乱版面。
    expect(renderAbilityText("<ul><li>四套智能战甲</li></ul>")).toBe(
      '<span class="ab-block"><span class="ab-listitem">四套智能战甲</span></span>',
    );
    expect(renderAbilityText("<p>皮肤介绍</p>")).toBe('<span class="ab-block">皮肤介绍</span>');
  });

  it("图标占位符 %i:xxx% 被摘掉（我们没有那套图标资源）", () => {
    // 全量扫描 999 处，其中 %i:cooldown% 974 处。
    expect(renderAbilityText("@Cooldown@秒 %i:cooldown%", { values: { Cooldown: "10" } })).toBe(
      '<span class="ab-value">10</span>秒 ',
    );
    expect(renderAbilityText("毒液伤害%i:OnHit% <OnHit>攻击特效</OnHit>")).toBe(
      '毒液伤害 <span class="ab-keyword">攻击特效</span>',
    );
  });

  it("引擎散文占位符 @SpellModifierDescriptionAppend@ 渲染时整段抹掉", () => {
    // 两份数据源都拿不到它：客户端 LCU 的 `spells[]` 里没这个键，CDragon 里连
    // `Modifier` / `Append` 字段都不存在。引擎本来就把「技能修饰器说明」拼在这里，
    // 瑞兹四个技能都是空的——以前会原样印出 `@SpellModifierDescriptionAppend@`。
    const raw = "使这个技能造成减速。@SpellModifierDescriptionAppend@";
    expect(renderAbilityText(raw)).toBe("使这个技能造成减速。");
    // 但它**仍然**要出现在 remainingPlaceholders 里，好让面板显示「这是拼接位」的说明
    // （那句说明写的就是「末尾没有显示内容的那一处」——抹掉渲染输出才让它名副其实）。
    expect(remainingPlaceholders(raw, {})).toEqual(["SpellModifierDescriptionAppend"]);
  });

  it("真的只是取不到值的占位符照旧标出来（别把口子开大）", () => {
    // 例外的只有引擎散文占位符这一个名单；其余缺值的一律保留原文可见。
    expect(renderAbilityText("@SomeUnknownVar@")).toContain("ab-placeholder");
    expect(renderAbilityText("@SomeUnknownVar@")).toContain("@SomeUnknownVar@");
    expect(remainingPlaceholders("@SomeUnknownVar@", {})).toEqual(["SomeUnknownVar"]);
  });

  it("仍然不认识的自定义标签照旧转义成文本（安全网）", () => {
    expect(renderAbilityText("<fooBar>x</fooBar>")).toBe("&lt;fooBar&gt;x&lt;/fooBar&gt;");
    // 顺带确认安全网还挡着真正的 HTML。
    expect(renderAbilityText("<script>alert(1)</script>")).not.toContain("<script>");
  });
});

describe("占位符：跨技能引用的大小写", () => {
  it("@Spell.RyzeR:X@ 能命中后端写的 spell.RyzeR:X（大写 S 也要认）", () => {
    // 客户端文案是 `@Spell.RyzeR:OverloadDamageBonus@`，而后端是按 CDragon 短名
    // 拼键的（`spell.RyzeR:OverloadDamageBonus`）。只认一种，用户看到的就是
    // 「明明有值，界面上却印着变量名」。
    const values = { "spell.RyzeR:OverloadDamageBonus": "10 / 20 / 30" };
    expect(renderAbilityText("@Spell.RyzeR:OverloadDamageBonus@%", { values })).toBe(
      '<span class="ab-value">10 / 20 / 30</span>%',
    );
  });

  it("大小写无关只是兜底，精确匹配优先", () => {
    const values = { "spell.A:Foo": "1", "Spell.A:Foo": "2" };
    expect(renderAbilityText("@Spell.A:Foo@", { values })).toBe('<span class="ab-value">2</span>');
  });

  it("取不到值时不再报成「缺失」（查找口径要和渲染一致）", () => {
    const values = { "spell.RyzeR:OverloadDamageBonus": "10" };
    expect(remainingPlaceholders("@Spell.RyzeR:OverloadDamageBonus@%", values)).toEqual([]);
  });
});

describe("技能数值：一个变量可以有多段加成", () => {
  it("ratioItems 全读出来（艾瑞莉娅 W = 攻击力 + 法强）", () => {
    const entry = { ratioItems: [{ ratio: 0.4, stat: "AD" }, { ratio: 0.5, stat: "AP" }] };
    expect(abilityRatioItems(entry)).toEqual([
      { ratio: 0.4, ratios: null, stat: "AD" },
      { ratio: 0.5, ratios: null, stat: "AP" },
    ]);
    expect(formatAbilityRatios(entry)).toBe("40% 攻击力 + 50% 法术强度");
  });

  it("没有 ratioItems 时回退到老字段（只有第一段）", () => {
    expect(formatAbilityRatios({ ratio: 1, ratioStat: "AP" })).toBe("100% 法术强度");
  });

  it("系数逐级不同就展开（金克丝 W）", () => {
    expect(formatAbilityRatios({ ratios: [1.4, 1.5, 1.6], ratioStat: "AD" })).toBe("140 / 150 / 160% 攻击力");
  });

  it("只有属性、没有系数的项不硬套系数（龙王 Q 的星尘项）", () => {
    expect(abilityRatioItems({ ratioStat: "MaxHealth" })).toEqual([{ ratio: null, ratios: null, stat: "MaxHealth" }]);
    // 它属于「按…算」，不属于「+ 系数」，所以不进加成那句话。
    expect(formatAbilityRatios({ ratioStat: "MaxHealth" })).toBe("");
  });

  it("系数 0 不算一段加成", () => {
    expect(abilityRatioItems({ ratio: 0, ratioStat: "AP" })).toEqual([{ ratio: null, ratios: null, stat: "AP" }]);
  });

  it("「最大法力值」有中文名（瑞兹 Q 的 2% 最大法力值）", () => {
    expect(statLabel("MaxMana")).toBe("最大法力值");
  });

  it("正文替换（withRatio）也带上多段", () => {
    const flat = flattenAbilityValues(
      { TotalDamage: { values: [40, 80], ratioItems: [{ ratio: 0.4, stat: "AD" }, { ratio: 0.5, stat: "AP" }] } },
      { withRatio: true },
    );
    expect(flat.TotalDamage).toBe("40 / 80 + 40% 攻击力 + 50% 法术强度");
  });
});
