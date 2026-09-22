<script setup lang="ts">
import { Eye, RefreshCw, Search, Trash2, UserRound } from "@lucide/vue";
import { NButton, NCheckbox, NInput, NPopconfirm, useMessage } from "naive-ui";
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import AssetIcon from "../components/AssetIcon.vue";
import PageHeader from "../components/PageHeader.vue";
import { backend, isTauri } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { FriendRecord, FriendToolsSnapshot } from "../types/domain";
import { relativeTime, shortDate } from "../utils/format";

const app = useAppStore();
const message = useMessage();
const data = ref<FriendToolsSnapshot>({ groups: [], friends: [] });
const loading = ref(false);
const deleting = ref(false);
const spectating = ref<string | null>(null);
const search = ref("");
const selected = ref<string[]>([]);
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
      message.success(`已删除 ${outcome.deleted} 位好友`);
    }
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    deleting.value = false;
  }
}

/**
 * 观战。
 *
 * 观战密钥由客户端临时下发，只有「在线且正在对局中」的好友才有，所以这里
 * **不**把它当成一个必成功的动作：成功/失败都用后端的 `reason` 告诉用户。
 */
async function spectate(friend: FriendRecord) {
  if (spectating.value) return;
  spectating.value = friend.puuid;
  try {
    const result = await backend.spectate(friend.puuid);
    if (result.ok) message.success(`正在启动观战：${friend.gameName}`);
    else message.warning(result.reason);
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    spectating.value = null;
  }
}

onMounted(() => {
  void refresh();
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
      <NInput v-model:value="search" clearable size="small" placeholder="搜索好友名称或标签"><template #prefix><Search :size="14" /></template></NInput>
      <NPopconfirm :disabled="!selectedCount || deleting" positive-text="删除" negative-text="取消" @positive-click="deleteSelected">
        <template #trigger><NButton size="small" type="error" secondary :disabled="!selectedCount || deleting"><template #icon><Trash2 :size="14" /></template>{{ selectedCount ? `删除 (${selectedCount})` : "删除" }}</NButton></template>
        将从 League 客户端删除选中的好友，此操作不可恢复。
      </NPopconfirm>
    </section>

    <section class="friends-table" :class="{ loading }">
      <header>
        <span class="friends-select-all"><NCheckbox :checked="allVisibleSelected" :indeterminate="selectedCount > 0 && !allVisibleSelected" :aria-label="allVisibleSelected ? '取消全选' : '全选当前好友'" @update:checked="toggleAllVisible" /></span>
        <span>好友分组</span><span>状态</span><span>最后对局日期</span><span>成为好友时间</span><span>操作</span>
      </header>
      <template v-for="group in groupedFriends" :key="group.id">
        <div class="friend-group"><UserRound :size="14" /><strong>{{ group.name }}</strong><span>{{ group.friends.length }}</span></div>
        <article v-for="friend in group.friends" :key="friend.id" class="friend-row">
          <NCheckbox :checked="selected.includes(friend.id)" @update:checked="updateSelection(friend.id, $event)" />
          <div class="friend-identity"><AssetIcon kind="profile" :id="friend.icon" :name="friend.gameName" size="xs" /><span><strong>{{ friend.gameName }}</strong><small>#{{ friend.gameTag || "--" }}</small></span></div>
          <span class="friend-presence" :data-state="friend.availability">{{ availabilityLabel[friend.availability] ?? friend.availability ?? "未知" }}</span>
          <time v-if="friend.lastGameAt" :datetime="friend.lastGameAt" :title="shortDate(friend.lastGameAt)"><strong>{{ shortDate(friend.lastGameAt) }}</strong><small>{{ relativeTime(friend.lastGameAt) }}</small></time><span v-else class="friend-empty">无对局数据</span>
          <time v-if="friend.friendsSince" :datetime="friend.friendsSince" :title="shortDate(friend.friendsSince)"><strong>{{ shortDate(friend.friendsSince) }}</strong><small>{{ relativeTime(friend.friendsSince) }}</small></time><span v-else class="friend-empty">未知</span>
          <NButton size="tiny" secondary class="friend-spectate" :loading="spectating === friend.puuid" :disabled="!friend.canSpectate || Boolean(spectating)" :title="friend.canSpectate ? `观战 ${friend.gameName}` : '观战密钥只在好友正在对局时由客户端下发'" @click="spectate(friend)"><template #icon><Eye :size="13" /></template>观战</NButton>
        </article>
      </template>
      <div v-if="!visibleFriends.length" class="friends-empty"><UserRound :size="22" /><strong>{{ search ? "没有匹配的好友" : loading ? "正在读取好友" : "好友列表为空" }}</strong></div>
    </section>
  </div>
</template>

<style scoped>
.friends-page { max-width: 1240px; }
.friends-toolbar { display: flex; align-items: center; gap: 8px; padding: 10px 12px; border: 1px solid var(--line); border-bottom: 0; background: var(--surface-muted); }
.friends-toolbar .n-input { width: min(360px, 100%); margin-right: auto; }
.friends-table { border: 1px solid var(--line); background: var(--surface); transition: opacity .15s; }.friends-table.loading { opacity: .72; }
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
@media (max-width: 900px) { .friends-toolbar { align-items: stretch; flex-wrap: wrap; }.friends-toolbar .n-input { width: 100%; }.friends-table { overflow-x: auto; }.friends-table > header, .friend-row { min-width: 860px; }.friend-group { min-width: 836px; } }
</style>
