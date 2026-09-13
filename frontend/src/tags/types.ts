import type { Component } from "vue";
import type { EncounterRecord, PlayerProfile } from "../types/domain";
import type { PlayerTagFacts } from "./facts";
import type { PlayerTagSettings } from "./settings";

/**
 * 标签渲染上下文。
 *
 * 对齐 LeagueAkari 的 `PlayerCardTagContext`：标签定义只依赖这份上下文，
 * 不再依赖组件内部状态，因此每个标签都可以独立推导、独立测试。
 */
export interface PlayerTagContext {
  /** 当前卡片对应的玩家。 */
  player: PlayerProfile;
  /** 本地玩家（自己）的 puuid，用于 `self` 标签与「上局队友/上局对手」判定。 */
  selfPuuid: string | null;
  /** 本地玩家的画像，`met` 需要比对双方最近一局是否同一场。 */
  selfPlayer: PlayerProfile | null;
  /** 逐标签开关。 */
  settings: PlayerTagSettings;
  /**
   * 已算好的样本事实（胜率、场均阵亡、连胜…）。
   * 由上下文构造时推导一次，所有标签共享，避免各自重复遍历样本。
   */
  facts: PlayerTagFacts;
  /** 共同对局记录（由 useEncounters 提供，可能仍在加载）。 */
  encounterRecords: EncounterRecord[];
  encounterLoading: boolean;
  encounterError: boolean;
  /** 当前对局 id，用于把本局从共同对局里排除。 */
  currentGameId: number;
  /** 开黑分组序号（同组同色），未检测到组队时为 undefined。 */
  premadeTone?: number;
  /** 本地玩家为该玩家写的备注。 */
  playerNotes: string[];
  /** 备注是否可以被编辑（自己不能给自己写备注）。 */
  canEditNotes: boolean;
  /** 打开备注编辑面板。 */
  onEditNotes?: () => void;
  /** 打开某一局的整局详情。 */
  openEncounterGame: (records: EncounterRecord[]) => void;
  /** 重新拉取共同对局。 */
  retryEncounters: () => void;
}

/** 标签悬浮层描述，字段语义与 LeagueAkari 的 `PlayerCardTagPopover` 一致。 */
export interface PlayerTagPopover {
  content: Component;
  delay?: number;
  keepAliveOnHover?: boolean;
  scrollable?: boolean;
  maxHeight?: number;
}

/** 单个标签的渲染结果。`label` 必须是一个组件，便于统一交给 `<component :is>` 渲染。 */
export interface PlayerTagRenderResult {
  label: Component;
  popover?: PlayerTagPopover;
}

/** 标签定义：注册表里的一条。 */
export interface PlayerTagDefinition {
  id: string;
  render: (ctx: PlayerTagContext) => PlayerTagRenderResult | null;
}

/** 注册表求值后的结果，带上 id 供渲染 key 使用。 */
export interface PlayerTagView extends PlayerTagRenderResult {
  id: string;
}
