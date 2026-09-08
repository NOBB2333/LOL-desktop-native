<script setup lang="ts">
import { AlertTriangle, CheckCircle2 } from "@lucide/vue";
import type { TeamSummary } from "../types/domain";
import { meterClass } from "../utils/format";
defineProps<{ summary: TeamSummary; side: "ally" | "enemy" }>();
const labels = { early: "前期", mid: "中期", late: "后期", teamfight: "团战" } as const;
</script>

<template>
  <section class="team-summary-card" :data-side="side">
    <div class="summary-score"><span>队伍评分</span><strong>{{ summary.score.toFixed(1) }}</strong><small>{{ summary.title }}</small></div>
    <div v-if="summary.composition" class="composition-grid">
      <div v-for="(value, key) in summary.composition" :key="key">
        <span>{{ labels[key] }}</span><i><b :class="meterClass(value)" /></i><em>{{ value }}</em>
      </div>
    </div>
    <div class="summary-notes">
      <p v-for="item in summary.strengths.slice(0, 1)" :key="item"><CheckCircle2 :size="13" />{{ item }}</p>
      <p v-for="item in summary.risks.slice(0, 1)" :key="item" class="risk"><AlertTriangle :size="13" />{{ item }}</p>
    </div>
  </section>
</template>
