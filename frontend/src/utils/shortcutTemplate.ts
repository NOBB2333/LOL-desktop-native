export interface ShortcutTemplateField {
  key: string;
  label: string;
  description: string;
  example: string;
}

export const shortcutTemplateFields: ShortcutTemplateField[] = [
  { key: "name", label: "玩家名", description: "Riot ID 中 # 前的名称", example: "峡谷侦察员" },
  { key: "tag", label: "首要标签", description: "当前命中的第一条分析标签", example: "状态火热" },
  { key: "position", label: "位置", description: "本局分路；未知时使用近期主要位置", example: "中路" },
  { key: "rank", label: "段位", description: "单双排段位和小段", example: "翡翠 II" },
  { key: "lp", label: "胜点", description: "当前单双排胜点，仅输出数字", example: "63" },
  { key: "score", label: "评分", description: "近期表现综合评分，满分 100", example: "82" },
  { key: "recent_wins", label: "近期胜场", description: "当前近期样本中的胜场数", example: "7" },
  { key: "recent_losses", label: "近期负场", description: "当前近期样本中的负场数", example: "3" },
  { key: "recent_win_rate", label: "近期胜率", description: "当前近期样本的胜率", example: "70%" },
  { key: "recent_games", label: "逐场战绩", description: "按设置数量输出每场胜负、英雄和 KDA", example: "近5场：胜 九尾妖狐 8/2/7；负 发条魔灵 3/5/6" },
  { key: "streak", label: "近期状态", description: "根据近期连续胜负生成的状态", example: "连胜 3 场" },
  { key: "kda", label: "平均 KDA", description: "近期有效对局的平均 KDA", example: "4.21" },
  { key: "current_champion", label: "当前英雄", description: "本局已选择或正在亮出的英雄", example: "九尾妖狐" },
  { key: "champion_games", label: "英雄场次", description: "近期样本中当前英雄的场次", example: "6" },
  { key: "champion_win_rate", label: "英雄胜率", description: "近期样本中当前英雄的胜率", example: "67%" },
  { key: "top_champions", label: "常用英雄", description: "近期常用英雄及各自胜率", example: "九尾妖狐 61%、发条魔灵 58%" },
  { key: "premade", label: "组队关系", description: "本地记录识别出的同队玩家", example: "打野玩家、辅助玩家" },
  { key: "risk", label: "风险标签", description: "当前玩家全部分析标签", example: "状态火热、英雄池集中" },
  { key: "jungle_preference", label: "打野偏好", description: "当前英雄的打野路线和行为分析", example: "偏好红开，3级常抓中路" },
  { key: "team", label: "队伍", description: "该玩家在当前分析中的队伍", example: "敌方" },
  { key: "horse", label: "等马评估", description: "按近期有效对局的评分、胜率和 KDA 评为上等马、中等马或下等马；不足 3 场时保持中等马", example: "上等马" },
  { key: "encounter", label: "遇到记录", description: "发送当前对局中遇到过的玩家，并对照双方 Riot ID、英雄、KDA 和胜负；由本地一年记录生成", example: "遇到过：09月06日 21:35，我（松间照#0721）使用 九尾妖狐 8/2/7 胜；对方（狐狸收藏家#MID）使用 盲僧 3/5/6 负" },
];

const examples = new Map(shortcutTemplateFields.map((field) => [field.key, field.example]));

export function renderShortcutTemplateExample(template: string) {
  const rendered = template.replace(/\{([^{}]+)\}/g, (placeholder, key: string) => examples.get(key) ?? placeholder);
  return rendered.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
}
