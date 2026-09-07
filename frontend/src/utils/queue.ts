const knownQueueLabels = new Map<number, string>([
  [0, "自定义房间"],
  [2, "召唤师峡谷匹配"], [14, "召唤师峡谷匹配"], [31, "召唤师峡谷匹配"],
  [32, "召唤师峡谷匹配"], [33, "召唤师峡谷匹配"], [41, "召唤师峡谷匹配"],
  [42, "召唤师峡谷匹配"], [52, "召唤师峡谷匹配"], [400, "召唤师峡谷匹配"],
  [410, "召唤师峡谷匹配"], [430, "召唤师峡谷匹配"],
  [4, "单双排"], [6, "单双排"], [420, "单双排"],
  [440, "灵活排位"],
  [65, "极地大乱斗"], [67, "极地大乱斗"], [70, "极地大乱斗"],
  [72, "极地大乱斗"], [450, "极地大乱斗"],
  [490, "快速模式"], [700, "冠军杯赛"], [7000, "冠军杯赛"],
  [830, "入门人机"], [840, "新手人机"], [850, "一般人机"],
  [900, "无限火力"], [1900, "无限火力"], [1020, "克隆大作战"],
  [1300, "极限闪击"], [1400, "终极魔典"],
  [1700, "斗魂竞技场"], [1710, "斗魂竞技场"],
  [1810, "无尽狂潮"], [1820, "无尽狂潮"], [1830, "无尽狂潮"], [1840, "无尽狂潮"],
  [2000, "新手教程"], [2010, "新手教程"], [2020, "新手教程"],
  [3000, "魄罗王大乱斗"], [3140, "多人训练模式"], [4310, "经典模式"],
]);

export function queueLabel(queueId: number, fallback?: string | null) {
  const raw = fallback?.trim() ?? "";
  const mode = raw.replace(/^LCU 模式\s*/i, "").toUpperCase();
  const modeLabels: Record<string, string> = {
    CLASS: "召唤师峡谷", CLASSIC: "召唤师峡谷", CLASSIC_SR: "召唤师峡谷",
    CLASSIC_5V5: "召唤师峡谷", SUMMONERS_RIFT: "召唤师峡谷",
    SUMMONERSRIFT: "召唤师峡谷", "LEAGUE OF LEGENDS": "召唤师峡谷",
    ARAM: "极地大乱斗", KIWI: "海克斯大乱斗", CHERRY: "斗魂竞技场", PRACTICETOOL: "训练模式",
    URF: "无限火力", ONEFORALL: "克隆大作战", SWARM: "无尽狂潮",
    STRAWBERRY: "无尽狂潮",
  };
  if (queueId === 0 && modeLabels[mode]) return modeLabels[mode];
  if (mode === "KIWI") return modeLabels.KIWI;
  const known = knownQueueLabels.get(queueId);
  if (known) return known;
  return (modeLabels[mode] ?? raw) || (queueId > 0 ? `队列 ${queueId}` : "未知模式");
}
