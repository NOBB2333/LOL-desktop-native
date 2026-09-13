/**
 * 展开一局时按 `gameId` 拉完整十人数据。
 *
 * 为什么需要单独拉一次：LCU 的战绩**列表**接口
 * `/lol-match-history/v1/products/lol/{puuid}/matches` 每局只返回**查询者本人**的
 * 一条 `participants`（实测本机缓存 32/32 局都是 1 条）。列表里的 MatchSummary
 * 直接用来渲染「十人阵容与 BP」只会显示一个人。完整数据只有
 * `/lol-match-history/v1/games/{gameId}`（后端 `get_match_detail`）才有。
 *
 * 三个 puuid 的分工见 `backend.matchDetail`：`selfPuuid` 只管账号归属校验，
 * `subjectPuuid` 决定行内视角——看别人的历史时要传「他」，那一局通常没有「我」。
 */
import { computed, type Ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import type { MatchSummary, RecentMatch } from "../types/domain";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import { matchDetailQueryKey } from "../matches/query";

interface MatchDetailOptions {
  /** 当前展开的那一局的 gameId；null 表示没有展开任何一局。 */
  gameId: Ref<number | null>;
  /** 被查看的玩家（行为方 / 行内视角）。 */
  subjectPuuid: Ref<string>;
  /** 当前登录账号的 puuid，仅用于后端账号归属校验。 */
  selfPuuid: Ref<string>;
  /** 额外的开关，例如抽屉是否打开。 */
  enabled?: Ref<boolean>;
}

export function useMatchDetail(options: MatchDetailOptions) {
  const app = useAppStore();
  const query = useQuery({
    queryKey: computed(() => matchDetailQueryKey({
      mode: app.mode,
      platformId: app.connection.platformId,
      gameId: options.gameId.value ?? 0,
      subjectPuuid: options.subjectPuuid.value,
    })),
    queryFn: () => backend.matchDetail(
      options.gameId.value ?? 0,
      app.connection.platformId ?? "",
      options.selfPuuid.value,
      options.subjectPuuid.value,
      options.subjectPuuid.value,
    ),
    enabled: computed(() => Boolean((options.enabled?.value ?? true) && options.gameId.value && options.subjectPuuid.value)),
    staleTime: 5 * 60_000,
    retry: false,
  });

  const detail = computed(() => query.data.value ?? null);
  /** 命中展开的那一局就换成完整数据，其余行走列表数据（不额外发请求）。 */
  function matchForRow<T extends MatchSummary | RecentMatch>(match: T): T | MatchSummary {
    return detail.value && detail.value.gameId === match.gameId ? detail.value : match;
  }

  return {
    detail,
    matchForRow,
    loading: computed(() => query.isFetching.value),
    error: computed(() => (query.isError.value ? "这局的完整十人数据读取失败，当前只显示被查看玩家的那条记录" : "")),
  };
}
