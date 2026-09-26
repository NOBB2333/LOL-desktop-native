import { describe, expect, it } from "vitest";
import { landingRedirect } from "./landing";

const base = { initialized: true, path: "/", mode: "live" as const, status: "connected" as const };

describe("landingRedirect", () => {
  it("客户端在跑：留在首页", () => {
    expect(landingRedirect({ ...base, status: "connected" })).toBeNull();
  });

  it("客户端没跑：去客户端页", () => {
    expect(landingRedirect({ ...base, status: "disconnected" })).toBe("/client");
    expect(landingRedirect({ ...base, status: "error" })).toBe("/client");
  });

  it("状态还没落地（connecting）时不下判断，等下一次状态更新", () => {
    // 启动瞬间多半读到的还是 bootstrap 的旧快照；这时候下判断会把人送错页。
    expect(landingRedirect({ ...base, status: "connecting" })).toBeNull();
  });

  it("还没初始化完不判断", () => {
    expect(landingRedirect({ ...base, initialized: false, status: "disconnected" })).toBeNull();
  });

  it("用户不在首页、或切到了演示模式，都不弹走", () => {
    expect(landingRedirect({ ...base, path: "/history", status: "disconnected" })).toBeNull();
    expect(landingRedirect({ ...base, mode: "fixture", status: "disconnected" })).toBeNull();
  });
});
