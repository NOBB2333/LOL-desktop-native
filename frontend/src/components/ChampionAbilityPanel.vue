<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { backend } from "../services/backend";
import type { ChampionAbility } from "../types/domain";
import { remainingPlaceholders, renderAbilityText, flattenAbilityValues, formatLevelValues } from "../utils/abilityText";
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
 * 当前槽位能用的取值表。
 *
 * 槽位键：被动在 CommunityDragon 那边是 `p`，主动是 `q`/`w`/`e`/`r`——和 LCU 的
 * `spellKey` 同一套，所以直接用 `tab` 配。
 *
 * 带系数的那种（`+1.0 法强`）**不拼进同一格**：系数是另一个变量，拼一起会让人
 * 以为「40/80/120 +1.0 法强」是一个整体。加成单独在下面列一行。
 */
const slotValues = computed(() => {
  const slot = tab.value;
  const sets = values.data.value?.spells ?? [];
  const match = sets.find((item) => item.slot.toLowerCase() === slot);
  return match?.values ?? {};
});

const valuesFor = (): Record<string, string> => flattenAbilityValues(slotValues.value);

/** 带系数的取值项——单独列出来给读者看「另外还加多少」。 */
const scaledEntries = computed(() =>
  Object.entries(slotValues.value)
    .filter(([, entry]) => entry.ratio !== undefined && entry.ratio !== 0)
    .map(([name, entry]) => ({
      name,
      text: `${formatLevelValues(entry.values)}${entry.ratioStat ? ` + ${entry.ratio} ${entry.ratioStat}` : ""}`,
      stat: entry.ratioStat ?? "",
    }))
    .filter((entry) => entry.text.length > 0),
);

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
        <!-- 带加成系数的项单独列：拼进正文格子会让人把「基础值」和「系数」读成一个数。 -->
        <dl v-if="scaledEntries.length" class="abilities__scaling">
          <div v-for="entry in scaledEntries" :key="entry.name">
            <dt>{{ entry.name }}</dt>
            <dd>{{ entry.text }}</dd>
          </div>
        </dl>
        <p v-if="leftover.length" class="abilities__note">
          <template v-if="leftoverIsOnlyAppend">
            末尾没有显示内容的那一处，是客户端用来<strong>拼接装备与符文加成</strong>的位置；你没带这些加成时它本来就是空的，不是漏了。
          </template>
          <template v-else>
            上面标出的 <span class="abilities__note-mark">@…@</span> 是官方文案里的<strong>变量</strong>，取值要按英雄等级与
            实时属性（移速 / 护甲 / 魔抗等）才算得出来。这类数值本地资料里没有现成的，所以原样保留，不替它填数字。
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
/* 带加成系数的项：和正文分开，避免把「基础值」与「系数」读成一个数。 */
.abilities__scaling { display: grid; gap: 4px; margin: 0; padding: 7px 9px; border: 1px solid var(--line); background: var(--surface-raised); }
.abilities__scaling div { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; }
.abilities__scaling dt { color: var(--text-muted); font-size: 9px; }
.abilities__scaling dd { margin: 0; color: var(--text-secondary); font-size: 10px; font-variant-numeric: tabular-nums; }

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
.abilities__text :deep(.ab-spell) { color: var(--accent); }
.abilities__text :deep(.ab-strong) { color: var(--text-primary); font-weight: 500; }
.abilities__text :deep(.ab-italic) { font-style: italic; }
.abilities__text :deep(.ab-flavor) { color: var(--text-muted); font-style: italic; }
.abilities__text :deep(.ab-block) { display: block; }
/* 取到值的变量 */
.abilities__text :deep(.ab-value) { color: var(--text-primary); font-weight: 500; font-variant-numeric: tabular-nums; }
/* 没取到值的变量：标出来，别让人以为是渲染坏了 */
.abilities__text :deep(.ab-placeholder) { color: var(--amber); font-family: var(--font-mono, monospace); font-size: 10px; }
</style>
