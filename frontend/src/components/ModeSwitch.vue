<script setup lang="ts">
import { Database, Radio } from "@lucide/vue";
import { useQueryClient } from "@tanstack/vue-query";
import { computed } from "vue";
import { useAppStore } from "../stores/app";
import type { DataMode } from "../types/domain";

const app = useAppStore();
const queryClient = useQueryClient();
const modes = [
  { value: "fixture" as const, label: "演示", icon: Database },
  { value: "live" as const, label: "实时", icon: Radio },
];
const active = computed(() => app.mode);

async function select(mode: DataMode) {
  if (active.value === mode) return;
  await app.setMode(mode);
  await queryClient.invalidateQueries();
}
</script>

<template>
  <div class="mode-switch" aria-label="数据模式">
    <button v-for="item in modes" :key="item.value" :class="{ active: active === item.value }" :aria-pressed="active === item.value" @click="select(item.value)">
      <component :is="item.icon" :size="14" />
      <span>{{ item.label }}</span>
    </button>
  </div>
</template>
