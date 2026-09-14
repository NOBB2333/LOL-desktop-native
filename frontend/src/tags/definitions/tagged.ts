import { h, type Component } from "vue";
import { chip } from "../chip";
import type { PlayerTagDefinition } from "../types";

/**
 * 玩家标记（tagged）：本地玩家为该玩家写的标记。
 *
 * 有标记时悬停展示全部内容、点击进入编辑；没有标记时不渲染，
 * 避免每张卡片都挂一个空入口。
 */
export const TAGGED_TAG: PlayerTagDefinition = {
  id: "tagged",
  render: (ctx) => {
    if (!ctx.settings.showTaggedTag || !ctx.canEditNotes) return null;
    const notes = ctx.playerNotes.filter((note) => note.trim().length > 0);
    if (notes.length === 0) return null;
    if (!ctx.onEditNotes) return null;

    return {
      label: clickable(
        chip("已标记", { tone: "note", interactive: true }),
        () => ctx.onEditNotes?.(),
        `编辑 ${ctx.player.gameName} 的玩家标记`,
      ),
      popover: {
        content: () => h(NotesPopover, { notes }),
        keepAliveOnHover: true,
        scrollable: true,
        maxHeight: 260,
      },
    };
  },
};

/**
 * 用一层按钮包裹 chip，把点击事件接到标签定义上。
 *
 * chip 本身是内联渲染组件，不接受 onClick；统一套一层按钮承接交互，
 * 保证点击与键盘可达，并阻止冒泡以免触发展开玩家详情。
 */
function clickable(inner: Component, onClick: () => void, ariaLabel: string): Component {
  return () =>
    h(
      "button",
      {
        type: "button",
        class: "tag-clickable",
        "aria-label": ariaLabel,
        onClick: (event: MouseEvent) => {
          event.stopPropagation();
          onClick();
        },
        onKeydown: (event: KeyboardEvent) => event.stopPropagation(),
      },
      [h(inner)],
    );
}

const NotesPopover = (props: { notes: string[] }) =>
  h(
    "div",
    { class: "tag-notes" },
    props.notes.map((note) => h("div", { class: "tag-notes__item" }, note)),
  );
