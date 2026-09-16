<script setup lang="ts">
import { computed } from "vue";

const props = defineProps<{ flashOnD: number; flashOnF: number }>();

const total = computed(() => props.flashOnD + props.flashOnF);

const rate = (count: number) => {
  if (total.value === 0) return "0";
  return ((count / total.value) * 100).toFixed(1);
};

const dWidth = computed(() => (total.value === 0 ? 0 : (props.flashOnD / total.value) * 100));
</script>

<template>
  <div class="flash-popover">
    <p class="flash-popover__title">闪现位置分布</p>
    <p class="flash-popover__description">
      该玩家近期在 D / F 两个位置都放置过闪现，按键习惯不稳定。
    </p>
    <div class="flash-popover__bar">
      <i class="flash-popover__seg flash-popover__seg--d" :style="{ width: `${dWidth}%` }" />
      <i class="flash-popover__seg flash-popover__seg--f" :style="{ width: `${100 - dWidth}%` }" />
    </div>
    <div class="flash-popover__legend">
      <span class="flash-popover__dot flash-popover__dot--d" />
      <span>D 位 {{ flashOnD }} 次（{{ rate(flashOnD) }}%）</span>
    </div>
    <div class="flash-popover__legend">
      <span class="flash-popover__dot flash-popover__dot--f" />
      <span>F 位 {{ flashOnF }} 次（{{ rate(flashOnF) }}%）</span>
    </div>
    <div class="flash-popover__total">基于最近 {{ total }} 场已分析对局统计</div>
  </div>
</template>

<style scoped>
.flash-popover {
  width: 230px;
  font-size: 11px;
  color: var(--text-primary);
}

.flash-popover__title {
  margin: 0;
  color: var(--text-primary);
  font-size: 12px;
  font-weight: 700;
}

.flash-popover__description {
  margin: 6px 0 0;
  color: var(--text-secondary);
  line-height: 1.6;
}

.flash-popover__bar {
  display: flex;
  height: 10px;
  margin: 8px 0 6px;
  border-radius: 2px;
  overflow: hidden;
  background: var(--line);
}

.flash-popover__seg {
  display: block;
  height: 100%;
}

.flash-popover__seg--d {
  background: #2563eb;
}

.flash-popover__seg--f {
  background: #f97316;
}

.flash-popover__legend {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 3px;
  color: var(--text-secondary);
}

.flash-popover__dot {
  width: 8px;
  height: 8px;
  flex: none;
  border-radius: 2px;
}

.flash-popover__dot--d {
  background: #2563eb;
}

.flash-popover__dot--f {
  background: #f97316;
}

.flash-popover__total {
  margin-top: 8px;
  padding-top: 6px;
  border-top: 1px solid var(--line);
  color: var(--text-muted);
  font-size: 10px;
}
</style>
