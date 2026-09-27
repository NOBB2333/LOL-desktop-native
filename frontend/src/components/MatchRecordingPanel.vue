<script setup lang="ts">
/**
 * 对局页里的「本地录制」时间轴。
 *
 * 数据是**本机**在游戏进行中每 N 秒采一帧存下来的（`lol.get_game_recording`）。这是可选
 * 功能：开关没开、不是本机在打、或者这一局已经超出保留局数被回收，拿到的都是空帧，
 * 这时整块面板**不渲染**——对没开这个开关的人来说，对局页跟以前一模一样。
 *
 * 刻意不画伤害曲线：本地接口里**没有**伤害字段，硬画就得凭 KDA 编，那是假数据。所以这里
 * 只画真的采到的东西（KDA / 补刀 / 视野分 / 装备 / 等级 / 复活倒计时），并在说明里写清
 * 「装备变化的最小精度 = 采样间隔」，免得被当成逐秒复盘。
 */
import { AlertTriangle, Clock, History, Timer } from "@lucide/vue";
import { NButton } from "naive-ui";
import { computed, ref, watch } from "vue";
import { useQuery } from "@tanstack/vue-query";
import AssetIcon from "./AssetIcon.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { GameRecordingPlayer, GameRecordingSelf } from "../types/domain";
import { championImage, roleName } from "../utils/format";

const props = defineProps<{ gameId: number }>();
const app = useAppStore();

const recording = useQuery({
  queryKey: computed(() => ["game-recording", props.gameId]),
  queryFn: () => backend.gameRecording(props.gameId),
  // 录制是「只在局内追加、打完就不变」的本地数据，拉到一次就够了。
  staleTime: 300_000,
});

const frames = computed(() => recording.data.value?.frames ?? []);
const intervalSeconds = computed(() => recording.data.value?.intervalSeconds ?? 0);
/**
 * 游标默认停在**最后一帧**。
 *
 * 开局帧十个人全是 0（没刀、没装备、没等级），落在那里看着像「录制坏了」。停在最后
 * 一帧至少是一份说得通的全场状态，想看过程再往前拖。
 */
const cursor = ref(0);
watch(frames, (value) => { cursor.value = Math.max(0, value.length - 1); }, { immediate: true });

const frame = computed(() => frames.value[cursor.value] ?? null);
const sides = computed(() => [
  { key: "order", label: "蓝色方", players: (frame.value?.players ?? []).filter((player) => player.team !== "CHAOS") },
  { key: "chaos", label: "红色方", players: (frame.value?.players ?? []).filter((player) => player.team === "CHAOS") },
]);
const self = computed<GameRecordingSelf | null>(() => frame.value?.me ?? null);

/** 一整队的合计：只有人头与补刀可加，别的（视野分也是可加的，但门槛不同）不混在一起。 */
function totals(players: GameRecordingPlayer[]) {
  return players.reduce((sum, player) => ({ kills: sum.kills + player.k, deaths: sum.deaths + player.d, assists: sum.assists + player.a, cs: sum.cs + player.cs }), { kills: 0, deaths: 0, assists: 0, cs: 0 });
}

/**
 * 「开关开着却什么都没录到」才提示一句。
 *
 * 开关关着时上面整块面板都不出现，再加一句「没录到」纯属噪声；反过来，用户明明把开关
 * 打开了、这一局却没有记录，必须给个说法（不是本机在打 / 已经超出保留局数）。
 */
const showsEmptyNote = computed(() => app.config.providers?.recording?.enabled === true && frames.value.length === 0);

/** `12:34`；不足十分钟也补成四位，游标滑动时数字不会左右晃。 */
function clock(seconds: number) {
  const total = Math.max(0, Math.round(seconds));
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}
function step(delta: number) {
  cursor.value = Math.min(Math.max(0, frames.value.length - 1), Math.max(0, cursor.value + delta));
}
function scrubTo(event: Event) {
  cursor.value = Number((event.target as HTMLInputElement).value);
}
/** 装备帧里只存了 id：原生环境下走 LCU 取图，预览里给一份同源的远程兜底。 */
const itemIcon = (id: number) => `https://ddragon.leagueoflegends.com/cdn/16.16.1/img/item/${id}.png`;
</script>

<template>
  <section v-if="frames.length" class="recording" aria-label="本地录制">
    <div class="recording__heading">
      <div><span class="eyebrow">LOCAL RECORDING</span><h3>本地录制 · 时间轴</h3></div>
      <span class="recording__meta"><History :size="12" />每 {{ intervalSeconds || "—" }} 秒一帧 · 共 {{ frames.length }} 帧 · 只存在本机</span>
    </div>

    <div class="recording__scrubber">
      <NButton size="tiny" secondary :disabled="cursor === 0" @click="step(-1)">上一帧</NButton>
      <input
        class="recording__range"
        type="range"
        min="0"
        :max="Math.max(0, frames.length - 1)"
        step="1"
        :value="cursor"
        aria-label="录制时间轴"
        @input="scrubTo"
      />
      <NButton size="tiny" secondary :disabled="cursor >= frames.length - 1" @click="step(1)">下一帧</NButton>
      <span class="recording__clock"><Clock :size="12" />{{ clock(frame?.t ?? 0) }}</span>
    </div>

    <p class="recording__note">
      这是游戏进行中本机采到的快照，不是逐秒复盘：官方接口没有伤害字段，「谁什么时候买了哪件装备」也只有采样间隔的精度（装备靠相邻两帧对比）。
    </p>

    <div class="recording__sides">
      <section v-for="side in sides" :key="side.key" class="recording__side" :data-side="side.key">
        <header>
          <strong>{{ side.label }} · {{ side.players.length }} 人</strong>
          <span>{{ totals(side.players).kills }}/{{ totals(side.players).deaths }}/{{ totals(side.players).assists }} · {{ totals(side.players).cs }} 刀</span>
        </header>
        <div v-for="player in side.players" :key="player.puuid" class="recording__row" :class="{ 'is-dead': player.dead }">
          <AssetIcon kind="champion" :id="player.cid" :name="player.champ" :fallback-url="championImage(player.cid)" size="sm" />
          <span class="recording__who"><strong>{{ player.rid || player.champ }}</strong><small>{{ player.champ }} · {{ roleName(player.pos) }}</small></span>
          <span class="recording__level" title="等级">{{ player.lvl }}</span>
          <span class="recording__kda">{{ player.k }}/{{ player.d }}/{{ player.a }}</span>
          <span class="recording__cs" title="补刀">{{ player.cs }}</span>
          <span class="recording__ward" title="视野分">{{ player.ward }}</span>
          <span class="recording__items">
            <AssetIcon v-for="item in player.items" :key="`${player.puuid}-${item}`" kind="item" :id="item" :fallback-url="itemIcon(item)" size="xs" />
            <i v-if="!player.items.length">—</i>
          </span>
          <em v-if="player.dead" class="recording__respawn" title="复活倒计时">{{ Math.round(player.respawn) }}s</em>
          <em v-else-if="player.bot" class="recording__bot">人机</em>
        </div>
      </section>
    </div>

    <div v-if="self" class="recording__self">
      <span class="recording__self-title"><Timer :size="12" />我（只有本人拿得到这一份）</span>
      <span><b>经济</b>{{ self.gold }}</span>
      <span><b>AD</b>{{ Math.round(self.ad) }}</span>
      <span><b>AP</b>{{ Math.round(self.ap) }}</span>
      <span><b>护甲</b>{{ Math.round(self.armor) }}</span>
      <span><b>魔抗</b>{{ Math.round(self.mr) }}</span>
      <span><b>移速</b>{{ Math.round(self.ms) }}</span>
      <span><b>生命</b>{{ Math.round(self.hp) }} / {{ Math.round(self.maxHp) }}</span>
    </div>
  </section>

  <p v-else-if="showsEmptyNote" class="recording__empty">
    <AlertTriangle :size="12" />这一局没有本地录制：录制只在「本机在打」且开关打开时才会存，跨局的老对局和观战视角都录不到。
  </p>
</template>

<style scoped>
.recording { margin-top: 10px; padding: 11px 15px 13px; border: 1px solid var(--line); border-left: 3px solid var(--accent); background: var(--surface); }
.recording__heading { display: flex; align-items: flex-end; justify-content: space-between; gap: 12px; }
.recording__heading h3 { margin: 2px 0 0; font-size: 12px; }
.recording__meta { display: inline-flex; align-items: center; gap: 4px; color: var(--text-secondary); font-size: 8px; }
.recording__scrubber { display: grid; grid-template-columns: auto minmax(120px, 1fr) auto auto; align-items: center; gap: 8px; margin-top: 9px; }
.recording__range { width: 100%; height: 18px; accent-color: var(--accent); cursor: pointer; }
.recording__clock { display: inline-flex; align-items: center; gap: 4px; min-width: 54px; color: var(--text-primary); font-size: 11px; font-variant-numeric: tabular-nums; }
.recording__note { margin: 7px 0 0; color: var(--text-muted); font-size: 8px; line-height: 1.5; }
.recording__sides { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-top: 9px; }
.recording__side { min-width: 0; border-top: 2px solid var(--blue); background: var(--surface-raised); }
.recording__side[data-side="chaos"] { border-top-color: var(--red); }
.recording__side > header { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 5px 8px; border-bottom: 1px solid var(--line); }
.recording__side > header strong { font-size: 9px; }
.recording__side > header span { color: var(--text-secondary); font-size: 8px; font-variant-numeric: tabular-nums; }
.recording__row { display: grid; grid-template-columns: 26px minmax(0, 1fr) 26px 48px 34px 30px minmax(0, 116px) 26px; align-items: center; gap: 6px; padding: 4px 7px; border-bottom: 1px solid var(--line); }
.recording__side .recording__row:last-child { border-bottom: 0; }
.recording__row.is-dead { background: color-mix(in srgb, var(--red) 8%, transparent); }
.recording__who { min-width: 0; }
.recording__who strong, .recording__who small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.recording__who strong { color: var(--text-primary); font-size: 9px; }
.recording__who small { margin-top: 2px; color: var(--text-secondary); font-size: 7px; }
.recording__level, .recording__kda, .recording__cs, .recording__ward { color: var(--text-secondary); font-size: 8px; font-variant-numeric: tabular-nums; }
.recording__kda { color: var(--text-primary); }
.recording__items { display: flex; align-items: center; gap: 2px; min-width: 0; overflow: hidden; white-space: nowrap; }
.recording__items > i { color: var(--text-muted); font-size: 8px; font-style: normal; }
.recording__row em { justify-self: start; padding: 1px 4px; font-size: 7px; font-style: normal; font-weight: 700; }
.recording__respawn { color: var(--red); background: color-mix(in srgb, var(--red) 16%, transparent); }
.recording__bot { color: var(--amber); background: var(--amber-soft); }
.recording__self { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 12px; margin-top: 9px; padding: 7px 9px; border: 1px dashed var(--line-strong); background: var(--surface-raised); }
.recording__self-title { display: inline-flex; align-items: center; gap: 4px; color: var(--text-secondary); font-size: 8px; }
.recording__self > span:not(.recording__self-title) { color: var(--text-primary); font-size: 9px; font-variant-numeric: tabular-nums; }
.recording__self b { margin-right: 3px; color: var(--text-muted); font-size: 7px; font-weight: 600; }
.recording__empty { display: flex; align-items: center; gap: 6px; margin: 10px 0 0; padding: 8px 10px; border: 1px dashed var(--line-strong); border-left: 3px solid var(--amber); color: var(--text-secondary); background: var(--surface-raised); font-size: 9px; line-height: 1.5; }
/*
  刻意**不写**按视口宽度的媒体查询。
  宿主卡片（`.match-row`）的栅格最小宽度约 990px，外面还套着 `overflow-x: auto`：
  窗口再窄，卡片本身也不会跟着变窄。这时候按视口收列/改成单列，只会得到「一列占了
  990px、右边全是空白」的错位版面（实测在 390px 视口下就是这样）。版面跟着**容器的
  实际宽度**走才不会和上面那张卡打架，窄窗口就横向滚。
*/
</style>
