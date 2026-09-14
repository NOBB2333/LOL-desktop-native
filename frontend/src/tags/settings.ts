/**
 * 逐标签开关。
 *
 * 与 LeagueAkari 的 `OngoingGamePanelPlayerCardTagSettings`
 * （`src/shared/shards/ongoing-game/settings.ts`）**逐字段、逐默认值**对齐：
 *
 * - 字段名与 AK 完全一致（`showWinningStreakTag` / `showLosingStreakTag` 是
 *   两个独立开关，不要合并成 `showStreakTag`；AK 里没有 `showPremadeTag`，
 *   只有 `showPremadeTeamTag`）。
 * - 默认值也照抄 AK：连胜连败、好抓难抓、单杀、优异表现、预组队、自己、
 *   遇到过、已标记、极高胜率、隐私、可疑闪现位置**默认开**；
 *   场均类指标里只有「击杀伤害转化」默认开，其余场均指标**默认关**。
 *   这是 AK 自己的取向——场均数字属于细节，需要的人再去打开，
 *   避免每张卡片都糊上一排数字。
 *
 * 定义内部通过 `ctx.settings.showXxxTag` 自行判断，不在渲染层统一过滤。
 */
export interface PlayerTagSettings {
  showSelfTag: boolean;
  showTaggedTag: boolean;
  showPremadeTeamTag: boolean;
  showWinRateTeamTag: boolean;
  showMetTag: boolean;
  showPrivacyTag: boolean;
  showWinningStreakTag: boolean;
  showLosingStreakTag: boolean;
  showGreatPerformanceTag: boolean;
  showSuspiciousFlashPositionTag: boolean;
  showEasyGankTag: boolean;
  showSoloKillsTag: boolean;
  showAverageTeamDamageTag: boolean;
  showAverageTeamDamageTakenTag: boolean;
  showAverageTeamGoldTag: boolean;
  showAverageCsPerMinuteTag: boolean;
  showAverageDamageGoldEfficiencyTag: boolean;
  showAverageEnemyMissingPingsTag: boolean;
  showAverageVisionScoreTag: boolean;
  showAverageKillDamageEfficiencyTag: boolean;
  showAkariScoreTag: boolean;
}

/** 与 AK 的 `DEFAULT_ONGOING_GAME_PANEL_PLAYER_CARD_TAG_SETTINGS` 一一对应。 */
export const defaultPlayerTagSettings: PlayerTagSettings = {
  showSelfTag: true,
  showTaggedTag: true,
  showPremadeTeamTag: true,
  showWinRateTeamTag: true,
  showMetTag: true,
  showPrivacyTag: true,
  showWinningStreakTag: true,
  showLosingStreakTag: true,
  showGreatPerformanceTag: true,
  showSuspiciousFlashPositionTag: true,
  showEasyGankTag: true,
  showSoloKillsTag: true,
  showAverageTeamDamageTag: false,
  showAverageTeamDamageTakenTag: false,
  showAverageTeamGoldTag: false,
  showAverageCsPerMinuteTag: false,
  showAverageDamageGoldEfficiencyTag: false,
  showAverageEnemyMissingPingsTag: false,
  showAverageVisionScoreTag: false,
  showAverageKillDamageEfficiencyTag: true,
  showAkariScoreTag: false,
};

/**
 * 设置页展示用的元数据；顺序与 `registry.ts` 的展示顺序一致。
 *
 * `label` 沿用 LeagueAkari 设置项的中文措辞，`description` 用本项目自己的话
 * 解释判定口径——两边都改文案时以 AK 的口径为准。
 */
export interface PlayerTagSettingMeta {
  key: keyof PlayerTagSettings;
  label: string;
  description: string;
}

export const playerTagSettingItems: PlayerTagSettingMeta[] = [
  { key: "showSelfTag", label: "自己标记", description: "在自己身上显示「自己」标识" },
  { key: "showTaggedTag", label: "已标记的玩家", description: "显示自己为该玩家写的标记，可点击编辑" },
  { key: "showPremadeTeamTag", label: "预组队文本", description: "按分组标注检测到的预组队玩家，同组同色" },
  { key: "showWinRateTeamTag", label: "极高胜率标记", description: "样本 ≥ 16 场且胜率 ≥ 85% 时高亮" },
  { key: "showMetTag", label: "遇到过的玩家", description: "标注近期共同对局，悬停展开逐局对照表" },
  { key: "showPrivacyTag", label: "战绩隐藏", description: "该玩家在客户端中把战绩设为私密时提示" },
  { key: "showWinningStreakTag", label: "连胜场次", description: "连续 3 场以上胜利时高亮" },
  { key: "showLosingStreakTag", label: "连败场次", description: "连续 3 场以上失败时高亮" },
  { key: "showGreatPerformanceTag", label: "优异标记", description: "Akari 评分达到「优异 / 通天代」时高亮" },
  { key: "showSuspiciousFlashPositionTag", label: "可疑闪现位置", description: "闪现一会儿放 D 一会儿放 F 时提示，悬停看分布" },
  { key: "showEasyGankTag", label: "好抓 / 难抓标记", description: "按 15 分钟前被敌方打野参与击杀次数评估" },
  { key: "showSoloKillsTag", label: "场均单杀次数", description: "有精确数据时展示场均单杀次数" },
  { key: "showAverageTeamDamageTag", label: "场均队伍伤害", description: "展示场均队伍伤害占比" },
  { key: "showAverageTeamDamageTakenTag", label: "场均队伍承伤", description: "展示场均队伍承伤占比" },
  { key: "showAverageTeamGoldTag", label: "场均队伍经济", description: "展示场均队伍经济占比" },
  { key: "showAverageCsPerMinuteTag", label: "场均分均补兵", description: "展示场均分均补兵与队伍补刀占比" },
  { key: "showAverageDamageGoldEfficiencyTag", label: "场均伤害经济转化", description: "每点经济打出多少伤害，越高越高效" },
  { key: "showAverageEnemyMissingPingsTag", label: "场均敌方消失信号", description: "场均发出多少次「敌人消失」信号" },
  { key: "showAverageVisionScoreTag", label: "场均视野得分", description: "展示场均视野得分" },
  { key: "showAverageKillDamageEfficiencyTag", label: "击杀伤害转化", description: "击杀份额与伤害份额的比值，明显偏离 1 时提示" },
  { key: "showAkariScoreTag", label: "Akari 评分", description: "显示 Akari 综合评分数值（满分 17）" },
];

/** 容错归一化：老配置缺字段按默认值补齐，多余的旧字段直接丢弃。 */
export function normalizePlayerTagSettings(input: Partial<PlayerTagSettings> | undefined | null): PlayerTagSettings {
  const source = input ?? {};
  const output = { ...defaultPlayerTagSettings };
  for (const key of Object.keys(defaultPlayerTagSettings) as (keyof PlayerTagSettings)[]) {
    if (typeof source[key] === "boolean") output[key] = source[key] as boolean;
  }
  return output;
}
