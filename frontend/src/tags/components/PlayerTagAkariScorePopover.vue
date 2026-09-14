<script setup lang="ts">
import type { AkariScore } from "../akari";

withDefaults(defineProps<{ score: AkariScore; precision?: number; description?: string }>(), {
  precision: 1,
  description: "",
});

const percent = (value: number, max: number) => (max > 0 ? Math.min(100, Math.max(0, (value / max) * 100)) : 0);
</script>

<template>
  <div class="akari-popover">
    <p v-if="description" class="akari-popover__description">{{ description }}</p>
    <div class="akari-popover__total">
      <strong>{{ score.total.toFixed(precision) }}</strong>
      <span>/ {{ score.maxScore }} · Akari 评分</span>
    </div>
    <div v-if="score.components.length" class="akari-popover__list">
      <div v-for="component in score.components" :key="component.key" class="akari-popover__row">
        <div class="akari-popover__head">
          <span>{{ component.label }}</span>
          <b>{{ component.score.toFixed(1) }} / {{ component.maxScore }}</b>
        </div>
        <div class="akari-popover__meter">
          <i :style="{ width: `${percent(component.score, component.maxScore)}%` }" />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.akari-popover {
  width: 240px;
  font-size: 11px;
  color: var(--text-primary);
}

.akari-popover__description {
  margin: 0 0 6px;
  color: var(--text-secondary);
  line-height: 1.6;
}

.akari-popover__total {
  display: flex;
  align-items: baseline;
  gap: 6px;
  padding-bottom: 6px;
  border-bottom: 1px solid var(--line);
}

.akari-popover__total strong {
  color: var(--accent);
  font-size: 18px;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
}

.akari-popover__total span {
  color: var(--text-muted);
  font-size: 10px;
}

.akari-popover__list {
  display: grid;
  gap: 6px;
  padding-top: 6px;
}

.akari-popover__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 6px;
}

.akari-popover__head span {
  color: var(--text-secondary);
}

.akari-popover__head b {
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}

.akari-popover__meter {
  height: 3px;
  margin: 2px 0;
  border-radius: 2px;
  background: var(--line);
  overflow: hidden;
}

.akari-popover__meter i {
  display: block;
  height: 100%;
  background: var(--accent);
}
</style>
