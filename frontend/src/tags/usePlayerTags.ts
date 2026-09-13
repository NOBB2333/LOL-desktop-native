import { computed, type ComputedRef } from "vue";
import { PLAYER_CARD_TAGS } from "./registry";
import type { PlayerTagContext, PlayerTagView } from "./types";

/**
 * 把上下文投影成待渲染的标签列表。
 *
 * 与 LeagueAkari 的 `usePlayerCardTags` 等价：顺序取自注册表，
 * 定义返回 `null` 表示该标签在当前数据下不成立，直接跳过。
 */
export function usePlayerTags(ctx: ComputedRef<PlayerTagContext>): ComputedRef<PlayerTagView[]> {
  return computed<PlayerTagView[]>(() =>
    PLAYER_CARD_TAGS.flatMap((tag) => {
      const rendered = tag.render(ctx.value);
      return rendered ? [{ id: tag.id, ...rendered }] : [];
    }),
  );
}
