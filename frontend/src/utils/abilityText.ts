/**
 * LoL 文案的富文本 → 安全 HTML。
 *
 * # 为什么必须自己转
 *
 * 客户端给的两段描述（`description` / `dynamicDescription`）**不是纯文本**，是一套
 * 自己的标记：
 *
 * ```
 * 拉莫斯蜷缩为球状，获得<speed>@MinimumMoveSpeed@移动速度</speed>，并在@RollDuration@秒里
 * 持续加速至<speed>@MaximumMoveSpeed@移动速度</speed>。…<br><br><recast>再次施放</recast>：…
 * ```
 *
 * 直接插值会把 `<speed>` 当字面量印出来；直接 `v-html` 又是把第三方字符串当 HTML 执行。
 * 所以这里做两件事：**白名单**挑出已知的样式标签，其余一律**当文本转义**。
 *
 * # 占位符
 *
 * `@Name@` 是官方模板变量。能拿到值的（`@RollDuration@` → 6）由调用方通过 `values` 传入；
 * 拿不到的（`@MinimumMoveSpeed@` 要看英雄实时属性）保留原样，由调用方补一句说明——
 * **绝不编一个数字**。
 */

/**
 * 标签 → class 后缀。只有这张表里的标签会被当成样式；其余全部转义成文本。
 */
const TAG_CLASSES: Record<string, string> = {
  // 数值类型
  speed: "speed",
  magicdamage: "magic",
  physicaldamage: "physical",
  truedamage: "true",
  healing: "healing",
  shield: "shield",
  // 状态与行为
  status: "status",
  recast: "recast",
  spellname: "spell",
  attention: "attention",
  passive: "passive",
  active: "active",
  /**
   * `spellPassive` / `spellActive`——国服文案里**真正的**「被动：」「主动：」标签。
   *
   * ⚠️ 别和上面那对弄混：`<passive>` / `<active>` 只在少数英雄用（20 / 14 处），
   * `<spellPassive>` / `<spellActive>` 才是常态——2026-10-03 全量扫描 245 个英雄，
   * 前者 264 处、后者 212 处。不加进来就会被当文本转义，界面上直接印出
   * `<spellActive>主动：</spellActive>` 这种字面量（用户 2026-10-03 报的）。
   */
  spellpassive: "passive",
  spellactive: "active",
  /**
   * 「开始蓄力 / 释放 / 秒放 / 蓄力」这类**阶段标签**（加里奥 W、沃里克 E…）。
   * 和「再次施放」是同一个角色：一句动作的导语。共用 `recast` 的样式。
   */
  charge: "recast",
  release: "recast",
  tap: "recast",
  hold: "recast",
  /**
   * 一堆「关键词上色」标签，语义都是「这是个机制名词，给它一点强调」。
   *
   * 逐个列是因为**上色方式不同**：`keywordMajor` 走 `<font color>`（内联色），
   * 这些没有颜色属性，统一走 `.ab-keyword` 的中性强调色。
   * 2026-10-03 全量扫描：`keywordStealth` 86、`onHit` 38、`toggle` 28、`evolve` 16、
   * `keywordName` 6、`magicPen`/`danger`/`factionIonia1`/`specialRules`/`lifeSteal`/
   * `armorPen`/`gold`/`slow`/`omnivamp` 各 2~4 处。
   */
  keywordstealth: "keyword",
  keywordname: "keyword",
  onhit: "keyword",
  toggle: "keyword",
  evolve: "keyword",
  danger: "keyword",
  factionionia1: "keyword",
  specialrules: "keyword",
  lifesteal: "keyword",
  omnivamp: "keyword",
  magicpen: "keyword",
  armorpen: "keyword",
  gold: "keyword",
  slow: "keyword",
  scalead: "scale",
  scalemr: "scale",
  scalearmor: "scale",
  scaleap: "scale",
  scalehp: "scale",
  scalemana: "scale",
  scalehealth: "scale",
  scalelevel: "scale",
  /** 攻速、冷却这类「带单位的数值」——和移速同样处理（`275%攻击速度`、`10秒`）。 */
  attackspeed: "speed",
  cooldown: "speed",
  /**
   * 客户端用来给「关键词」上色的标签，比如龙王的【星尘】：
   *
   * ```html
   * 每命中一名英雄就会吸收<font color='#3458eb'>@MassStolen@星尘</font>
   * ```
   *
   * 颜色取 `color` 属性（只放行十六进制，见 `safeColor`），取不到就用一个中性强调色。
   * 不做进 `TAG_CLASSES` 的普通分支是因为它要额外读属性。
   */
  font: "fontcolor",
  color: "fontcolor",
  /**
   * 国服文案里更常见的「关键词/重点」标签（2026-09-30 全英雄扫描：**108 个英雄**用它）。
   *
   * ```html
   * <li><keywordMajor>25 / 25 / …层</keywordMajor>：对目标周围的所有敌人造成伤害。
   * ```
   *
   * 不加进来就会被当文本转义，界面上直接印出 `<keywordMajor>` 字面量。
   */
  keywordmajor: "keyword",
  keyword: "keyword",
  keywordminor: "keyword",
  /**
   * 客户端用 `<li>` 排**列表项**（斯莫德 Q 的三档进化、薇恩 W 的三环…）。
   *
   * ⚠️ 它**不是**合法 HTML 的 `<li>` 语义——文案里是「连着写一串 `<li>`、
   * 没有 `<ul>` 包裹、也常常不闭合」。直接当文本转义会让三档效果挤成一句话；
   * 当 HTML 塞进 `<p>` 又会产生非法嵌套。所以映射成 `block` 类
   * （`display: block` + 行首符号），既不挤行也不破坏结构。
   */
  li: "listitem",
  /**
   * `<ul>` 是 `<li>` 的容器（皮肤介绍里的「四套搭配了智能战甲的致命枪械」那种列表）。
   * 映射成 `block` 而不是转义：不认它就会把 `<ul>` 字面量印出来。
   * 它**没有**配对闭合也常见，所以和 `li` 一样进 `OPTIONAL_CLOSE`。
   */
  ul: "block",
  // 纯排版
  br: "br",
  i: "italic",
  b: "strong",
  maintext: "block",
  stats: "block",
  rules: "block",
  flavortext: "flavor",
  /**
   * `<p>` / `<hr>`：皮肤介绍那种整段文案在用。
   *
   * - `<p>` 映射成块级 **span**（`block`）而不是 `<p>`——我们的渲染结果本身就塞在
   *   一个 `<p class="abilities__text">` 里，再嵌一层 `<p>` 是非法 HTML，
   *   浏览器会自动补闭合，把后面的内容挤到段落外面。
   * - `<hr>`（凯隐两种形态之间的分隔线）是自闭合标签，见 `VOID_TAGS`。
   */
  p: "block",
  hr: "separator",
};

/**
 * 只有 `#rgb` / `#rrggbb` 这两种十六进制写法会被当成颜色用。
 *
 * 客户端文案里的 `color` 属性是第三方字符串，直接拼进 `style` 就是 CSS 注入面
 * （`red;background:url(...)` 这类）。所以这里**只认十六进制**，其余一律返回 null
 * 让调用方退回默认色——**宁可颜色不对，也不能把任意字符串塞进样式**。
 */
function safeColor(raw: string | undefined): string | null {
  if (!raw) return null;
  const value = raw.trim().replace(/^['"]|['"]$/g, "");
  return /^#[0-9a-fA-F]{3}$/.test(value) || /^#[0-9a-fA-F]{6}$/.test(value) ? value : null;
}

/** 从 `<font color='#3458eb'>` 的原始片段里抠出 `color` 属性的值。 */
function attrValue(inner: string, name: string): string | undefined {
  const match = new RegExp(`${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s/>]+))`, "i").exec(inner);
  return match?.[1] ?? match?.[2] ?? match?.[3];
}

/** 自闭合：不需要配对的标签名。 */
const VOID_TAGS = new Set(["br", "hr"]);

/** 没有对应 `</tag>` 也要能处理的标签（客户端偶尔只开不闭）。 */
const OPTIONAL_CLOSE = new Set(["br", "maintext", "stats", "rules", "flavortext", "li", "ul", "p", "hr"]);

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export interface RenderOptions {
  /**
   * 占位符取值。键是 `@` 中间的名字，值是**已经格式化好的字符串**
   * （数组请调用方自己拼成 `"40 / 80 / 120"`）。
   *
   * 表里没有的占位符**保留原样**——让读者看到「这里有个官方变量」比看到编造的数字好。
   */
  values?: Record<string, string>;
  /** 数值占位符的样式后缀（默认 `value`，可用来区分「这是算出来的」）。 */
  valueClass?: string;
}

/**
 * 解析 `@…@` 里的内容。
 *
 * 官方文案里除了光秃秃的 `@SlowDuration@`，还有**带运算的表达式**：
 *
 * ```text
 * @AOEModifier*100@%          龙王 Q：溅射伤害是主伤害的 50%
 * @TrueDamageBonus*100@%      龙王 W：固定伤害提升的百分比
 * ```
 *
 * 以前这里只放行 `[A-Za-z0-9_.:]`，遇到 `*` 就整个 `@…@` 当成普通文本漏出去——
 * 于是界面上出现 `@AOEModifier*100@` 这种原文。现在拆成「基名 + 修饰」。
 *
 * 只认**乘一个常数**和**加一个常数**两种（`*100` / `+0.4`）；更复杂的嵌套一律返回 null，
 * 让调用方保留原文——宁可露出变量名，也不自己算一个可能错的数。
 */
export interface PlaceholderExpression {
  /** 变量名。 */
  name: string;
  /** 系数：`*100` → 100。没有就是 null。 */
  scale: number | null;
  /** 加数：`+0.4` → 0.4。没有就是 null。 */
  offset: number | null;
}

export function parsePlaceholderExpression(input: string): PlaceholderExpression | null {
  const trimmed = input.trim();
  if (!trimmed) return null;
  // 基名：与老逻辑一致（字母数字下划线点冒号），但**不带**运算符号。
  const match = /^([A-Za-z0-9_.:]+)(?:\s*([*+])\s*(-?\d+(?:\.\d+)?))?$/.exec(trimmed);
  if (!match) return null;
  const [, name, operator, operand] = match;
  if (operator === "*") return { name, scale: Number(operand), offset: null };
  if (operator === "+") return { name, scale: null, offset: Number(operand) };
  return { name, scale: null, offset: null };
}

/**
 * 客户端文案里的**图标占位符**：`%i:cooldown%`、`%i:OnHit%`、`%i:scaleAP%`…
 *
 * 2026-10-03 全量扫描 245 个英雄：共 999 处，其中 `%i:cooldown%` 占 974 处。
 * 客户端把它们渲染成一个小图标，我们没有那套图标资源；**删掉**最干净——
 * 旁边的文字已经把意思说全了（`10秒 %i:cooldown%`、`攻击特效 %i:OnHit%`），
 * 留着就会在界面上印出 `%i:cooldown%` 这种字面量。
 */
const ICON_TOKEN = /%i:[A-Za-z0-9_.]+%/g;

/**
 * 引擎侧的**散文占位符**：名字能解析出来，但**永远不会对应一个数值**——
 * 它是游戏引擎往里拼「技能修饰器说明」的位置，和 `DataValues` /
 * `mSpellCalculations` 没有半点关系。两份数据源都查过，拿不到：
 *
 *  - 客户端（LCU）英雄 JSON：`spells[]` 里根本没有这个键（只有
 *    spellKey/name/description/dynamicDescription/…）；
 *  - CommunityDragon 的 `ryze.bin.json`：整份文件里不存在 `Modifier` / `Append` 字段。
 *
 * 对绝大多数英雄这里本来就该是空的（瑞兹四个技能都没有修饰器）。以前会原样印出
 * `@SpellModifierDescriptionAppend@` 这个字面量——纯噪音，现在渲染时整段抹掉。
 *
 * 注意：**只抹渲染，不抹 `remainingPlaceholders`**。技能面板本来就用这一项来判断
 * 「剩下的全是拼接位」→ 显示「末尾没有显示内容的那一处，是客户端用来拼接装备与符文
 * 加成的位置」那句说明（见 `ChampionAbilityPanel.vue` 的 `leftoverIsOnlyAppend`）。
 * 那句说明本来就写着「没有显示内容」，所以抹掉渲染输出正好让它名副其实；
 * 若把 `remainingPlaceholders` 也一起改掉，那句说明就永远不会触发了。
 */
const PROSE_PLACEHOLDERS = new Set(["SpellModifierDescriptionAppend"]);

/**
 * 在取值表里找一个占位符**命中的那个键**（不只是值）。
 *
 * 四级降级，**顺序要紧**：
 *  1. 完整名字（`spell.SmolderP:Passive_QDamageIncrease`）——后端对跨技能引用
 *     正是用完整名字做键的，这一级命中就说明跨技能引用已经打通。
 *  2. 完整名字的**大小写无关**匹配——客户端文案写 `@Spell.RyzeR:OverloadDamageBonus@`
 *     （大写 `S`），而后端是按 CDragon 短名拼键的（`spell.RyzeR:…`，小写 `s`）。
 *     实测同一份数据里两种写法都有（拉莫斯 R 是 `@spell.PowerBall:…@`），
 *     只认一种就会把一个**明明取到了值**的占位符当成没取到。
 *  3. 冒号后的部分（`Passive_QDamageIncrease`）——老后端 / 只给短名的场合。
 *  4. 最后一段（`.` 与 `:` 都切开）。
 *
 * 不能只留第 1 级：同一份数据里两种键都可能出现；也不能只留第 4 级：
 * `spell.A:Foo` 与 `spell.B:Foo` 会互相抢（同一英雄里极少，但不是不可能）。
 *
 * ⚠️ 返回**键**而不是值，是为了让「这段文案到底引用了哪几个变量」
 * （`referencedValueKeys`）能和取值走**同一套**匹配规则——两套规则各写一遍，
 * 迟早会出现「明明填上了却报没填」的自相矛盾。
 */
function matchValueKey(values: Record<string, string> | undefined, name: string): string | undefined {
  if (!values) return undefined;
  if (values[name] !== undefined) return name;
  // 大小写无关：见上面第 2 条。
  const lower = name.toLowerCase();
  for (const key of Object.keys(values)) {
    if (key.toLowerCase() === lower) return key;
  }
  const afterColon = name.includes(":") ? name.slice(name.indexOf(":") + 1) : undefined;
  if (afterColon !== undefined && values[afterColon] !== undefined) return afterColon;
  const last = name.split(/[.:]/).pop();
  if (last !== undefined && values[last] !== undefined) return last;
  return undefined;
}

/** 按 `matchValueKey` 的降级链取值。 */
function lookupValue(values: Record<string, string> | undefined, name: string): string | undefined {
  const key = matchValueKey(values, name);
  return key === undefined ? undefined : values?.[key];
}

/**
 * 后端给**跨技能引用**加的键前缀（`spell.PowerBall:PowerBallDamage`）。
 *
 * 它同时是「这一项是不是本技能自己的变量」的判据——见 `referencedValueKeys`。
 */
const CROSS_SKILL_KEY = /^spell\.[A-Za-z0-9_]+:/;

/** 这一项是不是跨技能引用（`spell.<短名>:<变量>`）。 */
export function isCrossSkillKey(name: string): boolean {
  return CROSS_SKILL_KEY.test(name);
}

/**
 * 这段文案**真正引用到**了取值表里的哪些键。
 *
 * # 为什么必须过滤
 *
 * 后端为了支持 `@spell.X:Y@` 这种跨技能引用，会把**其他每个技能整体**收一遍、
 * 统一加上 `spell.<短名>:` 前缀塞进当前槽位。做法本身没错，但结果是**每个槽位
 * 都拿到全英雄的变量**——实测拉莫斯 5 个槽位各 46 项、cross 集合逐字相同：
 *
 * ```text
 * Q（动力冲刺）的取值表里混进了 spell.PuncturingTaunt:MonsterDamageCalc、
 *   spell.Tremors2:TurretDamageModifier、spell.RammusP:BaseDamage …
 * ```
 *
 * 界面上就表现为「点开任何一个技能，下面都列 46 行、大半跟这个技能无关」
 * （用户 2026-10-03 报的：拉莫斯 W 下面挂着 Q/E/R 的伤害系数）。
 *
 * CDragon 那份角色文件里**没有任何文案**（实测 `@` 出现 0 次、连中文都没有），
 * 所以后端无从判断谁被引用；而这一层手里正好有原文，就该在这里收口。
 *
 * @param text 该技能的原文（`description` + `dynamicDescription` + 被动的 `description`）
 * @param values 该槽位的取值表
 * @returns 被引用到的键集合；文案里没有任何占位符时返回**空集合**（由调用方决定退化成什么）
 */
export function referencedValueKeys(
  text: string,
  values: Record<string, unknown> | undefined,
): Set<string> {
  const hit = new Set<string>();
  if (!text || !values) return hit;
  const re = /@([^@]+)@/g;
  let match = re.exec(text);
  while (match) {
    const expression = parsePlaceholderExpression(match[1]);
    if (expression) {
      const key = matchValueKey(values as Record<string, string>, expression.name);
      if (key !== undefined) hit.add(key);
    }
    match = re.exec(text);
  }
  return hit;
}

/**
 * 把解析出来的表达式渲染成一段 HTML。取不到值返回 null（由调用方标出原文）。
 *
 * 关键一步是 `*100`：CDragon 那边的 `AOEModifier` 存的是 **0.5**，客户端文案写成
 * `@AOEModifier*100@%` 得到 `50%`。所以 `*100` 的真实含义就是「这个分数按百分数说」，
 * 渲染出 `50` 之后后面那个 `%` 由文案自己带——**不要**再补一个百分号。
 */
export function renderPlaceholderExpression(
  expression: PlaceholderExpression,
  values: Record<string, string> | undefined,
  valueClass: string,
): string | null {
  const { name, scale, offset } = expression;
  const raw = lookupValue(values, name);
  if (raw === undefined || raw === "") return null;

  // 只有「单值」才做运算：逐级数组（`"40 / 80 / 120"`）没法整体乘，保留就好。
  const single = /^-?\d+(?:\.\d+)?$/.test(raw.trim()) ? Number(raw.trim()) : null;
  if (single === null || (scale === null && offset === null)) {
    return `<span class="ab-${valueClass}">${escapeHtml(raw)}</span>`;
  }
  const computed = single * (scale ?? 1) + (offset ?? 0);
  const text = Number.isInteger(computed) ? String(computed) : String(Math.round(computed * 1000) / 1000);
  return `<span class="ab-${valueClass}">${escapeHtml(text)}</span>`;
}

/**
 * 把一段客户端文案转成可安全 `v-html` 的 HTML。
 *
 * - 白名单外的标签（含 `<script>`）**当文本转义**，不会执行。
 * - `<br>` → `<br />`。
 * - `@Name@` → `values[Name]`（有值）或原样保留。
 */
export function renderAbilityText(rawInput: string, options: RenderOptions = {}): string {
  if (!rawInput) return "";
  // 先把图标占位符摘掉（见 `ICON_TOKEN`），后面整段逻辑就不用再管它。
  const raw = rawInput.replace(ICON_TOKEN, "");
  const { values, valueClass = "value" } = options;
  let out = "";
  let index = 0;
  // 用栈记录当前打开的 span，保证闭合顺序正确（即使客户端标签嵌套得很随意）。
  // 存 `{cls, tag}` 是因为同一个 class 可能来自不同标签（`<font>` 与 `<color>`）。
  const open: { cls: string; tag: string }[] = [];

  /** 关掉最近一个同名 class 的 span；找不到就忽略。 */
  const closeTo = (tag: string) => {
    const cls = TAG_CLASSES[tag];
    if (!cls || VOID_TAGS.has(tag)) return;
    // 从栈顶往下找到最近的同名 class（不用 `findLastIndex`，target 到不了 es2023）。
    let at = -1;
    for (let i = open.length - 1; i >= 0; i -= 1) {
      if (open[i].cls === cls) {
        at = i;
        break;
      }
    }
    if (at === -1) return;
    // 先补掉它之后还开着的（客户端常见的不对称嵌套）
    for (let i = open.length - 1; i > at; i -= 1) out += "</span>";
    out += "</span>";
    open.splice(at, open.length - at);
  };

  while (index < raw.length) {
    const lt = raw.indexOf("<", index);
    const at = raw.indexOf("@", index);

    // 取最近的特殊起点；都没有就收尾。
    let next = -1;
    let kind: "tag" | "placeholder" | null = null;
    if (lt !== -1 && (at === -1 || lt < at)) {
      next = lt;
      kind = "tag";
    } else if (at !== -1) {
      next = at;
      kind = "placeholder";
    }
    if (next === -1 || kind === null) {
      out += escapeHtml(raw.slice(index));
      break;
    }

    out += escapeHtml(raw.slice(index, next));

    if (kind === "tag") {
      const gt = raw.indexOf(">", next);
      if (gt === -1) {
        // 没有闭合的 `<`，剩下的当文本。
        out += escapeHtml(raw.slice(next));
        break;
      }
      const inner = raw.slice(next + 1, gt).trim();
      const closing = inner.startsWith("/");
      const name = (closing ? inner.slice(1) : inner).split(/[\s/]/)[0].toLowerCase();
      const cls = TAG_CLASSES[name];

      if (!cls) {
        // 白名单外：原样转义成可见文本（而不是丢掉，避免句子断掉）。
        out += escapeHtml(raw.slice(next, gt + 1));
      } else if (VOID_TAGS.has(name)) {
        // 自闭合标签各有各的空元素：`<br>` 换行、`<hr>` 分隔线。
        out += name === "hr" ? '<hr class="ab-separator" />' : "<br />";
      } else if (closing) {
        closeTo(name);
      } else {
        // 自闭合写法 `<br/>` / `<hr/>` 也要认。
        if (inner.endsWith("/")) {
          out += name === "hr" ? '<hr class="ab-separator" />' : "<br />";
        } else if (cls === "fontcolor") {
          // 带属性上色：颜色只认十六进制（见 safeColor），其余退回默认强调色。
          const color = safeColor(attrValue(inner, "color") ?? attrValue(inner, "style"));
          out += color
            ? `<span class="ab-${cls}" style="color:${color}">`
            : `<span class="ab-${cls}">`;
          open.push({ cls, tag: name });
        } else {
          out += `<span class="ab-${cls}">`;
          open.push({ cls, tag: name });
        }
      }
      index = gt + 1;
      continue;
    }

    // 占位符：`@Name@`，名字里允许字母数字下划线和点（`@spell.PowerBall:PowerBallDamage@`）。
    const close = raw.indexOf("@", next + 1);
    if (close === -1) {
      out += escapeHtml(raw.slice(next));
      break;
    }
    const name = raw.slice(next + 1, close);
    const expression = parsePlaceholderExpression(name);
    if (!expression) {
      // `@` 只是普通字符（比如邮箱），别误吞。
      out += "@";
      index = next + 1;
      continue;
    }
    // 引擎散文占位符（见 `PROSE_PLACEHOLDERS`）：既取不到值、也不该露出原文，整段抹掉。
    if (PROSE_PLACEHOLDERS.has(expression.name)) {
      index = close + 1;
      continue;
    }
    const rendered = renderPlaceholderExpression(expression, values, valueClass);
    if (rendered !== null) {
      out += rendered;
    } else {
      // 取不到值：把**原始表达式**标出来（含 `*100`），让人一眼看出这是官方变量。
      out += `<span class="ab-placeholder">@${escapeHtml(name)}@</span>`;
    }
    index = close + 1;
  }

  // 收尾：补齐所有没闭合的 span。
  while (open.length) {
    out += "</span>";
    open.pop();
  }
  return out;
}

/**
 * 文案里还剩哪些没取到值的占位符（用于决定要不要显示「随属性变化」那句说明）。
 *
 * ⚠️ 必须和 `renderAbilityText` 用**同一套**解析：`@AOEModifier*100@` 要按基名
 * `AOEModifier` 去查值，不能把整串（含 `*100`）当名字——否则明明填上了也会被
 * 报成「没取到值」，用户就看到两句互相矛盾的说明。
 */
export function remainingPlaceholders(raw: string, values: Record<string, string> = {}): string[] {
  const found = new Set<string>();
  const re = /@([^@]+)@/g;
  let match = re.exec(raw);
  while (match) {
    const expression = parsePlaceholderExpression(match[1]);
    if (!expression) {
      match = re.exec(raw);
      continue;
    }
    const { name } = expression;
    // ⚠️ 必须走和渲染**同一套**查找（见 `lookupValue`），否则跨技能引用
    // （`spell.SmolderP:Passive_QDamageIncrease`）明明是后端给了值的，这里却会
    // 因为只比了短名而报成「没取到」，界面上就会出现自相矛盾的两句话。
    if (lookupValue(values, name) === undefined) found.add(name);
    match = re.exec(raw);
  }
  return [...found];
}

/**
 * 逐级数组 → 一句话。
 *
 * `[40, 80, 120, 160, 200, 240]` → `"40 / 80 / 120 / 160 / 200 / 240"`。
 * 超过 8 级就只给首尾（`"40 … 280"`）——再长就会把一行撑破。
 *
 * 整数不带 `.0`（`0.5` 这种亚索 E 的冷却要留住）。
 */
export function formatLevelValues(values: number[]): string {
  if (!Array.isArray(values) || values.length === 0) return "";
  const part = (value: number) => (Number.isInteger(value) ? String(value) : String(Math.round(value * 1000) / 1000));
  if (values.length <= 8) return values.map(part).join(" / ");
  return `${part(values[0])} … ${part(values[values.length - 1])}`;
}

/**
 * 一个变量该按「百分数」还是「普通数字」显示。
 *
 * - `percent`：`0.5` 要印成 `50`（`%` 由文案自己带在占位符外面）。
 * - `number`：`0.5` 就印 `0.5`。
 */
export type AbilityUnit = "percent" | "number";

/**
 * **正文自己声明的单位**——这是唯一权威依据。
 *
 * 官方文案在占位符后面**紧贴着**就写了单位，所以根本不用猜：
 *
 * ```text
 * 击飞敌人@KnockupDuration@秒      → number（0.5 秒，**否决**百分数）
 * 持续@SlowDuration@秒的@SlowAmount*100@%  → number / 不表态
 * ```
 *
 * 客户端自己的措辞就说明了一切，值落在 `[0, 1]` 只是**巧合**
 * （0.5 秒和 50% 在数值上无法区分）。
 *
 * # 为什么不靠「值像不像分数」来判断
 *
 * 早先只按「全部取值落在 `[0,1]`」判百分数，结果**击飞时长 0.5 秒被印成 50 秒**——
 * 而且这不是个别英雄的问题：2026-10-03 全量扫描 245 个英雄，
 * **`SlowDuration` / `StunDuration` / `KnockupDuration` / `CooldownRefund` 等 76 个
 * 时长类变量名、167 个英雄**都会中招（正文里共 151 处 `@XxxDuration@秒`）。
 * 逐个英雄加白名单是没有出路的——问题在**判据**，不在具体英雄。
 *
 * # ⚠️ `%` **不**作为「按分数处理」的依据，只在「秒」时表态
 *
 * 容易写错的一点：文案里的 `%` 只是**单位符号**，不代表这个值是 0~1 的分数。
 * `@SlowPercent@%` 的取值本来就是 `30 / 40 / …`（已经是百分数），
 * `@SlowAmount*100@%` 才是 0~1 的分数、靠占位符里的 `*100` 换算。
 * 若把 `%` 也当成「按分数处理」，`SlowPercent` 就会被再乘 100 → **3000%**。
 * 所以这里**只在正文说「秒」时返回 `number`（用来否决后端的 percent 猜测）**，
 * 其余情况一律返回 null，交给后端的 `unit` 决定。
 *
 * @param text 该技能的 `description` / `dynamicDescription` 原文
 * @param name 变量名（不含 `@`、不含 `*100` 之类修饰）
 * @returns 只在正文明确说「秒」时返回 `"number"`；其余（含 `%`、判不出、两种都有）返回 null
 */
export function detectUnitFromText(text: string, name: string): AbilityUnit | null {
  if (!text || !name) return null;
  // 变量名在正文里的三种写法都要认：
  //   `@SlowDuration@`                 —— 直接引用
  //   `@SlowAmount*100@`               —— 带运算修饰（只关心它后面的单位）
  //   `@spell.PowerBall:KnockupDuration@` —— 跨技能引用（前面带 `技能名:` 前缀）
  // 所以**不要求** `@` 紧贴名字：只按「结尾是这个名字 + 可选的 `技能名:` 前缀」匹配。
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // 前缀 `(?:[A-Za-z0-9_.]+:)?` 覆盖 `spell.PowerBall:`；`(?![A-Za-z0-9_])`
  // 是**关键**的边界保证——否则查 `SlowAmount` 会错配到 `SlowAmountExtra` 之类
  // 更长名字的前缀上。
  const re = new RegExp(`(?:[A-Za-z0-9_.]+:)?${escaped}(?![A-Za-z0-9_])(?:[*+][-\\d.]+)?@\\s*(%|秒)`, "g");
  const units = new Set<string>();
  let scan = re.exec(text);
  while (scan) {
    units.add(scan[1]);
    scan = re.exec(text);
  }
  // 全部命中都是「秒」→ 确定是时间，返回 number 去否决 percent。
  // 出现 `%`（或两种都有）→ 不表态，交给后端的 `unit`。
  if (units.size === 1 && units.has("秒")) return "number";
  return null;
}


/** 后端的 `ratioStat` 代码 → 中文。用户问的「它是什么加成」就是靠这张表回答。 */
const STAT_LABELS: Record<string, string> = {
  AP: "法术强度",
  AD: "攻击力",
  Armor: "护甲",
  MR: "魔法抗性",
  MaxHealth: "最大生命值",
  Health: "生命值",
  AttackSpeed: "攻击速度",
  MoveSpeed: "移动速度",
  Crit: "暴击",
  Mana: "法力值",
  /** 「按最大法力值的百分比」（瑞兹 Q/W/E、布里茨被动护盾 35% 最大法力值）。 */
  MaxMana: "最大法力值",
};

/** `ratioStat` 代码 → 中文（认不出来就给原文，不吞掉）。 */
export function statLabel(stat: string | undefined): string {
  if (!stat) return "加成";
  return STAT_LABELS[stat] ?? stat;
}

/**
 * 分数 → 百分数文本。
 *
 * `[0.5, 0.5, 0.5]` → `"50%"`；`[0.05, 0.1, 0.15]` → `"5 / 10 / 15%"`。
 *
 * ⚠️ `withSign` 这个开关是必须的，因为有两个消费方、口径不同：
 *
 * - **正文替换**（`@AOEModifier*100@%`）要用 `withSign: false`——客户端文案里
 *   `%` 是**写在占位符外面**的，我们再补一个就变成 `50%%`（2026-09-30 实测踩到）。
 * - **取值速查表**（没有上下文的一句话）要用 `withSign: true`，否则 `50` 孤零零一个数
 *   看不出是百分数。
 */
export function formatPercentValues(values: number[], options: { withSign?: boolean } = {}): string {
  if (!Array.isArray(values) || values.length === 0) return "";
  const sign = options.withSign === false ? "" : "%";
  // `Math.round(v*100*1000)/1000` 是为了抹掉浮点误差：0.07*100 会得到 7.000000000000001。
  const part = (value: number) => String(Math.round(value * 100 * 1000) / 1000);
  if (values.length <= 8) return `${values.map(part).join(" / ")}${sign}`;
  return `${part(values[0])} … ${part(values[values.length - 1])}${sign}`;
}

/**
 * 一段「系数 × 属性」。
 *
 * `ratio` 与 `ratios` 都可能是 null（只有属性的那种），**不要**当成系数 0。
 */
export interface AbilityRatioItem {
  /** 系数（逐级不同时为 null，看 `ratios`）。 */
  ratio: number | null;
  /** 系数**逐级**值；只有确实逐级不同时才有。 */
  ratios: number[] | null;
  /** 乘的属性代码（`AP` / `AD` / `MaxMana`…）；认不出为 null。 */
  stat: string | null;
}

/** 取值项里与加成有关的字段（后端形状的最小交集，便于测试直接构造）。 */
export interface AbilityRatioSource {
  ratio?: number;
  ratios?: number[];
  ratioStat?: string;
  ratioItems?: { ratio?: number; ratios?: number[]; stat?: string }[];
}

/**
 * 取出一个变量的**全部**加成段。
 *
 * # 为什么是「多段」
 *
 * 一个计算项可以同时吃好几个属性，客户端文案也是并着写的：
 *
 * ```text
 * 艾瑞莉娅 W  MinDamageCalc = 基础值 + 40% 攻击力 + 50% 法术强度
 * 瑞兹     Q  QDamageCalc   = 基础值 + 55% 法术强度 + 2% 最大法力值
 * ```
 *
 * 老形状只留**第一段**（`ratio` / `ratios` / `ratioStat`），第二段直接丢失。
 * 新后端在多段时会额外给 `ratioItems`，所以这里**优先**读它、没有再回退老字段。
 *
 * ⚠️ 「只有 `ratioStat`、没有系数」（龙王 Q 的 `BurstBonusTrueDamageToChamps`）
 * 也返回一段，`ratio` 为 null——它的意思是「按这个属性算」，不是「系数 0」。
 */
export function abilityRatioItems(entry: AbilityRatioSource): AbilityRatioItem[] {
  if (entry.ratioItems?.length) {
    return entry.ratioItems.map((item) => ({
      // 系数 0 视为「这一段不生效」：CDragon 里有 0 占位，列出来只会让人以为是加成。
      ratio: typeof item.ratio === "number" && item.ratio !== 0 ? item.ratio : null,
      ratios: item.ratios?.length ? item.ratios : null,
      stat: item.stat ?? null,
    }));
  }
  const ratio = typeof entry.ratio === "number" && entry.ratio !== 0 ? entry.ratio : null;
  const ratios = entry.ratios?.length ? entry.ratios : null;
  if (ratio === null && !ratios && !entry.ratioStat) return [];
  return [{ ratio, ratios, stat: entry.ratioStat ?? null }];
}

/**
 * 一段系数 → `10% 护甲` 里的前半截。
 *
 * # 为什么按百分数写
 *
 * 系数在数据里一律是**分数**（`APRatio = 1`、`DamageArmorRatio = 0.1`、
 * 艾瑞莉娅 W 的 `mCoefficient = 0.4`），而客户端自己的写法就是百分数：
 * 「造成 15（+10% 护甲）魔法伤害」。以前印成 `0.1 护甲`，用户看不懂，
 * 也正是「这个加成怎么才 0.1」的疑惑来源之一（2026-10-03 反馈）。
 *
 * 逐级不同的系数整条展开（`22.5 / 30 / … / 67.5%`），否则 5 级的加成会显示成 1 级的。
 */
export function formatRatioText(item: AbilityRatioItem): string {
  if (item.ratios) return formatPercentValues(item.ratios, { withSign: true });
  if (item.ratio !== null) return formatPercentValues([item.ratio], { withSign: true });
  return "";
}

/**
 * 一个变量的加成 → 一句人话：`100% 法术强度`、`10% 护甲 + 10% 魔法抗性`。
 *
 * 只保留**有系数**的段；「只有属性」的段由调用方单独说成「按最大生命值算」
 * （硬套一个系数是错的）。没有加成时返回空串。
 */
export function formatAbilityRatios(entry: AbilityRatioSource): string {
  return abilityRatioItems(entry)
    .map((item) => ({ text: formatRatioText(item), stat: statLabel(item.stat ?? undefined) }))
    .filter((part) => part.text !== "")
    .map((part) => `${part.text} ${part.stat}`)
    .join(" + ");
}

/**
 * 把后端的取值表拍平成 `renderAbilityText` 要的 `values` 映射。
 *
 * 这一层是**喂给正文替换**的，所以分数**不带百分号**——客户端文案里 `%` 写在
 * 占位符外面（`@SlowAmount*100@%`），这里再带一个就变成 `80%%`。
 * 需要带百分号的场合（取值速查表）直接用 `formatPercentValues`。
 *
 * # `text` 参数：正文里声明的单位**优先于**后端给的 `unit`
 *
 * 后端只能靠「值像不像分数」猜，而 `0.5 秒` 和 `50%` 在数值上完全一样——
 * 这正是「击飞 50 秒」的来源（详见 `detectUnitFromText`）。
 * 客户端文案里紧跟着占位符的 `秒` / `%` 才是权威，所以传正文进来覆盖后端判断。
 */
export function flattenAbilityValues(
  values: Record<string, { values: number[]; ratio?: number; ratios?: number[]; ratioStat?: string; ratioItems?: { ratio?: number; ratios?: number[]; stat?: string }[]; percent?: boolean; unit?: string }> | undefined,
  options: { withRatio?: boolean; text?: string } = {},
): Record<string, string> {
  const out: Record<string, string> = {};
  if (!values) return out;
  for (const [name, entry] of Object.entries(values)) {
    const levels = formatEntryValues(name, entry, options.text, false);
    if (!levels) continue;
    // 系数是**另一个独立变量**（`QTotalDamage` 那种），塞进同一格会让读者以为
    // 「40/80/120 +1.0 法强」是一体的。所以系数只在明确要求时才拼上。
    //
    // ⚠️ 拼法必须是**平铺的 ` + `**，不能加括号。官方文案/客户端面板里就是
    // 「造成 30 / 60 / 90 / 120 / 150（+60% 法术强度）」写成一行连着的，
    // 而用户 2026-10-03 明确要求「有加成的直接写在伤害后面」——
    // 括号会把「基础值」和「加成」读成两件事，平铺才是一句话。
    if (options.withRatio) {
      const ratioText = formatAbilityRatios(entry);
      out[name] = ratioText ? `${levels} + ${ratioText}` : levels;
    } else {
      out[name] = levels;
    }
  }
  return out;
}

/**
 * 单个变量的逐级值 → 一句话，**单位按 `detectUnitFromText` 的判据**决定。
 *
 * 判据优先级（高到低）：
 *  1. 正文里紧跟占位符的 `秒` / `%`（权威，客户端自己写的）；
 *  2. 后端给的 `unit` 字段；
 *  3. 后端给的 `percent` 布尔（老缓存 / 老后端的形状）。
 */
export function formatEntryValues(
  name: string,
  entry: { values: number[]; percent?: boolean; unit?: string },
  text?: string,
  withSign = true,
): string {
  if (!entry || !Array.isArray(entry.values) || entry.values.length === 0) return "";
  const unit = detectUnitFromText(text ?? "", name) ?? normalizeUnit(entry);
  return unit === "percent"
    ? formatPercentValues(entry.values, { withSign })
    : formatLevelValues(entry.values);
}

/** 后端 `unit` 字符串 → 前端口径；老形状只有 `percent` 布尔。 */
function normalizeUnit(entry: { percent?: boolean; unit?: string }): AbilityUnit {
  if (entry.unit === "percent" || entry.unit === "number") return entry.unit;
  return entry.percent ? "percent" : "number";
}

export { OPTIONAL_CLOSE };
