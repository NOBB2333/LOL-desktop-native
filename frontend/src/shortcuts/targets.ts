import type { ShortcutTarget } from "../types/domain";

/**
 * 快捷消息「发送对象」的可读名。自动化页的下拉框和实时概览底部的快捷键图例
 * 共用这一份，避免两处各写一份之后慢慢对不上。
 */
export const shortcutTargetOptions: { label: string; value: ShortcutTarget }[] = [
  { label: "我方每位玩家", value: "ally" },
  { label: "敌方每位玩家", value: "enemy" },
  { label: "双方打野", value: "jungle" },
  { label: "已知组队汇总", value: "premade" },
  { label: "发送遇到记录", value: "encounter" },
  { label: "本局所有玩家", value: "lobby" },
  { label: "仅发送一次", value: "custom" },
];

export function shortcutTargetLabel(target: ShortcutTarget): string {
  return shortcutTargetOptions.find((option) => option.value === target)?.label ?? target;
}
