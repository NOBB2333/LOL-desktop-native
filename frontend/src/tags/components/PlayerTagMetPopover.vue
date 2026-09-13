<script setup lang="ts">
import { computed } from "vue";
import AssetIcon from "../../components/AssetIcon.vue";
import type { EncounterRecord } from "../../types/domain";
import { encounterKda, type EncounterGame } from "../../utils/encounters";
import { championImage, dateTime, fromNow, roleName } from "../../utils/format";

const props = withDefaults(
  defineProps<{
    games: EncounterGame[];
    /** 后端统计到的相遇总次数（可能大于表格行数）。 */
    total?: number;
    /** 该玩家显示名，缺省时用「该玩家」。 */
    targetName?: string;
    /** 最近一次相遇时间；表格为空时用它兜底。 */
    lastMetAt?: string;
    /** 抽屉等场景已有分区标题，可隐藏这里的汇总说明。 */
    hideSummary?: boolean;
  }>(),
  { total: 0, targetName: "", lastMetAt: "", hideSummary: false },
);

const emit = defineEmits<{ inspect: [records: EncounterRecord[]] }>();

const rows = computed(() => props.games);
const totalCount = computed(() => Math.max(props.total, props.games.length));
const lastMetAt = computed(() => props.games[0]?.target.encounteredAt ?? props.lastMetAt);
const playerLabel = computed(() => props.targetName || "该玩家");

const resultLabel = (win?: boolean) => (win === true ? "胜利" : win === false ? "失败" : "待结算");
const relationLabel = (side?: string) => (side === "ally" ? "友" : side === "enemy" ? "敌" : "—");
const resultTone = (win?: boolean) => (win === true ? "win" : win === false ? "loss" : "unknown");
const relationTone = (side?: string) => (side === "ally" ? "ally" : side === "enemy" ? "enemy" : "unknown");
</script>

<template>
  <div class="met-popover">
    <div v-if="!hideSummary" class="met-popover__summary">
      <div>最近在 {{ dateTime(lastMetAt) }} 遇到过该玩家，共遇到过 {{ totalCount }} 次</div>
      <div class="met-popover__note">仅显示最近 {{ rows.length }} 场对局</div>
    </div>

    <div class="met-popover__scroll">
      <table class="met-table">
        <thead>
          <tr>
            <th>对局 ID</th>
            <th>对局日期</th>
            <th>结果</th>
            <th>关系</th>
            <th>自己</th>
            <th>{{ playerLabel }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="!rows.length">
            <td colspan="6" class="met-table__empty">当前战绩样本中没有可展示的共同对局</td>
          </tr>
          <tr v-for="game in rows" :key="game.gameId" data-testid="met-row">
            <td>
              <button
                type="button"
                class="met-table__game"
                :title="`查看 ${game.gameId} 整局详情`"
                data-testid="met-inspect"
                @click.stop="emit('inspect', game.records)"
              >
                查看 {{ game.gameId }}
              </button>
            </td>
            <td>
              <div class="met-table__time">
                <span>{{ dateTime(game.target.encounteredAt) }}</span>
                <small>({{ fromNow(game.target.encounteredAt) }})</small>
              </div>
            </td>
            <td>
              <span class="met-table__result" :data-tone="resultTone(game.target.selfWin)">
                {{ resultLabel(game.target.selfWin) }}
              </span>
            </td>
            <td>
              <span class="met-table__relation" :data-tone="relationTone(game.target.side)">
                {{ relationLabel(game.target.side) }}
              </span>
            </td>
            <td>
              <div class="met-table__participant">
                <small>{{ roleName(game.target.selfPosition) }}</small>
                <AssetIcon
                  kind="champion"
                  :id="game.target.selfChampionId || 0"
                  :name="game.target.selfChampionName || '未知英雄'"
                  :fallback-url="championImage(game.target.selfChampionId || 0)"
                  size="xs"
                />
                <b>{{ encounterKda(game.target.selfKills, game.target.selfDeaths, game.target.selfAssists) }}</b>
              </div>
            </td>
            <td>
              <div class="met-table__participant">
                <small>{{ roleName(game.target.position) }}</small>
                <AssetIcon
                  kind="champion"
                  :id="game.target.championId"
                  :name="game.target.championName"
                  :fallback-url="championImage(game.target.championId)"
                  size="xs"
                />
                <b>{{ encounterKda(game.target.kills, game.target.deaths, game.target.assists) }}</b>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<script lang="ts">
export default { name: "PlayerTagMetPopover" };
</script>

<style scoped>
.met-popover {
  font-size: 11px;
  color: var(--text-primary);
}

.met-popover__summary {
  margin-bottom: 6px;
  color: var(--text-secondary);
  line-height: 1.6;
}

.met-popover__note {
  color: var(--text-muted);
}

.met-popover__scroll {
  max-width: 100%;
  overflow-x: auto;
  border: 1px solid var(--line);
  border-radius: 5px;
  background: var(--surface);
}

.met-table {
  min-width: max-content;
  border-collapse: collapse;
  white-space: nowrap;
}

.met-table th,
.met-table td {
  padding: 4px 8px;
  border-left: 1px solid var(--line);
  text-align: center;
}

.met-table th:first-child,
.met-table td:first-child {
  border-left: 0;
}

.met-table thead th {
  color: var(--text-muted);
  background: var(--surface-muted);
  font-size: 10px;
  font-weight: 700;
}

.met-table tbody tr + tr td {
  border-top: 1px solid var(--line);
}

.met-table tbody tr:hover td {
  background: var(--accent-soft);
}

.met-table__game {
  padding: 1px 5px;
  border: 1px solid var(--line);
  border-radius: 3px;
  color: var(--text-secondary);
  background: var(--surface-raised);
  font: inherit;
  font-size: 10px;
  cursor: pointer;
}

.met-table__game:hover,
.met-table__game:focus-visible {
  border-color: var(--accent);
  color: var(--accent);
  outline: none;
}

.met-table__time {
  display: flex;
  align-items: baseline;
  gap: 4px;
  color: var(--text-secondary);
  font-size: 10px;
  font-variant-numeric: tabular-nums;
}

.met-table__time small {
  color: var(--text-muted);
  font-size: 9px;
}

.met-table__result {
  font-size: 10px;
  font-weight: 800;
}

.met-table__result[data-tone="win"] { color: var(--green); }
.met-table__result[data-tone="loss"] { color: var(--red); }
.met-table__result[data-tone="unknown"] { color: var(--text-muted); }

.met-table__relation {
  display: inline-block;
  padding: 0 5px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 800;
}

.met-table__relation[data-tone="ally"] {
  color: var(--blue);
  background: var(--blue-soft);
}

.met-table__relation[data-tone="enemy"] {
  color: var(--red);
  background: var(--red-soft);
}

.met-table__relation[data-tone="unknown"] {
  color: var(--text-muted);
  background: var(--surface-muted);
}

.met-table__participant {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 4px;
}

.met-table__participant small {
  color: var(--text-muted);
  font-size: 9px;
}

.met-table__participant b {
  font-size: 10px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.met-table__empty {
  padding: 10px 12px;
  color: var(--text-muted);
  font-size: 10px;
}
</style>
