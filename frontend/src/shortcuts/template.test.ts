import { describe, expect, it } from "vitest";
import { renderShortcutTemplateExample } from "./template";

describe("shortcut template examples", () => {
  it("shows the complete output shape for enemy assessment fields", () => {
    expect(renderShortcutTemplateExample("敌方{position} {current_champion}：{rank} {recent_games}"))
      .toEqual(["敌方中路 九尾妖狐：翡翠 II 近5场：胜 九尾妖狐 8/2/7；负 发条魔灵 3/5/6"]);
  });

  it("keeps unknown fields visible and splits multiline sends", () => {
    expect(renderShortcutTemplateExample("{team} {name}\n{unknown}"))
      .toEqual(["敌方 峡谷侦察员", "{unknown}"]);
  });

  it("shows the horse assessment label", () => {
    expect(renderShortcutTemplateExample("{team}{position} {horse}"))
      .toEqual(["敌方中路 上等马"]);
  });

  it("shows both identities and performances for encounter messages", () => {
    expect(renderShortcutTemplateExample("{encounter}"))
      .toEqual(["遇到过：09月06日 21:35，我（松间照#0721）使用 九尾妖狐 8/2/7 胜；对方（狐狸收藏家#MID）使用 盲僧 3/5/6 负"]);
  });
});
