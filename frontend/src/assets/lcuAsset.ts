/**
 * LCU 资源路径 → 能直接塞进 `<img src>` 的地址。
 *
 * 领取奖励那类图标**只有一条 LCU 资源路径**（`/lol-game-data/assets/v1/...`），
 * 没有 `(kind, id)` 这种编号，所以走不了 `AssetIcon`。浏览器预览里既没有原生宿主
 * 也连不上 LCU，就按 LeagueAkari 的规则把路径直接映射到 CommunityDragon——不然这块
 * 在预览里永远是占位块。
 */

const LCU_ASSET_PREFIX = "/lol-game-data/assets/";

/** 对齐 AK 的 `CDRAGON_DEFAULT_ASSET_BASE`。 */
const CDRAGON_ASSET_BASE = "https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/default";

/**
 * 是不是一条 LCU 游戏资源路径。
 *
 * 前缀之后必须还有内容——`/lol-game-data/assets/` 本身不是资源。这条判断和后端
 * `assets_ipc.zig` 的 `isLcuAssetPath` 是同一口径，别只改一边。
 */
export function isLcuAssetPath(path: string | null | undefined): boolean {
  return typeof path === "string" && path.startsWith(LCU_ASSET_PREFIX) && path.length > LCU_ASSET_PREFIX.length;
}

/**
 * 映射到 CommunityDragon 上的同名资源。
 *
 * 规则抄 AK 的 `resolveCommunityDragonAssetUrl`：前缀之后的相对路径**整条转小写**
 * 再拼到默认资产根后面（CommunityDragon 的目录全是小写的），查询串和 hash 丢掉。
 * 不是 LCU 路径就返回 `null`，让调用方决定怎么退化。
 */
export function lcuAssetToCommunityDragon(path: string | null | undefined): string | null {
  if (!path || !isLcuAssetPath(path)) return null;
  const relative = path.slice(LCU_ASSET_PREFIX.length).split(/[?#]/, 1)[0];
  if (!relative) return null;
  return `${CDRAGON_ASSET_BASE}/${relative.toLowerCase()}`;
}
