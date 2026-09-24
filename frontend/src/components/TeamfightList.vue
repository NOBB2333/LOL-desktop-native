<script setup lang="ts">
/**
 * 每波团：左边一张地图标出落点（编号与右边列表一一对应），右边是事件列表。
 *
 * ⚠️ 地图**本身是深色底图**，所以图上的圆点用写死的亮色，不能用跟随主题的
 * `--blue` / `--red`——浅色主题下那些 token 是深色，会糊在底图里看不见。
 */
import { computed } from "vue";
import map11 from "../assets/map11.png";
import AssetIcon from "./AssetIcon.vue";
import { mapToImagePosition } from "../live/gameMap";
import { clockOf, TEAM_BLUE, TEAM_RED, teamLabel } from "../matches/timeline";
import { describeLocation, type Teamfight } from "../matches/teamfights";
import { championImage } from "../utils/format";

const props = defineProps<{
  fights: Teamfight[];
  championNameOf: (id: number) => string;
}>();

const toneOf = (fight: Teamfight) =>
  fight.winningTeam === TEAM_BLUE ? "blue" : fight.winningTeam === TEAM_RED ? "red" : "even";

function pinStyle(fight: Teamfight) {
  if (!fight.center) return {};
  const { left, top } = mapToImagePosition(fight.center.x, fight.center.y, 1, 1);
  return { left: `${left * 100}%`, top: `${top * 100}%` };
}

/** 两边各自的参战者，蓝在前。空的一边也返回，界面才知道「这波是单边」。 */
function sidesOf(fight: Teamfight) {
  return [TEAM_BLUE, TEAM_RED].map((team) => ({
    team,
    members: fight.involved.filter((member) => member.team === team),
  }));
}

function scoreOf(fight: Teamfight) {
  return `${teamLabel(TEAM_BLUE)} ${fight.killsByTeam[TEAM_BLUE] ?? 0} : ${fight.killsByTeam[TEAM_RED] ?? 0} ${teamLabel(TEAM_RED)}`;
}

const located = computed(() => props.fights.filter((fight) => fight.center));
</script>

<template>
  <div v-if="fights.length" class="teamfights">
    <div class="teamfights__map" :class="{ 'teamfights__map--empty': !located.length }">
      <img class="teamfights__plate" :src="map11" alt="召唤师峡谷地图" />
      <span
        v-for="fight in located"
        :key="fight.index"
        class="teamfights__pin"
        :style="pinStyle(fight)"
        :data-tone="toneOf(fight)"
        :title="describeLocation(fight.center)"
        :aria-label="`第 ${fight.index} 波团：${describeLocation(fight.center)}`"
      >{{ fight.index }}</span>
      <span v-if="!located.length" class="teamfights__no-position">这一局的事件没有带位置，画不出落点</span>
    </div>

    <ol class="teamfights__list">
      <li v-for="fight in fights" :key="fight.index" class="teamfight" :data-tone="toneOf(fight)">
        <span class="teamfight__index">{{ fight.index }}</span>
        <div class="teamfight__body">
          <div class="teamfight__head">
            <strong>{{ describeLocation(fight.center) }}</strong>
            <span class="teamfight__time">{{ clockOf(fight.startSeconds) }}–{{ clockOf(fight.endSeconds) }}</span>
            <span class="teamfight__score">{{ scoreOf(fight) }}</span>
          </div>
          <div class="teamfight__sides">
            <div v-for="side in sidesOf(fight)" :key="side.team" class="teamfight__side" :data-team="side.team">
              <AssetIcon v-for="member in side.members" :key="member.participantId" kind="champion" :id="member.championId" :name="championNameOf(member.championId)" :fallback-url="championImage(member.championId)" size="xs" />
              <small v-if="!side.members.length">无人</small>
            </div>
          </div>
        </div>
      </li>
    </ol>
  </div>
  <p v-else class="teamfights__none">
    Riot 的数据里<b>没有团战事件</b>，「团战」是按击杀聚类算出来的；这一局没有聚出符合条件的击杀簇。
  </p>
</template>

<style scoped>
.teamfights { display: grid; grid-template-columns: 148px minmax(0, 1fr); gap: 14px; align-items: start; }
.teamfights__map { position: relative; aspect-ratio: 1; border: 1px solid var(--line); background: #0b1210; }
.teamfights__map--empty { display: grid; place-items: center; }
.teamfights__plate { display: block; width: 100%; height: 100%; object-fit: cover; }
.teamfights__pin { position: absolute; display: grid; place-items: center; width: 17px; height: 17px; margin: -8px 0 0 -8px; border-radius: 50%; color: #08201a; background: #ffd166; font-size: 10px; font-weight: 700; }
.teamfights__pin[data-tone="blue"] { background: #57b4ff; }
.teamfights__pin[data-tone="red"] { background: #ff7a7a; }
.teamfights__no-position { padding: 10px; color: rgba(255, 255, 255, .62); font-size: 9px; text-align: center; line-height: 1.5; }
.teamfights__list { display: grid; gap: 8px; margin: 0; padding: 0; list-style: none; }
.teamfight { display: grid; grid-template-columns: 20px minmax(0, 1fr); gap: 9px; align-items: start; padding: 8px 10px; border: 1px solid var(--line); border-left: 3px solid var(--line-strong); background: var(--surface); }
.teamfight[data-tone="blue"] { border-left-color: #57b4ff; }
.teamfight[data-tone="red"] { border-left-color: #ff7a7a; }
.teamfight[data-tone="even"] { border-left-color: #ffd166; }
.teamfight__index { display: grid; place-items: center; width: 20px; height: 20px; border-radius: 50%; color: var(--text-secondary); background: var(--surface-muted); font-size: 10px; font-weight: 700; }
.teamfight__body { display: grid; gap: 6px; min-width: 0; }
.teamfight__head { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
.teamfight__head strong { font-size: 12px; }
.teamfight__time { color: var(--text-muted); font-size: 10px; font-variant-numeric: tabular-nums; }
.teamfight__score { margin-left: auto; color: var(--text-secondary); font-size: 11px; font-variant-numeric: tabular-nums; }
.teamfight__sides { display: grid; gap: 3px; }
.teamfight__side { display: flex; align-items: center; gap: 3px; min-height: 18px; flex-wrap: wrap; }
.teamfight__side[data-team="100"] { border-left: 2px solid #57b4ff; padding-left: 5px; }
.teamfight__side[data-team="200"] { border-left: 2px solid #ff7a7a; padding-left: 5px; }
.teamfight__side small { color: var(--text-muted); font-size: 9px; }
.teamfights__none { margin: 0; padding: 12px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }
.teamfights__none b { color: var(--text-secondary); }
@media (max-width: 900px) { .teamfights { grid-template-columns: 1fr; }.teamfights__map { max-width: 200px; } }
</style>
