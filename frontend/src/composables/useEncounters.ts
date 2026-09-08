import { computed, toValue, watch, type MaybeRefOrGetter } from "vue";
import { useQuery } from "@tanstack/vue-query";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";

export function useEncounters(target: MaybeRefOrGetter<string>, enabled: MaybeRefOrGetter<boolean>, gameId: MaybeRefOrGetter<number>, revision?: MaybeRefOrGetter<string>) {
  const app = useAppStore();
  const query = useQuery({
    queryKey: computed(() => ["encounters", app.mode, app.connection.platformId, app.connection.gameName, app.connection.tagLine, toValue(target), toValue(gameId)] as const),
    queryFn: ({ queryKey }) => backend.encounters(queryKey[5] || undefined, 40, queryKey[6]),
    enabled: computed(() => toValue(enabled)),
    staleTime: 5_000,
    retry: 1,
  });
  if (revision) watch(() => toValue(revision), () => {
    if (toValue(enabled)) void query.refetch();
  });
  return query;
}
