import { computed } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import { buildLocalPlayerIndex } from "../matches/localPlayers";

/**
 * 本地「见过的玩家」索引。
 *
 * 两个来源都在本地（历史遇到记录 + 好友列表），一次取回后在内存里合成，
 * 所以搜索本身不再发任何请求；`staleTime` 给到一分钟，免得在战绩页反复试名字时
 * 把遇到记录和好友列表翻来覆去地拉。
 *
 * 任一侧读不到都**不该**让整个索引失败：非实时模式下好友列表本来就取不到，
 * 而「只用历史记录搜」仍然有用，所以两侧各自 catch 成空。
 */
export function useLocalPlayers() {
  const app = useAppStore();
  return useQuery({
    queryKey: computed(() => ["local-players", app.mode, app.connection.puuid] as const),
    queryFn: async () => {
      const [encounters, friendSnapshot] = await Promise.all([
        backend.encounters(undefined, 100).catch(() => []),
        backend.friends().catch(() => ({ groups: [], friends: [] })),
      ]);
      return buildLocalPlayerIndex({ encounters, friends: friendSnapshot.friends });
    },
    enabled: computed(() => app.initialized),
    staleTime: 60_000,
  });
}
