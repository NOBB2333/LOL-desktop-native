<script setup lang="ts">
withDefaults(defineProps<{ maxWidth?: number }>(), { maxWidth: 260 });
</script>

<template>
  <div class="tag-popover-text" :style="{ maxWidth: `${maxWidth}px` }">
    <slot />
  </div>
</template>

<style scoped>
.tag-popover-text {
  color: var(--text-secondary);
  font-size: 11px;
  line-height: 1.6;
  white-space: pre-line;
}
</style>
