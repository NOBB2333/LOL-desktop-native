<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { backend } from "../services/backend";
import type { ChampionAbility, ChampionAbilityValueEntry } from "../types/domain";
import {
  abilityRatioItems,
  formatRatioText,
  isCrossSkillKey,
  referencedValueKeys,
  remainingPlaceholders,
  renderAbilityText,
  flattenAbilityValues,
  formatEntryValues,
  statLabel,
} from "../utils/abilityText";
import LcuAssetImage from "./LcuAssetImage.vue";

/**
 * 单个英雄的技能详情（被动 + Q/W/E/R）。
 *
 * # 为什么按需拉
 *
 * 一个英雄一份 30~70KB 的 LCU 原始 JSON。英雄列表有 245 行，全塞进去首屏要白等几秒。
 * 所以列表只带名字和统计（`get_champions`），技能详情是点开某个英雄才拉一次
 * （`get_champion_abilities`），且后端会落盘缓存。
 *
 * # 数据来源与口径
 *
 * 来自**本机 LCU** 的 `/lol-game-data/assets/v1/champions/{id}.json`，所以技能名和描述
 * 是**你客户端当前语言**的（国服就是中文），不需要我们维护翻译表。
 *
 * 但是那份描述**不是纯文本**——它带一整套标记：
 *
 * ```
 * 获得<speed>@MinimumMoveSpeed@移动速度</speed>，并在@RollDuration@秒里…
 * ```
 *
 * 所以不能直接插值（会把 `<speed>` 印出来），也不能直接 `v-html`（第三方字符串当 HTML）。
 * 统一走 `utils/abilityText.ts` 的白名单渲染：认识的标签变样式，其余当文本转义。
 *
 * ⚠️ **`@RollDuration@` 这类占位符的数值来自 CommunityDragon**，不在 LCU 那份里
 * （LCU 的真实系数全是 0）。`values` 里给到的就替换成真实数字，给不到的原样保留并标出来——
 * 宁可让人看到「这里有个官方变量」，也不能自己算一个数出来冒充实测值。
 *
 * # 数值那一层是**可选增强**
 *
 * 逐级数值要过公网（CommunityDragon），断网 / 被代理挡了就整体拿不到。那种情况下
 * **只有变量保留原文**，技能名、描述、冷却、耗蓝、射程全部照常显示——所以这里
 * 不用 `isError` 去盖掉主面板，只在文案下面提一句。
 */
const props = defineProps<{ championId: number; championName: string }>();

const abilities = useQuery({
  queryKey: computed(() => ["champion-abilities", props.championId]),
  queryFn: () => backend.championAbilities(props.championId),
  enabled: computed(() => props.championId > 0),
  // 技能资料只随补丁变，不必频繁回源。
  staleTime: 30 * 60_000,
  // **不重试**：失败基本就是「客户端没开」，重试只会让错误提示晚几秒才出现。
  retry: false,
});

/**
 * 逐级数值。必须等 `abilities` 先回来——CommunityDragon 的目录用**英文别名**
 * （`Rammus`），光有数字 id 拼不出路径。
 */
const values = useQuery({
  queryKey: computed(() => ["champion-ability-values", props.championId]),
  queryFn: () => backend.championAbilityValues(props.championId, abilities.data.value?.alias ?? ""),
  enabled: computed(() => props.championId > 0 && !!abilities.data.value?.alias),
  // 随补丁变，同样是长缓存。
  staleTime: 30 * 60_000,
  retry: false,
});

/** 当前选中的槽位。被动用 `p` 表示。 */
const tab = ref<string>("q");
// 换英雄时回到 Q：停在「上个英雄的 R」上会让人以为这个英雄没有 Q。
watch(() => props.championId, () => { tab.value = "q"; });

const spells = computed<ChampionAbility[]>(() => abilities.data.value?.spells ?? []);
/**
 * 标签页只在**真的有这个槽位**时才出现。
 *
 * 真机上有英雄缺 W 或 E（Yasuo 的 Q 走 wrapper、部分英雄少了某一格），
 * 硬写四个标签会点出一片空白，看起来像加载失败。
 */
const tabs = computed(() => {
  const items: { key: string; label: string; name: string }[] = [];
  const passiveEntry = abilities.data.value?.passive;
  if (passiveEntry) items.push({ key: "p", label: "被动", name: passiveEntry.name });
  for (const spell of spells.value) {
    const slot = spell.slot.toLowerCase();
    items.push({ key: slot, label: slot.toUpperCase(), name: spell.name });
  }
  return items;
});

/** 选中的那个技能；选中的是被动就返回 null（被动结构不一样，单独渲染）。 */
const selected = computed(() => spells.value.find((spell) => spell.slot.toLowerCase() === tab.value) ?? null);
const passive = computed(() => (tab.value === "p" ? abilities.data.value?.passive ?? null : null));

/**
 * 冷却 / 耗蓝 / 射程的展示文本。
 *
 * 只取**前 5 格**（技能最多点 5 级）。个别技能数组有 6 格，第 6 格不是可点等级
 * （LCU 自己多给一格），照着显示会让人以为「能点 6 级」。
 */
function levelsOf(values: number[]): string {
  if (!values.length) return "—";
  return values.slice(0, 5).map(formatNumber).join(" / ");
}

/** 0.5 → "0.5"，7 → "7"（亚索 E 的冷却就是小数）。 */
function formatNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : String(Math.round(value * 100) / 100);
}

/** 射程只有一个值（多数技能五级同射程），全一样就只写一个数。 */
const rangeText = computed(() => {
  const values = (selected.value?.range ?? []).slice(0, 5);
  if (!values.length) return "—";
  const first = values[0];
  return values.every((value) => value === first) ? formatNumber(first) : levelsOf(values);
});

/**
 * 逐级数组最多显示到第几级。
 *
 * 两份数据源都**没有**「这个技能能点几级」这个字段：CommunityDragon 的
 * `DataValues` 一律给 7 格，LCU 的 `cooldown` / `cost` 一律给 6 格
 * （拉莫斯 R 只有 3 级，LCU 也照样给 6 格）——所以只能取一个上限。
 * 这里取 **5**，和下面「冷却 / 耗蓝 / 射程」三行同一个口径
 * （用户 2026-10-03 明确说想要「5 个层级、5 个技能点」）。
 *
 * 代价：大招收尾会多显示两格重复值（R 实际 3 级）。要真正修得先拿到等级数。
 */
const MAX_RANKS = 5;

/**
 * 把一条取值裁到 `MAX_RANKS` 级（值和逐级系数一起裁，否则会错位）。
 *
 * ⚠️ 这一步必须**同时**作用于正文替换与速查表。只裁速查表的话，正文里
 * `@ReturnDamageCalc@` 还是会印出 7 格 `15 / 15 / … / 15`——那正是用户
 * 2026-10-03 贴出来的原文形状，也是他说的「应该是 5 个层级」。
 * 两处口径一旦不同，「面板上的数和正文里的数对不上」比多显示两格更难解释。
 */
function trimRanks(entry: ChampionAbilityValueEntry): ChampionAbilityValueEntry {
  const trim = (values: number[] | undefined) => values?.slice(0, MAX_RANKS);
  return {
    ...entry,
    values: entry.values.slice(0, MAX_RANKS),
    ratios: trim(entry.ratios),
    ratioItems: entry.ratioItems?.map((item) => ({ ...item, ratios: trim(item.ratios) })),
  };
}

/**
 * 当前槽位能用的取值表（**已裁到 `MAX_RANKS` 级**）。
 *
 * 槽位键：被动在 CommunityDragon 那边是 `p`，主动是 `q`/`w`/`e`/`r`——和 LCU 的
 * `spellKey` 同一套，所以直接用 `tab` 配。
 *
 * 带系数的那种（`+100% 法强`）**不拼进同一格**：系数是另一个变量，拼一起会让人
 * 以为「40/80/120 +100% 法强」是一个整体。加成单独在下面列一行。
 *
 * 裁级放在这一层（而不是各个消费点各裁一次）：正文替换、速查表、引用过滤
 * 全都读这一份，口径自然一致。
 */
const slotValues = computed<Record<string, ChampionAbilityValueEntry>>(() => {
  const slot = tab.value;
  const sets = values.data.value?.spells ?? [];
  const match = sets.find((item) => item.slot.toLowerCase() === slot);
  const raw = match?.values ?? {};
  const out: Record<string, ChampionAbilityValueEntry> = {};
  for (const [name, entry] of Object.entries(raw)) out[name] = trimRanks(entry);
  return out;
});

/**
 * 当前技能的**原文**（描述 + 动态描述拼起来）。
 *
 * 它的唯一用途是当「单位」的权威依据：客户端在占位符后面紧贴着的
 * `秒` / `%` 说明了变量到底是秒还是百分数。没有它就只能靠数值范围猜，
 * 而 `0.5 秒` 和 `50%` 数值上完全一样——猜错就是「击飞 50 秒」
 * （见 `utils/abilityText.ts` 的 `detectUnitFromText`）。
 */
const slotText = computed(() => {
  const spell = selected.value;
  // 被动结构不一样（`ChampionPassive` 只有 `description`，没有 `dynamicDescription`）。
  const passiveText = passive.value?.description ?? "";
  return `${spell?.description ?? ""} ${spell?.dynamicDescription ?? ""} ${passiveText}`.trim();
});

/**
 * 正文替换用的取值表。
 *
 * ⚠️ 这里**必须**带 `withRatio`（2026-10-03 用户要求）：正文里
 * `@WDamageCalc@` 要渲染成 `30 / 60 / 90 / 120 / 150 + 60% 法术强度 + 3% 最大法力值`，
 * 也就是**把加成直接接在基础值后面**，和客户端自己的写法一致
 * （客户端面板就是「基础伤害（+加成）」一行连着写）。
 * 以前正文只给基础值、加成单独列在下面一个框里，用户看到的是一句话被拆成两处，
 * 而且那个框和「这个技能用到的数值」框内容重复。
 */
const valuesFor = (): Record<string, string> =>
  flattenAbilityValues(slotValues.value, { text: slotText.value, withRatio: true });

/**
 * 这段文案**真正引用到**的键。
 *
 * 后端为了支持 `@spell.X:Y@` 会把其他每个技能整体收一遍塞进当前槽位，
 * 于是每个槽位都拿到全英雄的变量（实测拉莫斯 5 个槽位各 46 项、集合逐字相同）。
 * 那一层拿不到文案（CDragon 角色文件里 `@` 出现 0 次），所以过滤必须在这里做。
 */
const referencedKeys = computed(() => referencedValueKeys(slotText.value, slotValues.value));

/**
 * 这一格该展示哪些变量。
 *
 * - 文案里有引用 → **只留被引用的**。这正是「像客户端面板那样，只列这个技能
 *   自己的数字」：拉莫斯 W 从此只剩 `BuffDuration` / `ReturnDamageCalc` /
 *   `BonusArmorTooltip` / `BonusMRTooltip`；Q/E/R 的系数、以及文案根本没提的
 *   `RecastDamageTooltip` 都不再出现。
 * - 文案里**一个占位符都没有**（被动常见，比如拉莫斯被动就一句纯文字）→
 *   退化成「本技能自己的变量」，把 `spell.X:` 那批排除掉。宁可少列，
 *   也不要把别的技能的东西摊出来。
 */
const visibleValueNames = computed(() => {
  const all = Object.keys(slotValues.value);
  if (referencedKeys.value.size > 0) return all.filter((name) => referencedKeys.value.has(name));
  return all.filter((name) => !isCrossSkillKey(name));
});

/**
 * 取值速查表：这一格**用到的**每个变量逐项列出来。
 *
 * 这是为了回答「**它是什么加成**」——正文里 `@BurstBonusTrueDamageToChamps@`
 * 只有一个变量名，读者没法知道它是法强、攻击力还是最大生命值。所以这里逐项列出来：
 * 变量名 + 逐级值 + （有系数时）系数乘的是哪个属性。
 *
 * - 百分数按百分数显示：`0.5` → `50%`，而不是让人读成「0.5 点」。
 *   这里**要**带百分号（和正文替换相反——正文那个 `%` 由客户端文案自己带）。
 *   ⚠️ 但**先看原文声明的单位**：`@SlowDuration@秒` 是 0.5 **秒**，
 *   按百分数显示就会变成「50 秒」——这正是那个 bug。`withSign = true` 只在
 *   确认是百分数时才补 `%`。
 * - 带系数的单独标出「+60% 法术强度」——**这一句就是用户要的答案**。
 *   系数一律按百分数写（`+10% 护甲` 而不是 `+0.1 护甲`），和客户端文案一致
 *   （用户 2026-10-03 看到 `0.1 护甲` 时以为识别错了）。
 * - 系数逐级不同的（`ratios`）按级展开，否则 5 级的加成会显示成 1 级的；
 *   拉莫斯 W 的 `BonusArmorTooltip` 正是如此（22.5% → 67.5%）。
 * - **一个变量可以有好几段加成**（艾瑞莉娅 W = 攻击力 + 法强、瑞兹 Q = 法强 +
 *   最大法力值），全部列出、用 ` + ` 连起来；只留第一段就是用户报的「加成没了」。
 */
const valueRows = computed(() =>
  visibleValueNames.value.map((name) => {
    // `slotValues` 已经在源头裁过级（见 `trimRanks`），这里直接用。
    const entry = slotValues.value[name];
    const levels = formatEntryValues(name, entry, slotText.value, true);
    const items = abilityRatioItems(entry);
    /**
     * 带系数的段：`100% 法术强度`、`40% 攻击力 + 50% 法术强度`。
     *
     * 系数逐级不同就展开（否则 5 级会被显示成 1 级）。
     */
    const ratioParts = items
      .filter((item) => item.ratios !== null || item.ratio !== null)
      .map((item) => `${formatRatioText(item)} ${statLabel(item.stat ?? undefined)}`);
    /**
     * 只有属性、没有系数的段（龙王 Q 的星尘项）——
     * 单独一句话回答「它是什么加成」，不硬套系数。
     */
    const statLabels = items
      .filter((item) => item.ratios === null && item.ratio === null && item.stat !== null)
      .map((item) => statLabel(item.stat ?? undefined));
    return {
      name,
      levels,
      /** 展示用后缀：`+ 100% 法术强度`；没有系数就留空。 */
      ratios: ratioParts.join(" + "),
      statOnly: ratioParts.length === 0 && statLabels.length > 0,
      statOnlyText: `按${statLabels.join(" / ")}算`,
    };
  }).filter((row) => row.levels.length > 0),
);

/**
 * ⚠️ 这里原来还有一个 `scaledEntries`（把「带系数的项」单独列成**另一个框**）。
 * **2026-10-03 删除**：加成已经由 `valuesFor()` 直接写进正文的伤害后面
 * （`30 / 60 / 90 / 120 / 150 + 60% 法术强度 + 3% 最大法力值`），
 * 再单开一个框会和下面「这个技能用到的数值」框**逐行重复**——
 * 用户原话：「我不知道为什么有两个框，两个框写的一样的东西」。
 * 现在只保留下面那个可折叠的速查表（它是**唯一**列出变量名的地方，
 * 正文里只有数字、没有变量名）。
 */

/** 逐级数值整体拿不到（断网 / 被代理挡）时提一句——不是错误，只是这一层没有。 */
const valuesUnavailable = computed(() => props.championId > 0 && !!abilities.data.value && values.isError.value);

/** 被动描述也可能带标签与占位符，同样走白名单渲染。 */
const passiveHtml = computed(() => renderAbilityText(abilities.data.value?.passive?.description ?? "", { values: valuesFor() }));

/** 简版描述（一句话概括）——也可能带 `@…@`，一起渲染。 */
const shortHtml = computed(() => renderAbilityText(selected.value?.description ?? "", { values: valuesFor() }));

/** 完整描述，带官方占位符的那段。这是主文案。 */
const dynamicHtml = computed(() => renderAbilityText(selected.value?.dynamicDescription ?? "", { values: valuesFor() }));

/** 还剩哪些占位符没取到值——决定要不要显示那句说明。 */
const leftover = computed(() =>
  remainingPlaceholders(selected.value?.dynamicDescription ?? "", valuesFor()),
);

/** `@SpellModifierDescriptionAppend@` 不是数值，是客户端拼装备/符文加成的**位置**。 */
const leftoverIsOnlyAppend = computed(
  () => leftover.value.length > 0 && leftover.value.every((name) => name.includes("SpellModifierDescriptionAppend")),
);
</script>

<template>
  <section class="abilities" :aria-label="`${props.championName} 的技能`">
    <!-- 失败分支放在加载前面：vue-query 里 `isLoading` 是 `isPending && isFetching`，
         失败后 `isPending` 仍会短暂为 true——先判 isLoading 会把错误态**盖住**，
         用户就永远看到「正在读取…」转圈（2026-09-29 实测）。 -->
    <p v-if="abilities.isError.value" class="abilities__state abilities__state--warn">
      没能读到技能资料：需要本机开启《英雄联盟》客户端（技能文案由客户端按你的语言提供）。<br />
      <small>离线时这一类数据取不到，但上面那份英雄列表与 OP.GG 统计不受影响。</small>
    </p>
    <p v-else-if="abilities.isLoading.value" class="abilities__state">正在读取 {{ props.championName }} 的技能资料…</p>
    <template v-else>
      <div v-if="tabs.length" class="abilities__tabs" role="tablist">
        <button
          v-for="item in tabs"
          :key="item.key"
          type="button"
          role="tab"
          :aria-selected="tab === item.key"
          :class="{ active: tab === item.key }"
          :title="item.name"
          @click="tab = item.key"
        >
          <b>{{ item.label }}</b>
          <small>{{ item.name }}</small>
        </button>
      </div>

      <article v-if="passive" class="abilities__body">
        <header>
          <LcuAssetImage :path="passive.iconPath" :alt="passive.name" size="lg"><b>P</b></LcuAssetImage>
          <div><strong>{{ passive.name }}</strong><small>被动</small></div>
        </header>
        <p v-if="passiveHtml" class="abilities__text" v-html="passiveHtml" />
      </article>

      <article v-else-if="selected" class="abilities__body">
        <header>
          <LcuAssetImage :path="selected.iconPath" :alt="selected.name" size="lg"><b>{{ selected.slot.toUpperCase() }}</b></LcuAssetImage>
          <div><strong>{{ selected.name }}</strong><small>{{ selected.slot.toUpperCase() }}</small></div>
        </header>
        <dl class="abilities__stats">
          <div><dt>冷却（秒）</dt><dd>{{ levelsOf(selected.cooldown) }}</dd></div>
          <div><dt>耗蓝</dt><dd>{{ levelsOf(selected.cost) }}</dd></div>
          <div><dt>射程</dt><dd>{{ rangeText }}</dd></div>
        </dl>
        <!-- 两段文案：`description` 是一句话概括，`dynamicDescription` 是带官方变量的完整版。
             都走白名单渲染（标签变样式、变量标出来），不做纯文本插值。 -->
        <p v-if="shortHtml" class="abilities__text abilities__text--short" v-html="shortHtml" />
        <p v-if="dynamicHtml" class="abilities__text" v-html="dynamicHtml" />
        <!-- 取值速查：**这段文案真正用到**的每个 `@变量@` 分别是什么数
             （后端会把其他技能的变量也一并塞进来，这里按引用过滤掉了）。
             分数按百分数显示（50% 而不是 0.5），避免读成「0.5 点伤害」。
             ⚠️ 这是**唯一**列出变量名的框：正文里已经带着加成（`基础值 + 60% 法强`），
             但只有数字没有变量名，所以这一栏不能省（2026-10-03 删掉的是上面那个
             内容重复的「带系数的项」框，见 `scaledEntries` 处的注释）。 -->
        <details v-if="valueRows.length" class="abilities__values">
          <summary>这个技能用到的数值（{{ valueRows.length }} 项）</summary>
          <dl>
            <div v-for="row in valueRows" :key="row.name">
              <dt>{{ row.name }}</dt>
              <dd>
                {{ row.levels }}
                <small v-if="row.ratios !== ''">+ {{ row.ratios }}</small>
                <!-- 只有属性没有系数的那种：直接写「按最大生命值算」。 -->
                <small v-else-if="row.statOnly">{{ row.statOnlyText }}</small>
              </dd>
            </div>
          </dl>
        </details>
        <p v-if="leftover.length" class="abilities__note">
          <template v-if="leftoverIsOnlyAppend">
            末尾没有显示内容的那一处，是客户端用来<strong>拼接装备与符文加成</strong>的位置；你没带这些加成时它本来就是空的，不是漏了。
          </template>
          <template v-else>
            上面标出的 <span class="abilities__note-mark">@…@</span> 是官方文案里的<strong>变量</strong>，取值要按英雄等级与
            实时属性（移速 / 护甲 / 魔抗等）才算得出来。这类数值本地资料里没有现成的，所以原样保留，不替它填数字。
            它的具体含义在下面的「变量取值」里能查到。
          </template>
        </p>
        <p v-if="valuesUnavailable" class="abilities__note abilities__note--muted">
          本次<strong>没能取到逐级数值</strong>（那一步要联网），所以上面带 <span class="abilities__note-mark">@…@</span> 的地方保留了原文。
          技能名、描述、冷却、耗蓝、射程都不受影响。
        </p>
      </article>
      <p v-else class="abilities__state">这个英雄没有可展示的技能条目。</p>
    </template>
  </section>
</template>

<style scoped>
.abilities { display: grid; gap: 10px; }
.abilities__state { margin: 0; color: var(--text-secondary); font-size: 11px; line-height: 1.6; }
.abilities__state--warn { color: var(--amber); }
.abilities__state small { color: var(--text-muted); font-size: 10px; }
.abilities__tabs { display: flex; flex-wrap: wrap; gap: 5px; }
.abilities__tabs button { display: grid; gap: 2px; min-width: 88px; padding: 6px 9px; border: 1px solid var(--line); background: var(--surface); color: var(--text-secondary); text-align: left; cursor: pointer; }
.abilities__tabs button:hover { border-color: var(--accent); background: var(--surface-raised); }
.abilities__tabs button.active { border-color: var(--accent); background: var(--accent-soft); color: var(--text-primary); }
.abilities__tabs b { font-size: 10px; }
.abilities__tabs small { overflow: hidden; color: var(--text-muted); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.abilities__tabs button.active small { color: var(--accent); }
.abilities__body { display: grid; gap: 9px; padding: 11px; border: 1px solid var(--line); background: var(--surface); }
.abilities__body header { display: flex; align-items: center; gap: 10px; }
.abilities__body header strong { display: block; color: var(--text-primary); font-size: 13px; }
.abilities__body header small { display: block; margin-top: 3px; color: var(--text-muted); font-size: 9px; }
.abilities__stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 7px; margin: 0; }
.abilities__stats dt { color: var(--text-muted); font-size: 9px; }
.abilities__stats dd { margin: 3px 0 0; color: var(--text-primary); font-size: 11px; font-variant-numeric: tabular-nums; }
.abilities__text { margin: 0; color: var(--text-secondary); font-size: 11px; line-height: 1.7; }
.abilities__text--short { color: var(--text-muted); }
.abilities__note { margin: 0; padding: 7px 9px; border-left: 2px solid var(--amber); color: var(--text-secondary); background: var(--surface-raised); font-size: 10px; line-height: 1.6; }
.abilities__note--muted { border-left-color: var(--line); color: var(--text-muted); }
.abilities__note code { color: var(--amber); font-size: 10px; }
.abilities__note-mark { color: var(--amber); font-family: var(--font-mono, monospace); font-size: 10px; }
/* `.abilities__scaling`（「带系数的项」那个独立框）已随 2026-10-03 的去重一起删除：
   加成现在直接跟在正文的基础值后面，再单开一栏就和下面的速查表逐行重复了。 */
/* 变量取值速查：默认收起，需要时才展开（正文已经用不上的信息不必占地方）。 */
.abilities__values { border: 1px solid var(--line); background: var(--surface-raised); }
.abilities__values > summary { padding: 6px 9px; color: var(--text-muted); font-size: 9px; cursor: pointer; }
.abilities__values > summary:hover { color: var(--accent); }
.abilities__values > dl { display: grid; gap: 3px; margin: 0; padding: 0 9px 8px; }
.abilities__values > dl > div { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; }
.abilities__values dt { color: var(--text-muted); font-family: var(--font-mono, monospace); font-size: 9px; }
.abilities__values dd { margin: 0; color: var(--text-secondary); font-size: 10px; font-variant-numeric: tabular-nums; }
.abilities__values dd small { margin-left: 4px; color: var(--accent); font-size: 9px; }

/* 官方文案里的样式标签（<speed> <magicDamage> …）映射到这里。
   配色跟游戏内保持一致：魔法伤害紫、物理伤害橙、真伤白、治疗绿、护盾灰蓝。 */
.abilities__text :deep(.ab-magic) { color: var(--purple, #a08bd8); }
.abilities__text :deep(.ab-physical) { color: var(--amber, #d8903c); }
.abilities__text :deep(.ab-true) { color: var(--text-primary); font-weight: 500; }
.abilities__text :deep(.ab-healing) { color: var(--green, #5fae6a); }
.abilities__text :deep(.ab-shield) { color: var(--text-secondary); }
.abilities__text :deep(.ab-speed) { color: var(--text-secondary); }
.abilities__text :deep(.ab-status) { color: var(--amber, #d8903c); }
.abilities__text :deep(.ab-attention) { color: var(--text-primary); font-weight: 500; }
.abilities__text :deep(.ab-scale) { color: var(--text-secondary); }
.abilities__text :deep(.ab-recast) { color: var(--accent); font-weight: 500; }
/* `<spellActive>主动：</spellActive>` / `<spellPassive>被动：</spellPassive>`——
   国服文案里成对出现的导语（前者 212 处、后者 264 处）。它们和「再次施放：」
   是同一个角色（一句动作的导语），所以样式一致。 */
.abilities__text :deep(.ab-active) { color: var(--accent); font-weight: 500; }
.abilities__text :deep(.ab-passive) { color: var(--accent); font-weight: 500; }
/* `<hr>`：凯隐两种形态之间的分隔线。做成一条细分隔，别让它变成一行字面量。 */
.abilities__text :deep(.ab-separator) { display: block; margin: 6px 0; border: 0; border-top: 1px solid var(--line); }
.abilities__text :deep(.ab-spell) { color: var(--accent); }
.abilities__text :deep(.ab-strong) { color: var(--text-primary); font-weight: 500; }
.abilities__text :deep(.ab-italic) { font-style: italic; }
.abilities__text :deep(.ab-flavor) { color: var(--text-muted); font-style: italic; }
.abilities__text :deep(.ab-block) { display: block; }
/* 客户端 `<li>` 是**列表项**（斯莫德 Q 的三档进化、薇恩 W 的三环…）。
   文案里连着写一串 `<li>` 且常常不闭合，直接转义会挤成一句话、当 HTML 又会
   在 `<p>` 里非法嵌套。所以做成块级 + 行首圆点，既不挤行也不破坏结构。 */
.abilities__text :deep(.ab-listitem) { display: block; margin: 2px 0 2px 10px; }
.abilities__text :deep(.ab-listitem)::before { content: "· "; color: var(--text-muted); }
/* `<keywordMajor>` 是国服文案的重点标记（108 个英雄在用）。
   不给它特别颜色——用客户端的十六进制 `<font color>` 时颜色由内联 style 决定，
   这里只兜底「没有 color 时也要看得出是重点」。 */
.abilities__text :deep(.ab-keyword) { color: var(--text-primary); font-weight: 500; }
/* 取到值的变量 */
.abilities__text :deep(.ab-value) { color: var(--text-primary); font-weight: 500; font-variant-numeric: tabular-nums; }
/* 没取到值的变量：标出来，别让人以为是渲染坏了 */
.abilities__text :deep(.ab-placeholder) { color: var(--amber); font-family: var(--font-mono, monospace); font-size: 10px; }
/* 客户端 `<font color='#3458eb'>星尘</font>` 这类关键词着色。
   内联 style 里的颜色由 `safeColor` 限定成十六进制（见 abilityText.ts），
   没有 color 属性时退回这里的中性强调色。

   ⚠️ 只加 `font-weight: 500`，**不能**改 `font-size`：字号一变，行内这一段的
   基线就会和周围的说明文字错开，看起来像「渲染坏了」（用户 2026-09-30 报的
   「字体有些时候没渲染特别好」就是这个）。颜色一律走内联 style，
   这里只兜底没写 color 的情况。 */
.abilities__text :deep(.ab-fontcolor) { color: var(--green, #5fae6a); font-weight: 500; }
</style>
