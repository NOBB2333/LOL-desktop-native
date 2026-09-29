<script setup lang="ts">
/**
 * 展开一局后的**完整详情**：观战式面板（十人 + 可拖时间轴）+ 每波团 / 事件流。
 *
 * 历史页两个页签都要用它——「对局」页签展开一局、「人」页签展开某一局的
 * 「全局对局信息」，看到的东西必须一致，所以抽成一个组件、一处取数：
 * - `get_match_detail`：十人完整数据（阵容、终局 KDA、装备）——列表接口每局只带查询者本人；
 * - `get_match_timeline`：逐帧事件 + 分钟帧（金币/等级/走位），观战面板和每波团都吃它，
 *   逐局落盘缓存；
 * - 「当前选中第几波团」由这里持有：观战面板的时间轴/地图钉点选，与下方
 *   「每波团」的摘要条是**同一个选中态**，两处永远同步。
 *
 * **五处都挂这个组件**（2026-09-28 起），任何一处改了五处一起变，所以只维护这一份：
 * 1. 历史页「对局」页签 → 展开一局
 * 2. 历史页「人」页签 → 展开某一局的「全局对局信息」
 * 3. 战绩页·索引模式 → 右侧详情面板下面的 `.matches-deep`
 * 4. 战绩页·完整对局模式 → `MatchDetailCard` 的 `#deep` 插槽
 * 5. **首页**最近对局 → 同一个 `#deep` 插槽（用户反馈「首页的下边怎么没有对应的明细图表」）
 *
 * 三份数据各自独立加载：哪份到了就画哪块，互不阻塞。第三份是本机录制（可选功能，默认关）：
 * 有它观战面板的「装备」与 K/D/A 才会跟着游标走，没有就退回终局口径。
 */
import { computed, ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import MatchDetailPanel from "./MatchDetailPanel.vue";
import MatchSpectatePanel from "./MatchSpectatePanel.vue";
import MatchSummaryStrip from "./MatchSummaryStrip.vue";
import { deriveTeamfights } from "../matches/teamfights";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import { useGameRecording } from "../composables/useGameRecording";

const props = defineProps<{
  gameId: number;
  /** 必须出现在这一局里的人（「人」页签传他，「对局」页签传我）。 */
  targetPuuid?: string;
  /** 账号归属（当前登录账号）；所有取数都以它做校验。 */
  selfPuuid: string;
  /** puuid → 本地相遇档案里的相遇次数，用于观战面板的「遇到过」角标。 */
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

/** 每波团在这里推导一次，观战面板（时间轴高亮段 + 地图钉）与详情面板共用同一份。 */
const fights = computed(() => (timeline.data.value ? deriveTeamfights(timeline.data.value.events, timeline.data.value.participants) : []));

/**
 * 本机对这一局的录制（可选功能，默认关）。
 *
 * 拿它把观战面板缺的两项补齐——官方数据里只有「终局装备」和「终局 KDA」，而本机录制
 * 每分钟（默认 5 秒）都存了当时的装备与战绩，所以拖游标就能看到**那一刻**的装备和
 * K/D/A。没录到就是空数组，观战面板自动退回原来的「终局」口径。
 */
const { frames: recordingFrames } = useGameRecording(() => props.gameId);

/** 选中的团战（下标）。观战面板点时间轴/地图钉、详情面板点摘要条，都改这一个值。 */
const selectedFightIndex = ref(0);

/**
 * 游标要跳去的时刻。点事件流、切团战、点「上一波/下一波」都会改它，观战面板收到就落位。
 * 用 `null` 起手（不是 0）——0 会被当成「跳到开局」，一挂载就把默认的终局视角冲掉。
 *
 * 观战面板落位后会发 `seek-consumed`，这里立刻清回 null：否则「拖走游标 → 再点同一条
 * 事件」因为值没变、watch 不触发，会一点反应都没有。
 */
const seekSeconds = ref<number | null>(null);

/** 选中某一波团时把游标带到那一波开打那一刻：选中与「看回放」是同一个动作。 */
function selectFight(index: number) {
  selectedFightIndex.value = index;
  const fight = fights.value[index];
  if (fight) seekSeconds.value = fight.startSeconds;
}
</script>

<template>
  <div class="match-deep">
    <!-- 结论条放最上面：一局的看点（首杀/击杀/团战/多杀）先给，再往下才是面板。 -->
    <MatchSummaryStrip v-if="timeline.data.value" :timeline="timeline.data.value" :champion-name-of="championNameOf" :fights="fights" />

    <section class="match-deep__block">
      <h4>观战面板 <small>拖时间轴回看每一刻的等级 / 金币；点团战段或地图上的编号钉跳到那一波。走位是每分钟一个采样点，中间由界面插值补成连续（悬停某位玩家看他整局的**真**采样点）</small></h4>
      <MatchSpectatePanel
        v-if="detail.data.value && timeline.data.value"
        :detail="detail.data.value"
        :timeline="timeline.data.value"
        :champion-name-of="championNameOf"
        :fights="fights"
        :selected-fight-index="selectedFightIndex"
        :self-puuid="selfPuuid"
        :encounter-counts="encounterCounts"
        :seek-seconds="seekSeconds"
        :recording="recordingFrames"
        @select-fight="selectFight"
        @seek-consumed="seekSeconds = null"
      />
      <div v-else-if="detail.isFetching.value || timeline.isFetching.value" class="match-deep__state"><span>正在读取这一局的十人数据与逐帧明细…</span></div>
      <p v-else-if="detail.isError.value && timeline.isError.value" class="match-deep__state">
        这一局的数据没拿到（自定义对局、重开局或客户端缓存缺失时会发生）。
      </p>
    </section>

    <MatchDetailPanel
      v-if="timeline.data.value"
      :timeline="timeline.data.value"
      :champion-name-of="championNameOf"
      :fights="fights"
      :selected-fight-index="selectedFightIndex"
      :players="detail.data.value?.participants"
      :recording="recordingFrames"
      @select-fight="selectFight"
      @seek-time="seekSeconds = $event"
    />
  </div>
</template>

<style scoped>
.match-deep { display: grid; gap: 14px; }
.match-deep__block { display: grid; gap: 8px; }
.match-deep__block h4 { display: flex; align-items: baseline; gap: 7px; margin: 0; font-size: 12px; font-weight: 600; }
.match-deep__block h4 small { color: var(--text-muted); font-size: 9px; font-weight: 400; }
.match-deep__state { margin: 0; padding: 10px 12px; border: 1px dashed var(--line); color: var(--text-muted); font-size: 10px; line-height: 1.6; }
</style>
