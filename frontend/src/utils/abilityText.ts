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

/** 标签 → class 后缀。只有这张表里的标签会被当成样式；其余全部转义成文本。 */
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
  // 纯排版
  br: "br",
  i: "italic",
  b: "strong",
  maintext: "block",
  stats: "block",
  rules: "block",
  flavortext: "flavor",
};

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
  // 用栈记录当前打开的 class，保证闭合顺序正确（即使客户端标签嵌套得很随意）。
  const open: string[] = [];

  /** 关掉最近一个同名 class 的 span；找不到就忽略。 */
  const closeTo = (tag: string) => {
    const cls = TAG_CLASSES[tag];
    if (!cls || VOID_TAGS.has(tag)) return;
    const at = open.lastIndexOf(cls);
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
        } else {
          out += `<span class="ab-${cls}">`;
          open.push(cls);
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
    if (!/^[A-Za-z0-9_.:]+$/.test(name)) {
      // `@` 只是普通字符（比如邮箱），别误吞。
      out += "@";
      index = next + 1;
      continue;
    }
    const value = values?.[name] ?? values?.[name.split(/[.:]/).pop() ?? name];
    if (value !== undefined && value !== "") {
      out += `<span class="ab-${valueClass}">${escapeHtml(value)}</span>`;
    } else {
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

/** 文案里还剩哪些没取到值的占位符（用于决定要不要显示「随属性变化」那句说明）。 */
export function remainingPlaceholders(raw: string, values: Record<string, string> = {}): string[] {
  const found = new Set<string>();
  const re = /@([A-Za-z0-9_.:]+)@/g;
  let match = re.exec(raw);
  while (match) {
    const name = match[1];
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

/** 把后端的取值表拍平成 `renderAbilityText` 要的 `values` 映射。 */
export function flattenAbilityValues(
  values: Record<string, { values: number[]; ratio?: number; ratioStat?: string }> | undefined,
  options: { withRatio?: boolean } = {},
): Record<string, string> {
  const out: Record<string, string> = {};
  if (!values) return out;
  for (const [name, entry] of Object.entries(values)) {
    const levels = formatLevelValues(entry.values);
    if (!levels) continue;
    // 系数是**另一个独立变量**（`QTotalDamage` 那种），塞进同一格会让读者以为
    // 「40/80/120 +1.0 法强」是一体的。所以系数只在明确要求时才拼上。
    if (options.withRatio && entry.ratio) {
      const stat = entry.ratioStat ?? "加成";
      out[name] = `${levels}（+${entry.ratio} ${stat}）`;
    } else {
      out[name] = levels;
    }
  }
  return out;
}

export { OPTIONAL_CLOSE };
