<script setup lang="ts">
/**
 * 顶栏公告铃铛（主题切换旁边）。
 *
 * 内容源是 GitHub 仓库 `announcements/` 目录里文件名最大的 .md（见 services/announcements）。
 * 网络策略：**挂载时静默拉一次**——异步、失败不吭声、退回上次缓存，所以不会拖慢启动
 * 也不会弹错误横幅（用户明确担心过网络因素）。未读红点只在「拉到了且没看过」时出现。
 *
 * 展示用 `<details>` 弹层：和本项目其它顶栏弹层同一套路，点外面自己关不上，
 * 需要监听 document pointerdown 补一刀。
 */
import { Bell, RefreshCw } from "@lucide/vue";
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import {
  cachedAnnouncement,
  hasUnreadAnnouncement,
  loadAnnouncement,
  markAnnouncementSeen,
  seenAnnouncementId,
  type Announcement,
} from "../services/announcements";

const announcement = ref<Announcement | null>(cachedAnnouncement());
const unread = ref(hasUnreadAnnouncement());
const loading = ref(false);
const menu = ref<HTMLDetailsElement | null>(null);

const dateLabel = computed(() => announcement.value?.date ?? "");

async function refresh() {
  if (loading.value) return;
  loading.value = true;
  try {
    const result = await loadAnnouncement();
    if (result) announcement.value = result;
    // 未读以「拿到的这份」为准，而不是缓存：预览（fixture）路径不写缓存，
    // 用缓存判断的话预览里红点永远不亮。
    unread.value = Boolean(announcement.value && announcement.value.id !== seenAnnouncementId());
  } finally {
    loading.value = false;
  }
}

function onToggle() {
  // 打开面板才算「看过」：红点消失，但公告内容保持展示。
  if (menu.value?.open && announcement.value) {
    markAnnouncementSeen(announcement.value.id);
    unread.value = false;
  }
}

// 点击别处收起：<details> 不会自己关。
function onDocumentPointerDown(event: PointerEvent) {
  if (!menu.value?.open) return;
  if (event.target instanceof Node && menu.value.contains(event.target)) return;
  menu.value.open = false;
}

onMounted(() => {
  document.addEventListener("pointerdown", onDocumentPointerDown);
  // 静默预取：不 await，失败已被 loadAnnouncement 吃掉。
  void refresh();
});
onBeforeUnmount(() => document.removeEventListener("pointerdown", onDocumentPointerDown));
</script>

<template>
  <details
    ref="menu"
    class="announcement-bell"
    @toggle="onToggle"
  >
    <summary
      class="announcement-bell__button"
      :title="unread ? '有新公告' : '公告'"
      aria-label="公告"
    >
      <Bell :size="16" />
      <i
        v-if="unread"
        class="announcement-bell__dot"
      />
    </summary>

    <div class="announcement-bell__panel">
      <header>
        <strong>公告</strong>
        <button
          type="button"
          :disabled="loading"
          title="重新获取公告"
          @click="refresh"
        >
          <RefreshCw
            :size="12"
            :class="{ spinning: loading }"
          />
        </button>
      </header>

      <template v-if="announcement">
        <h3>{{ announcement.title }}</h3>
        <span
          v-if="dateLabel"
          class="announcement-bell__date"
        >{{ dateLabel }}</span>
        <pre>{{ announcement.body }}</pre>
        <footer>来自 GitHub 仓库 announcements/ 目录，文件名最大的 .md 即当前公告</footer>
      </template>

      <p
        v-else
        class="announcement-bell__empty"
      >
        {{ loading ? "正在获取公告…" : "暂时拿不到公告（网络原因或仓库还没有公告），可点上方按钮重试" }}
      </p>
    </div>
  </details>
</template>

<style scoped>
.announcement-bell {
  position: relative;
  display: inline-flex;
}
.announcement-bell__button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  position: relative;
  width: 29px;
  height: 29px;
  border: 1px solid var(--line);
  border-radius: 6px;
  color: var(--text-secondary);
  background: var(--surface);
  cursor: pointer;
  list-style: none;
}
.announcement-bell__button::-webkit-details-marker {
  display: none;
}
.announcement-bell__button:hover,
.announcement-bell[open] .announcement-bell__button {
  border-color: var(--accent);
  color: var(--accent);
  background: var(--accent-soft, var(--surface-raised));
}
.announcement-bell__dot {
  position: absolute;
  top: 4px;
  right: 4px;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--red);
}
.announcement-bell__panel {
  position: absolute;
  z-index: 40;
  top: calc(100% + 8px);
  right: 0;
  display: grid;
  gap: 6px;
  width: 300px;
  max-height: 420px;
  overflow: auto;
  padding: 12px;
  border: 1px solid var(--line-strong);
  border-radius: 8px;
  background: var(--surface);
  box-shadow: 0 14px 32px #1a342b24;
}
.announcement-bell__panel header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.announcement-bell__panel header strong {
  font-size: 11px;
  font-weight: 700;
}
.announcement-bell__panel header button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  height: 20px;
  border: 1px solid var(--line);
  border-radius: 5px;
  color: var(--text-muted);
  background: var(--surface);
  cursor: pointer;
}
.announcement-bell__panel header button:disabled {
  cursor: progress;
}
.announcement-bell__panel h3 {
  margin: 2px 0 0;
  font-size: 12px;
  font-weight: 700;
}
.announcement-bell__date {
  color: var(--text-muted);
  font-size: 9px;
}
.announcement-bell__panel pre {
  overflow: visible;
  margin: 2px 0 0;
  color: var(--text-secondary);
  font-family: inherit;
  font-size: 11px;
  line-height: 1.7;
  white-space: pre-wrap;
  word-break: break-word;
}
.announcement-bell__panel footer {
  margin-top: 4px;
  border-top: 1px solid var(--line);
  padding-top: 6px;
  color: var(--text-muted);
  font-size: 9px;
}
.announcement-bell__empty {
  margin: 4px 0 0;
  color: var(--text-muted);
  font-size: 10px;
  line-height: 1.6;
}
.spinning {
  animation: announcement-bell-spin 900ms linear infinite;
}
@keyframes announcement-bell-spin {
  to {
    transform: rotate(360deg);
  }
}
@media (prefers-reduced-motion: reduce) {
  .spinning {
    animation: none;
  }
}
</style>
