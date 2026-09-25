import { describe, expect, it } from "vitest";
import { createFixtureMatchDetail, createFixtureMatchTimeline, createFixtureRoomLobby, fixtureBpHistory, fixtureChampions, fixtureConfig, fixtureEncounters, fixtureLobby, fixtureMatches } from "./data";
import { TEAM_BLUE, TEAM_RED } from "../matches/lineup";

describe("fixture data", () => {
  it("contains two complete teams for offline preview", () => {
    expect(fixtureLobby.ally).toHaveLength(5);
    expect(fixtureLobby.enemy).toHaveLength(5);
    expect(fixtureLobby.ally.every((player) => player.dataComplete)).toBe(true);
    expect(fixtureLobby.enemySummary.score).toBeGreaterThan(0);
    expect(fixtureLobby.layoutKind).toBe("classic");
    expect(fixtureLobby.teams).toHaveLength(2);
    expect(fixtureLobby.teams?.every((team) => team.players.length === 5)).toBe(true);
  });

  it("contains cached champion and match records", () => {
    expect(fixtureChampions).toHaveLength(10);
    expect(fixtureChampions.some((champion) => champion.alias === "Ahri")).toBe(true);
    expect(fixtureMatches).toHaveLength(10);
    expect(fixtureMatches[0].items.length).toBeGreaterThan(0);
    expect(fixtureMatches[0].participants).toHaveLength(10);
    expect(fixtureMatches[0].damageDealt).toBeGreaterThan(0);
    expect(fixtureMatches[0].queueId).toBe(420);
    expect(fixtureMatches[5].queueId).toBe(450);
    expect(fixtureEncounters.every((record) => record.championId > 0)).toBe(true);
    expect(fixtureBpHistory.every((record) => record.allyChampionIds.length === record.allyChampions.length)).toBe(true);
    expect(fixtureBpHistory.every((record) => record.enemyChampionIds.length === record.enemyChampions.length)).toBe(true);
  });

  it("ships only valid shortcut placeholders", () => {
    const templates = fixtureConfig.automation.shortcuts.map((shortcut) => shortcut.template);
    expect(templates.join(" ")).not.toContain("{record}");
  });

  it("models the lobby room snapshot the way the backend emits it", () => {    const room = createFixtureRoomLobby(false);
    // 房间没有局号，id 退回占位值——后端 `liveSessionEnvelopePhaseContext` 同口径。
    expect(room.id).toBe("lcu-session");
    expect(room.phase).toBe("Lobby");
    // 房间里只有本机所在小队，不该凭空造出敌方。
    expect(room.ally.length).toBeGreaterThan(0);
    expect(room.ally.length).toBeLessThanOrEqual(5);
    expect(room.enemy).toHaveLength(0);
    // 一支队伍就够，硬摆 0 人的敌方阵容会误导人。
    expect(room.teams).toHaveLength(1);
    expect(room.teams?.[0].label).toBe("房间成员");
    expect(room.enemySummary.score).toBeGreaterThan(0);
    // 「上一局对局信息」在房间里会露出来，fixture 得给出同一局，否则预览是空的。
    expect(room.recentMatch?.gameId).toBe(fixtureMatches[0].gameId);
  });

  /**
   * `?frameDamage=0` 那条开关要真的等价于「客户端帧里没有伤害字段」，否则预览骗人：
   * 界面上的「输出 / 承伤降级为全场总账」这条路就永远在预览里走不到。
   */
  it("can drop per-minute damage to mirror what the real client sends", () => {
    const withDamage = createFixtureMatchTimeline(fixtureMatches[0].gameId);
    expect(withDamage.frames.some((frame) => frame.damage.some((value) => value > 0))).toBe(true);
    expect(withDamage.frames.some((frame) => frame.taken.some((value) => value > 0))).toBe(true);

    const noDamage = createFixtureMatchTimeline(fixtureMatches[0].gameId, { frameDamage: false });
    expect(noDamage.frames.length).toBe(withDamage.frames.length);
    expect(noDamage.frames.every((frame) => frame.damage.every((value) => value === 0))).toBe(true);
    expect(noDamage.frames.every((frame) => frame.taken.every((value) => value === 0))).toBe(true);
    // 金币 / 等级 / 位置不受影响——真机上这几项是有的，降级只该影响伤害。
    expect(noDamage.frames.every((frame) => frame.gold.some((value) => value > 0))).toBe(true);
    expect(noDamage.frames.every((frame) => frame.gold.length === 10)).toBe(true);
    expect(noDamage.participants).toHaveLength(10);
  });

  /**
   * `?selfSide=red` 的意义：让预览能复现「`side` 与 `team` 不同向」的真机形状。
   *
   * 这两套坐标在默认 fixture 里恰好同向（我方 = 蓝 = 100），所以「拿 side 去配座位」
   * 写错了预览也看不出来。这里钉住三件事：我方的 `side` 仍是 "ally"、`team` 变成 200、
   * 而帧里的**绝对颜色**跟着换边（蓝方总经济改成取后五个座位）。
   */
  it("can put the viewing subject on red without breaking the relative side", () => {
    const gameId = fixtureMatches[0].gameId;
    // 默认视角：我方就是蓝方，所以 team 与 side 同向（这正是旧 fixture 会掩盖 bug 的地方）。
    const blueView = createFixtureMatchDetail(gameId);
    expect(blueView?.participants.filter((player) => player.team === TEAM_BLUE)).toHaveLength(5);
    expect(blueView?.participants.filter((player) => player.side === "ally").every((player) => player.team === TEAM_BLUE)).toBe(true);

    const redView = createFixtureMatchDetail(gameId, { selfTeam: TEAM_RED });
    // `side` 是**相对**的：换边之后我方那五个人的 side 依然是 "ally"。
    const allies = redView?.participants.filter((player) => player.side === "ally") ?? [];
    expect(allies).toHaveLength(5);
    expect(allies.every((player) => player.team === TEAM_RED)).toBe(true);
    const enemies = redView?.participants.filter((player) => player.side === "enemy") ?? [];
    expect(enemies.every((player) => player.team === TEAM_BLUE)).toBe(true);
    // 数值与胜负不该因为换边而变——真机上变的是阵营，不是战绩。
    expect(redView?.kda).toBe(fixtureMatches[0].kda);
    expect(redView?.result).toBe(fixtureMatches[0].result);
    expect(redView?.participants.map((player) => player.championId)).toEqual(fixtureMatches[0].participants.map((player) => player.championId));
  });

  it("keeps the timeline seats and absolute colours consistent when the subject is on red", () => {
    const gameId = fixtureMatches[0].gameId;
    const blue = createFixtureMatchTimeline(gameId);
    const red = createFixtureMatchTimeline(gameId, { selfTeam: TEAM_RED });

    // 座位 1..5 是主视角那一队，所以红方视角下它们是 200。
    expect(blue.participants.slice(0, 5).every((seat) => seat.team === TEAM_BLUE)).toBe(true);
    expect(red.participants.slice(0, 5).every((seat) => seat.team === TEAM_RED)).toBe(true);
    expect(red.participants.slice(5).every((seat) => seat.team === TEAM_BLUE)).toBe(true);
    // 英雄目录按 ally 先、enemy 后，换边不该动顺序——动了说明座位与十人对不上。
    expect(red.participants.map((seat) => seat.championId)).toEqual(blue.participants.map((seat) => seat.championId));

    // `blueGold` 是**绝对颜色**：主视角在红方时它取后五个座位，和不换边时正好互换。
    const lastFrame = red.frames.length - 1;
    const gold = red.frames[lastFrame].gold;
    expect(red.frames[lastFrame].blueGold).toBe(gold.slice(5).reduce((sum, value) => sum + value, 0));
    expect(red.frames[lastFrame].redGold).toBe(gold.slice(0, 5).reduce((sum, value) => sum + value, 0));
    expect(red.frames[lastFrame].goldDiff).toBe(red.frames[lastFrame].blueGold - red.frames[lastFrame].redGold);

    // 事件里的 `team` 是「做事的一方」的绝对阵营：座位 1..5 的人干的事要跟着我换到 200。
    const bySeat = new Map(red.participants.map((seat) => [seat.participantId, seat.team]));
    expect(red.events.every((event) => event.killerId === 0 || event.team === bySeat.get(event.killerId))).toBe(true);
    expect(red.events.some((event) => event.team === TEAM_RED)).toBe(true);
    expect(red.events.some((event) => event.team === TEAM_BLUE)).toBe(true);
  });
});
