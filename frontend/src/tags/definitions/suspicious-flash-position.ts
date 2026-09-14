import { h } from "vue";
import { chip } from "../chip";
import PlayerTagFlashPositionPopover from "../components/PlayerTagFlashPositionPopover.vue";
import type { PlayerTagDefinition } from "../types";

/**
 * 可疑闪现位置。
 *
 * AK 的判定极简：`isSuspicious = Boolean(flashOnD && flashOnF)`——
 * 只要这个玩家在最近的对局里**既把闪现放过 D 位、又放过 F 位**就标出来。
 * 正常玩家会固定一个位置（毕竟肌肉记忆），两边都有说明他要么换过、要么是代打/租号。
 *
 * 计数来自 `player.recentMatches[].summonerSpells`：索引 0 = D 位、索引 1 = F 位，
 * 闪现 id = 4。见 `facts.ts` 的 `flashOnD / flashOnF`。
 */
export const SUSPICIOUS_FLASH_POSITION_TAG: PlayerTagDefinition = {
  id: "suspicious-flash-position",
  render: (ctx) => {
    if (!ctx.settings.showSuspiciousFlashPositionTag) return null;
    const { flashOnD, flashOnF } = ctx.facts;
    if (!flashOnD || !flashOnF) return null;

    return {
      label: chip("闪现位置可疑", { tone: "flash" }),
      popover: {
        content: () => h(PlayerTagFlashPositionPopover, { flashOnD, flashOnF }),
      },
    };
  },
};
