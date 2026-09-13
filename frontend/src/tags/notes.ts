/**
 * 玩家标记（备注）的文本处理。
 *
 * 与后端 `backend/player_tags.zig` 的收敛规则保持一致：
 * 按行拆分、去掉空白、去重、限制条数与单条长度。
 */
export const MAX_TAG_NOTES = 8;
/** 单条备注长度按 UTF-16 码元计数；后端 `player_tags.zig` 的字节上限
 * （`max_note_bytes`）按 120 * 3 预留，保证这里的输入不会被二次截断。 */
export const MAX_TAG_NOTE_LENGTH = 120;

export function splitTagNotes(text: string, limit = MAX_TAG_NOTES): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    const value = line.trim().slice(0, MAX_TAG_NOTE_LENGTH);
    if (!value || seen.has(value)) continue;
    seen.add(value);
    result.push(value);
    if (result.length >= limit) break;
  }
  return result;
}

/** 备注列表渲染成编辑框文本。 */
export function joinTagNotes(notes: string[]): string {
  return notes.join("\n");
}
