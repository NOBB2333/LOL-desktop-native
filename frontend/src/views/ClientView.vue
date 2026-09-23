<script setup lang="ts">
/**
 * 客户端启动页（左侧导航「客户端」）。
 *
 * 这里取代了原来顶栏的一键启动按钮：启动是一次性动作，长期占着顶栏不合适；而
 * 「本机装了哪些入口、各在什么路径」又是值得常驻展示的信息（对齐 AK 的启动面板：
 * 图标 + 名称 + 完整路径）。所以整页搬过来，顶栏只留与状态相关的东西。
 *
 * 与顶栏按钮时代的差别：页面**不看连接状态**——就算客户端已经连上，也照样列出
 * 安装位置（用户可能想看路径、或再拉一个入口）。探测每次都现场跑一遍
 * （`lol.get_client_installations` 不落缓存），「重新探测」因此总是新鲜的。
 *
 * 图标按入口 id 映射（`tcls`/`league-client` 是英雄联盟系，`wegame-launcher`/
 * `wegame` 是 WeGame 系，`riot-client` 是官方客户端），认不出的 id 退回火箭图标。
 */
import { Copy, RefreshCw, Rocket } from "@lucide/vue";
import { NButton, useMessage } from "naive-ui";
import { onMounted, ref } from "vue";
import PageHeader from "../components/PageHeader.vue";
import clientLeagueIcon from "../assets/client-league.png";
import clientRiotIcon from "../assets/client-riot.png";
import clientWeGameIcon from "../assets/client-wegame.png";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { ClientLaunchEntry } from "../types/domain";

const app = useAppStore();
const message = useMessage();

const entries = ref<ClientLaunchEntry[]>([]);
const loading = ref(false);
const loaded = ref(false);
/** 正在启动的那条入口；null 表示当前没有启动动作。 */
const launchingId = ref<string | null>(null);
const copiedId = ref<string | null>(null);

const entryIcons: Record<string, string> = {
  tcls: clientLeagueIcon,
  "league-client": clientLeagueIcon,
  "wegame-launcher": clientWeGameIcon,
  wegame: clientWeGameIcon,
  "riot-client": clientRiotIcon,
};
const iconFor = (id: string) => entryIcons[id] ?? "";

async function detect() {
  loading.value = true;
  try {
    const result = await backend.clientInstallations();
    entries.value = Array.isArray(result?.entries) ? result.entries : [];
    loaded.value = true;
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    loading.value = false;
  }
}

async function launch(entry: ClientLaunchEntry) {
  if (launchingId.value) return;
  launchingId.value = entry.id;
  try {
    const result = await backend.launchClient(entry.id);
    if (result.ok) message.success(`已启动 ${result.label || entry.label}，客户端起来后会自动连上`);
    else message.warning(result.reason || "没能启动客户端");
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    launchingId.value = null;
  }
}

async function copyPath(entry: ClientLaunchEntry) {
  try {
    await navigator.clipboard.writeText(entry.path);
    copiedId.value = entry.id;
    message.info("路径已复制");
    setTimeout(() => {
      if (copiedId.value === entry.id) copiedId.value = null;
    }, 1600);
  } catch {
    // 某些 webview 不给 clipboard 权限：退回老办法（隐藏选区 + execCommand）。
    const helper = document.createElement("textarea");
    helper.value = entry.path;
    helper.setAttribute("readonly", "true");
    helper.style.position = "fixed";
    helper.style.opacity = "0";
    document.body.appendChild(helper);
    helper.select();
    const copied = document.execCommand("copy");
    helper.remove();
    if (copied) {
      copiedId.value = entry.id;
      message.info("路径已复制");
      setTimeout(() => {
        if (copiedId.value === entry.id) copiedId.value = null;
      }, 1600);
    } else {
      message.error("复制失败，请手动选中路径复制");
    }
  }
}

onMounted(detect);
</script>

<template>
  <div class="page-shell client-page">
    <PageHeader title="客户端" eyebrow="LAUNCHER" :meta="loaded ? (entries.length ? `探测到 ${entries.length} 个启动入口` : '没找到可用的启动入口') : '正在探测本机安装位置…'">
      <NButton size="small" secondary :loading="loading" @click="detect"><template #icon><RefreshCw :size="14" /></template>重新探测</NButton>
    </PageHeader>

    <p v-if="app.mode === 'live' && app.connection.status === 'connected'" class="client-connected">
      客户端已连接。这里仍保留安装位置与启动入口，方便查看路径或再拉起别的入口。
    </p>

    <section class="client-panel">
      <ul v-if="entries.length" class="client-list">
        <li v-for="entry in entries" :key="entry.id" class="client-row">
          <img v-if="iconFor(entry.id)" :src="iconFor(entry.id)" alt="" class="client-row__icon" />
          <span v-else class="client-row__icon client-row__icon--fallback"><Rocket :size="20" /></span>
          <div class="client-row__copy">
            <strong>{{ entry.label }}</strong>
            <code class="client-row__path" :title="entry.path">{{ entry.path }}</code>
            <small>来源：{{ entry.detail }}</small>
          </div>
          <div class="client-row__actions">
            <NButton size="tiny" quaternary :data-copied="copiedId === entry.id" :title="`复制完整路径：${entry.path}`" @click="copyPath(entry)">
              <template #icon><Copy :size="13" /></template>复制路径
            </NButton>
            <NButton size="small" type="primary" secondary :loading="launchingId === entry.id" :disabled="launchingId !== null && launchingId !== entry.id" @click="launch(entry)">
              <template #icon><Rocket :size="14" /></template>启动
            </NButton>
          </div>
        </li>
      </ul>

      <div v-else-if="!loading" class="client-empty">
        <Rocket :size="26" />
        <p>没在本机找到英雄联盟 / WeGame / Riot 客户端</p>
        <small>探测覆盖 WeGameApps 安装目录、Riot 安装清单与 WeGame 常见路径。如果确定装过，点上面的「重新探测」再试一次。</small>
      </div>

      <p class="client-note">启动用的是系统创建进程，拉起后就与本应用无关；客户端就绪后会自动连上，无需手动刷新。</p>
    </section>
  </div>
</template>

<style scoped>
.client-connected {
  margin: 0 0 12px;
  padding: 8px 12px;
  border: 1px solid var(--line);
  border-left: 3px solid var(--accent);
  border-radius: 6px;
  background: var(--surface);
  color: var(--text-secondary);
  font-size: 11px;
}
.client-panel {
  display: grid;
  gap: 12px;
}
.client-list {
  display: grid;
  gap: 8px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.client-row {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 12px 14px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
}
.client-row:hover {
  border-color: var(--line-strong);
  background: var(--surface-raised);
}
.client-row__icon {
  flex: none;
  width: 36px;
  height: 36px;
  border-radius: 8px;
  object-fit: contain;
}
.client-row__icon--fallback {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--accent);
  background: var(--accent-soft, var(--surface-raised));
}
.client-row__copy {
  display: grid;
  gap: 2px;
  min-width: 0;
  flex: 1;
}
.client-row__copy strong {
  font-size: 13px;
  font-weight: 700;
}
.client-row__path {
  overflow: hidden;
  padding: 1px 6px;
  border-radius: 4px;
  background: var(--surface-raised);
  color: var(--text-secondary);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11px;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.client-row__copy small {
  color: var(--text-muted);
  font-size: 10px;
}
.client-row__actions {
  display: inline-flex;
  flex: none;
  align-items: center;
  gap: 8px;
}
.client-empty {
  display: grid;
  justify-items: center;
  gap: 6px;
  padding: 34px 16px;
  border: 1px dashed var(--line-strong);
  border-radius: 8px;
  color: var(--text-muted);
  text-align: center;
}
.client-empty p {
  margin: 0;
  color: var(--text-primary);
  font-size: 13px;
  font-weight: 700;
}
.client-empty small {
  max-width: 420px;
  font-size: 11px;
  line-height: 1.6;
}
.client-note {
  margin: 0;
  color: var(--text-muted);
  font-size: 10px;
}
@media (max-width: 720px) {
  .client-row {
    flex-wrap: wrap;
  }
  .client-row__actions {
    width: 100%;
    justify-content: flex-end;
  }
}
</style>
