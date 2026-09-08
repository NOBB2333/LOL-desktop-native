<script setup lang="ts">
import { computed } from "vue";
import { useQuery } from "@tanstack/vue-query";
import type { EncounterRecord } from "../types/domain";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import EncounterMatchModal from "./EncounterMatchModal.vue";
import MatchHistoryDetail from "./MatchHistoryDetail.vue";

const props = defineProps<{ show: boolean; records: EncounterRecord[]; targetPuuid: string }>();
defineEmits<{ "update:show": [show: boolean] }>();
const app = useAppStore();
const detail = useQuery({
  queryKey: computed(() => ["encounter-detail", app.mode, app.connection.platformId, props.records[0]?.selfPuuid ?? "", props.targetPuuid, props.records[0]?.gameId ?? 0] as const),
  queryFn: ({ queryKey }) => backend.matchDetail(queryKey[5], queryKey[2] ?? "", queryKey[3], queryKey[4]),
  enabled: computed(() => props.show && Boolean(props.records[0]?.gameId)),
  staleTime: 60_000,
  retry: false,
});
</script>

<template>
  <EncounterMatchModal :show="show" :records="records" :target-puuid="targetPuuid" :detail="detail.data.value" :loading="detail.isFetching.value" :error="detail.isError.value" @retry="detail.refetch()" @update:show="$emit('update:show', $event)">
    <template #detail><MatchHistoryDetail v-if="detail.data.value" :match="detail.data.value" :highlighted-puuids="[records[0]?.selfPuuid ?? '', targetPuuid]" @close="$emit('update:show', false)" /></template>
  </EncounterMatchModal>
</template>
