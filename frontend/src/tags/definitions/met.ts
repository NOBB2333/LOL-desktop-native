import { h } from "vue";
import { chip } from "../chip";
import PlayerTagMetPopover from "../components/PlayerTagMetPopover.vue";
import { encounterGames, encounterRelation } from "../../encounters/records";
import type { EncounterRecord } from "../../types/domain";
import type { PlayerTagDefinition } from "../types";

/**
 * 遇到过：标注近期共同对局，并以表格展开逐局对照。
 *
 * 对齐 LeagueAkari 的 `MET_TAG`：
 * - 标签文案只区分「遇到过 / 上局队友 / 上局对手」，不带次数；
 * - 次数、最近相遇时间、逐局明细全部收进弹层，保证 chip 尺寸统一、不撑破卡片。
 */
export const MET_TAG: PlayerTagDefinition = {
  id: "met",
  render: (ctx) => {
    if (!ctx.settings.showMetTag) return null;
    // 自己身上不标「遇到过自己」。
    if (ctx.selfPuuid && ctx.player.puuid === ctx.selfPuuid) return null;

    const games = encounterGames(ctx.encounterRecords, ctx.player.puuid, ctx.currentGameId);
    const hasRecord = games.length > 0 || ctx.player.encounterCount > 0;
    if (!hasRecord) return null;

    const relation = encounterRelation(games, ctx.player, ctx.selfPlayer);
    const text =
      relation === "last-teammate" ? "上局队友" : relation === "last-opponent" ? "上局对手" : "遇到过";

    return {
      label: chip(text, { tone: "met" }),
      popover: {
        content: () =>
          h(PlayerTagMetPopover, {
            games,
            total: Math.max(games.length, ctx.player.encounterCount),
            targetName: ctx.player.gameName,
            lastMetAt: ctx.player.lastEncounteredAt ?? "",
            onInspect: (records: EncounterRecord[]) => ctx.openEncounterGame(records),
          }),
        keepAliveOnHover: true,
        scrollable: true,
        maxHeight: 320,
      },
    };
  },
};
