<script setup lang="ts">
import type { ScoreBreakdown } from "../../types/domain";

withDefaults(defineProps<{ score: ScoreBreakdown; precision?: number; description?: string }>(), {
  precision: 1,
  description: "",
});

const percent = (value: number, max: number) => (max > 0 ? Math.min(100, Math.max(0, (value / max) * 100)) : 0);
</script>

<template>
  <div class="score-popover">
    <div class="score-popover__total">
      <strong>{{ score.total.toFixed(precision) }}</strong>
      <span>综合评分</span>
    </div>
    <div v-if="score.components.length" class="score-popover__list">
      <div v-for="component in score.components" :key="component.key" class="score-popover__row">
        <div class="score-popover__head">
          <span>{{ component.label }}</span>
          <b>{{ component.score.toFixed(1) }} / {{ component.maxScore }}</b>
        </div>
        <div class="score-popover__meter">
          <i :style="{ width: `${percent(component.score, component.maxScore)}%` }" />
        </div>
        <small>{{ component.evidence }}</small>
      </div>
    </div>
    <div class="score-popover__confidence">样本置信度 {{ Math.round(score.confidence) }}%</div>
  </div>
</template>

<style scoped>
.score-popover {
  width: 240px;
  font-size: 11px;
  color: var(--text-primary);
}

.score-popover__description {
  margin-bottom: 6px;
  color: var(--text-secondary);
  line-height: 1.6;
}

.score-popover__total {
  display: flex;
  align-items: baseline;
  gap: 6px;
  padding-bottom: 6px;
  border-bottom: 1px solid var(--line);
}

.score-popover__total strong {
  color: var(--accent);
  font-size: 18px;
  font-weight: 900;
  font-variant-numeric: tabular-nums;
}

.score-popover__total span {
  color: var(--text-muted);
  font-size: 10px;
}

.score-popover__list {
  display: grid;
  gap: 6px;
  padding-top: 6px;
}

.score-popover__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 6px;
}

.score-popover__head span {
  color: var(--text-secondary);
}

.score-popover__head b {
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}

.score-popover__meter {
  height: 3px;
  margin: 2px 0;
  border-radius: 2px;
  background: var(--line);
  overflow: hidden;
}

.score-popover__meter i {
  display: block;
  height: 100%;
  background: var(--accent);
}

.score-popover__row small {
  display: block;
  color: var(--text-muted);
  font-size: 9px;
  line-height: 1.4;
}

.score-popover__confidence {
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px solid var(--line);
  color: var(--text-muted);
  font-size: 9px;
}
</style>
