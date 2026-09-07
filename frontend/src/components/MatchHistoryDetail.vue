<script setup lang="ts">
import { Coins, Crosshair, Download, HeartPulse, Shield, Swords, Target, X } from "@lucide/vue";
import { computed } from "vue";
import type { BanSummary, MatchParticipant, MatchSummary } from "../types/domain";
import AssetIcon from "./AssetIcon.vue";
import { backend, isTauri } from "../services/backend";
import { championImage, roleName, shortDate } from "../utils/format";

const props = defineProps<{ match: MatchSummary }>();
const emit = defineEmits<{ close: []; exported: [path: string]; exportError: [message: string] }>();

const itemSlots = Array.from({ length: 8 }, (_, index) => index);
const isUnfinished = (match: MatchSummary) => match.durationMinutes === 0;
const isWin = (match: MatchSummary) => !isUnfinished(match) && match.result === "胜利";
const resultLabel = (match: MatchSummary) => isUnfinished(match) ? "未完成" : isWin(match) ? "胜利" : "失败";
const number = (value: number | undefined) => new Intl.NumberFormat("zh-CN", { notation: "compact", maximumFractionDigits: 1 }).format(value ?? 0);
const sourceLabel = (source: string) => source === "lcu" ? "LCU 实时" : source === "fixture" ? "Fixture" : source.includes("sqlite") ? "SQLite 缓存" : source;
const itemsOf = (participant: MatchParticipant) => participant.items ?? [];
const spellsOf = (participant: MatchParticipant) => participant.summonerSpells ?? [];
const runesOf = (participant: MatchParticipant) => participant.runes ?? [];
const participantGroups = computed(() => [
  { key: "ally", label: "我方", rows: props.match.participants.filter((participant) => participant.side !== "enemy") },
  { key: "enemy", label: "敌方", rows: props.match.participants.filter((participant) => participant.side === "enemy") },
].filter((group) => group.rows.length));
const banDetails = computed<BanSummary[]>(() => props.match.banDetails?.length ? props.match.banDetails : props.match.bans.map((name) => ({ id: 0, name, iconUrl: "" })));
const banGroups = computed(() => {
  const details = banDetails.value;
  const hasSides = details.some((ban) => ban.side === "ally" || ban.side === "enemy");
  if (hasSides) return [
    { key: "ally", label: "我方禁用", rows: details.filter((ban) => ban.side === "ally") },
    { key: "enemy", label: "敌方禁用", rows: details.filter((ban) => ban.side === "enemy") },
  ];
  const midpoint = Math.ceil(details.length / 2);
  return [
    { key: "ally", label: "我方禁用", rows: details.slice(0, midpoint) },
    { key: "enemy", label: "敌方禁用", rows: details.slice(midpoint) },
  ];
});
const groupDamage = (rows: MatchParticipant[]) => rows.reduce((sum, participant) => sum + participant.damageDealt, 0);
const groupKills = (rows: MatchParticipant[]) => rows.reduce((sum, participant) => sum + participant.kills, 0);

function downloadFile(content: string, name: string, type: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 500);
}

async function saveExport(content: string, format: "csv" | "json", type: string) {
  const name = `lol-match-${props.match.gameId}.${format}`;
  try {
    if (isTauri()) {
      const path = await backend.saveMatchExport(props.match.gameId, format, content);
      emit("exported", path);
      return;
    }
    downloadFile(content, name, type);
    emit("exported", `浏览器下载：${name}`);
  } catch (cause) {
    emit("exportError", cause instanceof Error ? cause.message : String(cause));
  }
}

function downloadJson() {
  void saveExport(JSON.stringify(props.match, null, 2), "json", "application/json;charset=utf-8");
}

function csvCell(value: unknown) {
  return `"${String(value ?? "").replace(/"/g, "\"\"")}"`;
}

function downloadCsv() {
  const header = ["比赛ID", "日期", "结果", "模式", "时长", "阵营", "玩家", "PUUID", "英雄", "位置", "K/D/A", "伤害", "伤害占比", "承伤", "承伤占比", "经济", "补刀", "参团", "治疗", "推塔伤害", "推塔数", "插眼", "排眼", "视野分", "真眼", "装备", "召唤师技能", "符文", "人机"];
  const rows = props.match.participants.map((participant) => [
    props.match.gameId, props.match.playedAt, resultLabel(props.match), props.match.queueName, props.match.durationMinutes,
    participant.side === "enemy" ? "敌方" : "我方", participant.gameName, participant.puuid, participant.championName,
    roleName(participant.position), `${participant.kills}/${participant.deaths}/${participant.assists}`, participant.damageDealt,
    `${Math.round((participant.damageShare ?? 0) * 100)}%`, participant.damageTaken, `${Math.round((participant.damageTakenShare ?? 0) * 100)}%`,
    participant.goldEarned, participant.cs, `${Math.round((participant.killParticipation ?? 0) * 100)}%`, participant.heal ?? 0,
    participant.towerDamage ?? 0, participant.turretKills ?? 0, participant.wardsPlaced ?? 0, participant.wardsKilled ?? 0,
    participant.visionScore ?? 0, participant.visionWardsBought ?? 0,
    itemsOf(participant).map((item) => item.name).join(" / "), spellsOf(participant).map((spell) => spell.name).join(" / "),
    runesOf(participant).map((rune) => rune.name).join(" / "), participant.isBot ? "是" : "否",
  ].map(csvCell).join(","));
  void saveExport(`\uFEFF${[header.map(csvCell).join(","), ...rows].join("\n")}`, "csv", "text/csv;charset=utf-8");
}
</script>

<template>
  <article class="history-detail" :data-result="isUnfinished(match) ? 'unfinished' : isWin(match) ? 'win' : 'loss'">
    <header class="history-detail__header">
      <div>
        <span class="eyebrow">MATCH DETAIL / {{ shortDate(match.playedAt) }}</span>
        <div class="history-detail__result"><i /><strong>{{ resultLabel(match) }}</strong><span>{{ match.queueName }}</span><span>{{ match.durationMinutes ? `${match.durationMinutes} 分钟` : "训练 / 中途退出" }}</span></div>
      </div>
      <div class="history-detail__actions"><button type="button" title="下载 JSON 明细" @click="downloadJson"><Download :size="14" />JSON</button><button type="button" title="下载 CSV 明细" @click="downloadCsv"><Download :size="14" />CSV</button><button class="history-detail__close" type="button" aria-label="关闭对局详情" title="关闭详情" @click="emit('close')"><X :size="16" /></button></div>
    </header>

    <section class="history-detail__hero">
      <div class="history-detail__champion"><AssetIcon kind="champion" :id="match.championId" :name="match.championName" :fallback-url="championImage(match.championId)" size="xl" /><div><strong>{{ match.championName }}</strong><span>{{ roleName(match.position) }} · {{ sourceLabel(match.dataStatus.source) }}</span><small>{{ shortDate(match.playedAt) }}</small></div></div>
      <div class="history-detail__kda"><span>K / D / A</span><strong>{{ match.kills }} <b>/</b> {{ match.deaths }} <b>/</b> {{ match.assists }}</strong><small>{{ ((match.kills + match.assists) / Math.max(1, match.deaths)).toFixed(2) }} KDA</small></div>
      <div class="history-detail__headline"><span>{{ match.mvp ?? "本局表现" }}</span><strong>{{ match.performance === "carry" ? "Carry" : match.performance === "carried" ? "躺赢" : match.performance === "struggling" ? "低迷" : "正常" }}</strong><small>{{ Math.round(match.killParticipation * 100) }}% 参团</small></div>
      <div class="history-detail__hero-loadout">
        <div class="history-detail__hero-items"><span>装备</span><div class="history-detail__icons"><template v-for="index in itemSlots" :key="`item-${index}`"><AssetIcon v-if="match.items[index]" kind="item" :id="match.items[index]!.id" :name="match.items[index]!.name" :fallback-url="match.items[index]!.iconUrl" size="sm" /><i v-else class="history-detail__empty-icon">{{ index === 6 ? "饰" : index === 7 ? "任" : "—" }}</i></template></div></div>
        <div class="history-detail__hero-utilities"><span><b>召唤师技能</b><i><AssetIcon v-for="spell in match.summonerSpells" :key="`spell-${spell.id}`" kind="spell" :id="spell.id" :name="spell.name" :fallback-url="spell.iconUrl" size="sm" /></i></span><span><b>符文</b><i><AssetIcon v-for="rune in match.runes" :key="`rune-${rune.id}`" kind="perk" :id="rune.id" :name="rune.name" :fallback-url="rune.iconUrl" size="sm" /></i></span></div>
      </div>
    </section>

    <section class="history-detail__stats" aria-label="对局数据">
      <div><Crosshair :size="14" /><span>英雄伤害</span><strong>{{ number(match.damageDealt) }}</strong><small>{{ Math.round(match.damageShare * 100) }}% 团队</small></div>
      <div><Shield :size="14" /><span>承受伤害</span><strong>{{ number(match.damageTaken) }}</strong><small>{{ Math.round(match.damageTakenShare * 100) }}% 团队</small></div>
      <div><Coins :size="14" /><span>经济</span><strong>{{ number(match.goldEarned) }}</strong><small>全场经济</small></div>
      <div><Swords :size="14" /><span>补刀</span><strong>{{ match.cs }}</strong><small>总补刀</small></div>
      <div><HeartPulse :size="14" /><span>治疗</span><strong>{{ number(match.heal) }}</strong><small>有效治疗</small></div>
      <div><Target :size="14" /><span>推塔</span><strong>{{ number(match.towerDamage) }}</strong><small>{{ match.turretKills }} 座防御塔</small></div>
    </section>

    <section class="history-detail__teams">
      <div class="history-detail__section-heading"><div><span class="eyebrow">PLAYERS / BP</span><h3>十人完整数据</h3></div><span>队伍击杀 {{ match.teamKills }} · 下载可留存全部字段</span></div>
      <div class="history-detail__bans"><section v-for="group in banGroups" :key="group.key" :data-side="group.key"><span>{{ group.label }} · {{ group.rows.length }}</span><div><div v-for="ban in group.rows" :key="`${group.key}-${ban.id}-${ban.name}`" class="history-detail__ban" :title="ban.bannedBy ? `禁用者：${ban.bannedBy}` : ban.pickTurn ? `第 ${ban.pickTurn} 手禁用` : 'LCU 未提供具体禁用者'"><AssetIcon v-if="ban.id" kind="champion" :id="ban.id" :name="ban.name" :fallback-url="ban.iconUrl" size="sm" /><i v-else class="history-detail__empty-icon">禁</i><b>{{ ban.name }}</b><small v-if="ban.bannedBy">{{ ban.bannedBy }}</small><small v-else-if="ban.pickTurn">第{{ ban.pickTurn }}手</small></div><small v-if="!group.rows.length">暂无记录</small></div></section></div>
      <div class="history-detail__participant-groups"><section v-for="group in participantGroups" :key="group.key" class="history-detail__participant-group" :data-side="group.key"><header><strong>{{ group.label }} · {{ group.rows.length }} 人</strong><span>{{ groupKills(group.rows) }} 击杀 · {{ number(groupDamage(group.rows)) }} 伤害</span></header><div class="history-detail__table-scroll"><table class="history-detail__participant-table"><thead><tr><th>玩家 / 英雄</th><th>K/D/A</th><th>伤害</th><th>承伤</th><th>经济</th><th>补刀</th><th>参团</th><th>视野</th><th>装备</th><th>召唤师技能</th><th>符文</th></tr></thead><tbody><tr v-for="participant in group.rows" :key="participant.puuid"><td class="history-detail__player"><AssetIcon kind="champion" :id="participant.championId" :name="participant.championName" :fallback-url="championImage(participant.championId)" size="md" /><span><strong>{{ participant.gameName }}<em v-if="participant.isBot">人机</em></strong><small>{{ participant.championName }} · {{ roleName(participant.position) }}</small></span></td><td class="history-detail__numeric"><strong>{{ participant.kills }}/{{ participant.deaths }}/{{ participant.assists }}</strong></td><td class="history-detail__numeric"><strong>{{ number(participant.damageDealt) }}</strong><small>{{ Math.round((participant.damageShare ?? 0) * 100) }}%</small></td><td class="history-detail__numeric"><strong>{{ number(participant.damageTaken) }}</strong><small>{{ Math.round((participant.damageTakenShare ?? 0) * 100) }}%</small></td><td class="history-detail__numeric">{{ number(participant.goldEarned) }}</td><td class="history-detail__numeric">{{ participant.cs }}</td><td class="history-detail__numeric">{{ Math.round((participant.killParticipation ?? 0) * 100) }}%</td><td class="history-detail__numeric"><strong>{{ participant.wardsPlaced ?? 0 }}/{{ participant.wardsKilled ?? 0 }}</strong><small>视野分 {{ participant.visionScore ?? 0 }}</small></td><td class="history-detail__loadout-cell"><div class="history-detail__mini-row"><AssetIcon v-for="item in itemsOf(participant)" :key="`p-item-${participant.puuid}-${item.id}`" kind="item" :id="item.id" :name="item.name" :fallback-url="item.iconUrl" size="sm" /><i v-if="!itemsOf(participant).length">—</i></div></td><td class="history-detail__loadout-cell"><div class="history-detail__mini-row"><AssetIcon v-for="spell in spellsOf(participant)" :key="`p-spell-${participant.puuid}-${spell.id}`" kind="spell" :id="spell.id" :name="spell.name" :fallback-url="spell.iconUrl" size="sm" /><i v-if="!spellsOf(participant).length">—</i></div></td><td class="history-detail__loadout-cell"><div class="history-detail__mini-row"><AssetIcon v-for="rune in runesOf(participant)" :key="`p-rune-${participant.puuid}-${rune.id}`" kind="perk" :id="rune.id" :name="rune.name" :fallback-url="rune.iconUrl" size="sm" /><i v-if="!runesOf(participant).length">—</i></div></td></tr></tbody></table></div></section></div>
    </section>
  </article>
</template>

<style scoped>
.history-detail { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-left: 3px solid var(--accent); background: var(--surface); }.history-detail[data-result="win"] { border-left-color: var(--green); }.history-detail[data-result="loss"] { border-left-color: var(--red); }.history-detail[data-result="unfinished"] { border-left-color: var(--amber); }
.history-detail__header, .history-detail__section-heading { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }.history-detail__header { padding: 12px 15px 10px; border-bottom: 1px solid var(--line); }.history-detail__result { display: flex; align-items: center; gap: 7px; margin-top: 6px; }.history-detail__result i { width: 7px; height: 7px; border-radius: 50%; background: var(--green); }.history-detail[data-result="loss"] .history-detail__result i { background: var(--red); }.history-detail[data-result="unfinished"] .history-detail__result i { background: var(--amber); }.history-detail__result strong { font-size: 17px; }.history-detail[data-result="win"] .history-detail__result strong { color: var(--green); }.history-detail[data-result="loss"] .history-detail__result strong { color: var(--red); }.history-detail[data-result="unfinished"] .history-detail__result strong { color: var(--amber); }.history-detail__result span { color: var(--text-secondary); font-size: 9px; }.history-detail__actions { display: flex; align-items: center; gap: 4px; }.history-detail__actions > button { display: inline-flex; align-items: center; gap: 4px; height: 27px; padding: 0 7px; border: 1px solid var(--line); color: var(--text-secondary); background: transparent; cursor: pointer; font-size: 9px; }.history-detail__actions > button:hover { color: var(--accent); border-color: var(--accent); }.history-detail__close { display: grid !important; place-items: center; width: 27px; padding: 0 !important; }
.history-detail__hero { display: grid; grid-template-columns: minmax(0, 1fr) auto auto; align-items: center; gap: 14px; padding: 12px 15px; background: var(--surface-raised); }.history-detail__champion { display: flex; align-items: center; gap: 9px; min-width: 0; }.history-detail__champion div { min-width: 0; }.history-detail__champion strong, .history-detail__champion span, .history-detail__champion small { display: block; }.history-detail__champion strong { font-size: 15px; }.history-detail__champion span { margin-top: 3px; color: var(--text-secondary); font-size: 9px; }.history-detail__champion small { margin-top: 3px; color: var(--text-muted); font-size: 8px; }.history-detail__kda, .history-detail__headline { min-width: 78px; }.history-detail__kda span, .history-detail__kda small, .history-detail__headline span, .history-detail__headline small { display: block; color: var(--text-secondary); font-size: 8px; }.history-detail__kda strong { display: block; margin-top: 4px; color: var(--text-primary); font-size: 18px; font-variant-numeric: tabular-nums; white-space: nowrap; }.history-detail__kda strong b { color: var(--text-muted); font-size: 11px; font-weight: 500; }.history-detail__kda small, .history-detail__headline small { margin-top: 3px; color: var(--accent); }.history-detail__headline strong { display: block; margin-top: 4px; font-size: 15px; }
.history-detail__stats { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 1px; padding: 1px; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: var(--line); }.history-detail__stats > div { display: grid; grid-template-columns: 15px minmax(0, 1fr); gap: 2px 5px; padding: 8px; background: var(--surface); }.history-detail__stats svg { grid-row: span 3; color: var(--accent); }.history-detail__stats span, .history-detail__stats small { color: var(--text-secondary); font-size: 8px; }.history-detail__stats strong { color: var(--text-primary); font-size: 11px; font-variant-numeric: tabular-nums; }.history-detail__stats small { color: var(--text-muted); }
.history-detail__loadout, .history-detail__teams { padding: 11px 15px; }.history-detail__loadout { border-bottom: 1px solid var(--line); }.history-detail__section-heading { align-items: center; margin-bottom: 8px; }.history-detail__section-heading h3 { margin: 2px 0 0; font-size: 12px; }.history-detail__section-heading > span { color: var(--text-secondary); font-size: 8px; }.history-detail__loadout-grid { display: grid; grid-template-columns: minmax(280px, 2fr) minmax(100px, .7fr) minmax(130px, 1fr); gap: 1px; border: 1px solid var(--line); background: var(--line); }.history-detail__loadout-cell { min-width: 0; padding: 7px 8px; background: var(--surface); }.history-detail__loadout-cell > span { display: block; margin-bottom: 5px; color: var(--text-secondary); font-size: 8px; }.history-detail__icons { display: flex; align-items: center; gap: 4px; min-width: 0; flex-wrap: wrap; }.history-detail__empty-icon { display: inline-grid; place-items: center; width: 26px; height: 26px; border: 1px dashed var(--line-strong); color: var(--text-muted); background: var(--surface-raised); font-size: 7px; font-style: normal; }.history-detail__icons small { color: var(--text-muted); font-size: 8px; }
.history-detail__teams { background: var(--surface-raised); }.history-detail__bans { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px; padding: 7px 0 9px; border-top: 1px solid var(--line); }.history-detail__bans > section { min-width: 0; padding: 6px; border-top: 2px solid var(--blue); background: var(--surface); }.history-detail__bans > section[data-side="enemy"] { border-top-color: var(--red); }.history-detail__bans > section > span { display: block; margin-bottom: 5px; color: var(--text-secondary); font-size: 8px; }.history-detail__bans > section > div { display: flex; align-items: center; flex-wrap: wrap; gap: 4px; }.history-detail__ban { display: inline-flex; align-items: center; gap: 4px; padding: 2px 4px 2px 2px; border: 1px solid var(--line); color: var(--text-primary); background: var(--surface-raised); }.history-detail__ban b { font-size: 8px; font-weight: 500; }.history-detail__bans small { color: var(--text-muted); font-size: 8px; }
.history-detail__participant-groups { display: grid; gap: 8px; }.history-detail__participant-group { min-width: 0; border-top: 2px solid var(--blue); background: var(--surface); }.history-detail__participant-group[data-side="enemy"] { border-top-color: var(--red); }.history-detail__participant-group > header { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 8px; border-bottom: 1px solid var(--line); }.history-detail__participant-group > header strong { font-size: 9px; }.history-detail__participant-group > header span { color: var(--text-secondary); font-size: 8px; }.history-detail__table-scroll { overflow-x: auto; }.history-detail__participant-table { width: 100%; min-width: 1170px; border-collapse: collapse; table-layout: fixed; }.history-detail__participant-table th, .history-detail__participant-table td { padding: 5px 6px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: middle; }.history-detail__participant-table th { color: var(--text-muted); background: var(--surface-muted); font-size: 7px; font-weight: 600; white-space: nowrap; }.history-detail__participant-table td { color: var(--text-secondary); font-size: 8px; }.history-detail__participant-table th:nth-child(1), .history-detail__participant-table td:nth-child(1) { width: 188px; }.history-detail__participant-table th:nth-child(2), .history-detail__participant-table td:nth-child(2) { width: 66px; }.history-detail__participant-table th:nth-child(3), .history-detail__participant-table td:nth-child(3), .history-detail__participant-table th:nth-child(4), .history-detail__participant-table td:nth-child(4) { width: 68px; }.history-detail__participant-table th:nth-child(5), .history-detail__participant-table td:nth-child(5) { width: 62px; }.history-detail__participant-table th:nth-child(6), .history-detail__participant-table td:nth-child(6), .history-detail__participant-table th:nth-child(7), .history-detail__participant-table td:nth-child(7) { width: 45px; }.history-detail__participant-table th:nth-child(8), .history-detail__participant-table td:nth-child(8) { width: 64px; }.history-detail__participant-table th:nth-child(9), .history-detail__participant-table td:nth-child(9), .history-detail__participant-table th:nth-child(10), .history-detail__participant-table td:nth-child(10), .history-detail__participant-table th:nth-child(11), .history-detail__participant-table td:nth-child(11) { width: 126px; }.history-detail__player { display: flex; align-items: center; gap: 7px; min-width: 0; }.history-detail__player > span { min-width: 0; }.history-detail__player strong, .history-detail__player small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.history-detail__player strong { color: var(--text-primary); font-size: 9px; }.history-detail__player small { margin-top: 2px; color: var(--text-secondary); font-size: 7px; }.history-detail__player em { margin-left: 3px; padding: 1px 2px; color: var(--amber); background: var(--amber-soft); font-size: 6px; font-style: normal; }.history-detail__numeric { font-variant-numeric: tabular-nums; white-space: nowrap; }.history-detail__numeric strong, .history-detail__numeric small { display: block; }.history-detail__numeric strong { color: var(--text-primary); font-size: 8px; }.history-detail__numeric small { margin-top: 2px; color: var(--text-muted); font-size: 7px; }.history-detail__loadout-cell { min-width: 0; }.history-detail__mini-row { display: flex; align-items: center; gap: 3px; min-height: 24px; overflow: hidden; white-space: nowrap; }.history-detail__mini-row span { overflow: hidden; color: var(--text-muted); font-size: 7px; text-overflow: ellipsis; }.history-detail__mini-row > i { color: var(--text-muted); font-style: normal; }.history-detail__participant-table tbody tr:last-child td { border-bottom: 0; }
@media (max-width: 900px) { .history-detail__hero { grid-template-columns: 1fr 1fr; }.history-detail__champion { grid-column: 1 / -1; }.history-detail__stats { grid-template-columns: repeat(3, minmax(0, 1fr)); } }.history-detail__participant-table :deep(.asset-icon--sm) { width: 22px; height: 22px; }.history-detail__participant-table :deep(.asset-icon--md) { width: 34px; height: 34px; }
.history-detail__table-scroll { max-width: 100%; }
.history-detail__participant-table { min-width: 1080px; }
.history-detail__participant-table td.history-detail__loadout-cell { padding-inline: 3px; }
.history-detail__mini-row { gap: 2px; }
.history-detail__ban small { color: var(--text-muted); font-size: 7px; white-space: nowrap; }
@media (max-width: 760px) { .history-detail__loadout-grid, .history-detail__bans { grid-template-columns: 1fr; } }
@media (max-width: 620px) { .history-detail__header, .history-detail__loadout, .history-detail__teams { padding-inline: 10px; }.history-detail__stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }.history-detail__hero { padding: 10px; gap: 10px; }.history-detail__actions > button:not(.history-detail__close) { padding-inline: 5px; }.history-detail__actions > button:not(.history-detail__close) { font-size: 8px; } }

/* Keep the selected player's loadout beside the hero on wide index layouts. */
.history-detail__hero { grid-template-columns: minmax(170px, 1fr) auto auto minmax(280px, 1.15fr); gap: 12px; padding-block: 10px; }
.history-detail__hero-loadout { display: grid; gap: 5px; min-width: 0; padding-left: 9px; border-left: 1px solid var(--line); }
.history-detail__hero-items, .history-detail__hero-utilities > span { display: flex; align-items: center; gap: 6px; min-width: 0; }
.history-detail__hero-items > span, .history-detail__hero-utilities b { flex: none; color: var(--text-secondary); font-size: 8px; font-weight: 600; }
.history-detail__hero-items .history-detail__icons { flex-wrap: nowrap; overflow: hidden; }
.history-detail__hero-items .asset-icon--sm, .history-detail__hero-utilities .asset-icon--sm { width: 24px; height: 24px; }
.history-detail__hero-utilities { display: grid; grid-template-columns: auto 1fr; gap: 4px 10px; min-width: 0; }
.history-detail__hero-utilities > span:last-child { grid-column: 1 / -1; }
.history-detail__hero-utilities i { display: flex; gap: 3px; min-width: 0; font-style: normal; }
.history-detail__participant-table { min-width: 980px; }
@media (max-width: 1100px) {
  .history-detail__hero { grid-template-columns: minmax(150px, 1fr) auto auto; }
  .history-detail__hero-loadout { grid-column: 1 / -1; padding: 7px 0 0; border-top: 1px solid var(--line); border-left: 0; }
}
</style>
