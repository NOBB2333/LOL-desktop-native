import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import { flushPromises, mount } from "@vue/test-utils";
import type { VueWrapper } from "@vue/test-utils";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createFixtureMatchTimeline, fixtureEncounters, fixtureMatches } from "../fixtures/data";
import { deriveTeamfights } from "../matches/teamfights";
import HistoryView from "./HistoryView.vue";

/**
 * 历史页重做后的结构（**只有两个页签**）：
 * - 「对局」= 对局列表，点开一局才去拉那一局的逐帧数据，展开区给首杀 / 每波团 / 事件流 / 同场的人；
 * - 「人」= 首页「关系记录」那批人的详细版，展开一行看逐局对比。
 *
 * 旧的四页签（最近对局 / 遇到的玩家 / 对局时间线 / BP 记录）已经删掉，
 * 所以这里的断言也把「删干净了」写进去——否则下次谁把那半页经济曲线捡回来没人拦得住。
 */
const { pushedRoutes, routeState, timelineRequests } = vi.hoisted(() => ({
  pushedRoutes: [] as Array<{ path: string; query?: Record<string, string> }>,
  /** 假的 URL query：深链测试要在挂载前写好。 */
  routeState: { query: {} as Record<string, unknown> },
  /** 逐帧数据是按需拉的，记录到底拉过哪几局。 */
  timelineRequests: [] as number[],
}));

vi.mock("vue-router", () => ({
  useRouter: () => ({
    push: async (route: { path: string; query?: Record<string, string> }) => {
      pushedRoutes.push(route);
    },
  }),
  useRoute: () => ({ query: routeState.query }),
}));

vi.mock("../stores/app", () => ({
  // 逐帧查询会带 `connection.puuid` 做账号归属校验，所以这里必须把 connection 补齐，
  // 否则 queryFn 会抛错、详情永远停在错误态（曾经漏过一次，测试只看到空区块）。
  useAppStore: () => ({ mode: "fixture", initialized: true, connection: { puuid: "self-puuid" } }),
}));

vi.mock("../services/backend", async () => {
  const { createFixtureMatchTimeline, fixtureChampions, fixtureEncounters, fixtureMatches } = await import("../fixtures/data");
  return {
    isTauri: () => false,
    backend: {
      champions: async () => structuredClone(fixtureChampions),
      encounters: async () => structuredClone(fixtureEncounters),
      matches: async () => structuredClone(fixtureMatches),
      matchTimeline: async (gameId: number) => {
        timelineRequests.push(gameId);
        return createFixtureMatchTimeline(gameId);
      },
      // 展开区的十人对位面板走完整详情（fixture 的 participants 就挂在 match 上），
      // 等级段位是另一条命令——这里给个最小实现，够面板渲染「Lv.N」就行。
      matchDetail: async (gameId: number) => {
        const found = fixtureMatches.find((item) => item.gameId === gameId);
        if (!found) throw new Error("该对局的完整详情不可用");
        return structuredClone(found);
      },
      playerStats: async (puuids: string[]) =>
        puuids.map((puuid, index) => ({ puuid, summonerLevel: 120 + index, soloRank: null, flexRank: null })),
    },
  };
});

// `round` 要跟着透出来：地图上的英雄头像是圆形裁切的，光数图标个数测不出「有没有裁圆」。
// 注意必须写成 `type: Boolean`（等价于真实组件的类型推断）——数组式 props 不做布尔转换，
// 裸写的 `round` 属性会以空字符串落进来，被当成 false。
const AssetIconStub = {
  props: { id: { default: 0 }, name: { default: "" }, round: { type: Boolean, default: false } },
  template: '<i class="asset-icon-stub" :data-id="id" :data-name="name" :data-round="round ? \'1\' : \'0\'" />',
};

function mountView() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return mount(HistoryView, {
    global: {
      plugins: [[VueQueryPlugin, { queryClient }]],
      stubs: {
        AssetIcon: AssetIconStub,
        PageHeader: { template: "<header><slot /></header>" },
        NButton: { template: "<button><slot /></button>" },
        NInput: { props: ["value"], template: "<input />" },
        NSpin: { template: '<span class="n-spin-stub" />' },
      },
    },
  });
}

/**
 * 按文字点页签。
 *
 * **不要用 `nth-child`**：页签顺序、以及中间那条分隔主次的分组竖线都会变，
 * 按下标取会在下次调整页签时静默点到别的地方（重做前已经踩过一次）。
 */
function tab(wrapper: VueWrapper, label: string) {
  const found = wrapper.findAll(".history-tabs button").find((item) => item.text().includes(label));
  if (!found) throw new Error(`没有找到页签：${label}`);
  return found;
}

/**
 * 展开一局的链是三跳的：拉最近对局 → 点开 → 按 gameId 拉该局逐帧，
 * 一次 `flushPromises` 只够跳一步。
 */
async function settle() {
  for (let tick = 0; tick < 6; tick += 1) await flushPromises();
}

beforeEach(() => {
  pushedRoutes.length = 0;
  timelineRequests.length = 0;
  routeState.query = {};
});

describe("HistoryView", () => {
  it("只剩下「对局」与「人」两个页签，默认落在对局，旧的四页签不留痕", async () => {
    const wrapper = mountView();
    await settle();

    const labels = wrapper.findAll(".history-tabs button").map((item) => item.text());
    expect(labels).toHaveLength(2);
    expect(labels[0]).toContain("对局");
    expect(labels[1]).toContain("人");
    expect(tab(wrapper, "对局").classes()).toContain("active");

    // 一次只渲染一个区块：两个页签是 v-if / v-else，漏了就会两块同时出现。
    expect(wrapper.findAll(".history-section")).toHaveLength(1);
    expect(wrapper.findAll(".match-card")).toHaveLength(fixtureMatches.length);

    // 重做删掉的东西：分组竖线、经济曲线、BP 记录。
    expect(wrapper.find(".history-tabs__divider").exists()).toBe(false);
    expect(wrapper.find(".timeline-chart").exists()).toBe(false);
    expect(wrapper.find(".bp-champion-list").exists()).toBe(false);
    expect(wrapper.text()).not.toContain("BP 记录");
  });

  it("逐帧数据只在展开那一局时才拉，展开后给出首杀 / 每波团 / 事件流", async () => {
    const wrapper = mountView();
    await settle();
    expect(timelineRequests).toHaveLength(0);

    await wrapper.get(".match-card__head").trigger("click");
    await settle();

    const first = fixtureMatches[0];
    expect(timelineRequests).toEqual([first.gameId]);
    expect(wrapper.get(".match-card").classes()).toContain("is-open");

    const timeline = createFixtureMatchTimeline(first.gameId);
    const summary = wrapper.get(".match-detail__summary").text();
    expect(summary).toContain("首杀");
    expect(summary).toContain("（红方）");
    expect(summary).toContain("击杀");
    expect(summary).toContain("多杀");

    // fixture 里刻意设计了三波团（中路 / 红方下路 / 大龙坑）。
    expect(summary).toContain("3 波");
    // 团战是「点哪波、共用表显示哪波」：三行摘要 + 观战面板三个钉 + 只有一张详情表。
    expect(wrapper.findAll(".teamfights__chip")).toHaveLength(3);
    expect(wrapper.findAll(".spectate__pin")).toHaveLength(3);
    expect(wrapper.findAll(".teamfight-detail")).toHaveLength(1);
    // 默认选中第一波：共用详情给蓝方 3 : 1 红方；十人数据用**柱状图**展示，
    // 指标可以切（本波输出 / 本波承伤 / 全场输出 / 全场承伤）。
    expect(wrapper.findAll(".teamfights__chip")[0].classes()).toContain("is-active");
    expect(wrapper.get(".teamfight-detail").text()).toContain("蓝方 3 : 1 红方");
    expect(wrapper.find(".teamfight-detail__bars").exists()).toBe(true);
    expect(wrapper.findAll(".teamfight-bars__row")).toHaveLength(10);
    const metrics = wrapper.findAll(".teamfight-detail__metrics button");
    expect(metrics.map((item) => item.text())).toEqual(["本波输出", "本波承伤", "全场输出", "全场承伤", "出装"]);
    expect(metrics[0].classes()).toContain("active");
    expect(wrapper.get(".teamfight-bars__head").text()).toContain("本波输出");
    // 四个柱状指标**都要有图**：之前某一项整列是 0 时整块会被换成对位表，看起来就是
    // 「柱状图时有时无」（用户反馈的原话）。现在图恒在，只多一句「全列是 0」的说明。
    for (const [index, label] of ["本波输出", "本波承伤", "全场输出", "全场承伤"].entries()) {
      await metrics[index].trigger("click");
      await flushPromises();
      expect(wrapper.find(".teamfight-detail__bars").exists()).toBe(true);
      expect(wrapper.get(".teamfight-bars__head").text()).toContain(label);
      expect(wrapper.findAll(".teamfight-bars__row")).toHaveLength(10);
      expect(wrapper.findAll(".teamfight-bars__track i")).toHaveLength(10);
    }
    // 「出装」：团战是一个时间点，装备在这几秒里不会换，所以这一项直接摆六件装备图标。
    await metrics[4].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".teamfight-bars--items")).toHaveLength(2);
    expect(wrapper.findAll(".teamfight-bars__items")).toHaveLength(10);
    expect(wrapper.findAll(".teamfight-bars__items .asset-icon-stub").length).toBeGreaterThan(0);
    expect(wrapper.get(".teamfight-bars__head").text()).toContain("出装");
    await metrics[0].trigger("click");
    await flushPromises();
    expect(wrapper.get(".teamfight-bars__head").text()).toContain("本波输出");
    // 点第二波的摘要：还是同一张表，内容换成第二波（比分 1 : 2）。
    await wrapper.findAll(".teamfights__chip")[1].trigger("click");
    await flushPromises();
    expect(wrapper.get(".teamfight-detail").text()).toContain("蓝方 1 : 2 红方");
    expect(wrapper.findAll(".teamfights__chip")[1].classes()).toContain("is-active");

    // 事件流**跟着选中的团走**：只列这一波时间窗里发生的事（团战击杀 + 这期间的龙 / 塔），
    // 不是把整局几十条全糊上来（用户原话「不要把所有的事件流都贴进来」）。
    const fights = deriveTeamfights(timeline.events, timeline.participants);
    const inFight = timeline.events.filter((event) => event.seconds >= fights[1].startSeconds && event.seconds <= fights[1].endSeconds);
    expect(inFight.length).toBeGreaterThan(0);
    expect(inFight.length).toBeLessThan(timeline.events.length);
    expect(wrapper.findAll(".match-event")).toHaveLength(inFight.length);
    // 标题要写清「这是哪一波的、不是整局」（第二个 block 才是事件流）。
    expect(wrapper.findAll(".match-detail__block h4")[1].text()).toContain("只看这一波");
    // 缩到某一波之后，每行都一样的「团N」角标被过滤掉，只留首杀 / 多杀这类真信息。
    const badges = wrapper.findAll(".match-event__badges i").map((item) => item.text());
    expect(badges.some((badge) => badge.startsWith("团"))).toBe(false);
    // 每行都带英雄头像：击杀是「谁杀谁」两张脸，拿龙推塔只有「谁做的」一头。
    expect(wrapper.findAll(".match-event__faces .asset-icon-stub").length).toBeGreaterThan(0);
  });

  it("展开区给观战式面板（十人 + 可拖时间轴），选中态与每波团双向同步", async () => {
    const wrapper = mountView();
    await settle();

    await wrapper.get(".match-card__head").trigger("click");
    await settle();

    const timeline = createFixtureMatchTimeline(fixtureMatches[0].gameId);
    const kills = timeline.events.filter((event) => event.type === "CHAMPION_KILL");
    const fights = deriveTeamfights(timeline.events, timeline.participants);
    const clock = (time: number) => `${String(Math.floor(time / 60)).padStart(2, "0")}:${String(time % 60).padStart(2, "0")}`;

    // 观战面板：左右各五个人的记分板，默认游标停在终局——击杀比等于全场总数。
    const spectate = wrapper.get(".spectate");
    expect(wrapper.findAll(".spectate-player")).toHaveLength(10);
    // 等级徽标（fixture 帧里带 level）与圆形英雄头像都要画出来。
    expect(wrapper.findAll(".spectate-player__level").length).toBeGreaterThan(0);
    expect(wrapper.findAll(".spectate-player__portrait .asset-icon-stub")).toHaveLength(10);
    // 玩家行第二行不再是装备，而是「到游标时刻为止的累计对英雄伤害」柱条（装备格子信息量太低，被换掉了）。
    expect(wrapper.findAll(".spectate-player__items")).toHaveLength(0);
    expect(wrapper.findAll(".spectate-player__damage .spectate-player__damage-track")).toHaveLength(10);
    // 战绩与经济拆成两枚胶囊——原来挤在一行 9px 次级色文字里根本读不出来。
    expect(wrapper.findAll(".spectate-kda")).toHaveLength(10);
    expect(wrapper.findAll(".spectate-gold")).toHaveLength(10);
    expect(wrapper.findAll(".spectate-kda").every((chip) => chip.element.children.length === 5)).toBe(true);
    // 本地相遇档案里见过的人要带「遇到过 N」角标。
    expect(spectate.text()).toContain("遇到过");

    const blueKills = kills.filter((event) => event.team === 100).length;
    expect(wrapper.get(".spectate__score b[data-team='100']").text()).toBe(String(blueKills));

    // 时间轴：每个击杀一颗标记，大小龙/推塔各自有形状；经济差折线画出来了。
    expect(wrapper.findAll(".spectate__mark--kill")).toHaveLength(kills.length);
    expect(wrapper.findAll(".spectate__mark--monster").length).toBeGreaterThan(0);
    expect(wrapper.findAll(".spectate__mark--building").length).toBeGreaterThan(0);
    expect(wrapper.findAll(".spectate__spark path").length).toBeGreaterThan(0);

    // 地图上的十个位置画的是**圆形英雄头像**，不是纯色圆点（用户明确要求换成头像）。
    const mapDots = wrapper.findAll(".spectate__dot .asset-icon-stub");
    expect(mapDots.length).toBeGreaterThan(0);
    expect(mapDots.every((icon) => icon.attributes("data-round") === "1")).toBe(true);

    // 点时间轴上的团战高亮段 → 下方「每波团」的摘要条跟着切；反向同理。
    await wrapper.findAll(".spectate__fight")[1].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".teamfights__chip")[1].classes()).toContain("is-active");
    expect(wrapper.findAll(".spectate__fight")[1].classes()).toContain("is-active");
    await wrapper.findAll(".teamfights__chip")[0].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".spectate__fight")[0].classes()).toContain("is-active");

    // 地图上的编号钉与摘要条同源：点某个钉，选中的必须是它自己标着的那一波。
    // （落点算不出来的团会被滤掉，所以钉的下标与数组下标不一定相同——这里按钉上的字来验。）
    const pin = wrapper.findAll(".spectate__pin")[0];
    await pin.trigger("click");
    await flushPromises();
    const activeChip = wrapper.findAll(".teamfights__chip").find((chip) => chip.classes().includes("is-active"));
    expect(activeChip?.text()).toContain(pin.text());

    // 地图**常驻**（「地图 / 实时伤害」那组 Tab 已经删掉）。第二行的指标切换器长在
    // 十人列**正上方**那条通栏里（`.spectate__rowbar`）——它管的就是下面那十行，
    // 原来塞在底部回放控制条里，用户反馈「不容易找到、不容易看到」。
    expect(wrapper.find(".spectate__map").exists()).toBe(true);
    expect(wrapper.find(".spectate__center-switch").exists()).toBe(false);
    expect(wrapper.find(".spectate__rowbar").exists()).toBe(true);
    const rowSwitch = wrapper.findAll(".spectate__rowbar .spectate__rowswitch button");
    expect(rowSwitch.map((item) => item.text())).toEqual(["输出", "承伤", "推塔", "装备"]);
    expect(rowSwitch[0].classes()).toContain("is-active");
    // 默认「输出」= 到此刻的累计对英雄伤害。分母是**终局那一帧**的最大值（十根轨道同宽才
    // 谈得上横向比，而且分母固定柱子才会随游标变长），所以游标不在结尾时最长的那根**不该**
    // 满格——满格恰恰说明分母是「当前游标下的最大值」，那种归一化会让柱子长度几乎不动。
    const barWidths = () =>
      wrapper.findAll(".spectate-player__damage-track i").map((bar) => Number.parseFloat(bar.attributes("style")?.match(/width:\s*([\d.]+)%/)?.[1] ?? "0"));
    expect(barWidths()).toHaveLength(10);
    expect(new Set(barWidths()).size).toBeGreaterThan(1);
    expect(Math.max(...barWidths())).toBeGreaterThan(0);
    expect(Math.max(...barWidths())).toBeLessThanOrEqual(100);
    // 两队合计不该是同一个数（fixture 里逐人加了确定性的状态系数，否则两队数值会一模一样）。
    const teamTotals = wrapper.findAll(".spectate__teamlabel").map((item) => item.text());
    expect(teamTotals).toHaveLength(2);
    expect(teamTotals[0]).not.toBe(teamTotals[1]);
    // 「推塔」走的是整局总账（LCU 的分钟帧里没有对塔伤害），标题要写明不是「到此刻」。
    await rowSwitch[2].trigger("click");
    await flushPromises();
    expect(wrapper.get(".spectate__teamlabel").text()).toContain("全场对塔伤害");
    expect(Math.max(...barWidths())).toBeCloseTo(100, 5);
    // 切到「装备」：第二行整排换成装备格子，地图照旧在。
    await rowSwitch[3].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".spectate-player__damage")).toHaveLength(0);
    expect(wrapper.findAll(".spectate-player__items")).toHaveLength(10);
    expect(wrapper.findAll(".spectate-player__items .asset-icon-stub").length).toBeGreaterThan(0);
    expect(wrapper.find(".spectate__map").exists()).toBe(true);
    // 切回「输出」，后面的用例还要看柱条。
    await rowSwitch[0].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".spectate-player__damage-track")).toHaveLength(10);

    // 顶部对局面板：中间记分牌（比分两个 b），两翼各一块阵营面板（阵营名 + 金币 + 目标物）。
    // 点地图钉 / 团条会把游标**带到那一波开打那一刻**（设计如此），所以先回终局，
    // 下面这些「累计到此刻」的目标物数才有确定的落点。
    await wrapper.findAll(".spectate__controls > button")[2].trigger("click");
    await flushPromises();
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(timeline.durationSeconds));
    expect(wrapper.get(".spectate__tally").findAll("b")).toHaveLength(2);
    const blueSide = wrapper.get(".spectate__side[data-team='100']");
    const redSide = wrapper.get(".spectate__side[data-team='200']");
    expect(blueSide.get(".spectate__sidename").text()).toContain("蓝方");
    expect(redSide.get(".spectate__sidename").text()).toContain("红方");
    // 队伍经济前面必须有金币图标——面板上还有一组伤害数字，没有图标就分不清谁是谁。
    expect(blueSide.findAll(".spectate__sidegold .coin")).toHaveLength(1);
    expect(redSide.findAll(".spectate__sidegold .coin")).toHaveLength(1);
    // 塔 / 大小龙都要数出来，小龙还要带龙种（fixture 里蓝方拿到了火龙）。
    const blueObjectives = blueSide.get(".spectate__objs").text();
    expect(blueObjectives).toContain("塔");
    expect(blueObjectives).toContain("小龙");
    expect(blueObjectives).toContain("火龙");
    expect(blueObjectives).toContain("大龙");
    expect(blueObjectives).toContain("先锋");
    expect(wrapper.get(".spectate__score").text()).toContain("经济差");
    // 十人行的金币胶囊同样带图标（10 个人各一个）。
    expect(wrapper.findAll(".spectate-gold .coin")).toHaveLength(10);
    // 塔 / 水晶都画在地图上，且**被推掉的画成空心**（拖时间轴能看到一座座掉）。
    const structures = wrapper.findAll(".spectate__structure");
    expect(structures.length).toBeGreaterThan(20);
    expect(structures.filter((item) => item.classes().includes("is-down")).length).toBeGreaterThan(0);

    // 逐帧明细（首杀 / 每波团 / 事件流）不受影响；事件流只列**选中那一波**：
    // 击杀严格按团战窗口，大小龙 / 推塔放宽 ±15 秒（抢龙和开团在时间上是一件事）。
    const summary = wrapper.get(".match-detail__summary").text();
    expect(summary).toContain("首杀");
    const scopedIndex = wrapper.findAll(".teamfights__chip").findIndex((chip) => chip.classes().includes("is-active"));
    expect(scopedIndex).toBeGreaterThanOrEqual(0);
    const scopedFight = fights[scopedIndex];
    const scopedEvents = timeline.events.filter((event) => event.seconds >= scopedFight.startSeconds - 15 && event.seconds <= scopedFight.endSeconds + 15);
    expect(wrapper.findAll(".match-event")).toHaveLength(scopedEvents.length);
    expect(wrapper.findAll(".match-event__hit")).toHaveLength(scopedEvents.length);
    expect(scopedEvents.length).toBeGreaterThan(0);
    expect(scopedEvents.length).toBeLessThan(timeline.events.length);
    expect(wrapper.findAll(".match-detail__block h4")[1].text()).toContain("只看这一波");

    // 回放交互：点事件流某条 → 观战面板游标落在那秒（不需要用户自己去拖时间轴）。
    // 事件流已经缩到选中那一波，所以「第一条」是**这一波**的第一条，不是整局的第一条。
    const firstInFight = scopedEvents[0];
    await wrapper.findAll(".match-event__hit")[0].trigger("click");
    await flushPromises();
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(firstInFight.seconds));

    // 上一波 / 下一波：换选中波的**同时**把游标带到那一波开打那一刻。
    // 控制条现在只有三个回放按钮（第二行指标切换器已经挪到十人列上方）。
    await wrapper.findAll(".spectate__controls > button")[1].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".teamfights__chip")[1].classes()).toContain("is-active");
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(fights[1].startSeconds));
    await wrapper.findAll(".spectate__controls > button")[0].trigger("click");
    await flushPromises();
    expect(wrapper.findAll(".teamfights__chip")[0].classes()).toContain("is-active");
    // 「回到终局」把游标放回最后一秒。
    await wrapper.findAll(".spectate__controls > button")[2].trigger("click");
    await flushPromises();
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(timeline.durationSeconds));

    // 键盘擦洗：声明了 role=slider，方向键就得管用（←/→ 5 秒、Shift 30 秒、Home/End 到两端）。
    const bar = wrapper.get(".spectate__timeline");
    expect(bar.attributes("tabindex")).toBe("0");
    const total = timeline.durationSeconds;
    await bar.trigger("keydown", { key: "ArrowLeft" });
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(Math.max(0, total - 5)));
    await bar.trigger("keydown", { key: "ArrowLeft", shiftKey: true });
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(Math.max(0, total - 35)));
    await bar.trigger("keydown", { key: "Home" });
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(0));
    await bar.trigger("keydown", { key: "End" });
    expect(wrapper.get(".spectate__clock strong").text()).toBe(clock(total));
  });

  it("「人」页签按玩家聚合成一行，展开后能看到逐局细节，并能跳战绩页", async () => {
    const wrapper = mountView();
    await settle();

    await tab(wrapper, "人").trigger("click");
    await settle();

    // 原始记录是「每局每人一行」，同一个人 3 局就会出现 3 次；聚合后每人只占一行。
    const uniquePlayers = new Set(fixtureEncounters.map((record) => record.puuid)).size;
    expect(wrapper.findAll(".encounter-table__row")).toHaveLength(uniquePlayers);
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(0);

    await wrapper.get(".encounter-table__row").trigger("click");
    await settle();
    expect(wrapper.get(".encounter-table__row").classes()).toContain("is-open");
    // 这套 fixture 里每位玩家都出现在全部 3 局中。
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(3);
    // 表头必须解释「他 / 我」两列，否则两串 KDA 只能猜。
    const head = wrapper.get(".encounter-detail__head").text();
    for (const column of ["英雄", "他", "我", "结果"]) expect(head).toContain(column);
    const detail = wrapper.get(".encounter-detail__row");
    expect(detail.findAll(".encounter-detail__side")).toHaveLength(1);
    expect(detail.text()).toMatch(/队友|对手/);
    expect(detail.text()).toContain("单双排");

    pushedRoutes.length = 0;
    const rowName = wrapper.get(".encounter-table__row .encounter-player strong").text().split("#")[0];
    await wrapper.get(".encounter-detail__foot button").trigger("click");
    await flushPromises();
    expect(pushedRoutes).toHaveLength(1);
    expect(pushedRoutes[0].path).toBe("/matches");
    expect(pushedRoutes[0].query?.summoner).toContain(rowName);
  });

  it("「人」页签展开的某一行还能再点开全局对局信息", async () => {
    const wrapper = mountView();
    await settle();

    await tab(wrapper, "人").trigger("click");
    await settle();
    await wrapper.get(".encounter-table__row").trigger("click");
    await settle();

    // 逐局行先给最简对照（他 / 我各一列英雄），此时还没有更深的详情。
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(3);
    expect(wrapper.find(".encounter-detail__deep").exists()).toBe(false);

    await wrapper.get(".encounter-detail__row").trigger("click");
    await settle();

    // 点开的行下面挂出观战面板 + 事件流——和「对局」页签展开看到的是同一套。
    const deep = wrapper.get(".encounter-detail__deep");
    expect(deep.findAll(".spectate-player")).toHaveLength(10);
    expect(deep.findAll(".spectate__mark--kill").length).toBeGreaterThan(0);
    expect(deep.find(".match-detail__summary").exists()).toBe(true);
    // 再点一次收起。
    await wrapper.get(".encounter-detail__row").trigger("click");
    await settle();
    expect(wrapper.find(".encounter-detail__deep").exists()).toBe(false);
  });

  it("首页「关系记录」的深链：切到「人」并直接把那一行展开", async () => {
    // 这个链接是首页写出去的（`/history?player=<puuid>&tab=players`）。不读 query
    // 就等于点了没反应——用户点了一个名字，落到的却是一张要自己再找一遍的表。
    const target = fixtureEncounters[0];
    routeState.query = { tab: "players", player: target.puuid };

    const wrapper = mountView();
    await settle();

    expect(tab(wrapper, "人").classes()).toContain("active");
    expect(wrapper.findAll(".encounter-table__row.is-open")).toHaveLength(1);
    expect(wrapper.get(".encounter-table__row.is-open").text()).toContain(target.gameName);
    expect(wrapper.findAll(".encounter-detail__row")).toHaveLength(3);
  });
});
