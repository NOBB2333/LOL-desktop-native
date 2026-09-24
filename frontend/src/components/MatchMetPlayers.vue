<script setup lang="ts">
/**
 * 一局里的同场玩家：「队友 N / 对手 N」两列可点的小圆片。
 *
 * 抽成组件是因为历史页有**两处**要用同一份信息——「对局时间线」下面（这一局里
 * 遇到的是谁）和「最近对局」每张卡里。文案、点击目标（去战绩页看这个人的完整
 * 数据）必须一致，所以只留一份实现。
 *
 * 只做展示，不取数：列表由父级从本地相遇档案里挑好传进来。
 */
import type { EncounterRecord } from "../types/domain";

defineProps<{ allies: EncounterRecord[]; enemies: EncounterRecord[] }>();
const emit = defineEmits<{ open: [record: EncounterRecord] }>();

/** `名字#标签`；没有标签时退化成只用名字（与战绩页的查询口径一致）。 */
function riotIdOf(record: EncounterRecord) {
  const tag = record.tagLine?.trim();
  return tag ? `${record.gameName}#${tag}` : record.gameName;
}
</script>

<template>
  <div class="met-players">
    <div class="met-players__side">
      <span class="met-players__label">队友 {{ allies.length }}</span>
      <div class="met-players__chips">
        <button v-for="record in allies" :key="`ally-${record.puuid}`" type="button" class="met-players__chip" :title="riotIdOf(record)" @click="emit('open', record)">{{ record.gameName }}</button>
        <span v-if="!allies.length" class="met-players__empty">未记录</span>
      </div>
    </div>
    <div class="met-players__side met-players__side--enemy">
      <span class="met-players__label">对手 {{ enemies.length }}</span>
      <div class="met-players__chips">
        <button v-for="record in enemies" :key="`enemy-${record.puuid}`" type="button" class="met-players__chip" :title="riotIdOf(record)" @click="emit('open', record)">{{ record.gameName }}</button>
        <span v-if="!enemies.length" class="met-players__empty">未记录</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.met-players { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 10px; }
.met-players__side { min-width: 0; }
.met-players__label { display: block; margin-bottom: 5px; color: var(--text-muted); font-size: 10px; }
.met-players__chips { display: flex; flex-wrap: wrap; gap: 4px; }
.met-players__chip { padding: 2px 8px; border: 1px solid var(--line); border-radius: 999px; color: var(--text-primary); background: var(--surface-raised); cursor: pointer; font-size: 10px; transition: border-color 140ms ease, background 140ms ease; }
.met-players__chip:hover { border-color: var(--accent); background: var(--accent-soft); }
.met-players__empty { color: var(--text-muted); font-size: 10px; }
@media (max-width: 720px) { .met-players { grid-template-columns: 1fr; } }
</style>
