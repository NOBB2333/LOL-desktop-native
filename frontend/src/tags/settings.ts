/**
 * 逐标签开关。
 *
 * 对齐 LeagueAkari 的 `OngoingGamePanelPlayerCardTagSettings`：
 * 每个标签都能被单独关闭，定义内部通过 `ctx.settings.showXxxTag` 判断，
 * 而不是在渲染层做统一过滤。
 */
export interface PlayerTagSettings {
  showSelfTag: boolean;
  showTaggedTag: boolean;
  showPremadeTag: boolean;
  showHighWinRateTag: boolean;
  showMetTag: boolean;
  showStreakTag: boolean;
  showGreatPerformanceTag: boolean;
  showEasyGankTag: boolean;
  showSoloKillsTag: boolean;
  showDamageShareTag: boolean;
  showCsPerMinuteTag: boolean;
  showVisionScoreTag: boolean;
  showDeathsTag: boolean;
  showParticipationTag: boolean;
  showPoolConcentrationTag: boolean;
  showScoreTag: boolean;
}

export const defaultPlayerTagSettings: PlayerTagSettings = {
  showSelfTag: true,
  showTaggedTag: true,
  showPremadeTag: true,
  showHighWinRateTag: true,
  showMetTag: true,
  showStreakTag: true,
  showGreatPerformanceTag: true,
  showEasyGankTag: true,
  showSoloKillsTag: true,
  showDamageShareTag: true,
  showCsPerMinuteTag: true,
  showVisionScoreTag: true,
  showDeathsTag: true,
  showParticipationTag: true,
  showPoolConcentrationTag: true,
  showScoreTag: true,
};

/**
 * 设置页展示用的元数据；顺序与 registry 中的展示顺序一致。
 * `label` 尽量沿用 LeagueAkari 设置项的原文（`settings.playerCardTags.tags.*`），
 * `description` 用本项目自己的话解释判定口径。
 */
export interface PlayerTagSettingMeta {
  key: keyof PlayerTagSettings;
  label: string;
  description: string;
}

export const playerTagSettingItems: PlayerTagSettingMeta[] = [
  { key: "showSelfTag", label: "自己标记", description: "在自己身上显示「自己」标识" },
  { key: "showTaggedTag", label: "已标记的玩家", description: "显示自己为该玩家写的备注，可点击编辑" },
  { key: "showPremadeTag", label: "预组队文本", description: "按分组标注检测到的预组队玩家，同组同色" },
  { key: "showHighWinRateTag", label: "超高胜率标记", description: "样本 ≥ 16 场且胜率 ≥ 85% 时高亮" },
  { key: "showMetTag", label: "遇到过的玩家", description: "标注近期共同对局，悬停展开逐局对照表" },
  { key: "showStreakTag", label: "连胜 / 连败场次", description: "连续 3 场以上同结果时高亮" },
  { key: "showGreatPerformanceTag", label: "优异标记", description: "综合评分达到「优异 / 通天代」时高亮" },
  { key: "showEasyGankTag", label: "好抓 / 难抓标记", description: "按 15 分钟前被敌方打野参与击杀次数评估" },
  { key: "showSoloKillsTag", label: "场均单杀次数", description: "有精确数据时展示场均单杀次数" },
  { key: "showDamageShareTag", label: "场均队伍伤害", description: "场均团队伤害占比达核心水平时高亮" },
  { key: "showCsPerMinuteTag", label: "分均补兵", description: "分均补刀达到高水平时高亮" },
  { key: "showVisionScoreTag", label: "场均视野得分", description: "场均视野得分偏高或偏低时高亮" },
  { key: "showDeathsTag", label: "阵亡倾向", description: "场均阵亡明显偏高或偏低时高亮" },
  { key: "showParticipationTag", label: "参团率", description: "场均参团率明显偏高或偏低时高亮" },
  { key: "showPoolConcentrationTag", label: "英雄池集中", description: "单一英雄占近期样本一半以上时提示" },
  { key: "showScoreTag", label: "综合评分", description: "显示综合对局评分数值" },
];

/** 容错归一化：老配置缺字段时按默认值补齐。 */
export function normalizePlayerTagSettings(input: Partial<PlayerTagSettings> | undefined | null): PlayerTagSettings {
  const source = input ?? {};
  const output = { ...defaultPlayerTagSettings };
  for (const key of Object.keys(defaultPlayerTagSettings) as (keyof PlayerTagSettings)[]) {
    if (typeof source[key] === "boolean") output[key] = source[key] as boolean;
  }
  return output;
}
