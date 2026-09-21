import { describe, expect, it } from "vitest";
import type { JungleCampCounts } from "../types/domain";
import {
  JUNGLE_CAMP_SPOTS,
  campCountsTotal,
  campMarkerSize,
  describeCamps,
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
  it("按次数降序取前两个，占比以该组总次数为基数", () => {
    expect(describeCamps(camps({ blue: 1, red: 2 }))).toBe("红 Buff 67% · 蓝 Buff 33%");
  });

  it("没有样本时不吐空字符串，给出可读占位", () => {
    expect(describeCamps(camps())).toBe("无样本");
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
