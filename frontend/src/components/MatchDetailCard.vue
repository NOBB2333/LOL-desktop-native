<script setup lang="ts">
import { computed } from "vue";
import { ChevronDown, ChevronUp, Coins, Crosshair, HeartPulse, Shield, Swords, TowerControl, Trophy } from "@lucide/vue";
import type { MatchSummary, RecentMatch } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import { championImage, roleName, shortDate } from "../utils/format";

const props = withDefaults(defineProps<{
  match: MatchSummary | RecentMatch;
  expanded?: boolean;
  compact?: boolean;
  /**
   * 宿主显式声明「这一行可以展开」。
   *
   * 默认判定看数据形态：带 `participants` 的 `MatchSummary` 本来就能展开。
   * 首页 / 对局页拿到的行本身没有 `participants`（只有查询者本人一条），
   * 展开能力由宿主用 `useMatchDetail` 补上，那些场景必须显式传 `true`，
   * 否则箭头不渲染、点了也没反应。
   *
   * 只做「额外允许」，不做「禁止」：`boolean` 类型的 prop 在 Vue 里缺省会被强转成
   * `false`，写成 `props.expandable ?? isSummary(...)` 会让所有不传它的调用方都失去
   * 展开能力（这正是之前首页点不动的原因）。没有任何调用方需要禁止展开，所以用
   * `isSummary(...) || expandable === true`。
   */
  expandable?: boolean;
  /** 展开后正在按 gameId 拉完整十人数据。 */
  detailLoading?: boolean;
  /** 完整十人数据读取失败的原因；空串表示没有失败。 */
  detailError?: string;
}>(), { expanded: false, compact: false, detailLoading: false, detailError: "" });

const emit = defineEmits<{ toggle: [] }>();
const isSummary = (match: MatchSummary | RecentMatch): match is MatchSummary => "participants" in match;
/** 这一行能不能展开：带 `participants` 的数据自带十人明细，或者宿主显式允许。 */
const canExpand = computed(() => isSummary(props.match) || props.expandable === true);
/**
 * 展开后要渲染的那份「有十人明细」的数据。
 *
 * 宿主会把 `useMatchDetail().matchForRow()` 的结果传进来，所以明细到位后这里才会有值；
 * 在此之前是 null —— 模板据此走「正在读取这局的十人数据…」分支，而不是硬渲染
 * 一份不存在 `participants` 的列表数据。
 */
const summary = computed<MatchSummary | null>(() => (isSummary(props.match) ? props.match : null));
const banRows = computed(() => (summary.value ? banGroups(summary.value) : []));
const teamRows = computed(() => (summary.value ? participantGroups(summary.value) : []));
const teamKillsText = computed(() => {
  const value = summary.value?.teamKills;
  return typeof value === "number" ? String(value) : "—";
});
const unfinished = (match: MatchSummary | RecentMatch) => match.durationMinutes === 0;
const win = (match: MatchSummary | RecentMatch) => !unfinished(match) && ("win" in match ? match.win : match.result === "胜利");
const resultLabel = (match: MatchSummary | RecentMatch) => unfinished(match) ? "未完成" : win(match) ? "胜利" : "失败";
const resultClass = (match: MatchSummary | RecentMatch) => unfinished(match) ? "unfinished" : win(match) ? "win" : "loss";
const performance = (match: MatchSummary | RecentMatch) => !win(match) && match.performance === "carried" ? "solid" : match.performance;
const performanceLabel = (match: MatchSummary | RecentMatch) => {
  const labels = { carry: "Carry", solid: "正常", carried: "躺赢", struggling: "低迷" } as const;
  return labels[performance(match)];
};
const outcomeLabel = (match: MatchSummary | RecentMatch) => {
  if (unfinished(match)) return null;
  if (win(match) && performance(match) === "carried") return "躺赢局";
  if (win(match) && match.kills >= 8 && match.deaths <= 3 && match.damageShare >= 0.25) return "碾压局";
  if (!win(match) && match.deaths <= 4 && match.damageShare >= 0.25) return "惜败局";
  return null;
};
const damageTakenShare = (match: MatchSummary | RecentMatch) => isSummary(match) ? match.damageTakenShare : null;
const towerDamage = (match: MatchSummary | RecentMatch) => isSummary(match) ? match.towerDamage : 0;
const turretKills = (match: MatchSummary | RecentMatch) => isSummary(match) ? match.turretKills : 0;
const towerLeader = (match: MatchSummary | RecentMatch) => isSummary(match) && match.towerLeader;
const number = (value: number) => new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 1 }).format(value);
const fallbackChampion = (match: MatchSummary | RecentMatch) => championImage(match.championId);
const itemSlots = Array.from({ length: 8 }, (_, index) => index);
const itemAt = (match: MatchSummary | RecentMatch, index: number) => match.items[index] ?? null;
const participantItems = (participant: MatchSummary["participants"][number]) => participant.items ?? [];
/** 仍然是列表级数据（只有查询者本人），十人详情还没到位。 */
const incompleteParticipants = computed(() => !isSummary(props.match) || props.match.participants.length < 2);
const participantSpells = (participant: MatchSummary["participants"][number]) => participant.summonerSpells ?? [];
const participantRunes = (participant: MatchSummary["participants"][number]) => participant.runes ?? [];
const participantGroups = (match: MatchSummary) => [
  { key: "ally", label: "我方阵容", rows: match.participants.filter((participant) => participant.side === "ally") },
  { key: "enemy", label: "敌方阵容", rows: match.participants.filter((participant) => participant.side === "enemy") },
];
const banGroups = (match: MatchSummary) => {
  const details = match.banDetails ?? [];
  const hasSides = details.some((ban) => ban.side === "ally" || ban.side === "enemy");
  if (hasSides) return [
    { key: "ally", label: "我方禁用", rows: details.filter((ban) => ban.side === "ally") },
    { key: "enemy", label: "敌方禁用", rows: details.filter((ban) => ban.side === "enemy") },
  ];
  const midpoint = Math.ceil(match.bans.length / 2);
  return [
    { key: "ally", label: "我方禁用", rows: details.slice(0, midpoint) },
    { key: "enemy", label: "敌方禁用", rows: details.slice(midpoint) },
  ];
};
function toggleFromRow(event: MouseEvent) {
  // 只要这一行能展开，点行身也应该展开：首页 / 对局页的行本来就没有单独的可点区域，
  // 之前这里额外要求 `clickable`，结果那些页面上点击毫无反应（只有右上角小箭头能用）。
  if (!canExpand.value) return;
  const target = event.target as HTMLElement | null;
  if (!target?.closest) return;
  // 详情区是行的子节点：在里面选文字、点图标都算「看详情」，不该把刚展开的行收回去。
  // 收起请点右上角的箭头（那个按钮自带 @click.stop）。
  if (target.closest(".match-row__detail")) return;
  if (target.closest("button, a, input, select, textarea")) return;
  emit("toggle");
}
</script>

<template>
  <article
    class="match-row"
    :class="[`match-row--${resultClass(match)}`, { 'match-row--compact': compact, 'match-row--clickable': canExpand }]"
    :data-game-id="match.gameId"
    :aria-label="`${resultLabel(match)}，${match.championName}，${match.kills}/${match.deaths}/${match.assists}`"
    @click="toggleFromRow"
  >
    <span v-if="match.mvp" class="match-row__mvp-mark" :data-mvp="match.mvp" :title="`${match.mvp}：本地评分模型生成，并非 Riot 官方 MVP 字段`"><Trophy :size="12" /><em>{{ match.mvp }}</em></span>
    <div class="match-row__identity">
      <div class="match-row__asset-cluster">
        <AssetIcon kind="champion" :id="match.championId" :name="match.championName" :fallback-url="fallbackChampion(match)" size="lg" />
        <div class="match-row__spells" aria-label="召唤师技能">
          <AssetIcon v-for="spell in match.summonerSpells" :key="`spell-${spell.id}`" kind="spell" :id="spell.id" :name="spell.name" :fallback-url="spell.iconUrl" size="sm" />
        </div>
      </div>

      <div class="match-row__identity-copy">
        <div class="match-row__mode-line">
          <span class="match-row__result-dot" />
          <strong>{{ match.queueName }}</strong>
          <span>{{ roleName(match.position) }}</span>
          <span v-if="outcomeLabel(match)" class="match-row__outcome">{{ outcomeLabel(match) }}</span>
        </div>
        <div class="match-row__champion-name">{{ match.championName }}</div>
        <div class="match-row__time">{{ match.durationMinutes }} 分钟 · {{ shortDate(match.playedAt) }}</div>
      </div>
    </div>

    <div class="match-row__kda">
      <strong><b>{{ match.kills }}</b><i>/</i><em>{{ match.deaths }}</em><i>/</i><b>{{ match.assists }}</b></strong>
      <span>{{ ((match.kills + match.assists) / Math.max(1, match.deaths)).toFixed(2) }} KDA</span>
      <small>{{ Math.round(match.killParticipation * 100) }}% 参团</small>
    </div>

    <div class="match-row__traits">
      <div class="match-row__runes" aria-label="符文">
        <AssetIcon v-for="rune in match.runes" :key="`rune-${rune.id}`" kind="perk" :id="rune.id" :name="rune.name" :fallback-url="rune.iconUrl" size="sm" />
      </div>
      <div class="match-row__badges">
        <span class="match-row__badge" :data-performance="performance(match)" title="本地规则根据胜负、KDA 与伤害贡献生成">{{ performanceLabel(match) }}</span>
        <span v-if="towerLeader(match)" class="match-row__badge match-row__badge--tower" title="本局十人中对防御塔伤害最高">拆塔最高</span>
      </div>
    </div>

    <div class="match-row__metrics">
      <div class="match-row__stat">
        <Crosshair :size="13" />
        <span>输出</span>
        <strong>{{ number(match.damageDealt) }}</strong>
        <small>{{ Math.round(match.damageShare * 100) }}%</small>
      </div>
      <div class="match-row__stat">
        <Shield :size="13" />
        <span>承伤</span>
        <strong>{{ number(match.damageTaken) }}</strong>
        <small v-if="damageTakenShare(match) !== null">{{ Math.round((damageTakenShare(match) ?? 0) * 100) }}%</small>
      </div>
      <div class="match-row__stat">
        <HeartPulse :size="13" />
        <span>治疗</span>
        <strong>{{ number(match.heal) }}</strong>
      </div>
      <div class="match-row__stat">
        <Coins :size="13" />
        <span>经济</span>
        <strong>{{ number(match.goldEarned) }}</strong>
      </div>
      <div class="match-row__stat">
        <Swords :size="13" />
        <span>补刀</span>
        <strong>{{ match.cs }}</strong>
      </div>
      <div class="match-row__stat">
        <TowerControl :size="13" />
        <span>推塔</span>
        <strong>{{ number(towerDamage(match)) }}</strong>
        <small v-if="turretKills(match)">{{ turretKills(match) }} 座</small>
      </div>
    </div>

    <button
      v-if="canExpand"
      class="match-row__toggle"
      type="button"
      :aria-expanded="expanded"
      :aria-label="expanded ? '收起对局详情' : '展开对局详情'"
      @click.stop="emit('toggle')"
    >
      <ChevronUp v-if="expanded" :size="16" />
      <ChevronDown v-else :size="16" />
    </button>

    <div class="match-row__items">
      <span>装备</span>
      <div class="match-row__item-list">
        <template v-for="index in itemSlots" :key="`item-slot-${index}`">
          <AssetIcon v-if="itemAt(match, index)" kind="item" :id="itemAt(match, index)!.id" :name="itemAt(match, index)!.name" :fallback-url="itemAt(match, index)!.iconUrl" size="sm" />
          <span v-else class="match-row__item-slot" :class="{ 'match-row__item-slot--quest': index === 7 }" :title="index === 6 ? '饰品 / 扫描位' : index === 7 ? '任务进度：当前 LCU 比赛数据未提供' : '装备数据未提供'">{{ index === 7 ? "任务" : index === 6 ? "饰品" : "—" }}</span>
        </template>
      </div>
    </div>

    <section v-if="expanded && canExpand" class="match-row__detail">
      <header>
        <div><span class="eyebrow">MATCH DETAIL</span><h3>十人阵容与 BP</h3></div>
        <span>队伍击杀 {{ teamKillsText }}</span>
      </header>
      <!-- 列表接口每局只带查询者本人，十人数据要按 gameId 单独拉；这期间先说明情况。 -->
      <p v-if="incompleteParticipants && detailLoading" class="match-row__detail-status">正在读取这局的十人数据…</p>
      <p v-else-if="incompleteParticipants && detailError" class="match-row__detail-status" data-tone="warning">{{ detailError }}</p>
      <p v-else-if="incompleteParticipants" class="match-row__detail-status">这局没有可用的十人明细（通常是人机、训练或数据源未提供）。</p>
      <template v-if="summary">
        <div class="match-row__bans">
          <section v-for="group in banRows" :key="group.key" :data-side="group.key"><span>{{ group.label }}</span><div><template v-for="ban in group.rows" :key="`${group.key}-${ban.id}-${ban.name}`"><span class="ban-chip" :title="ban.bannedBy ? `禁用者：${ban.bannedBy}` : ban.pickTurn ? `第 ${ban.pickTurn} 手禁用` : 'LCU 未提供具体禁用者'"><AssetIcon v-if="ban.id" kind="champion" :id="ban.id" :name="ban.name" :fallback-url="ban.iconUrl" size="sm" /><b>{{ ban.name }}</b><small v-if="ban.bannedBy">{{ ban.bannedBy }}</small><small v-else-if="ban.pickTurn">第{{ ban.pickTurn }}手</small></span></template><b v-if="!group.rows.length">暂无记录</b></div></section>
        </div>
        <div class="match-row__participants">
          <section v-for="group in teamRows" :key="group.key" class="participant-team" :data-side="group.key">
            <header><strong>{{ group.label }}</strong><span>{{ group.rows.length }} 人</span></header>
            <div class="participant-team__rows">
              <div v-for="participant in group.rows" :key="participant.puuid || `${participant.championId}-${participant.gameName}`" class="participant-line" :data-side="participant.side">
                <AssetIcon class="participant-line__champion" kind="champion" :id="participant.championId" :name="participant.championName" :fallback-url="championImage(participant.championId)" size="sm" />
                <span class="participant-line__identity"><strong>{{ participant.gameName }}<em v-if="participant.isBot">人机</em></strong><small>{{ participant.championName }} · {{ roleName(participant.position) }}</small></span>
                <b class="participant-line__kda">{{ participant.kills }}/{{ participant.deaths }}/{{ participant.assists }}</b>
                <span class="participant-line__metric participant-line__damage"><strong>{{ number(participant.damageDealt) }}</strong><small>英雄伤害</small></span>
                <span class="participant-line__metric participant-line__economy"><strong>{{ number(participant.goldEarned) }}</strong><small>{{ participant.cs }} 补刀</small></span>
                <span class="participant-line__icons participant-line__items"><AssetIcon v-for="item in participantItems(participant)" :key="`item-${participant.puuid}-${item.id}`" kind="item" :id="item.id" :name="item.name" :fallback-url="item.iconUrl" size="sm" /><i v-if="!participantItems(participant).length">无装备数据</i></span>
                <span class="participant-line__icons participant-line__spells"><AssetIcon v-for="spell in participantSpells(participant)" :key="`spell-${participant.puuid}-${spell.id}`" kind="spell" :id="spell.id" :name="spell.name" :fallback-url="spell.iconUrl" size="sm" /><i v-if="!participantSpells(participant).length">无技能</i></span>
                <span class="participant-line__icons participant-line__runes"><AssetIcon v-for="rune in participantRunes(participant)" :key="`rune-${participant.puuid}-${rune.id}`" kind="perk" :id="rune.id" :name="rune.name" :fallback-url="rune.iconUrl" size="sm" /><i v-if="!participantRunes(participant).length">无符文</i></span>
                <span class="participant-line__metric participant-line__vision"><strong>{{ participant.wardsPlaced ?? 0 }}/{{ participant.wardsKilled ?? 0 }}</strong><small>视野 {{ participant.visionScore ?? 0 }}</small></span>
              </div>
            </div>
          </section>
        </div>
      </template>
    </section>
  </article>
</template>

<style scoped>
.match-row {
  position: relative;
  display: grid;
  grid-template-areas:
    "identity kda traits items metrics toggle";
  grid-template-columns: minmax(205px, 1.12fr) minmax(102px, .58fr) minmax(112px, .64fr) minmax(228px, 1.1fr) minmax(245px, 1.35fr) 28px;
  align-items: center;
  gap: 7px 14px;
  min-width: 0;
  padding: 10px 10px 8px 13px;
  border: 1px solid color-mix(in srgb, var(--green) 44%, var(--line));
  border-left-width: 4px;
  background: color-mix(in srgb, var(--green-soft) 24%, var(--surface));
}

.match-row--clickable { cursor: pointer; }
.match-row--clickable:hover { border-color: var(--accent); }

.match-row--loss {
  border-color: color-mix(in srgb, var(--red) 44%, var(--line));
  background: color-mix(in srgb, var(--red-soft) 22%, var(--surface));
}

.match-row--unfinished {
  border-color: color-mix(in srgb, var(--amber) 48%, var(--line));
  background: color-mix(in srgb, var(--amber-soft) 18%, var(--surface));
}

.match-row--compact {
  padding-block: 8px 7px;
}

.match-row__identity {
  grid-area: identity;
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}

.match-row__mvp-mark {
  position: absolute;
  z-index: 2;
  top: 0;
  left: 0;
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 3px 5px 3px 4px;
  border-radius: 0 0 4px 0;
  color: #fff;
  background: var(--amber);
  font-size: 8px;
  font-style: normal;
  font-weight: 800;
  line-height: 1;
}

.match-row__mvp-mark[data-mvp="SVP"] {
  background: var(--blue);
}

.match-row__mvp-mark em {
  font-style: normal;
}

.match-row__asset-cluster {
  display: flex;
  align-items: stretch;
  gap: 3px;
  flex: none;
}

.match-row__spells {
  display: grid;
  align-content: center;
  gap: 3px;
}

.match-row__identity-copy {
  min-width: 0;
}

.match-row__mode-line {
  display: flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
}

.match-row__result-dot {
  width: 6px;
  height: 6px;
  flex: none;
  border-radius: 50%;
  background: var(--green);
}

.match-row--loss .match-row__result-dot {
  background: var(--red);
}

.match-row--unfinished .match-row__result-dot {
  background: var(--amber);
}

.match-row__mode-line strong {
  overflow: hidden;
  color: var(--text-primary);
  font-size: 12px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.match-row__mode-line span:last-child {
  flex: none;
  color: var(--text-secondary);
  font-size: 9px;
}

.match-row__outcome {
  flex: none;
  padding: 2px 4px;
  border-radius: 3px;
  color: var(--amber);
  background: var(--amber-soft);
  font-size: 8px !important;
  font-weight: 700;
}

.match-row__champion-name {
  margin-top: 3px;
  overflow: hidden;
  color: var(--text-secondary);
  font-size: 10px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.match-row__time {
  margin-top: 3px;
  color: var(--text-muted);
  font-size: 9px;
}

.match-row__kda {
  grid-area: kda;
  min-width: 0;
}

.match-row__kda strong {
  display: flex;
  align-items: baseline;
  gap: 4px;
  font-size: 16px;
  font-variant-numeric: tabular-nums;
}

.match-row__kda strong b {
  color: var(--text-primary);
}

.match-row__kda strong em {
  color: var(--red);
  font-style: normal;
}

.match-row__kda strong i {
  color: var(--text-muted);
  font-size: 11px;
  font-style: normal;
}

.match-row__kda span,
.match-row__kda small {
  display: block;
  margin-top: 3px;
  color: var(--text-muted);
  font-size: 9px;
}

.match-row__kda small {
  color: var(--accent);
}

.match-row__traits {
  grid-area: traits;
  display: grid;
  gap: 6px;
  min-width: 0;
}

.match-row__runes,
.match-row__badges,
.match-row__item-list {
  display: flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
}

.match-row__badges {
  flex-wrap: wrap;
}

.match-row__badge {
  padding: 2px 5px;
  border-radius: 3px;
  color: var(--blue);
  background: var(--blue-soft);
  font-size: 8px;
  font-weight: 700;
  line-height: 1.35;
}

.match-row__badge[data-performance="carry"] {
  color: var(--green);
  background: var(--green-soft);
}

.match-row__badge[data-performance="carried"] {
  color: var(--amber);
  background: var(--amber-soft);
}

.match-row__badge[data-performance="struggling"] {
  color: var(--red);
  background: var(--red-soft);
}

.match-row__badge--mvp {
  color: #fff;
  background: var(--amber);
}

.match-row__badge--mvp[data-mvp="SVP"] {
  background: var(--blue);
}

.match-row__badge--tower {
  color: var(--accent);
  background: var(--accent-soft);
}

.match-row__metrics {
  grid-area: metrics;
  display: grid;
  grid-template-columns: repeat(3, minmax(80px, 1fr));
  gap: 5px 8px;
  min-width: 0;
}

.match-row__stat {
  display: grid;
  grid-template-columns: 14px minmax(20px, 1fr) minmax(0, auto) minmax(0, 30px);
  align-items: center;
  gap: 3px;
  min-width: 0;
  color: var(--text-muted);
  font-size: 8px;
}

.match-row__stat svg {
  color: var(--accent);
}

.match-row__stat strong {
  overflow: hidden;
  color: var(--text-primary);
  font-size: 10px;
  font-variant-numeric: tabular-nums;
  text-align: right;
  text-overflow: ellipsis;
}

.match-row__stat small {
  min-width: 0;
  overflow: hidden;
  color: var(--text-muted);
  font-size: 8px;
  text-align: right;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.match-row__toggle {
  grid-area: toggle;
  display: grid;
  place-items: center;
  width: 28px;
  height: 100%;
  min-height: 54px;
  padding: 0;
  border: 1px solid var(--line);
  border-radius: 4px;
  color: var(--text-secondary);
  background: var(--surface-raised);
  cursor: pointer;
  transition: color 140ms ease, border-color 140ms ease, transform 140ms cubic-bezier(.23, 1, .32, 1);
}

.match-row__toggle:hover {
  color: var(--accent);
  border-color: var(--accent);
}

.match-row__toggle:active {
  transform: scale(.97);
}

.match-row__items {
  grid-area: items;
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  padding-top: 6px;
  border-top: 1px solid color-mix(in srgb, var(--line) 75%, transparent);
}

.match-row__items > span {
  flex: none;
  color: var(--text-muted);
  font-size: 8px;
  font-weight: 700;
}

.match-row__item-list small {
  color: var(--text-muted);
  font-size: 9px;
}

.match-row__item-list {
  flex-wrap: nowrap;
  overflow: visible;
}

.match-row__item-slot { display: inline-grid; place-items: center; width: 26px; height: 26px; border: 1px dashed var(--line-strong); border-radius: 4px; color: var(--text-muted); background: var(--surface-raised); font-size: 7px; line-height: 1; text-align: center; }.match-row__item-slot--quest { width: 32px; color: var(--amber); border-color: color-mix(in srgb, var(--amber) 50%, var(--line)); background: var(--amber-soft); }

.match-row__detail {
  grid-column: 1 / -1;
  margin: 2px -10px -8px -13px;
  padding: 13px;
  border-top: 1px solid var(--line);
  background: var(--surface-raised);
}

.match-row__detail header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  color: var(--text-secondary);
  font-size: 10px;
}

.match-row__detail h3 {
  margin: 3px 0 0;
  color: var(--text-primary);
  font-size: 14px;
}

.match-row__bans {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 5px;
  margin: 10px 0;
  color: var(--text-secondary);
  font-size: 9px;
}

.match-row__detail-status { margin: 9px 0 0; padding: 7px 9px; border: 1px dashed var(--line-strong); color: var(--text-secondary); font-size: 9px; }
.match-row__detail-status[data-tone="warning"] { color: var(--amber); }

.match-row__bans section { display: grid; grid-template-columns: 68px minmax(0, 1fr); align-items: center; gap: 5px; min-width: 0; padding: 5px 7px; border-top: 2px solid var(--blue); background: var(--surface); }
.match-row__bans section[data-side="enemy"] { border-top-color: var(--red); }
.match-row__bans section > div { display: flex; align-items: center; gap: 3px; min-width: 0; }
.match-row__bans b { overflow: hidden; color: var(--text-primary); font-size: 8px; font-weight: 500; text-overflow: ellipsis; white-space: nowrap; }
.ban-chip { display: inline-flex; align-items: center; gap: 3px; min-width: 0; padding: 2px 3px 2px 2px; border: 1px solid var(--line); background: var(--surface-raised); }.ban-chip b { max-width: 72px; }.ban-chip small { color: var(--text-muted); font-size: 7px; white-space: nowrap; }

.match-row__participants {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 7px;
  min-width: 0;
}

.participant-team { min-width: 0; overflow: hidden; border: 1px solid var(--line); background: var(--surface); }
.participant-team > header { display: flex; align-items: center; justify-content: space-between; gap: 6px; min-height: 26px; padding: 4px 7px; border-bottom: 1px solid var(--line); color: var(--text-secondary); font-size: 8px; }
.participant-team[data-side="ally"] > header { border-top: 2px solid var(--blue); }.participant-team[data-side="enemy"] > header { border-top: 2px solid var(--red); }
.participant-team > header strong { color: var(--text-primary); font-size: 9px; }.participant-team__rows { display: grid; gap: 2px; padding: 3px; }
.participant-line {
  display: grid;
  grid-template-columns: 28px minmax(80px, 1fr) 48px 55px 54px minmax(94px, 1.15fr) minmax(38px, .5fr) minmax(58px, .65fr) 45px;
  grid-template-areas:
    "champion identity kda damage economy items spells runes vision";
  align-items: center;
  gap: 4px;
  min-width: 0;
  min-height: 42px;
  padding: 3px 4px;
  color: var(--text-secondary);
  font-size: 8px;
}

.participant-line[data-side="ally"] {
  background: color-mix(in srgb, var(--green-soft) 65%, transparent);
}

.participant-line[data-side="enemy"] {
  background: color-mix(in srgb, var(--red-soft) 55%, transparent);
}

.participant-line__champion { grid-area: champion; }.participant-line__identity { grid-area: identity; }.participant-line__kda { grid-area: kda; }.participant-line__damage { grid-area: damage; }.participant-line__economy { grid-area: economy; }.participant-line__items { grid-area: items; }.participant-line__spells { grid-area: spells; }.participant-line__runes { grid-area: runes; }.participant-line__vision { grid-area: vision; }

.participant-line strong,
.participant-line span,
.participant-line small {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.participant-line strong,
.participant-line b {
  color: var(--text-primary);
}

.participant-line b {
  font-variant-numeric: tabular-nums;
}
.participant-line > span:not(.participant-line__icons) { display: grid; gap: 2px; min-width: 0; }
.participant-line small { color: var(--text-muted); font-size: 7px; }
.participant-line__identity em { margin-left: 4px; color: var(--blue); font-size: 7px; font-style: normal; }
.participant-line__icons { display: flex; align-items: center; gap: 2px; min-width: 0; overflow: hidden; }
.participant-line__icons i { color: var(--text-muted); font-size: 7px; font-style: normal; }

@media (max-width: 1050px) {
  .match-row {
    grid-template-areas:
      "identity kda traits toggle"
      "items metrics metrics toggle";
    grid-template-columns: minmax(220px, 1.1fr) minmax(100px, .55fr) minmax(150px, .8fr) 28px;
  }

  .match-row__metrics {
    grid-template-columns: repeat(3, minmax(80px, 1fr));
  }
}

@media (max-width: 720px) {
  .match-row {
    grid-template-areas:
      "identity toggle"
      "kda toggle"
      "traits toggle"
      "metrics toggle"
      "items toggle";
    grid-template-columns: minmax(0, 1fr) 28px;
  }

  .match-row__kda {
    display: flex;
    align-items: baseline;
    gap: 8px;
  }

  .match-row__kda span,
  .match-row__kda small {
    margin-top: 0;
  }

  .match-row__participants {
    grid-template-columns: 1fr;
  }
}
</style>
