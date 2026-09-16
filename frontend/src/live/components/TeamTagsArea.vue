<script setup lang="ts">
import { NPopover } from "naive-ui";
import { computed } from "vue";
import AssetIcon from "../../components/AssetIcon.vue";
import { useAppStore } from "../../stores/app";
import { premadeGroupColor } from "../../tags/tones";
import type { PlayerProfile } from "../../types/domain";
import { championImage } from "../../utils/format";
import { analyzeTeamStats, resolvePremadeTeamTags, type PremadeGroupRef } from "../teamStats";

/**
 * 队伍级标签条，移植 LeagueAkari 的 `widgets/TeamTagsArea.vue`：
 *
 *   [队伍平均胜率%] │ [队伍平均 KDA] │ [N 黑 pill…]
 *
 * 「胜率队 / 败率队」是预组队 pill 后面的附加徽标，判定见 `../teamStats.ts`。
 */
const props = defineProps<{
  players: PlayerProfile[];
  /** 该队的预组队分组（字母 + 内部配色序号 + 成员 puuid）。 */
  groups: PremadeGroupRef[];
}>();

const app = useAppStore();
const dark = computed(() => app.config.appearance.colorMode === "dark");

const stats = computed(() => analyzeTeamStats(props.players));
const teamTags = computed(() => resolvePremadeTeamTags(props.groups, props.players));

/** AK 的 `teamPremadeTeams`：按人数升序。 */
const orderedGroups = computed(() => [...props.groups].sort((left, right) => left.puuids.length - right.puuids.length));

/** 分组 + 该分组的胜率队/败率队判定，一次算好，模板里直接读。 */
const pills = computed(() =>
  orderedGroups.value.map((group) => ({ group, tag: teamTags.value.get(group.id) ?? null })),
);

const playersByPuuid = computed(() => {
  const map = new Map<string, PlayerProfile>();
  for (const player of props.players) if (player.puuid) map.set(player.puuid, player);
  return map;
});

const groupMembers = (group: PremadeGroupRef) =>
  group.puuids.map((puuid) => playersByPuuid.value.get(puuid)).filter((player): player is PlayerProfile => Boolean(player));

const groupStyle = (group: PremadeGroupRef) => {
  const color = premadeGroupColor(group.tone, dark.value);
  return { backgroundColor: color?.bg ?? "#ffffff40", color: color?.fg ?? "#ffffff" };
};
</script>

<template>
  <div class="team-tags" data-testid="team-tags">
    <template v-if="stats">
      <NPopover :show-arrow="false" :delay="50">
        <template #trigger>
          <span
            class="team-tags__win-rate"
            :class="stats.avgWinRate >= 0.5 ? 'team-tags__win-rate--high' : 'team-tags__win-rate--low'"
          >
            {{ (stats.avgWinRate * 100).toFixed(0) }}%
          </span>
        </template>
        胜率 {{ (stats.avgWinRate * 100).toFixed(2) }}% ({{ stats.wins }} / {{ stats.games }})
      </NPopover>

      <span class="team-tags__divider" />

      <NPopover :show-arrow="false" :delay="50">
        <template #trigger>
          <span class="team-tags__kda">{{ stats.avgKda.toFixed(2) }}</span>
        </template>
        KDA {{ stats.avgKda.toFixed(4) }} (K {{ stats.kills }} / D {{ stats.deaths }} / A {{ stats.assists }})
      </NPopover>
    </template>

    <span v-if="stats && orderedGroups.length" class="team-tags__divider" />

    <div v-if="pills.length" class="team-tags__premade">
      <NPopover v-for="pill of pills" :key="pill.group.id" :show-arrow="false" :delay="50">
        <template #trigger>
          <div class="team-tags__pill" :class="{ 'team-tags__pill--split': pill.tag }">
            <span class="team-tags__size" :style="groupStyle(pill.group)">{{ pill.group.puuids.length }} 黑</span>
            <span v-if="pill.tag" class="team-tags__team-type" :data-type="pill.tag.type">
              {{ pill.tag.type === "win-rate-team" ? "胜率队" : "败率队" }}
            </span>
          </div>
        </template>
        <div class="team-tags__members">
          <div v-for="member in groupMembers(pill.group)" :key="member.puuid || member.gameName" class="team-tags__member">
            <AssetIcon
              kind="champion"
              :id="member.championId"
              :name="member.championName"
              :fallback-url="championImage(member.championId)"
              size="xs"
            />
            <span>{{ member.gameName }}</span>
          </div>
          <span v-if="!groupMembers(pill.group).length" class="team-tags__members-empty">成员身份未解析</span>
        </div>
      </NPopover>
    </div>
  </div>
</template>

<style scoped>
.team-tags {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

.team-tags__win-rate {
  font-size: 12px;
  font-weight: 700;
}

.team-tags__win-rate--high {
  color: #2c8c6c;
}

.team-tags__win-rate--low {
  color: #cc0000;
}

:root[data-color-mode="dark"] .team-tags__win-rate--high {
  color: #4cc69d;
}

:root[data-color-mode="dark"] .team-tags__win-rate--low {
  color: #ff6161;
}

.team-tags__kda {
  color: var(--text-secondary);
  font-size: 12px;
}

.team-tags__divider {
  width: 1px;
  height: 0.9em;
  flex: none;
  background: var(--line);
}

.team-tags__premade {
  display: flex;
  gap: 6px;
  min-width: 0;
}

.team-tags__pill {
  display: flex;
  align-items: center;
  overflow: hidden;
  border-radius: 3px;
}

.team-tags__size,
.team-tags__team-type {
  padding: 1px 4px;
  font-size: 10px;
  line-height: 12px;
  color: #ffffff;
  white-space: nowrap;
}

.team-tags__team-type[data-type="win-rate-team"] {
  background: #7e2c85;
}

.team-tags__team-type[data-type="loss-rate-team"] {
  background: #893b3b;
}

.team-tags__members {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 140px;
}

.team-tags__member {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: var(--text-primary);
}

.team-tags__members-empty {
  color: var(--text-muted);
  font-size: 11px;
}
</style>
