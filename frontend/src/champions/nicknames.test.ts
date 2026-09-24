import { describe, expect, it } from "vitest";
import {
  NICKNAME_CHAMPION_COUNT,
  NICKNAME_KEYS,
  championNicknames,
  championSearchHints,
  championSearchText,
  matchesChampionQuery,
  normalizeChampionKey,
} from "./nicknames";

const champion = (name: string, alias: string) => ({ name, alias });

describe("normalizeChampionKey", () => {
  it("小写并去掉空格、撇号、连字符", () => {
    expect(normalizeChampionKey("Kog'Maw")).toBe("kogmaw");
    expect(normalizeChampionKey("Kog Maw")).toBe("kogmaw");
    expect(normalizeChampionKey("lee-sin")).toBe("leesin");
    expect(normalizeChampionKey("  牛头 ")).toBe("牛头");
  });
});

describe("英雄昵称表", () => {
  it("键都是归一化过的且不重复", () => {
    // 键要是带了大小写或空格，`championNicknames` 就永远查不到——而且不会报错，
    // 只会表现为「这个昵称搜不到」，极难排查。所以这条必须钉死。
    for (const key of NICKNAME_KEYS) expect(key, `键未归一化：${key}`).toBe(normalizeChampionKey(key));
    expect(new Set(NICKNAME_KEYS).size).toBe(NICKNAME_KEYS.length);
    expect(NICKNAME_CHAMPION_COUNT).toBeGreaterThan(80);
  });

  it("用户点名的四个俗称都能查到人", () => {
    expect(championNicknames("Alistar")).toContain("牛头");
    expect(championNicknames("Soraka")).toContain("奶妈");
    expect(championNicknames("Rammus")).toContain("龙龟");
    expect(championNicknames("Draven")).toContain("文森特");
  });

  it("查不到的 alias 返回空数组，不抛错", () => {
    expect(championNicknames("")).toEqual([]);
    expect(championNicknames("NotAChampion")).toEqual([]);
  });

  it("alias 的大小写与标点差异不影响查表", () => {
    expect(championNicknames("kogmaw")).toContain("大嘴");
    expect(championNicknames("Kog'Maw")).toContain("大嘴");
    expect(championNicknames("KOGMAW")).toContain("大嘴");
    // 悟空在 Riot 目录里的 alias 是 MonkeyKing，但社区直接打 Wukong 也要能搜到。
    expect(championNicknames("MonkeyKing")).toContain("猴哥");
    expect(matchesChampionQuery(champion("齐天大圣", "MonkeyKing"), "wukong")).toBe(true);
  });
});

describe("matchesChampionQuery", () => {
  it("称号、英文名、俗称三种打法都能命中", () => {
    const alistar = champion("牛头酋长", "Alistar");
    expect(matchesChampionQuery(alistar, "牛头")).toBe(true);
    expect(matchesChampionQuery(alistar, "alistar")).toBe(true);
    expect(matchesChampionQuery(alistar, "Alistar")).toBe(true);

    // 界面上显示的是国服称号（如「暗裔剑魔」），用户会照着抄一半。
    const aatrox = champion("暗裔剑魔", "Aatrox");
    expect(matchesChampionQuery(aatrox, "剑魔")).toBe(true);
    expect(matchesChampionQuery(aatrox, "aatrox")).toBe(true);
  });

  it("空查询一律命中，因为搜索框空着就是「全都显示」", () => {
    const ahri = champion("九尾妖狐", "Ahri");
    expect(matchesChampionQuery(ahri, "")).toBe(true);
    expect(matchesChampionQuery(ahri, "   ")).toBe(true);
  });

  it("查询里的空格与大小写不敏感", () => {
    const leesin = champion("盲僧", "LeeSin");
    expect(matchesChampionQuery(leesin, "lee sin")).toBe(true);
    expect(matchesChampionQuery(leesin, "LEESIN")).toBe(true);
    expect(matchesChampionQuery(leesin, "盲 僧")).toBe(true);
  });

  it("不相关的查询不命中", () => {
    expect(matchesChampionQuery(champion("九尾妖狐", "Ahri"), "牛头")).toBe(false);
  });

  it("搜索文本里三项都在，别只塞昵称", () => {
    const draven = champion("荣耀行刑官", "Draven");
    const text = championSearchText(draven);
    for (const part of ["荣耀行刑官", "draven", "文森特", "德莱文"]) expect(text).toContain(part);
  });

  it("hints 给的昵称可用于界面提示", () => {
    expect(championSearchHints(champion("牛头酋长", "Alistar"))).toEqual(championNicknames("Alistar"));
  });
});
