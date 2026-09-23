<script setup lang="ts">
/**
 * 设置页「检查更新」卡片。
 *
 * 检查时机是这里的关键约束：**只在本组件挂载（也就是用户打开设置页）时查一次**，
 * 平时不做任何后台轮询——查更新要走 GitHub API，没连上代理的用户等它超时纯属折磨。
 * 本组件被 `SettingsView.vue` 懒加载引用，路由不进设置页就不会创建实例。
 *
 * 数据来自 `lol.check_update`（GitHub Release API）。三种结局：
 * - `null`：已是最新（后端只在远端版本严格更新时才返回内容）；
 * - 有结果：展示新版本号、发布日期、说明前一段与 Release 链接；
 * - 抛错：网络不通（GitHub 直连失败很常见），给出重试而不是反复自动尝试。
 */
import { ExternalLink, RefreshCw } from "@lucide/vue";
import { NButton } from "naive-ui";
import { onMounted, ref } from "vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { ReleaseUpdate } from "../types/domain";

const app = useAppStore();

const checking = ref(false);
const update = ref<ReleaseUpdate | null>(null);
const failed = ref(false);
/** 查过至少一次之后才显示结果文案，避免首帧闪「已是最新」。 */
const checked = ref(false);

async function check() {
  if (checking.value) return;
  checking.value = true;
  failed.value = false;
  try {
    update.value = await backend.checkUpdate();
    checked.value = true;
  } catch {
    failed.value = true;
  } finally {
    checking.value = false;
  }
}

const statusText = () => {
  if (checking.value) return "正在检查更新…";
  if (failed.value) return "检查失败：连不上 GitHub，稍后可重试";
  if (!update.value) return "已是最新版本";
  return `发现新版本 v${update.value.version}`;
};

const publishedDate = () => {
  const raw = update.value?.publishedAt ?? "";
  return /^\d{4}-\d{2}-\d{2}/.test(raw) ? raw.slice(0, 10) : "";
};

onMounted(check);
</script>

<template>
  <div class="update-check">
    <div class="update-check__row">
      <div class="update-check__label">
        <strong>检查更新</strong>
        <small>当前版本 v{{ app.bootstrap.appVersion }} · 只在打开设置页时检查，不会后台轮询</small>
      </div>
      <div class="update-check__control">
        <span class="update-check__status" :data-kind="failed ? 'error' : update ? 'update' : 'idle'" aria-live="polite">{{ statusText() }}</span>
        <NButton size="tiny" quaternary :loading="checking" title="重新检查更新" @click="check"><template #icon><RefreshCw :size="13" /></template>重新检查</NButton>
      </div>
    </div>

    <div v-if="update" class="update-check__release">
      <div class="update-check__release-head">
        <strong>{{ update.title || `v${update.version}` }}</strong>
        <span v-if="publishedDate()">发布于 {{ publishedDate() }}</span>
      </div>
      <pre v-if="update.notes" class="update-check__notes">{{ update.notes }}</pre>
      <a class="update-check__link" :href="update.url" target="_blank" rel="noreferrer">
        <ExternalLink :size="13" />打开 Release 页面下载
      </a>
    </div>
  </div>
</template>

<style scoped>
.update-check {
  display: grid;
  gap: 10px;
}
.update-check__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
}
.update-check__label {
  display: grid;
  gap: 2px;
  min-width: 0;
}
.update-check__label strong {
  font-size: 12px;
  font-weight: 700;
}
.update-check__label small {
  color: var(--text-muted);
  font-size: 10px;
}
.update-check__control {
  display: inline-flex;
  flex: none;
  align-items: center;
  gap: 10px;
}
.update-check__status {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
}
.update-check__status[data-kind="update"] {
  color: var(--accent);
}
.update-check__status[data-kind="error"] {
  color: var(--amber);
}
.update-check__release {
  display: grid;
  gap: 8px;
  padding: 10px 12px;
  border: 1px solid var(--accent);
  border-radius: 8px;
  background: var(--accent-soft, var(--surface-raised));
}
.update-check__release-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
  font-size: 12px;
}
.update-check__release-head span {
  color: var(--text-muted);
  font-size: 10px;
}
.update-check__notes {
  overflow: auto;
  max-height: 132px;
  margin: 0;
  color: var(--text-secondary);
  font-family: inherit;
  font-size: 11px;
  line-height: 1.7;
  white-space: pre-line;
}
.update-check__link {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  color: var(--accent);
  font-size: 11px;
  font-weight: 600;
}
@media (max-width: 720px) {
  .update-check__row {
    flex-wrap: wrap;
  }
}
</style>
