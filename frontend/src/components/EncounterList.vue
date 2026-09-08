<script setup lang="ts">
import { Eye, RefreshCw } from "@lucide/vue";
import type { EncounterRecord } from "../types/domain";
import { encounterKda, encounterTime, type EncounterGame } from "../utils/encounters";
import { championImage, roleName } from "../utils/format";
import AssetIcon from "./AssetIcon.vue";

defineProps<{ games: EncounterGame[]; loading?: boolean; error?: boolean; compact?: boolean }>();
defineEmits<{ select: [records: EncounterRecord[]]; retry: [] }>();
const riotId = (name?: string, tag?: string) => `${name || "未知玩家"}${tag ? `#${tag}` : ""}`;
const result = (win?: boolean) => win == null ? "待结算" : win ? "胜" : "负";
</script>

<template>
  <div class="encounter-list" :class="{ 'encounter-list--compact': compact }" :aria-busy="loading">
    <div v-if="error" class="encounter-list__status" role="alert">共同对局读取失败<button type="button" title="重试" aria-label="重试相遇记录" @click.stop="$emit('retry')"><RefreshCw :size="14" /></button></div>
    <div v-else-if="loading && !games.length" class="encounter-list__status">正在读取共同对局...</div>
    <div v-else-if="!games.length" class="encounter-list__status">当前战绩样本中没有共同对局</div>
    <button v-for="game in games" :key="game.gameId" type="button" class="encounter-list__game" data-testid="encounter-match-open" @click.stop="$emit('select', game.records)">
      <span class="encounter-list__heading"><time>{{ encounterTime(game.target.encounteredAt) }}</time><span>{{ game.target.queueName || "对局" }}</span><Eye :size="14" /></span>
      <span class="encounter-list__players">
        <span class="encounter-list__player" data-subject="self">
          <AssetIcon kind="champion" :id="game.target.selfChampionId || 0" :name="game.target.selfChampionName || '未知英雄'" :fallback-url="championImage(game.target.selfChampionId || 0)" size="sm" />
          <span><small>我 · {{ roleName(game.target.selfPosition || '') }}</small><strong>{{ game.target.selfChampionName || "未知英雄" }}</strong><span :title="riotId(game.target.selfGameName, game.target.selfTagLine)">{{ riotId(game.target.selfGameName, game.target.selfTagLine) }}</span></span>
          <b>{{ encounterKda(game.target.selfKills, game.target.selfDeaths, game.target.selfAssists) }} <em :data-win="game.target.selfWin">{{ result(game.target.selfWin) }}</em></b>
        </span>
        <span class="encounter-list__player" data-subject="target">
          <AssetIcon kind="champion" :id="game.target.championId" :name="game.target.championName" :fallback-url="championImage(game.target.championId)" size="sm" />
          <span><small :data-side="game.target.side">{{ game.target.side === 'ally' ? '当时队友' : game.target.side === 'enemy' ? '当时对手' : '关系未知' }} · {{ roleName(game.target.position || '') }}</small><strong>{{ game.target.championName || "未知英雄" }}</strong><span :title="riotId(game.target.gameName, game.target.tagLine)">{{ riotId(game.target.gameName, game.target.tagLine) }}</span></span>
          <b>{{ encounterKda(game.target.kills, game.target.deaths, game.target.assists) }} <em :data-win="game.target.win">{{ result(game.target.win) }}</em></b>
        </span>
      </span>
    </button>
  </div>
</template>

<style scoped>
.encounter-list { min-width: 0; }
.encounter-list--compact { width: min(480px, calc(100vw - 48px)); max-height: 420px; overflow-y: auto; }
.encounter-list__status { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 0; color: var(--text-secondary); font-size: 12px; }
.encounter-list__status button { display: grid; place-items: center; width: 28px; height: 28px; color: inherit; background: transparent; border: 1px solid var(--line); cursor: pointer; }
.encounter-list__game { display: block; width: 100%; padding: 10px 2px; border: 0; border-bottom: 1px solid var(--line); color: var(--text-primary); background: transparent; text-align: left; cursor: pointer; }
.encounter-list__game:hover, .encounter-list__game:focus-visible { background: var(--accent-soft); outline: 1px solid var(--accent); outline-offset: -1px; }
.encounter-list__heading { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; color: var(--text-secondary); font-size: 11px; }
.encounter-list__heading > span { flex: 1; }
.encounter-list__heading svg { flex: none; color: var(--accent); }
.encounter-list__players { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.encounter-list__player { display: grid; grid-template-columns: 30px minmax(0, 1fr); align-items: center; gap: 4px 8px; min-width: 0; }
.encounter-list__player > span { min-width: 0; }
.encounter-list__player small, .encounter-list__player strong, .encounter-list__player > span > span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.encounter-list__player small { color: var(--text-muted); font-size: 10px; }
.encounter-list__player small[data-side="ally"] { color: var(--blue); }
.encounter-list__player small[data-side="enemy"] { color: var(--red); }
.encounter-list__player strong { font-size: 12px; }
.encounter-list__player > span > span { color: var(--text-secondary); font-size: 10px; }
.encounter-list__player > b { grid-column: 2; font-size: 12px; font-variant-numeric: tabular-nums; }
.encounter-list__player em { margin-left: 5px; color: var(--text-muted); font-size: 10px; font-style: normal; }
.encounter-list__player em[data-win="true"] { color: var(--green); }
.encounter-list__player em[data-win="false"] { color: var(--red); }
@media (max-width: 480px) { .encounter-list__players { grid-template-columns: 1fr; } }
</style>
