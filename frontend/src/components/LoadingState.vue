<script setup lang="ts">
withDefaults(defineProps<{ label?: string }>(), { label: "正在刷新数据" });
</script>

<template>
  <section class="loading-state" role="status" aria-live="polite">
    <div class="loading-state__mark"><span /><span /><span /></div>
    <strong>{{ label }}</strong>
    <small>正在请求最新数据；最多等待 6 秒后回退到缓存</small>
  </section>
</template>

<style scoped>
.loading-state { display: grid; place-items: center; min-height: 280px; gap: 12px; border: 1px solid var(--line); background: var(--surface); color: var(--text-secondary); }
.loading-state__mark { display: flex; align-items: flex-end; gap: 4px; height: 30px; }
.loading-state__mark span { width: 6px; height: 12px; border-radius: 3px; background: var(--accent); animation: loading-pulse 1s ease-in-out infinite; }
.loading-state__mark span:nth-child(2) { height: 21px; animation-delay: .12s; }
.loading-state__mark span:nth-child(3) { height: 16px; animation-delay: .24s; }
.loading-state strong { color: var(--text-primary); font-size: 14px; }
.loading-state small { color: var(--text-muted); font-size: 10px; }
@keyframes loading-pulse { 0%, 100% { opacity: .35; transform: scaleY(.75); } 50% { opacity: 1; transform: scaleY(1); } }
@media (prefers-reduced-motion: reduce) { .loading-state__mark span { animation: none; opacity: .8; } }
</style>
