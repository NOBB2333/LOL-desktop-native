import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";

let forbiddenRequests = 0;
let activeProfiles = 0;
let peakProfiles = 0;
const lookups = new Set();
const activeKinds = new Map();
const parallelPlayers = new Set();
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (url.pathname.startsWith("/lol-")) {
    assert.equal(request.method, "GET", "验证仅允许读取数据");
    activeProfiles += 1;
    peakProfiles = Math.max(peakProfiles, activeProfiles);
    let data;
    let player;
    let kind;
    let delay = 120;
    if (url.pathname === "/lol-summoner/v1/summoners") {
      const name = url.searchParams.get("name");
      assert.match(name, /^(我方|敌方)[0-4]#测试$/, "必须按每名玩家完整名称搜索");
      lookups.add(name);
      player = Number(name[2]) + (name.startsWith("敌方") ? 5 : 0);
      data = { puuid: `验证身份-${player}`, gameName: name.split("#")[0], tagLine: "测试" };
    } else {
      const match = decodeURIComponent(url.pathname).match(/验证身份-(\d+)/);
      assert.ok(match, "不能使用占位身份查询段位或战绩");
      player = Number(match[1]);
      kind = url.pathname.includes("ranked-stats") ? "rank" : "history";
      const kinds = activeKinds.get(player) ?? new Set();
      kinds.add(kind);
      activeKinds.set(player, kinds);
      if (kinds.size === 2) parallelPlayers.add(player);
      delay = kind === "history" && player === 0 ? 1200 : kind === "history" ? 260 : 180;
      data = kind === "rank" ? { queues: [] } : { games: { games: [420, 450].map((queueId, index) => ({ gameId: 1000 + player + index * 100, queueId, gameDuration: 1800, participants: [{ puuid: `验证身份-${player}`, championId: player + 1, teamId: 100, win: true, kills: player + 1 }] })) } };
    }
    response.on("close", () => {
      activeProfiles -= 1;
      if (kind) activeKinds.get(player)?.delete(kind);
    });
    setTimeout(() => {
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify(data));
    }, delay);
    return;
  }
  if (request.url === "/must-not-run") forbiddenRequests += 1;
  if (request.url === "/slow") {
    const timer = setTimeout(() => response.end("延迟结果"), 800);
    response.on("close", () => clearTimeout(timer));
  } else if (request.url === "/slow-body") {
    response.writeHead(200);
    const timer = setInterval(() => response.write("持续数据"), 20);
    response.on("close", () => clearInterval(timer));
  } else if (request.url === "/large") {
    response.end("内容".repeat(30000));
  } else {
    const status = /^\/\d{3}$/.test(request.url) ? Number(request.url.slice(1)) : 200;
    response.writeHead(status);
    response.end("受控响应");
  }
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}`;
try {
  const args = ["build", "verify-runtime", "-Dplatform=null", ...process.argv.slice(2), "--", url];
  const child = spawn("zig", args, { stdio: "inherit", windowsHide: true });
  const timeout = setTimeout(() => child.kill(), 120000);
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  }).finally(() => clearTimeout(timeout));
  assert.equal(code, 0, "原生网络验证必须全部通过");
  assert.equal(forbiddenRequests, 0, "已取消或处于退避期的请求不能抵达服务器");
  assert.equal(lookups.size, 9, "本人之外的九名玩家必须分别搜索");
  assert.ok(peakProfiles > 2 && peakProfiles <= 6, "原生资料请求必须并发且不超过六个名额");
  assert.ok(parallelPlayers.size >= 5, "多名玩家的段位和战绩必须重叠执行");
  console.log(`十人原生请求并发峰值 ${peakProfiles}，${parallelPlayers.size} 名玩家的段位和战绩重叠执行。`);
  console.log("受控服务器验证通过，没有过期请求抵达服务器。");
} finally {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}
