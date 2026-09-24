<script setup lang="ts">
/**
 * 一局的**十人对位面板**——比赛转播那种「一眼看出谁压谁」的表，而不是十个小头像。
 *
 * 数据全部来自这一局的十人详情（`MatchParticipant`），**不需要额外请求**：
 * 每行 = 英雄头像 + 称号 + 玩家名 + K/D/A + 当前指标的柱条和数值。
 * 指标可以切：输出 / 承伤 / 经济 / 补刀，柱条长度按全场最大值归一，
 * 所以跨分路也能比出「全场伤害王」；分路内部谁压谁则用 `data-lead` 高亮。
 *
 * 配对规则：位置齐全时按五路配对（上/野/中/下/辅），一边缺人就空着；
 * 位置缺失（大乱斗、或数据源没给位置）时按当前指标**从高到低逐一配对**，
 * 避免摆出一张随机顺序的表。
 *
 * 附带两件小事：
 * - 本地相遇档案里见过的人标「遇到过 N 次」——把原来「同场的人」那块的价值收进来；
 * - `stats` 里的等级/段位（后端按批拉，可能还没到）以 `Lv.315 · 钻石II` 的形式跟在名字后，
 *   没到就不渲染，到了自然补上。
 */
import { computed, ref } from "vue";
import AssetIcon from "./AssetIcon.vue";
import type { MatchParticipant, PlayerStatSummary } from "../types/domain";
import { championImage, rankName, roleName } from "../utils/format";

type MetricKey = "damage" | "taken" | "gold" | "cs";

const props = defineProps<{
  participants: MatchParticipant[];
  /** 当前登录账号；命中的行标「我」。 */
  selfPuuid?: string;
  /** puuid → 本地相遇档案里的相遇次数。 */
  encounterCounts?: Record<string, number>;
  /** puuid → 等级/段位；取不到的人字段为 null。 */
  stats?: Record<string, PlayerStatSummary>;
}>();

const METRICS = [
  { key: "damage", label: "输出", of: (participant: MatchParticipant) => participant.damageDealt },
  { key: "taken", label: "承伤", of: (participant: MatchParticipant) => participant.damageTaken },
  { key: "gold", label: "经济", of: (participant: MatchParticipant) => participant.goldEarned },
  { key: "cs", label: "补刀", of: (participant: MatchParticipant) => participant.cs },
] as const;

const metric = ref<MetricKey>("damage");
const metricDef = computed(() => METRICS.find((item) => item.key === metric.value) ?? METRICS[0]);
const metricOf = (participant: MatchParticipant) => metricDef.value.of(participant);

const compact = (value: number) => new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 1 }).format(value ?? 0);
const kda = (participant: MatchParticipant) => `${participant.kills}/${participant.deaths}/${participant.assists}`;

/** 参团率是比率，单独算个文案（没有就不显示）。 */
const participation = (participant: MatchParticipant) =>
  participant.killParticipation == null ? "" : `参团 ${Math.round(participant.killParticipation * 100)}%`;

const rankText = (puuid: string) => {
  const stat = props.stats?.[puuid];
  if (!stat) return "";
  const rank = stat.soloRank ?? stat.flexRank;
  const parts: string[] = [];
  if (stat.summonerLevel) parts.push(`Lv.${stat.summonerLevel}`);
  if (rank?.tier) parts.push(`${rankName(rank.tier)}${rank.division}`);
  return parts.join(" · ") || "—";
};

const sides = computed(() => ({
  ally: props.participants.filter((participant) => participant.side !== "enemy"),
  enemy: props.participants.filter((participant) => participant.side === "enemy"),
}));

/** 有几个人真的带位置（大乱斗没有，别按五路硬配）。 */
const hasPositions = computed(() => {
  const lanes = new Set(sides.value.ally.concat(sides.value.enemy).map((participant) => (participant.position || "").trim().toUpperCase()));
  return lanes.has("TOP") || lanes.has("JUNGLE") || lanes.has("MIDDLE") || lanes.has("BOTTOM");
});

const POSITION_ORDER = ["TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY"] as const;

interface Pair {
  key: string;
  label: string;
  ally?: MatchParticipant;
  enemy?: MatchParticipant;
}

const pairs = computed<Pair[]>(() => {
  const { ally, enemy } = sides.value;
  if (hasPositions.value) {
    return POSITION_ORDER.map((position) => ({
      key: position,
      label: roleName(position),
      ally: ally.find((participant) => (participant.position || "").trim().toUpperCase() === position),
      enemy: enemy.find((participant) => (participant.position || "").trim().toUpperCase() === position),
    })).filter((pair) => pair.ally || pair.enemy);
  }
  const byMetric = (list: MatchParticipant[]) => [...list].sort((left, right) => metricOf(right) - metricOf(left));
  const left = byMetric(ally);
  const right = byMetric(enemy);
  return Array.from({ length: Math.max(left.length, right.length) }, (_, index) => ({
    key: `slot-${index}`,
    label: roleName(left[index]?.position || right[index]?.position),
    ally: left[index],
    enemy: right[index],
  }));
});

const maxValue = computed(() => Math.max(1, ...props.participants.map(metricOf)));
const widthOf = (participant: MatchParticipant) => {
  const value = metricOf(participant);
  return value <= 0 ? "0%" : `${Math.max(2, Math.round((value / maxValue.value) * 100))}%`;
};

type Lead = "ally" | "enemy" | "even";
const leadOf = (pair: Pair): Lead => {
  if (!pair.ally || !pair.enemy) return "even";
  const ally = metricOf(pair.ally);
  const enemy = metricOf(pair.enemy);
  return ally === enemy ? "even" : ally > enemy ? "ally" : "enemy";
};

const teamTotals = computed(() => {
  const ally = sides.value.ally.reduce((sum, participant) => sum + metricOf(participant), 0);
  const enemy = sides.value.enemy.reduce((sum, participant) => sum + metricOf(participant), 0);
  const total = ally + enemy;
  return {
    ally,
    enemy,
    allyWidth: total <= 0 ? "50%" : `${Math.round((ally / total) * 100)}%`,
    allyLead: ally >= enemy,
  };
});

const metBadge = (participant: MatchParticipant) => {
  if (participant.puuid && participant.puuid === props.selfPuuid) return "我";
  const count = props.encounterCounts?.[participant.puuid] ?? 0;
  return count > 0 ? `遇到过 ${count}` : "";
};

const isHighlighted = (participant: MatchParticipant) => Boolean(props.selfPuuid && participant.puuid === props.selfPuuid);
</script>

<template>
  <div class="lineup">
    <header class="lineup__head">
      <div class="lineup__metrics" role="group" aria-label="对比指标">
        <button v-for="item in METRICS" :key="item.key" type="button" :class="{ active: metric === item.key }" @click="metric = item.key">{{ item.label }}</button>
      </div>
      <div class="lineup__totals" :title="`蓝方 ${compact(teamTotals.ally)} / 红方 ${compact(teamTotals.enemy)}`">
        <b :data-side="teamTotals.allyLead ? 'ally' : 'none'">蓝方 {{ compact(teamTotals.ally) }}</b>
        <i class="lineup__totals-bar"><span :style="{ width: teamTotals.allyWidth }" /></i>
        <b :data-side="teamTotals.allyLead ? 'none' : 'enemy'">{{ compact(teamTotals.enemy) }} 红方</b>
      </div>
    </header>

    <ul v-if="pairs.length" class="lineup__list">
      <li v-for="pair in pairs" :key="pair.key" class="duel" :data-lead="leadOf(pair)">
        <span class="duel__lane">{{ pair.label }}</span>

        <div class="duel__side" data-side="ally" :data-lead="leadOf(pair) === 'ally'">
          <template v-if="pair.ally">
            <AssetIcon kind="champion" :id="pair.ally.championId" :name="pair.ally.championName" :fallback-url="championImage(pair.ally.championId)" size="xs" />
            <div class="duel__who" :class="{ 'is-highlighted': isHighlighted(pair.ally) }">
              <b>{{ pair.ally.championName }}<i v-if="metBadge(pair.ally)">{{ metBadge(pair.ally) }}</i></b>
              <small :title="`${pair.ally.gameName} · ${kda(pair.ally)} · ${participation(pair.ally)}`">{{ pair.ally.gameName }} · {{ kda(pair.ally) }}</small>
              <small v-if="rankText(pair.ally.puuid)" class="duel__rank">{{ rankText(pair.ally.puuid) }}</small>
            </div>
            <i class="duel__meter"><b :style="{ width: widthOf(pair.ally) }" /></i>
            <span class="duel__value">{{ compact(metricOf(pair.ally)) }}</span>
          </template>
          <template v-else><span class="duel__empty">—</span></template>
        </div>

        <div class="duel__side" data-side="enemy" :data-lead="leadOf(pair) === 'enemy'">
          <template v-if="pair.enemy">
            <span class="duel__value">{{ compact(metricOf(pair.enemy)) }}</span>
            <i class="duel__meter"><b :style="{ width: widthOf(pair.enemy) }" /></i>
            <div class="duel__who" :class="{ 'is-highlighted': isHighlighted(pair.enemy) }">
              <b>{{ pair.enemy.championName }}<i v-if="metBadge(pair.enemy)">{{ metBadge(pair.enemy) }}</i></b>
              <small :title="`${pair.enemy.gameName} · ${kda(pair.enemy)} · ${participation(pair.enemy)}`">{{ pair.enemy.gameName }} · {{ kda(pair.enemy) }}</small>
              <small v-if="rankText(pair.enemy.puuid)" class="duel__rank">{{ rankText(pair.enemy.puuid) }}</small>
            </div>
            <AssetIcon kind="champion" :id="pair.enemy.championId" :name="pair.enemy.championName" :fallback-url="championImage(pair.enemy.championId)" size="xs" />
          </template>
          <template v-else><span class="duel__empty">—</span></template>
        </div>
      </li>
    </ul>
    <p v-else class="lineup__empty">这一局的十人数据没拿到（自定义对局、重开局或客户端缓存缺失时会发生）。</p>
  </div>
</template>

<style scoped>
.lineup { display: grid; gap: 8px; }
.lineup__head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.lineup__metrics { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
.lineup__metrics button { padding: 3px 10px; border: 0; color: var(--text-secondary); background: var(--surface); cursor: pointer; font-size: 10px; transition: color .12s, background .12s; }
.lineup__metrics button + button { border-left: 1px solid var(--line); }
.lineup__metrics button.active { color: var(--accent); background: var(--accent-soft); font-weight: 600; }

/* 队伍总量条：一眼看「哪边这局输出更高」。 */
.lineup__totals { display: grid; grid-template-columns: auto minmax(90px, 180px) auto; align-items: center; gap: 7px; }
.lineup__totals b { color: var(--text-secondary); font-size: 11px; font-variant-numeric: tabular-nums; white-space: nowrap; }
.lineup__totals b[data-side="ally"] { color: var(--blue); font-weight: 700; }
.lineup__totals b[data-side="enemy"] { color: var(--red); font-weight: 700; }
.lineup__totals-bar { position: relative; display: block; height: 7px; overflow: hidden; border: 1px solid var(--line); border-radius: 4px; background: var(--red-soft); }
.lineup__totals-bar span { position: absolute; inset: 0 auto 0 0; display: block; background: var(--blue); }

.lineup__list { display: grid; gap: 4px; margin: 0; padding: 0; list-style: none; }
.duel { display: grid; grid-template-columns: 26px minmax(0, 1fr) minmax(0, 1fr); align-items: center; gap: 7px; padding: 5px 8px; border: 1px solid var(--line); border-radius: 5px; background: var(--surface); }
.duel[data-lead="ally"] { border-left: 2px solid var(--blue); }
.duel[data-lead="enemy"] { border-right: 2px solid var(--red); }

/* 两半镜像：头像和名字在外侧、柱条贴着中线，数值并排在中间最好比。 */
.duel__side { display: grid; grid-template-columns: 20px minmax(0, 1fr) minmax(0, 1.15fr) 44px; align-items: center; gap: 6px; min-width: 0; }
.duel__side[data-side="enemy"] { grid-template-columns: 44px minmax(0, 1.15fr) minmax(0, 1fr) 20px; }
.duel__side[data-lead="true"] .duel__value { color: var(--text-primary); font-weight: 700; }
.duel__empty { color: var(--text-muted); font-size: 10px; }

.duel__who { min-width: 0; }
.duel__who b { display: block; overflow: hidden; color: var(--text-primary); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.duel__who b i { margin-left: 4px; padding: 0 4px; border-radius: 6px; color: var(--accent); background: var(--accent-soft); font-size: 8px; font-style: normal; font-weight: 500; }
.duel__who small { display: block; overflow: hidden; margin-top: 1px; color: var(--text-secondary); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.duel__rank { color: var(--text-muted) !important; }
.duel__who.is-highlighted b { color: var(--accent); }

.duel__meter { position: relative; display: block; height: 6px; overflow: hidden; border-radius: 3px; background: var(--surface-muted); }
.duel__meter b { position: absolute; top: 0; bottom: 0; right: 0; display: block; border-radius: 3px; background: var(--blue); }
.duel__side[data-side="enemy"] .duel__meter b { right: auto; left: 0; background: var(--red); }
.duel__value { color: var(--text-secondary); font-size: 10px; text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
.duel__side[data-side="enemy"] .duel__value { text-align: left; }

.lineup__empty { margin: 0; padding: 10px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }

@media (max-width: 720px) {
  .duel { grid-template-columns: 22px 1fr; }
  .duel__side { grid-column: 2; }
  .duel__side[data-side="ally"] { border-bottom: 1px dashed var(--line); padding-bottom: 4px; }
}
</style>
