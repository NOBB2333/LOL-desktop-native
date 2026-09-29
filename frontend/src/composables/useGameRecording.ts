/**
 * 本机对局录制的**唯一取数口**。
 *
 * 为什么抽出来：录制数据现在只服务观战面板的「此刻装备 / 此刻 K/D/A」
 * （`MatchSpectatePanel`，由 `MatchDeepDetail` 取数后传下去）。2026-09-28 之前还有一个
 * 独立的「本地录制 · 时间轴」表格（`MatchRecordingPanel`）也读它，用户认为那个块与观战
 * 面板重复、要求删掉——组件已删除，取数口保留在这里，免得下次再有消费方时又各写一份
 * `useQuery`，把 queryKey 写成两个形状、同一局被拉两次。
 *
 * 走同一个 key（`["game-recording", gameId]`）之后，vue-query 自动去重并共享缓存：
 * 同一局在页面上挂几块，后端都只被打一次。
 *
 * 取数语义与后端约定一致（见 `backend/game_recording.zig`）：
 * - `frames` 空数组**不是错误**——开关没开 / 不是本机在打 / 已超出保留局数被回收，
 *   都回空数组，界面据此决定是不渲染还是显示「这一局没有录制」。
 * - `recordedGames` 用来区分「这功能从没生效过」和「只是这一局没录」两种空。
 * - 只在局内追加、打完就不变，所以 `staleTime` 给得很长：拉到一次就够。
 */
import { computed, toValue, type MaybeRefOrGetter } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";

export function useGameRecording(gameId: MaybeRefOrGetter<number>) {
  const app = useAppStore();
  const id = computed(() => toValue(gameId) || 0);
  const query = useQuery({
    queryKey: computed(() => ["game-recording", app.mode, id.value] as const),
    queryFn: () => backend.gameRecording(id.value),
    enabled: computed(() => id.value > 0),
    staleTime: 300_000,
    retry: false,
  });

  return {
    /** 整份结果；没拿到时为 null（与「拿到了但没录到」是两回事）。 */
    recording: computed(() => query.data.value ?? null),
    frames: computed(() => query.data.value?.frames ?? []),
    /** 采样间隔（秒）；拿不到时为 0，界面上写「—」而不是写 0。 */
    intervalSeconds: computed(() => query.data.value?.intervalSeconds ?? 0),
    /** 本机库里现有多少局录制——空状态文案靠它分岔。 */
    recordedGames: computed(() => query.data.value?.recordedGames ?? 0),
    isFetching: computed(() => query.isFetching.value),
  };
}
