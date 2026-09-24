/**
 * 英雄的**社区昵称**搜索表。
 *
 * 为什么需要它：客户端目录里每个英雄只有两个可搜字段——`name`（国服的**称号**，
 * 如「暗裔剑魔」「九尾妖狐」）和 `alias`（英文名，如 `Aatrox` / `Ahri`）。玩家平时
 * 喊的却是「牛头」「奶妈」「龙龟」「文森特」这类社区叫法，这些**不在任何接口里**
 * （LCU 的 `champion-summary` 没有 keywords / 中文简称字段），所以只能本地维护。
 *
 * 三条规矩：
 * 1. **键用英文 `alias`**，不用中文名。中文名会随国服文案调整，alias 是稳定的；
 *    而且这里的 `name` 存的是**称号**（暗裔剑魔）而不是名字（亚托克斯），本来也不适合当键。
 * 2. **键必须先过 `normalizeChampionKey`**：小写 + 去掉空格/撇号/连字符，
 *    于是 `Kog'Maw` / `KogMaw` / `kog maw` 是同一个键。单测会校验这一点。
 * 3. 只收**玩家真的会用**的称呼。称号里已经能搜到的（搜「剑魔」能命中「暗裔剑魔」）
 *    不必重复登记——这里的价值全在那些搜不到的俗称上。
 *
 * 加新条目：写 `alias小写: ["俗称", "别名"]`，跑 `nicknames.test.ts` 即可。
 */

/**
 * 归一化一个可搜字符串：小写 + 去掉空格、撇号、连字符、下划线。
 *
 * 只用于**比较**，不用于显示——`Kog'Maw` 归一化成 `kogmaw` 之后就找不回原样了，
 * 所以界面上一律显示目录给的原始名字。
 */
export function normalizeChampionKey(value: string): string {
  return value.toLowerCase().replace(/[\s'’\-_.]/g, "");
}

/**
 * `alias（归一化）→ 社区昵称`。分路只是排版用的分组注释，不参与匹配。
 *
 * ⚠️ 键里**不允许**出现大写或空格，`nicknames.test.ts` 会逐条校验。
 */
const CHAMPION_NICKNAMES: Record<string, readonly string[]> = {
  // ── 上路 ─────────────────────────────────────────────────────────────────
  aatrox: ["剑魔", "亚托克斯", "吸血鬼剑"],
  camille: ["卡蜜尔", "青钢", "钢丝"],
  chogath: ["大虫子", "虫子", "科加斯"],
  darius: ["诺手", "诺克", "牛头人杀手"],
  fiora: ["剑姬", "菲奥娜"],
  gangplank: ["船长", "普朗克"],
  garen: ["德玛", "草丛伦", "大宝剑"],
  gnar: ["纳尔", "蜥蜴"],
  gragas: ["酒桶", "古拉加斯"],
  illaoi: ["触手妈", "俄洛伊", "大触"],
  irelia: ["刀妹", "艾瑞莉娅"],
  jax: ["武器", "武器大师", "跳跳虎"],
  jayce: ["杰斯", "双修"],
  kled: ["克烈", "小矮子"],
  ksante: ["奎桑提", "黑哥"],
  malphite: ["石头人", "石头", "墨菲特"],
  monkeyking: ["悟空", "猴哥", "猴子", "wukong"],
  mundo: ["蒙多", "蒙多医生"],
  nasus: ["狗头", "沙漠死神", "内瑟斯"],
  olaf: ["奥拉夫", "疯狗", "斧男"],
  ornn: ["奥恩", "铁匠"],
  pantheon: ["潘森", "斯巴达"],
  poppy: ["波比", "小矮子铁匠"],
  quinn: ["奎因", "德玛西亚之翼"],
  renekton: ["鳄鱼", "雷克顿"],
  riven: ["锐雯", "光速QA", "断剑"],
  rumble: ["兰博", "机械公敌"],
  sett: ["腕豪", "瑟提", "拳皇"],
  shen: ["慎", "暮光之眼"],
  singed: ["炼金", "辛吉德", "毒男"],
  sion: ["塞恩", "亡灵", "亡灵战神"],
  teemo: ["提莫", "蘑菇", "提百万"],
  trundle: ["巨魔", "特朗德尔"],
  tryndamere: ["蛮王", "蛮子", "泰隆德米尔"],
  urgot: ["厄加特", "螃蟹"],
  vladimir: ["吸血鬼", "弗拉基米尔"],
  volibear: ["沃利贝尔", "狗熊", "雷霆咆哮"],
  yorick: ["掘墓", "约里克", "牧魂人"],
  yone: ["永恩", "亚索的哥哥"],

  // ── 打野 ─────────────────────────────────────────────────────────────────
  amumu: ["木木", "阿木木", "哭泣的木乃伊"],
  briar: ["布蕾尔", "吸血鬼萝莉"],
  diana: ["皎月", "黛安娜", "月女"],
  ekko: ["艾克", "时间刺客", "无限循环"],
  evelynn: ["寡妇", "伊芙琳", "寡妇制造者"],
  fiddlesticks: ["稻草人", "费德提克"],
  graves: ["男枪", "格雷福斯", "枪手"],
  hecarim: ["人马", "赫卡里姆", "半人马"],
  heimerdinger: ["大头", "黑默丁格", "三炮"],
  ivern: ["艾翁", "树人"],
  jarvaniv: ["皇子", "嘉文四世", "嘉文"],
  karthus: ["死歌", "卡尔萨斯"],
  kayn: ["凯隐", "蓝凯", "红凯"],
  khazix: ["螳螂", "卡兹克", "虚空掠夺者"],
  kindred: ["千珏", "羊刀", "永猎双子"],
  leesin: ["盲僧", "盲僧李青", "李青"],
  lillia: ["莉莉娅", "小鹿"],
  masteryi: ["剑圣", "易大师", "无极剑圣"],
  nidalee: ["豹女", "奈德丽", "美洲狮"],
  nocturne: ["梦魇", "魔腾", "永恒梦魇"],
  nunu: ["雪人", "努努", "雪人骑士"],
  rammus: ["龙龟", "拉莫斯", "披甲龙龟"],
  reksai: ["挖掘机", "雷克塞", "虚空遁地兽"],
  rengar: ["狮子狗", "雷恩加尔", "傲之追猎者"],
  sejuani: ["猪妹", "瑟庄妮", "凛冬之怒"],
  shaco: ["小丑", "萨科", "恶魔小丑"],
  shyvana: ["龙女", "希瓦娜", "龙血武姬"],
  skarner: ["蝎子", "斯卡纳", "水晶先锋"],
  sylas: ["塞拉斯", "锁匠", "解脱者"],
  udyr: ["乌迪尔", "野兽", "兽灵行者"],
  vi: ["蔚", "拳妹", "皮城执法官"],
  viego: ["佛耶戈", "破败之王", "失落的王"],
  warwick: ["狼人", "沃里克", "祖安之怒"],

  // ── 中路 ─────────────────────────────────────────────────────────────────
  ahri: ["狐狸", "阿狸", "九尾"],
  akali: ["阿卡丽", "离群之刺", "刺客"],
  anivia: ["冰鸟", "艾尼维亚", "冰晶凤凰"],
  annie: ["火女", "安妮", "小熊"],
  aurelionsol: ["龙王", "索尔", "铸星龙王"],
  azir: ["沙皇", "阿兹尔", "沙漠皇帝"],
  brand: ["火男", "布兰德", "复仇焰魂"],
  cassiopeia: ["蛇女", "卡西奥佩娅", "魔蛇之拥"],
  corki: ["飞机", "库奇", "英勇投弹手"],
  fizz: ["小鱼人", "菲兹", "潮汐海灵"],
  galio: ["加里奥", "石像鬼", "正义巨像"],
  hwei: ["慧", "画师"],
  kassadin: ["卡萨丁", "虚空行者", "海克斯科技狂人"],
  katarina: ["卡特", "卡特琳娜", "不祥之刃"],
  leblanc: ["妖姬", "乐芙兰", "诡术妖姬"],
  lissandra: ["冰女", "丽桑卓", "冰霜女巫"],
  lux: ["光辉", "拉克丝", "光辉女郎"],
  malzahar: ["蚂蚱", "玛尔扎哈", "虚空先知"],
  mel: ["梅尔", "新英雄"],
  naafiri: ["那菲利", "狗子"],
  orianna: ["发条", "奥莉安娜", "发条魔灵"],
  ryze: ["符文法师", "瑞兹", "蓝皮"],
  swain: ["乌鸦", "斯维因", "诺克萨斯统领"],
  syndra: ["辛德拉", "暗黑元首", "球女"],
  talon: ["泰隆", "男刀", "刀锋之影"],
  twistedfate: ["卡牌", "卡牌大师", "崔斯特"],
  veigar: ["小法师", "维迦", "邪恶小法师"],
  vex: ["薇古丝", "小恶魔"],
  viktor: ["三只手", "维克托", "机械先驱"],
  xerath: ["泽拉斯", "远古巫灵", "移动炮台"],
  yasuo: ["亚索", "疾风剑豪", "风男"],
  zed: ["劫", "影流之主", "忍者"],
  ziggs: ["炸弹人", "吉格斯", "爆破鬼才"],
  zoe: ["佐伊", "暮光星灵", "淘气包"],
  zyra: ["婕拉", "荆棘之兴", "花女"],

  // ── 下路（射手） ─────────────────────────────────────────────────────────
  aphelios: ["厄斐琉斯", "月男", "月神"],
  ashe: ["寒冰", "艾希", "寒冰射手"],
  caitlyn: ["女警", "凯特琳", "皮城女警"],
  draven: ["文森特", "德莱文", "荣耀行刑官"],
  ezreal: ["EZ", "伊泽瑞尔", "探险家"],
  jhin: ["烬", "戏命师", "四发"],
  jinx: ["金克丝", "暴走萝莉", "疯丫头"],
  kaisa: ["卡莎", "虚空之女"],
  kalista: ["滑板鞋", "卡莉丝塔", "复仇之矛"],
  kogmaw: ["大嘴", "克格莫", "深渊巨口"],
  lucian: ["奥巴马", "卢锡安", "圣枪游侠"],
  missfortune: ["女枪", "厄运小姐", "赏金猎人"],
  samira: ["莎弥拉", "沙漠玫瑰"],
  senna: ["赛娜", "涤魂圣枪"],
  sivir: ["轮子妈", "希维尔", "战争女神"],
  smolder: ["斯莫德", "小奶龙"],
  tristana: ["小炮", "崔丝塔娜", "麦林炮手"],
  twitch: ["老鼠", "图奇", "瘟疫之源"],
  varus: ["韦鲁斯", "惩戒之箭"],
  vayne: ["薇恩", "暗夜猎手", "银弩"],

  // ── 辅助 ─────────────────────────────────────────────────────────────────
  alistar: ["牛头", "牛头人", "老牛", "阿利斯塔"],
  bard: ["巴德", "星界游神"],
  blitzcrank: ["机器人", "布里茨", "蒸汽机器人"],
  braum: ["布隆", "大叔", "弗雷尔卓德之心"],
  janna: ["风女", "迦娜", "风暴之怒"],
  karma: ["卡玛", "天启者"],
  leona: ["日女", "蕾欧娜", "曙光女神"],
  lulu: ["露露", "仙灵女巫"],
  milio: ["米利欧", "小火男"],
  morgana: ["莫甘娜", "堕落天使"],
  nami: ["娜美", "美人鱼", "唤潮鲛姬"],
  nautilus: ["泰坦", "深海泰坦", "诺提勒斯"],
  pyke: ["派克", "血港鬼影", "钩子男"],
  rakan: ["洛", "幻翎"],
  rell: ["蕊尔", "铁女"],
  renata: ["娜娜", "芮娜塔", "炼金男爵"],
  seraphine: ["歌姬", "瑟拉菲娜", "星籁歌姬"],
  sona: ["琴女", "娑娜", "琴瑟仙女"],
  soraka: ["奶妈", "索拉卡", "众星之子"],
  tahmkench: ["塔姆", "河流之王", "大嘴蛤"],
  taric: ["宝石", "塔里克", "瓦洛兰之盾"],
  thresh: ["锤石", "魂锁典狱长", "钩子机器"],
  yuumi: ["猫", "悠米", "魔法猫咪"],
  zilean: ["基兰", "时光老头", "时光守护者"],
  xayah: ["霞", "逆羽"],
};

const ENTRIES: [string, readonly string[]][] = Object.entries(CHAMPION_NICKNAMES);

const NICKNAME_INDEX = new Map(ENTRIES);

/** 这个英雄（按英文 alias）有哪些社区昵称；没登记过就返回空数组。 */
export function championNicknames(alias: string): readonly string[] {
  if (!alias) return [];
  return NICKNAME_INDEX.get(normalizeChampionKey(alias)) ?? [];
}

/** 表里登记了多少个英雄（「有多少英雄能按俗称搜到」的诚实数字，别写成英雄总数）。 */
export const NICKNAME_CHAMPION_COUNT = ENTRIES.length;

/** 表里所有键（已归一化的 alias）。导出只为让测试能校验「键都是归一化的且不重复」。 */
export const NICKNAME_KEYS: readonly string[] = ENTRIES.map(([key]) => key);

/**
 * 一个英雄的可搜文本：**称号 + 英文名 + 社区昵称**，整体归一化。
 *
 * 三项都要：称号是界面上显示的字（用户会照着抄），英文名是有人习惯打 `Ahri`，
 * 昵称是「牛头」这类俗称。归一化之后空格与大小写都不再敏感。
 */
export function championSearchText(champion: { name: string; alias: string }): string {
  return normalizeChampionKey([champion.name, champion.alias, ...championNicknames(champion.alias)].join(" "));
}

/** 空查询一律命中（搜索框空着就是「全都显示」）。 */
export function matchesChampionQuery(champion: { name: string; alias: string }, query: string): boolean {
  const needle = normalizeChampionKey(query ?? "");
  if (!needle) return true;
  return championSearchText(champion).includes(needle);
}

/** 给它排好序的昵称列表，供界面做「也可以搜：牛头 / 老牛」这类提示。 */
export function championSearchHints(champion: { name: string; alias: string }): string[] {
  return [...championNicknames(champion.alias)];
}
