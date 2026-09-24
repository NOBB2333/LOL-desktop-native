<script setup lang="ts">
import { Eye, History, RefreshCw, RotateCcw, Search, Trash2, UserRound } from "@lucide/vue";
import { NButton, NCheckbox, NInput, NPopconfirm, useMessage } from "naive-ui";
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import AssetIcon from "../components/AssetIcon.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend, isTauri } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { DeletedFriendRecord, FriendRecord, FriendToolsSnapshot, SpectateResult } from "../types/domain";
import { profileIconId, profileIconImage, relativeTime, shortDate } from "../utils/format";

const app = useAppStore();
const message = useMessage();
const data = ref<FriendToolsSnapshot>({ groups: [], friends: [] });
const loading = ref(false);
const deleting = ref(false);
const spectating = ref<string | null>(null);
const spectateQuery = ref("");
const spectatingById = ref(false);
const search = ref("");
const selected = ref<string[]>([]);
/** 回收站（被删好友的本地存档）。删之前后端会把记录抄一份到本地库，这里读的就是它。 */
const deleted = ref<DeletedFriendRecord[]>([]);
const binLoading = ref(false);
const restoring = ref<string | null>(null);
let loadGeneration = 0;
let friendEventTimer: ReturnType<typeof setTimeout> | null = null;
let stopLcuEventListener: (() => void) | null = null;

const availabilityLabel: Record<string, string> = { chat: "在线", online: "在线", dnd: "游戏中", away: "离开", mobile: "手机在线", spectating: "观战", offline: "离线" };
const groupName = (name: string) => name === "**Default" ? "综合" : name;
const groupById = computed(() => new Map(data.value.groups.map((group) => [group.id, group])));
const visibleFriends = computed(() => {
  const query = search.value.trim().toLocaleLowerCase();
  return data.value.friends
    .filter((friend) => !query || `${friend.gameName}#${friend.gameTag}`.toLocaleLowerCase().includes(query))
    .sort((left, right) => {
      const groupOrder = (groupById.value.get(right.groupId)?.priority ?? 0) - (groupById.value.get(left.groupId)?.priority ?? 0);
      if (groupOrder) return groupOrder;
      return (Date.parse(left.friendsSince ?? "") || Number.MAX_SAFE_INTEGER) - (Date.parse(right.friendsSince ?? "") || Number.MAX_SAFE_INTEGER);
    });
});
const groupedFriends = computed(() => {
  const groups = new Map<number, FriendRecord[]>();
  for (const friend of visibleFriends.value) groups.set(friend.groupId, [...(groups.get(friend.groupId) ?? []), friend]);
  return [...groups.entries()].map(([id, friends]) => ({ id, name: groupName(groupById.value.get(id)?.name ?? "其他"), friends }));
});
const selectedCount = computed(() => selected.value.length);
/** 现在真的能观战的好友有几位的依据是后端的 `canSpectate`，不是我们自己猜 `availability`。 */
const spectatableCount = computed(() => data.value.friends.filter((friend) => friend.canSpectate).length);
/** 观战必须走 LCU，所以「原生宿主 + 客户端在线」两个条件缺一不可（与刷新按钮同一口径）。 */
const spectateUnavailable = computed(() => app.mode === "live" && app.connection.status !== "connected");
const allVisibleSelected = computed(() => visibleFriends.value.length > 0 && visibleFriends.value.every((friend) => selected.value.includes(friend.id)));

function updateSelection(id: string, checked: boolean) {
  selected.value = checked ? [...new Set([...selected.value, id])] : selected.value.filter((value) => value !== id);
}

/** 全选只作用于**当前筛选出来**的好友，否则搜索时「全选」会静默勾上看不见的人。 */
function toggleAllVisible(checked: boolean) {
  const visible = visibleFriends.value.map((friend) => friend.id);
  selected.value = checked ? [...new Set([...selected.value, ...visible])] : selected.value.filter((id) => !visible.includes(id));
}

function nameOf(id: string) {
  return data.value.friends.find((friend) => friend.id === id)?.gameName ?? id;
}

async function loadLastGames(generation: number, force: boolean) {
  for (const friend of data.value.friends) {
    if (generation !== loadGeneration) return;
    try {
      const result = await backend.friendLastGame(friend.puuid, force);
      const current = data.value.friends.find((item) => item.puuid === result.puuid);
      if (current) current.lastGameAt = result.lastGameAt;
    } catch {
      // A private profile or transient history failure only affects this row.
    }
  }
}

async function refresh(force = false) {
  const generation = ++loadGeneration;
  loading.value = true;
  try {
    data.value = await backend.friends();
    selected.value = [];
    if (force) message.success("好友列表已刷新");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    loading.value = false;
  }
  void loadLastGames(generation, force);
}

/**
 * 批量删除走的是后端的 `lol.delete_friends`：**一次请求**把整批 id 交出去，
 * 后端逐条删、逐条回报。原来是在前端一条一条串行调用，于是不得不配一个
 * 「取消剩余删除」按钮；现在只有一个往返，取消已经没有意义，就没再保留。
 * 单条失败不影响其余，失败原因直接列给用户。
 */
async function deleteSelected() {
  if (!selectedCount.value || deleting.value) return;
  deleting.value = true;
  try {
    const outcome = await backend.deleteFriends(selected.value);
    const removed = new Set(outcome.results.filter((entry) => entry.ok).map((entry) => entry.id));
    data.value.friends = data.value.friends.filter((friend) => !removed.has(friend.id));
    selected.value = selected.value.filter((id) => !removed.has(id));
    const failures = outcome.results.filter((entry) => !entry.ok);
    if (failures.length) {
      const names = failures.slice(0, 3).map((entry) => nameOf(entry.id)).join("、");
      message.warning(`已删除 ${outcome.deleted} 位，${failures.length} 位没删掉：${names}`);
    } else {
      // 说清楚「还在回收站里」，否则删完会以为回不来了。
      message.success(`已删除 ${outcome.deleted} 位好友，记录留在页面底部的回收站里`);
    }
    void loadDeleted();
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    deleting.value = false;
  }
}

/** 读回收站。纯本地存档，客户端没开也能看。 */
async function loadDeleted() {
  binLoading.value = true;
  try {
    deleted.value = (await backend.deletedFriends()).friends;
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    binLoading.value = false;
  }
}

/**
 * 回收站里的两个动作。
 *
 * `addBack = true` 走的是**发好友申请**（客户端没有「直接把好友加回来」这种接口），
 * 所以成功不等于好友回来了，必须说清楚需要对方同意——这就是「后悔药」的真实边界。
 */
async function restore(record: DeletedFriendRecord, addBack: boolean) {
  if (restoring.value) return;
  restoring.value = record.id;
  try {
    const result = await backend.restoreFriend(record.id, addBack);
    if (result.ok) {
      deleted.value = deleted.value.filter((item) => item.id !== record.id);
      const who = `${result.gameName || record.gameName}#${result.gameTag || record.gameTag}`;
      message.success(result.added ? `已向 ${who} 发送好友申请，需要对方同意才能加回` : `已从回收站移除 ${who} 的记录`);
    } else {
      message.warning(result.reason || "没能完成这个操作");
    }
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    restoring.value = null;
  }
}

/**
 * 观战。
 *
 * 后端会先试**好友路线**（客户端临时下发的观战密钥，只有「在线且正在对局中」的
 * 好友才有），拿不到密钥就自动落到**观察者模式**——那条路不带密钥，所以
 * 不要求对方是好友。这里**不**把它当成一个必成功的动作：成功/失败都用后端的
 * `reason` 告诉用户，成功时顺带说明走的是哪条路线。
 */
async function spectate(friend: FriendRecord) {
  if (spectating.value) return;
  spectating.value = friend.puuid;
  try {
    const result = await backend.spectate(friend.puuid);
    if (result.ok) message.success(spectateSuccessText(friend.gameName, result.route));
    else message.warning(result.reason);
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    spectating.value = null;
  }
}

/**
 * 按「名字#标签」观战任意玩家。
 *
 * 与列表里的观战按钮共用同一条后端链路，区别只是多了一步「先在本大区把 Riot ID
 * 解析成 puuid」。本地没有跨区索引，所以只解析得到当前大区的玩家。
 */
async function spectateById() {
  const query = spectateQuery.value.trim();
  if (!query || spectatingById.value) return;
  spectatingById.value = true;
  try {
    const result = await backend.spectateById(query);
    if (result.ok) message.success(spectateSuccessText(gameNamePart(query), result.route));
    else message.warning(result.reason);
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    spectatingById.value = false;
  }
}

/** 只取 `名字#标签` 里的名字部分，用来拼提示文案。 */
function gameNamePart(query: string) {
  const index = query.indexOf("#");
  return (index >= 0 ? query.slice(0, index) : query).trim();
}

function spectateSuccessText(name: string, route?: SpectateResult["route"]) {
  return route === "observe" ? `正在用观察者模式启动观战：${name}` : `正在启动观战：${name}`;
}

onMounted(() => {
  void refresh();
  void loadDeleted();
  if (!isTauri()) return;
  const onLcuEvent = (rawEvent: Event) => {
    const uri = (rawEvent as CustomEvent<{ uri?: string }>).detail?.uri ?? "";
    if (!uri.startsWith("/lol-chat/v1/friend")) return;
    if (friendEventTimer) clearTimeout(friendEventTimer);
    friendEventTimer = setTimeout(() => {
      friendEventTimer = null;
      void refresh();
    }, 250);
  };
  window.addEventListener("lol-lcu-event", onLcuEvent);
  stopLcuEventListener = () => window.removeEventListener("lol-lcu-event", onLcuEvent);
});

onBeforeUnmount(() => {
  if (friendEventTimer) clearTimeout(friendEventTimer);
  stopLcuEventListener?.();
});
</script>

<template>
  <div class="page-shell friends-page">
    <PageHeader title="好友工具" eyebrow="FRIEND TOOLS" :meta="`${data.friends.length} 位好友 · ${data.groups.length} 个分组${spectatableCount ? ` · ${spectatableCount} 位可观战` : ''}`">
      <NButton size="small" secondary :loading="loading" :disabled="app.mode === 'live' && app.connection.status !== 'connected'" @click="refresh(true)"><template #icon><RefreshCw :size="14" /></template>刷新</NButton>
    </PageHeader>

    <section class="friends-toolbar">
      <div class="friends-toolbar-row">
        <NInput v-model:value="search" clearable size="small" placeholder="搜索好友名称或标签"><template #prefix><Search :size="14" /></template></NInput>
        <NPopconfirm :disabled="!selectedCount || deleting" positive-text="删除" negative-text="取消" @positive-click="deleteSelected">
          <template #trigger><NButton size="small" type="error" secondary :disabled="!selectedCount || deleting"><template #icon><Trash2 :size="14" /></template>{{ selectedCount ? `删除 (${selectedCount})` : "删除" }}</NButton></template>
          将从 League 客户端删除选中的好友。客户端侧不可撤销，但本地会留一份记录放进下方回收站，可以据此重新发好友申请。
        </NPopconfirm>
      </div>
    </section>

    <!--
      按 ID 观战。客户端里「观战」有两条路线：好友路线要 spectatorKey（只有对方
      在线且正在对局时才由客户端下发），观察者模式则**不带密钥**。所以观战不必
      被好友列表绑死——输入 Riot ID 就能看非好友。

      刻意从上面的工具栏里**拆出来**单独成块：它和下面的好友列表是两条平行入口
      ——一个是手动输入、谁都能看，一个是点列表行尾的按钮、只能看好友。混在同一行
      工具栏里分不出哪个管哪个。后端链路其实是同一条，区别只在多一步「先把
      Riot ID 解析成 puuid」。
    -->
    <section class="friends-spectate-any">
      <div class="friends-spectate-any__head">
        <span class="friends-spectate-any__icon"><Eye :size="14" /></span>
        <strong>观战任意玩家</strong>
        <span class="friends-spectate-any__tag">不是好友也能看</span>
      </div>
      <div class="friends-spectate-any__row">
        <NInput
          v-model:value="spectateQuery"
          clearable
          size="small"
          placeholder="名字#标签"
          :disabled="spectateUnavailable"
          @keyup.enter="spectateById"
        ><template #prefix><Eye :size="14" /></template></NInput>
        <NButton size="small" type="primary" secondary :loading="spectatingById" :disabled="!spectateQuery.trim() || spectatingById || spectateUnavailable" @click="spectateById">观战</NButton>
      </div>
      <p class="friends-spectate-any__hint">回车即可。需要对方正在对局中且允许被观战；本地只能解析当前大区的玩家。</p>
    </section>

    <section class="friends-table" :class="{ loading }">
      <div class="friends-list-label"><UserRound :size="13" /><strong>好友列表</strong><small>点行尾的「观战」直接看这位好友</small></div>
      <header>
        <span class="friends-select-all"><NCheckbox :checked="allVisibleSelected" :indeterminate="selectedCount > 0 && !allVisibleSelected" :aria-label="allVisibleSelected ? '取消全选' : '全选当前好友'" @update:checked="toggleAllVisible" /></span>
        <span>好友分组</span><span>状态</span><span>最后对局日期</span><span>成为好友时间</span><span>操作</span>
      </header>
      <template v-for="group in groupedFriends" :key="group.id">
        <div class="friend-group"><UserRound :size="14" /><strong>{{ group.name }}</strong><span>{{ group.friends.length }}</span></div>
        <article v-for="friend in group.friends" :key="friend.id" class="friend-row">
          <NCheckbox :checked="selected.includes(friend.id)" @update:checked="updateSelection(friend.id, $event)" />
          <div class="friend-identity"><AssetIcon kind="profile" :id="profileIconId(friend.icon)" :name="friend.gameName" :fallback-url="profileIconImage(friend.icon)" round size="sm" /><span><strong>{{ friend.gameName }}</strong><small>#{{ friend.gameTag || "--" }}</small></span></div>
          <span class="friend-presence" :data-state="friend.availability">{{ availabilityLabel[friend.availability] ?? friend.availability ?? "未知" }}</span>
          <time v-if="friend.lastGameAt" :datetime="friend.lastGameAt" :title="shortDate(friend.lastGameAt)"><strong>{{ shortDate(friend.lastGameAt) }}</strong><small>{{ relativeTime(friend.lastGameAt) }}</small></time><span v-else class="friend-empty">无对局数据</span>
          <time v-if="friend.friendsSince" :datetime="friend.friendsSince" :title="shortDate(friend.friendsSince)"><strong>{{ shortDate(friend.friendsSince) }}</strong><small>{{ relativeTime(friend.friendsSince) }}</small></time><span v-else class="friend-empty">未知</span>
          <!--
            列表里的按钮与上面「按 ID 观战」走的是同一套后端链路，所以**不**再用
            `canSpectate` 把它禁掉：没有密钥只代表拿不到好友路线的密钥，观察者模式
            仍然可能成功（例如对方在局内但状态不是「游戏中」）。失败的说明交给
            后端返回的 `reason`。
          -->
          <NButton size="tiny" secondary class="friend-spectate" :loading="spectating === friend.puuid" :disabled="Boolean(spectating) || spectateUnavailable" :title="friend.canSpectate ? `观战 ${friend.gameName}` : `观战 ${friend.gameName}（对方不在局内时会改走观察者模式）`" @click="spectate(friend)"><template #icon><Eye :size="13" /></template>观战</NButton>
        </article>
      </template>
      <div v-if="!visibleFriends.length" class="friends-empty"><UserRound :size="22" /><strong>{{ search ? "没有匹配的好友" : loading ? "正在读取好友" : "好友列表为空" }}</strong></div>
    </section>

    <!--
      回收站。删除是不可逆的，所以后端在真正删之前会把**客户端当时那条记录**抄一份到
      本地库（`friends_ipc.archiveDeletedFriend`），这里就是它的出口。

      刻意放在列表**下面**并且默认收起：它是「手滑了来补救」的地方，不该和日常浏览
      抢注意力。也刻意做得能离线用——存档在本地，客户端没开也看得见删过谁。
    -->
    <details class="friends-bin">
      <summary>
        <History :size="14" />
        <strong>回收站</strong>
        <span>{{ deleted.length }} 条</span>
        <small>删除好友前会先把记录存到本地，删错了可以从这里发回好友申请</small>
      </summary>
      <div class="friends-bin__body" :class="{ loading: binLoading }">
        <ul v-if="deleted.length">
          <li v-for="record in deleted" :key="record.id">
            <AssetIcon kind="profile" :id="profileIconId(record.icon)" :name="record.gameName" :fallback-url="profileIconImage(record.icon)" round size="sm" />
            <span class="friends-bin__identity"><strong>{{ record.gameName }}<small>#{{ record.gameTag || "--" }}</small></strong><time v-if="record.deletedAt" :datetime="record.deletedAt" :title="shortDate(record.deletedAt)">删除于 {{ relativeTime(record.deletedAt) }}</time></span>
            <NButton size="tiny" secondary :loading="restoring === record.id" :disabled="Boolean(restoring)" @click="restore(record, true)"><template #icon><RotateCcw :size="13" /></template>加回好友</NButton>
            <NPopconfirm positive-text="移除" negative-text="取消" @positive-click="restore(record, false)">
              <template #trigger><NButton size="tiny" quaternary :disabled="Boolean(restoring)" title="只删掉本地这条存档"><template #icon><Trash2 :size="13" /></template></NButton></template>
              只删掉本地这条存档，客户端和好友关系都不受影响。确定吗？
            </NPopconfirm>
          </li>
        </ul>
        <p v-else class="friends-bin__empty">还没有删除记录。删掉的好友会自动存在这里。</p>
      </div>
    </details>
  </div>
</template>

<style scoped>
.friends-page { max-width: 1240px; }
.friends-toolbar { display: grid; gap: 8px; padding: 10px 12px; border: 1px solid var(--line); background: var(--surface-muted); }
.friends-toolbar-row { display: flex; align-items: center; gap: 8px; }
.friends-toolbar-row .n-input { width: min(360px, 100%); }
.friends-toolbar-row:first-child .n-input { margin-right: auto; }
/* 「观战任意玩家」独立成块：虚线 + 强调色底，明确是「手动输入」入口，与好友列表分开。 */
.friends-spectate-any { display: grid; gap: 7px; margin-top: 10px; padding: 10px 12px; border: 1px dashed color-mix(in srgb, var(--accent) 45%, var(--line)); background: color-mix(in srgb, var(--accent-soft) 55%, var(--surface)); }
.friends-spectate-any__head { display: flex; align-items: center; gap: 7px; }
.friends-spectate-any__icon { display: grid; place-items: center; width: 22px; height: 22px; color: var(--accent); background: color-mix(in srgb, var(--accent) 14%, transparent); }
.friends-spectate-any__head strong { color: var(--text-primary); font-size: 11px; }
.friends-spectate-any__tag { padding: 2px 6px; color: var(--accent); background: color-mix(in srgb, var(--accent) 12%, transparent); font-size: 9px; }
.friends-spectate-any__row { display: flex; align-items: center; gap: 8px; }
.friends-spectate-any__row .n-input { width: min(360px, 100%); }
.friends-spectate-any__hint { margin: 0; color: var(--text-muted); font-size: 9px; }
.friends-table { margin-top: 10px; border: 1px solid var(--line); background: var(--surface); transition: opacity .15s; }.friends-table.loading { opacity: .72; }
.friends-list-label { display: flex; align-items: center; gap: 7px; min-height: 30px; padding: 0 12px; border-bottom: 1px solid var(--line); color: var(--text-secondary); background: color-mix(in srgb, var(--surface-muted) 60%, var(--surface)); }.friends-list-label strong { color: var(--text-primary); font-size: 11px; }.friends-list-label small { color: var(--text-muted); font-size: 9px; }
.friends-table > header, .friend-row { display: grid; grid-template-columns: 32px minmax(220px, 1.4fr) 100px minmax(150px, 1fr) minmax(150px, 1fr) auto; align-items: center; gap: 10px; }
.friends-table > header { min-height: 34px; padding: 0 12px; border-bottom: 1px solid var(--line); color: var(--text-muted); background: var(--surface-muted); font-size: 9px; }
.friends-select-all { display: flex; align-items: center; }
.friend-group { display: flex; align-items: center; gap: 7px; min-height: 34px; padding: 0 12px; border-bottom: 1px solid var(--line); color: var(--text-secondary); background: color-mix(in srgb, var(--surface-muted) 55%, var(--surface)); }.friend-group strong { font-size: 11px; }.friend-group span { display: grid; place-items: center; min-width: 20px; height: 18px; margin-left: 2px; color: var(--accent); background: var(--accent-soft); font-size: 9px; }
.friend-row { min-height: 52px; padding: 7px 12px; border-bottom: 1px solid var(--line); }.friend-row:last-child { border-bottom: 0; }.friend-row:hover { background: var(--surface-raised); }
.friend-identity { display: flex; align-items: center; gap: 9px; min-width: 0; }.friend-identity > span { min-width: 0; }.friend-identity strong, .friend-identity small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.friend-identity strong { font-size: 11px; }.friend-identity small { margin-top: 1px; color: var(--text-muted); font-size: 9px; }
.friend-presence { width: fit-content; padding: 3px 6px; color: var(--text-muted); background: var(--surface-muted); font-size: 9px; }.friend-presence[data-state="chat"], .friend-presence[data-state="online"] { color: var(--green); background: var(--green-soft); }.friend-presence[data-state="dnd"], .friend-presence[data-state="spectating"] { color: var(--red); background: var(--red-soft); }.friend-presence[data-state="away"] { color: var(--amber); background: var(--amber-soft); }
.friend-row time strong, .friend-row time small { display: block; }.friend-row time strong { font-size: 10px; font-weight: 500; }.friend-row time small { margin-top: 2px; color: var(--text-muted); font-size: 8px; }.friend-empty { color: var(--text-muted); font-size: 9px; }
.friend-spectate { justify-self: start; }
.friends-empty { display: grid; place-items: center; gap: 7px; min-height: 220px; color: var(--text-muted); }.friends-empty strong { font-size: 11px; }
/* 回收站：默认收起，展开后是一列「谁 + 什么时候删的 + 两个动作」。 */
.friends-bin { margin-top: 12px; border: 1px solid var(--line); background: var(--surface); }
.friends-bin > summary { display: flex; align-items: center; gap: 8px; min-height: 38px; padding: 0 12px; color: var(--text-secondary); cursor: pointer; list-style: none; }
.friends-bin > summary::-webkit-details-marker { display: none; }
.friends-bin > summary:hover { background: var(--surface-raised); }
.friends-bin > summary > strong { color: var(--text-primary); font-size: 11px; }
.friends-bin > summary > span { padding: 2px 6px; color: var(--accent); background: var(--accent-soft); font-size: 9px; }
.friends-bin > summary > small { margin-left: auto; overflow: hidden; color: var(--text-muted); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.friends-bin[open] > summary { border-bottom: 1px solid var(--line); }
.friends-bin__body { transition: opacity .15s; }.friends-bin__body.loading { opacity: .72; }
.friends-bin__body ul { margin: 0; padding: 0; list-style: none; }
.friends-bin__body li { display: grid; grid-template-columns: 26px minmax(0, 1fr) auto auto; align-items: center; gap: 10px; min-height: 50px; padding: 7px 12px; border-bottom: 1px solid var(--line); }
.friends-bin__body li:last-child { border-bottom: 0; }
.friends-bin__body li:hover { background: var(--surface-raised); }
.friends-bin__identity { display: grid; gap: 2px; min-width: 0; }
.friends-bin__identity strong { display: flex; align-items: baseline; gap: 2px; overflow: hidden; color: var(--text-primary); font-size: 11px; font-weight: 700; text-overflow: ellipsis; white-space: nowrap; }
.friends-bin__identity strong small { color: var(--text-muted); font-size: 9px; font-weight: 500; }
.friends-bin__identity time { color: var(--text-muted); font-size: 9px; }
.friends-bin__empty { margin: 0; padding: 18px 12px; color: var(--text-muted); font-size: 10px; text-align: center; }
@media (max-width: 900px) { .friends-toolbar-row { align-items: stretch; flex-wrap: wrap; }.friends-toolbar-row .n-input { width: 100%; }.friends-toolbar-row:first-child .n-input { margin-right: 0; }.friends-spectate-any__row { align-items: stretch; flex-wrap: wrap; }.friends-spectate-any__row .n-input { width: 100%; }.friends-table { overflow-x: auto; }.friends-table > header, .friend-row { min-width: 860px; }.friend-group { min-width: 836px; }.friends-bin > summary > small { display: none; }.friends-bin__body li { grid-template-columns: 26px minmax(0, 1fr) auto; }.friends-bin__body li .n-popconfirm { display: none; } }
</style>
