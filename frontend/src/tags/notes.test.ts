import { describe, expect, it } from "vitest";
import { MAX_TAG_NOTE_LENGTH, MAX_TAG_NOTES, joinTagNotes, splitTagNotes } from "./notes";

describe("玩家标记文本处理", () => {
  it("按行拆分并去掉空白项", () => {
    expect(splitTagNotes("爱打野\n\n  挂机过  \n")).toEqual(["爱打野", "挂机过"]);
    expect(splitTagNotes("   ")).toEqual([]);
    expect(splitTagNotes("")).toEqual([]);
  });

  it("去重并限制条数", () => {
    expect(splitTagNotes("同一条\n同一条\n另一条")).toEqual(["同一条", "另一条"]);
    const many = Array.from({ length: MAX_TAG_NOTES + 4 }, (_, index) => `备注${index}`).join("\n");
    expect(splitTagNotes(many)).toHaveLength(MAX_TAG_NOTES);
  });

  it("单条超长时截断", () => {
    const [note] = splitTagNotes("字".repeat(MAX_TAG_NOTE_LENGTH + 50));
    expect(note).toHaveLength(MAX_TAG_NOTE_LENGTH);
  });

  it("joinTagNotes 与 splitTagNotes 互为逆运算", () => {
    const notes = ["爱打野", "挂机过"];
    expect(splitTagNotes(joinTagNotes(notes))).toEqual(notes);
  });
});
