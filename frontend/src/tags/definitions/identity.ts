import { h, type Component } from "vue";
import { chip, textPopover } from "../chip";
import { premadeGroupColor } from "../tones";
import type { PlayerTagDefinition } from "../types";

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

/** 自己：只在本地玩家身上出现。 */
export const SELF_TAG: PlayerTagDefinition = {
  id: "self",
  render: (ctx) => {
    if (!ctx.settings.showSelfTag || !ctx.selfPuuid || ctx.player.puuid !== ctx.selfPuuid) return null;
    return { label: chip("自己", { tone: "self" }) };
  },
};

/**
 * 玩家标记（chip 文案对齐 LeagueAkari 的「已标记」）：本地玩家为该玩家写的备注。
 *
 * 有备注时悬停展示全部备注、点击进入编辑；没有备注时不渲染，
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

const NotesPopover = (props: { notes: string[] }) =>
  h(
    "div",
    { class: "tag-notes" },
    props.notes.map((note) => h("div", { class: "tag-notes__item" }, note)),
  );

/** 开黑组队：按分组编号取色，同组同色。 */
export const PREMADE_TAG: PlayerTagDefinition = {
  id: "premade",
  render: (ctx) => {
    if (!ctx.settings.showPremadeTag) return null;
    const tone = ctx.premadeTone;
    if (tone === undefined && !ctx.player.isPremade) return null;

    const color = premadeGroupColor(tone);
    const members = ctx.player.premadeWith.filter(Boolean);
    const labelText = tone === undefined ? "开黑" : `开黑 ${tone + 1}`;
    const detail = members.length
      ? `与 ${members.join("、")} 开黑`
      : "检测到已知组队（选人阶段可能尚未公开队友名称）";

    return {
      label: chip(labelText, { tone: "premade", bg: color?.bg, fg: color?.fg }),
      popover: textPopover(detail),
    };
  },
};
