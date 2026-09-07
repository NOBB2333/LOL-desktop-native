<script setup lang="ts">
defineProps<{ title: string; eyebrow?: string; meta?: string }>();
</script>

<template>
  <header class="page-header">
    <div>
      <p v-if="eyebrow" class="eyebrow">{{ eyebrow }}</p>
      <h1>{{ title }}</h1>
      <p v-if="meta" class="page-meta">{{ meta }}</p>
    </div>
    <div class="page-actions"><slot /></div>
  </header>
</template>
