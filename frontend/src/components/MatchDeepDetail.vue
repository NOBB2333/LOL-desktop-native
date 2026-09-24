<script setup lang="ts">
/**
 * 展开一局后的**完整详情**：十人对位（比赛式柱状图）+ 每波团 / 事件流。
 *
 * 历史页两个页签都要用它——「对局」页签展开一局、「人」页签展开某一局的
 * 「全局对局信息」，看到的东西必须一致，所以抽成一个组件、一处取数：
 * - `get_match_detail`：十人完整数据（阵容、伤害、KDA）——列表接口每局只带查询者本人，
 *   所以十人对位**必须**走这个命令，不能拿列表凑；
 * - `get_match_timeline`：逐帧事件（首杀 / 每波团 / 事件流），逐局落盘缓存；
 * - `get_player_stats`：十个人的等级与段位，**每人两次 LCU 往返**，所以只在十人名单
 *   到手后才发、`staleTime` 拉长，展开收起不会反复打客户端。
 *
 * 三份数据**各自独立加载**：哪份到了就画哪块，互不阻塞——十人对位最快出，
 * 逐帧数据第一次要向客户端取一次，等级段位最慢。
 */
import { computed } from "vue";
import { useQuery } from "@tanstack/vue-query";
import MatchDetailPanel from "./MatchDetailPanel.vue";
import MatchLineupPanel from "./MatchLineupPanel.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";

const props = defineProps<{
  gameId: number;
  /** 必须出现在这一局里的人（「人」页签传他，「对局」页签传我）。 */
  targetPuuid?: string;
  /** 账号归属（当前登录账号）；所有取数都以它做校验。 */
  selfPuuid: string;
  /** puuid → 本地相遇档案里的相遇次数，用于对位面板的「遇到过」角标。 */
  encounterCounts?: Record<string, number>;
  championNameOf: (id: number) => string;
}>();

const app = useAppStore();
const enabled = computed(() => props.gameId > 0 && Boolean(props.selfPuuid));

/** targetPuuid 缺省等于我：这局里必须出现我（对局页签的口径）。 */
const target = computed(() => props.targetPuuid?.trim() || props.selfPuuid);

const detail = useQuery({
  queryKey: computed(() => ["match-detail", app.mode, app.connection.platformId ?? "", props.selfPuuid, target.value, props.gameId] as const),
  queryFn: () => backend.matchDetail(props.gameId, app.connection.platformId ?? "", props.selfPuuid, target.value),
  enabled,
  staleTime: 60_000,
  retry: false,
});

const timeline = useQuery({
  queryKey: computed(() => ["match-timeline", app.mode, props.gameId] as const),
  queryFn: () => backend.matchTimeline(props.gameId, props.selfPuuid),
  enabled,
  staleTime: 60_000,
  retry: false,
});

/** 每人两次 LCU 往返，所以十人名单到手才发，而且缓存得比其它查询久。 */
const participantPuuids = computed(() =>
  [...new Set((detail.data.value?.participants ?? []).map((participant) => participant.puuid?.trim() ?? "").filter(Boolean))].slice(0, 10),
);
const stats = useQuery({
  queryKey: computed(() => ["player-stats", app.mode, participantPuuids.value.join(",")] as const),
  queryFn: () => backend.playerStats(participantPuuids.value, props.selfPuuid),
  enabled: computed(() => enabled.value && participantPuuids.value.length > 0),
  staleTime: 600_000,
  retry: false,
});
const statsByPuuid = computed(() => Object.fromEntries((stats.data.value ?? []).map((item) => [item.puuid, item])));
</script>

<template>
  <div class="match-deep">
    <section class="match-deep__block">
      <h4>十人对位 <small>点输出 / 承伤 / 经济 / 补刀切换对比口径</small></h4>
      <MatchLineupPanel
        v-if="detail.data.value"
        :participants="detail.data.value.participants"
        :self-puuid="selfPuuid"
        :encounter-counts="encounterCounts"
        :stats="statsByPuuid"
      />
      <div v-else-if="detail.isFetching.value" class="match-deep__state"><span>正在读取这一局的十人数据…</span></div>
      <p v-else-if="detail.isError.value" class="match-deep__state">
        十人数据没拿到（自定义对局、重开局或客户端缓存缺失时会发生），下面的每波团与事件流不受影响。
      </p>
    </section>

    <section class="match-deep__block">
      <h4>这一局发生了什么 <small>首杀 / 每波团 / 事件流（逐帧按需解析）</small></h4>
      <MatchDetailPanel v-if="timeline.data.value" :timeline="timeline.data.value" :champion-name-of="championNameOf" />
      <div v-else-if="timeline.isFetching.value" class="match-deep__state"><span>正在解析逐帧数据（第一次读一局要向客户端取一次明细）</span></div>
      <p v-else-if="timeline.isError.value" class="match-deep__state">这一局拿不到逐帧数据：自定义对局、重开局、或客户端还没缓存明细时会这样。</p>
    </section>
  </div>
</template>

<style scoped>
.match-deep { display: grid; gap: 14px; }
.match-deep__block { display: grid; gap: 8px; }
.match-deep__block h4 { display: flex; align-items: baseline; gap: 7px; margin: 0; font-size: 12px; font-weight: 600; }
.match-deep__block h4 small { color: var(--text-muted); font-size: 9px; font-weight: 400; }
.match-deep__state { margin: 0; padding: 10px 12px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }
</style>
