/**
 * 录制帧里的十人 ↔ 座位（`participantId`）的配对。
 *
 * ## 为什么需要单独一份规则
 *
 * 用户的报障是「拖动时间轴，人的战绩/装备**完全不变化**」。根因不在取数，而在配对：
 * 原来按 `puuid` 比（`entry.puuid === player.puuid`），但 Live Client Data 的
 * `allPlayers` **压根没有 `puuid` 字段**（官方 endpoint 文档里该结构的字段集是
 * `championName / isBot / isDead / items / level / position / rawChampionName /
 * respawnTimer / runes / scores / skinID / summonerName / summonerSpells / team`）。
 *
 * 实测落盘帧里 `"puuid": ""` 是**恒定**的，于是配对 100% 失败 → 静默退回终局值
 * → 表现就是「战绩和装备不动」。这个 bug 特别隐蔽，因为**数据全是对的**，
 * 只有配对是死的，而失败路径又恰好长得和「这一局没录到」一样。
 *
 * ## 配对优先级
 *
 * 1. **`rid`（`名字#编号`）**：录制帧里的 `rid` 就是 Live Client 的 `riotId`，
 *    而这正是 LCU 侧认定的身份键，也是**唯一**在录制里稳定存在的标识。
 *    用它还能区分「同队同英雄」的两个人（镜像对局）。
 * 2. **绝对阵营 + `championId`**：bot 的 rid 是 `Khazix#BOT` 这类合成名、
 *    真人也可能因为改名/特殊字符对不上，这时退回「同阵营 + 同英雄」；
 *    若该阵营里没有同英雄的人，就退到该阵营**任意未被认领**的人。
 * 3. 都配不上 → `null`，界面按「这一帧没有这个人」降级（退回终局值），不猜。
 *
 * 认领制（`claimed`）解决的是「同队同英雄时两个座位指向同一个人」：
 * 配上就从池子里标记掉，后来者拿下一个。
 *
 * ## 注意：录制帧可能只有 5 个人
 *
 * 实测训练模式/自定义局里 `allPlayers` 只回**我方 5 人**（外加 bot），不是十人。
 * 所以配对**不能假设帧里一定凑得齐十个人**——帧里缺人是正常情况，不是异常。
 */
import type { GameRecordingFrame, GameRecordingPlayer, MatchParticipant } from "../types/domain";
import { TEAM_BLUE, TEAM_RED, teamOf } from "./lineup";

/** `名字#编号` 归一化：Live Client 大小写/首尾空白不稳，统一成小写去空白再比。 */
export function normalizeRiotId(value: string | undefined | null): string {
  return (value ?? "").trim().toLowerCase();
}

/**
 * 取 `名字#编号` 里的**名字部分**。
 *
 * 为什么需要：十人详情（`MatchParticipant`）只有 `gameName`，**没有 tagLine**，
 * 而录制帧的 `rid` 是完整的 `名字#编号`。所以直接比两个串永远不等——
 * 得允许「只比名字部分」这一档，否则这个修复等于没做。
 * 名字部分也不可靠（可重名），所以它排在精确 rid 之后、且仍限定在同一阵营内。
 */
export function namePartOf(value: string | undefined | null): string {
  const normalized = normalizeRiotId(value);
  const hash = normalized.indexOf("#");
  return hash > 0 ? normalized.slice(0, hash) : normalized;
}

/** 由 `gameName` + `tagLine` 拼出与录制帧 `rid` 同形的字符串。 */
export function riotIdOf(gameName: string | undefined | null, tagLine: string | undefined | null): string {
  const name = (gameName ?? "").trim();
  const tag = (tagLine ?? "").trim();
  if (!name) return "";
  return tag ? `${name}#${tag}` : name;
}

/** 录制帧的 `team` 字符串 → 绝对阵营码（100/200）；认不出为 0。 */
export function frameTeamCode(team: string | undefined): number {
  return team === "ORDER" ? TEAM_BLUE : team === "CHAOS" ? TEAM_RED : 0;
}

export interface RecordedSeatLookup {
  /** 归一化 rid → 候选人（同一 rid 理论上只有一个，留数组防止脏数据）。 */
  byRid: Map<string, GameRecordingPlayer[]>;
  /** 归一化**名字部分**（`#` 之前）→ 候选人；详情只有 `gameName` 时靠这一档。 */
  byName: Map<string, GameRecordingPlayer[]>;
  /** 绝对阵营（100/200）→ 该阵营在录制帧里的候选人，按帧内顺序。 */
  byTeam: Map<number, GameRecordingPlayer[]>;
  /** 已经被认领的候选人，防止同队同英雄时两个座位吃到同一个人。 */
  claimed: Set<GameRecordingPlayer>;
}

function push<K>(map: Map<K, GameRecordingPlayer[]>, key: K, value: GameRecordingPlayer): void {
  const bucket = map.get(key);
  if (bucket) bucket.push(value);
  else map.set(key, [value]);
}

export function buildRecordedSeatLookup(frame: GameRecordingFrame | null): RecordedSeatLookup {
  const byRid = new Map<string, GameRecordingPlayer[]>();
  const byName = new Map<string, GameRecordingPlayer[]>();
  const byTeam = new Map<number, GameRecordingPlayer[]>();
  for (const player of frame?.players ?? []) {
    const rid = normalizeRiotId(player.rid);
    if (rid) push(byRid, rid, player);
    const name = namePartOf(player.rid);
    if (name) push(byName, name, player);
    const team = frameTeamCode(player.team);
    if (team) push(byTeam, team, player);
  }
  return { byRid, byName, byTeam, claimed: new Set() };
}

/** 取一个未被认领的候选人；全被认领了就退第一个（宁可重复也不要整块空掉）。 */
function takeUnclaimed(
  candidates: readonly GameRecordingPlayer[] | undefined,
  claimed: Set<GameRecordingPlayer>,
): GameRecordingPlayer | null {
  if (!candidates?.length) return null;
  return candidates.find((candidate) => !claimed.has(candidate)) ?? candidates[0];
}

/** 座位在十人详情里的身份；详情缺这个座位时为 null。 */
export type SeatIdentity = Pick<MatchParticipant, "team" | "championId" | "gameName"> & { tagLine?: string };

/** 候选池限定到该阵营；阵营未知时不筛（宁可多配也别全空）。 */
function inTeam(
  lookup: RecordedSeatLookup,
  candidates: readonly GameRecordingPlayer[] | undefined,
  team: number,
): readonly GameRecordingPlayer[] | undefined {
  if (!candidates) return undefined;
  if (!team) return candidates;
  const bucket = lookup.byTeam.get(team);
  if (!bucket?.length) return candidates;
  return candidates.filter((candidate) => bucket.includes(candidate));
}

/**
 * 座位 → 录制帧里的那个人。
 *
 * `seatTeam` 必须是**绝对阵营**（100/200），与时间线座位同源。
 */
export function recordedPlayerForSeat(
  seatTeam: number,
  _participantId: number,
  identity: SeatIdentity | null,
  lookup: RecordedSeatLookup,
): GameRecordingPlayer | null {
  if (!identity) return null;
  const teamPlayers = lookup.byTeam.get(seatTeam);
  const championId = identity.championId;

  /** 英雄对得上（或任一方不知道英雄）才算命中，避免张冠李戴。 */
  const championAgrees = (candidate: GameRecordingPlayer) =>
    championId <= 0 || candidate.cid <= 0 || candidate.cid === championId;

  // 1) 完整 rid 精确匹配（最可靠，还能区分同队同英雄）。
  const rid = normalizeRiotId(identity.tagLine ? riotIdOf(identity.gameName, identity.tagLine) : identity.gameName);
  const ridHit = takeUnclaimed(inTeam(lookup, lookup.byRid.get(rid), seatTeam), lookup.claimed);
  if (ridHit && championAgrees(ridHit)) {
    lookup.claimed.add(ridHit);
    return ridHit;
  }

  // 2) 只比名字部分（详情只有 gameName、没有 tagLine，这一档是**主路径**）。
  const name = namePartOf(identity.gameName);
  if (name) {
    const nameHit = takeUnclaimed(inTeam(lookup, lookup.byName.get(name), seatTeam), lookup.claimed);
    if (nameHit && championAgrees(nameHit)) {
      lookup.claimed.add(nameHit);
      return nameHit;
    }
  }

  // 3) 同阵营 + 同英雄；该阵营没有同英雄的人时退到该阵营任意未被认领的人。
  const sameChampion = championId > 0 ? teamPlayers?.filter((candidate) => candidate.cid === championId) : undefined;
  const hit = takeUnclaimed(sameChampion?.length ? sameChampion : teamPlayers, lookup.claimed);
  if (hit) lookup.claimed.add(hit);
  return hit;
}

/** 十人详情里这名玩家的绝对阵营（老缓存缺字段时按历史口径退回蓝方）。 */
export function seatTeamOf(player: MatchParticipant | null): number {
  if (!player) return 0;
  return teamOf(player) ?? (player.side !== "enemy" ? TEAM_BLUE : TEAM_RED);
}

/**
 * 某个时刻对应的那一帧录制：取 `t <= seconds` 的**最后一帧**。
 *
 * 录制帧是「一个瞬间的快照」：两次采样之间他有没有换装备、有没有死，数据里没有，
 * 所以只能给最近一帧，**绝不插值**（插值会造出一件并不存在的装备、或一个假的死亡区间）。
 * 游标还没到第一帧时才退回第一帧——比返回 null、让十个人一起变空要好。
 * 帧按 `t` 升序（后端追加写入），顺序扫一遍就能停。
 */
export function recordedFrameAt(
  frames: readonly GameRecordingFrame[] | null | undefined,
  seconds: number,
): GameRecordingFrame | null {
  if (!frames?.length) return null;
  let candidate: GameRecordingFrame | null = null;
  for (const frame of frames) {
    if (frame.t > seconds) break;
    candidate = frame;
  }
  return candidate ?? frames[0];
}
