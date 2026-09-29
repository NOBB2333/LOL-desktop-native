<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { backend } from "../services/backend";
import type { ChampionAbility } from "../types/domain";
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
 * ⚠️ **这里没有每级伤害数字**，而且这是有意的：LCU 那份里真实系数（AD/AP 加成）
 * 全是 0，只有 CommunityDragon 的公式数据里才有。所以面板只展示**冷却 / 耗蓝 / 射程**
 * 这些 LCU 确实给了的数，以及 `dynamicDescription` 里带 `@TotalDamage@` 占位符的模板。
 * 宁可少给，也不能自己算一个数出来——那会让人以为是官方数据。
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

/** 描述里的 `@TotalDamage@` 这类占位符是**官方模板的原文**。 */
const hasPlaceholders = computed(() => /@[A-Za-z0-9_]+@/.test(selected.value?.dynamicDescription ?? ""));
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
        <p class="abilities__text" v-html="passive.description" />
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
        <!-- 三段文案全列出来：`description` 是简版，`dynamicDescription` 带官方占位符。
             只给一段会让「有占位符」看起来像我们没渲染好。 -->
        <p v-if="selected.description" class="abilities__text">{{ selected.description }}</p>
        <p v-if="selected.dynamicDescription" class="abilities__text abilities__text--muted">{{ selected.dynamicDescription }}</p>
        <p v-if="hasPlaceholders" class="abilities__note">
          上面 <code>@…@</code> 是**官方文案里的占位符**（如 `@TotalDamage@` 指这一项的伤害值）。
          真实数值要按英雄等级/装备才算得出来，LCU 本地资料里没有这份系数，所以这里原样展示，不替它填数字。
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
.abilities__text--muted { color: var(--text-muted); }
.abilities__note { margin: 0; padding: 7px 9px; border-left: 2px solid var(--amber); color: var(--text-secondary); background: var(--surface-raised); font-size: 10px; line-height: 1.6; }
.abilities__note code { color: var(--amber); font-size: 10px; }
</style>
