<script setup lang="ts">
import type { TagTone } from "../tones";

const props = withDefaults(
  defineProps<{
    tone?: TagTone;
    /** 覆盖配色（用于开黑分组等动态色）。 */
    bg?: string;
    fg?: string;
    title?: string;
    /** 是否是可点击样式（例如「玩家标记」）。 */
    interactive?: boolean;
  }>(),
  { interactive: false },
);

const styleVars = () => {
  if (!props.bg && !props.fg) return undefined;
  return {
    ...(props.bg ? { "--tag-bg": props.bg } : {}),
    ...(props.fg ? { "--tag-fg": props.fg } : {}),
  };
};
</script>

<template>
  <span
    class="tag-chip"
    :class="[tone ? `tag-chip--${tone}` : 'tag-chip--neutral', interactive ? 'tag-chip--interactive' : '']"
    :style="styleVars()"
    :title="title"
  >
    <slot />
  </span>
</template>
