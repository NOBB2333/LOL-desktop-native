import { describe, expect, it } from "vitest";
import type { JungleCampCounts } from "../types/domain";
import {
  JUNGLE_CAMP_SHORT_LABELS,
  JUNGLE_CAMP_SPOTS,
  campCountsTotal,
  campMarkerSize,
  clearCountsAt,
  describeCamps,
  isCurrentJungler,
  isJunglePosition,
  mapToImagePosition,
} from "./gameMap";

const camps = (counts: Partial<JungleCampCounts> = {}): JungleCampCounts => ({
  blue: 0,
  red: 0,
  wolves: 0,
  raptors: 0,
  ...counts,
});

describe("mapToImagePosition", () => {
  it("游戏原点的 y 轴方向与图片相反，映射到左下角", () => {
    expect(mapToImagePosition(0, 0, 200, 200)).toEqual({ left: 0, top: 200 });
  });

  it("坐标域的最大角映射到右上角", () => {
    expect(mapToImagePosition(14820, 14881, 200, 200)).toEqual({ left: 200, top: 0 });
  });

  it("超出坐标域的点被夹回图内，不会画到地图外面", () => {
    expect(mapToImagePosition(-5000, 999999, 200, 200)).toEqual({ left: 0, top: 0 });
  });
});

describe("campCountsTotal", () => {
  it("四个营地求和", () => {
    expect(campCountsTotal(camps({ blue: 1, raptors: 2 }))).toBe(3);
  });
});

describe("describeCamps", () => {
  it("按次数降序取前两个，占比以该组总次数为基数，并按 AK 的文案带上「开」", () => {
    expect(describeCamps(camps({ blue: 1, red: 2 }))).toBe("红 Buff 开 67% · 蓝 Buff 开 33%");
  });

  it("没有样本时不吐空字符串，给出可读占位", () => {
    expect(describeCamps(camps())).toBe("无样本");
  });
});

describe("JUNGLE_CAMP_SHORT_LABELS", () => {
  it("八个营地都有短标签，且短到能贴在地图圆圈旁边", () => {
    for (const spot of JUNGLE_CAMP_SPOTS) {
      const label = JUNGLE_CAMP_SHORT_LABELS[spot.camp];
      expect(label).toBeTruthy();
      // 卡片上的图只有 190px 宽，标签超过 3 个字就会压到别的落点上。
      expect(label.length).toBeLessThanOrEqual(3);
    }
  });
});

describe("campMarkerSize", () => {
  it("没有样本的点不画", () => {
    expect(campMarkerSize(0, 5)).toBe(0);
  });

  it("样本最多的点最大，且落在设计区间内", () => {
    expect(campMarkerSize(5, 5)).toBe(17);
    expect(campMarkerSize(5, 0)).toBe(8);
  });
});

describe("isJunglePosition", () => {
  it("接受 LCU 的两种打野写法，大小写不敏感", () => {
    expect(isJunglePosition("JUNGLE")).toBe(true);
    expect(isJunglePosition("jug")).toBe(true);
  });

  it("其它位置与空值都不算打野", () => {
    expect(isJunglePosition("MIDDLE")).toBe(false);
    expect(isJunglePosition(undefined)).toBe(false);
  });
});

it("营地坐标表覆盖双半区各四个营地，且互不重叠", () => {
  expect(JUNGLE_CAMP_SPOTS).toHaveLength(8);
  expect(new Set(JUNGLE_CAMP_SPOTS.map((spot) => `${spot.side}-${spot.camp}`)).size).toBe(8);
});

describe("clearCountsAt", () => {
  // 后端四组计数是按「场次所属阵营 × 起始半区」分的，所以入侵那一组记的是
  // **对面**半区的落点：blueInvade 落在红方半区，redInvade 落在蓝方半区。
  const groups = {
    blueOwn: camps({ blue: 2 }),
    blueInvade: camps({ red: 1 }),
    redOwn: camps({ blue: 3 }),
    redInvade: camps({ wolves: 4 }),
  };

  it("蓝方半区的落点：常规开读 blueOwn，入侵开读 redInvade", () => {
    expect(clearCountsAt(groups, "blue", "blue")).toEqual({ own: 2, invade: 0 });
    expect(clearCountsAt(groups, "blue", "wolves")).toEqual({ own: 0, invade: 4 });
  });

  it("红方半区的落点：常规开读 redOwn，入侵开读 blueInvade", () => {
    expect(clearCountsAt(groups, "red", "blue")).toEqual({ own: 3, invade: 0 });
    expect(clearCountsAt(groups, "red", "red")).toEqual({ own: 0, invade: 1 });
  });
});

describe("isCurrentJungler", () => {
  it("分路写着打野就算，两种写法都认", () => {
    expect(isCurrentJungler({ assignedPosition: "JUNGLE" })).toBe(true);
    expect(isCurrentJungler({ assignedPosition: "jug", summonerSpells: [] })).toBe(true);
  });

  it("分路缺失或过期时退回惩戒判定", () => {
    // 选人阶段与刚进游戏时 assignedPosition 经常还是空的，只有惩戒可靠。
    expect(isCurrentJungler({ assignedPosition: "", summonerSpells: [{ id: 11 }] })).toBe(true);
    expect(isCurrentJungler({ assignedPosition: "MIDDLE", summonerSpells: [{ id: 4 }] })).toBe(false);
  });

  it("其它位置、空对象与 null 都不算打野", () => {
    expect(isCurrentJungler({ assignedPosition: "TOP", summonerSpells: [{ id: 4 }, { id: 12 }] })).toBe(false);
    expect(isCurrentJungler({})).toBe(false);
    expect(isCurrentJungler(null)).toBe(false);
    expect(isCurrentJungler(undefined)).toBe(false);
  });
});
