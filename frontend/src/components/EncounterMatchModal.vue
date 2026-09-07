<script setup lang="ts">
import { NModal } from "naive-ui";
import { computed } from "vue";
import type { EncounterRecord } from "../types/domain";
import { championImage, roleName } from "../utils/format";
import AssetIcon from "./AssetIcon.vue";

interface EncounterParticipant {
  puuid: string;
  gameName: string;
  tagLine: string;
  championId: number;
  championName: string;
  position: string;
  kills?: number;
  deaths?: number;
  assists?: number;
  win?: boolean;
  side: "ally" | "enemy";
}

const props = defineProps<{
  show: boolean;
  records: EncounterRecord[];
  targetPuuid: string;
}>();
const emit = defineEmits<{ "update:show": [value: boolean] }>();
const sides = ["ally", "enemy"] as const;

const anchor = computed(() => props.records[0] ?? null);
const participants = computed<EncounterParticipant[]>(() => {
  const first = anchor.value;
  if (!first) return [];
  const values: EncounterParticipant[] = [{
    puuid: first.selfPuuid || "self",
    gameName: first.selfGameName || "未知玩家",
    tagLine: first.selfTagLine || "",
    championId: first.selfChampionId || 0,
    championName: first.selfChampionName || "未知英雄",
    position: first.selfPosition || "",
    kills: first.selfKills,
    deaths: first.selfDeaths,
    assists: first.selfAssists,
    win: first.selfWin,
    side: "ally",
  }];
  for (const record of props.records) {
    if (values.some((player) => player.puuid === record.puuid)) continue;
    values.push({
      puuid: record.puuid,
      gameName: record.gameName || "未知玩家",
      tagLine: record.tagLine || "",
      championId: record.championId,
      championName: record.championName || "未知英雄",
      position: record.position || "",
      kills: record.kills,
      deaths: record.deaths,
      assists: record.assists,
      win: record.win,
      side: record.side === "ally" ? "ally" : "enemy",
    });
  }
  return values;
});

const positionOrder = new Map([
  ["TOP", 0], ["JUNGLE", 1], ["JUG", 1], ["MIDDLE", 2], ["MID", 2],
  ["BOTTOM", 3], ["BOT", 3], ["ADC", 3], ["UTILITY", 4], ["SUPPORT", 4], ["SUP", 4],
]);
function team(side: "ally" | "enemy") {
  return participants.value
    .filter((player) => player.side === side)
    .sort((left, right) => (positionOrder.get(left.position.toUpperCase()) ?? 99) - (positionOrder.get(right.position.toUpperCase()) ?? 99));
}
function riotId(player: EncounterParticipant) {
  return player.tagLine ? `${player.gameName}#${player.tagLine}` : player.gameName;
}
function kda(player: EncounterParticipant) {
  if (player.kills === undefined || player.deaths === undefined || player.assists === undefined) return "战绩待结算";
  return `${player.kills}/${player.deaths}/${player.assists}`;
}
function result(player: EncounterParticipant) {
  if (player.win === undefined) return "待结算";
  return player.win ? "胜" : "负";
}
function isSelf(player: EncounterParticipant) {
  return !!anchor.value?.selfPuuid && player.puuid === anchor.value.selfPuuid;
}
</script>

<template>
  <NModal
    :show="show"
    preset="card"
    class="encounter-match"
    :style="{ width: 'min(920px, calc(100vw - 32px))' }"
    :title="anchor ? `历史对局 #${anchor.gameId}` : '历史对局'"
    :bordered="false"
    @update:show="emit('update:show', $event)"
  >
    <div v-if="anchor" class="encounter-match__meta">
      <strong>{{ anchor.queueName || "对局" }}</strong>
      <span>{{ new Date(anchor.encounteredAt).toLocaleString("zh-CN", { hour12: false }) }}</span>
      <b :data-win="anchor.selfWin === true">{{ anchor.result || "结果待结算" }}</b>
    </div>
    <div class="encounter-match__teams">
      <section v-for="side in sides" :key="side" :data-side="side">
        <header><strong>{{ side === "ally" ? "我方阵容" : "敌方阵容" }}</strong><span>{{ team(side).length }} 人</span></header>
        <div class="encounter-match__players">
          <article v-for="player in team(side)" :key="player.puuid" class="encounter-match__player" :class="{ 'encounter-match__player--target': player.puuid === targetPuuid, 'encounter-match__player--self': isSelf(player) }">
            <AssetIcon kind="champion" :id="player.championId" :name="player.championName" :fallback-url="championImage(player.championId)" size="md" />
            <div><strong :title="riotId(player)">{{ riotId(player) }}</strong><span>{{ player.championName }} · {{ roleName(player.position) }}</span></div>
            <div class="encounter-match__performance"><strong>{{ kda(player) }}</strong><span>{{ result(player) }}</span></div>
            <em v-if="isSelf(player)">本人</em><em v-else-if="player.puuid === targetPuuid">当前玩家</em>
          </article>
        </div>
      </section>
    </div>
  </NModal>
</template>

<style scoped>
.encounter-match__meta { display: flex; align-items: center; gap: 10px; padding: 0 0 12px; border-bottom: 1px solid var(--line); }
.encounter-match__meta strong { font-size: 13px; }
.encounter-match__meta span { flex: 1; color: var(--text-secondary); font-size: 10px; }
.encounter-match__meta b { color: var(--red); font-size: 11px; }
.encounter-match__meta b[data-win="true"] { color: var(--green); }
.encounter-match__teams { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; margin-top: 14px; }
.encounter-match__teams > section { min-width: 0; }
.encounter-match__teams > section > header { display: flex; justify-content: space-between; padding: 0 2px 7px; color: var(--text-secondary); font-size: 10px; }
.encounter-match__teams > section[data-side="ally"] > header strong { color: var(--blue); }
.encounter-match__teams > section[data-side="enemy"] > header strong { color: var(--red); }
.encounter-match__players { display: grid; gap: 5px; }
.encounter-match__player { position: relative; display: grid; grid-template-columns: 34px minmax(0, 1fr) auto; align-items: center; gap: 8px; min-height: 50px; padding: 7px 9px; border: 1px solid var(--line); background: var(--surface-raised); }
.encounter-match__player--self { border-color: var(--blue); box-shadow: inset 3px 0 0 var(--blue); }
.encounter-match__player--target { border-color: var(--accent); box-shadow: inset 3px 0 0 var(--accent); }
.encounter-match__player > div { min-width: 0; }
.encounter-match__player > div > strong, .encounter-match__player > div > span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.encounter-match__player > div > strong { font-size: 10px; }
.encounter-match__player > div > span { margin-top: 3px; color: var(--text-secondary); font-size: 8px; }
.encounter-match__performance { text-align: right; font-variant-numeric: tabular-nums; }
.encounter-match__performance strong { font-size: 10px; }
.encounter-match__performance span { color: var(--text-secondary); }
.encounter-match__player em { position: absolute; top: 2px; right: 4px; color: var(--accent); font-size: 7px; font-style: normal; }
@media (max-width: 720px) { .encounter-match__teams { grid-template-columns: 1fr; } }
</style>
