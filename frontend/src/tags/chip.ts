import { h, type Component } from "vue";
import PlayerTagChip from "./components/PlayerTagChip.vue";
import PlayerTagTextPopover from "./components/PlayerTagTextPopover.vue";
import type { PlayerTagPopover } from "./types";
import type { TagTone } from "./tones";

export interface ChipOptions {
  tone?: TagTone;
  bg?: string;
  fg?: string;
  title?: string;
  /** 可点击样式（例如「玩家标记」）。 */
  interactive?: boolean;
}

/**
 * 生成一个标签 chip 组件。
 *
 * 对齐 LeagueAkari 里 `tagClass(...)` + `<div class={...}>` 的写法，
 * 但这里把样式收敛到 `PlayerTagChip`，保证所有标签的尺寸/圆角/字号完全一致。
 */
export function chip(text: string | (() => string), options: ChipOptions = {}): Component {
  return () =>
    h(
      PlayerTagChip,
      {
        tone: options.tone,
        bg: options.bg,
        fg: options.fg,
        title: options.title,
        interactive: options.interactive,
      },
      {
        default: () => (typeof text === "function" ? text() : text),
      },
    );
}

/** 纯文本弹层，等价于 LeagueAkari 的 `textPopover`。 */
export function textPopover(content: string | (() => string), maxWidth = 260): PlayerTagPopover {
  return {
    content: () => h(PlayerTagTextPopover, { maxWidth }, { default: () => (typeof content === "function" ? content() : content) }),
  };
}
