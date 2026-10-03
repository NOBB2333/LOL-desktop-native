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
  scalead: "scale",
  scalemr: "scale",
  scalearmor: "scale",
  scaleap: "scale",
  scalehp: "scale",
  scalemana: "scale",
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
  // 纯排版
  br: "br",
  i: "italic",
  b: "strong",
  maintext: "block",
  stats: "block",
  rules: "block",
  flavortext: "flavor",
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
const VOID_TAGS = new Set(["br"]);

/** 没有对应 `</tag>` 也要能处理的标签（客户端偶尔只开不闭）。 */
const OPTIONAL_CLOSE = new Set(["br", "maintext", "stats", "rules", "flavortext"]);

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
  const raw = values?.[name] ?? values?.[name.split(/[.:]/).pop() ?? name];
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
export function renderAbilityText(raw: string, options: RenderOptions = {}): string {
  if (!raw) return "";
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
        out += '<br />';
      } else if (closing) {
        closeTo(name);
      } else {
        // 自闭合写法 `<br/>` 也要认。
        if (inner.endsWith("/")) {
          out += '<br />';
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
    const short = name.split(/[.:]/).pop() ?? name;
    if (values[name] === undefined && values[short] === undefined) found.add(name);
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
 * 把后端的取值表拍平成 `renderAbilityText` 要的 `values` 映射。
 *
 * 这一层是**喂给正文替换**的，所以分数**不带百分号**——客户端文案里 `%` 写在
 * 占位符外面（`@SlowAmount*100@%`），这里再带一个就变成 `80%%`。
 * 需要带百分号的场合（取值速查表）直接用 `formatPercentValues`。
 */
export function flattenAbilityValues(
  values: Record<string, { values: number[]; ratio?: number; ratioStat?: string; percent?: boolean }> | undefined,
  options: { withRatio?: boolean } = {},
): Record<string, string> {
  const out: Record<string, string> = {};
  if (!values) return out;
  for (const [name, entry] of Object.entries(values)) {
    const levels = entry.percent
      ? formatPercentValues(entry.values, { withSign: false })
      : formatLevelValues(entry.values);
    if (!levels) continue;
    // 系数是**另一个独立变量**（`QTotalDamage` 那种），塞进同一格会让读者以为
    // 「40/80/120 +1.0 法强」是一体的。所以系数只在明确要求时才拼上。
    if (options.withRatio && entry.ratio) {
      out[name] = `${levels}（+${entry.ratio} ${statLabel(entry.ratioStat)}）`;
    } else {
      out[name] = levels;
    }
  }
  return out;
}

export { OPTIONAL_CLOSE };
