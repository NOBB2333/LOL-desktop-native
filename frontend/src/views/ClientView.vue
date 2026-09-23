<script setup lang="ts">
/**
 * 客户端启动页（左侧导航「客户端」）。
 *
 * 这里取代了原来顶栏的一键启动按钮：启动是一次性动作，长期占着顶栏不合适；而
 * 「本机装了哪些入口、各在什么路径」又是值得常驻展示的信息（对齐 AK 的启动面板：
 * 图标 + 名称 + 完整路径）。所以整页搬过来，顶栏只留与状态相关的东西。
 *
 * 版式按「启动台」来设计，而不是一张设置表：顶部一条 hero（应用标识 + 版本 +
 * 连接状态），下面把入口铺成自适应网格的卡片。**不要退回单列细行**——那看着
 * 像条款，而这一页本来东西就少，铺开才撑得住。
 *
 * 与顶栏按钮时代的差别：页面**不看连接状态**——就算客户端已经连上，也照样列出
 * 安装位置（用户可能想看路径、或再拉一个入口）。探测每次都现场跑一遍
 * （`lol.get_client_installations` 不落缓存），「重新探测」因此总是新鲜的。
 *
 * 图标按入口 id 映射（`tcls`/`league-client` 是英雄联盟系，`wegame-launcher`/
 * `wegame` 是 WeGame 系，`riot-client` 是官方客户端），认不出的 id 退回火箭图标。
 */
import { Copy, Check, RefreshCw, Rocket, ServerCog, PlugZap } from "@lucide/vue";
import { NButton, useMessage } from "naive-ui";
import { computed, onMounted, ref } from "vue";
import clientLeagueIcon from "../assets/client-league.png";
import clientRiotIcon from "../assets/client-riot.png";
import clientWeGameIcon from "../assets/client-wegame.png";
import logoUrl from "../assets/lol-mark.png";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { ClientLaunchEntry } from "../types/domain";
import { platformRegionName } from "../utils/format";

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

/**
 * 每个入口「到底是干什么的」。
 *
 * 光看「英雄联盟（腾讯登录器）」和「英雄联盟（WeGame 启动）」没人分得清该点哪个，
 * 而它们的差别是实打实的（一个绕过 WeGame，一个要经 WeGame）。这里只是短说明，
 * 认不出的 id 就不显示，别硬编。
 */
const entryHints: Record<string, string> = {
  tcls: "腾讯登录器，直接拉起游戏客户端，不走 WeGame。",
  "wegame-launcher": "经 WeGame 拉起游戏，适合要用 WeGame 登录/加速的场景。",
  wegame: "WeGame 主程序本身，启动后还得在里面点开游戏。",
  "league-client": "游戏客户端本体，已有登录态时才直接拉得起来。",
  "riot-client": "官方 Riot 启动器，登录后再拉起游戏。",
};
const hintFor = (id: string) => entryHints[id] ?? "";

const connected = computed(() => app.mode === "live" && app.connection.status === "connected");
/** 后端按优先级返回，`entries[0]` 就是不带 id 启动时会被拉起的那个。 */
const recommendedId = computed(() => entries.value[0]?.id ?? "");

const statusText = computed(() => {
  if (connected.value) return "客户端已连接，无需启动";
  if (!loaded.value) return "正在探测本机安装位置…";
  if (!entries.value.length) return "没找到可用的启动入口";
  return `探测到 ${entries.value.length} 个启动入口，已按优先级排好`;
});

/**
 * 「启动完到底成没成」——这一页点完启动就走，所以把连接后的结果摊在这里：
 * 连上了、连的是谁、在哪个区、现在什么阶段。字段全都来自已有的连接状态，
 * 没有就不编（显示「—」）。
 */
const statusLabel = computed(() => {
  switch (app.connection.status) {
    case "connected": return "已连接";
    case "connecting": return "连接中";
    case "error": return "连接失败";
    default: return "未连接";
  }
});
const accountLabel = computed(() => {
  const { gameName, tagLine } = app.connection;
  if (!gameName) return "—";
  return tagLine ? `${gameName}#${tagLine}` : gameName;
});
const levelLabel = computed(() => (app.connection.summonerLevel ? `Lv ${app.connection.summonerLevel}` : "—"));
const regionLabel = computed(() => (app.connection.platformId ? platformRegionName(app.connection.platformId) : "—"));
const phaseLabel = computed(() => app.connection.queueLabel || app.connection.phase || "—");

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

function markCopied(id: string) {
  copiedId.value = id;
  setTimeout(() => {
    if (copiedId.value === id) copiedId.value = null;
  }, 1600);
}

async function copyPath(entry: ClientLaunchEntry) {
  try {
    await navigator.clipboard.writeText(entry.path);
    markCopied(entry.id);
    message.info("路径已复制");
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
      markCopied(entry.id);
      message.info("路径已复制");
    } else {
      message.error("复制失败，请手动选中路径复制");
    }
  }
}

onMounted(detect);
</script>

<template>
  <div class="page-shell client-page">
    <section class="client-hero">
      <img :src="logoUrl" alt="" class="client-hero__mark" />
      <div class="client-hero__body">
        <span class="client-hero__eyebrow">CLIENT LAUNCHER</span>
        <h1>桌上英雄联盟</h1>
        <div class="client-hero__meta">
          <span class="client-status" :data-connected="connected">
            <PlugZap :size="13" />
            {{ statusText }}
          </span>
          <span v-if="app.bootstrap.appVersion" class="client-hero__version">v{{ app.bootstrap.appVersion }}</span>
        </div>
      </div>
      <NButton class="client-hero__action" size="small" secondary :loading="loading" @click="detect">
        <template #icon><RefreshCw :size="14" /></template>重新探测
      </NButton>
    </section>

    <div v-if="entries.length" class="client-grid">
      <article
        v-for="entry in entries"
        :key="entry.id"
        class="client-card"
        :data-recommended="entry.id === recommendedId"
      >
        <header class="client-card__head">
          <img v-if="iconFor(entry.id)" :src="iconFor(entry.id)" alt="" class="client-card__icon" />
          <span v-else class="client-card__icon client-card__icon--fallback"><Rocket :size="24" /></span>
          <div class="client-card__title">
            <strong>{{ entry.label }}</strong>
            <div class="client-card__tags">
              <span class="client-tag">{{ entry.detail }}</span>
              <span v-if="entry.id === recommendedId" class="client-tag client-tag--accent">优先级最高</span>
            </div>
          </div>
        </header>

        <p v-if="hintFor(entry.id)" class="client-card__hint">{{ hintFor(entry.id) }}</p>

        <code class="client-card__path" :title="entry.path">{{ entry.path }}</code>

        <footer class="client-card__foot">
          <NButton
            size="small"
            type="primary"
            secondary
            class="client-card__launch"
            :loading="launchingId === entry.id"
            :disabled="launchingId !== null && launchingId !== entry.id"
            @click="launch(entry)"
          >
            <template #icon><Rocket :size="14" /></template>启动
          </NButton>
          <NButton
            size="small"
            quaternary
            :aria-label="`复制路径：${entry.path}`"
            :title="`复制完整路径：${entry.path}`"
            @click="copyPath(entry)"
          >
            <template #icon>
              <Check v-if="copiedId === entry.id" :size="14" />
              <Copy v-else :size="14" />
            </template>
            {{ copiedId === entry.id ? "已复制" : "复制路径" }}
          </NButton>
        </footer>
      </article>
    </div>

    <div v-else-if="!loading" class="client-empty">
      <ServerCog :size="30" />
      <p>没在本机找到英雄联盟 / WeGame / Riot 客户端</p>
      <small>探测顺序：注册表安装记录 → Riot 安装清单 → 固定磁盘扫盘。如果确定装过，点右上角「重新探测」再试一次。</small>
    </div>

    <section class="client-runtime">
      <header class="client-runtime__head">
        <h2>运行状态</h2>
        <RouterLink v-if="connected" to="/game" class="client-runtime__jump">
          去看当前对局
        </RouterLink>
      </header>
      <dl class="client-facts">
        <div class="client-fact">
          <dt>客户端连接</dt>
          <dd :data-state="app.connection.status">{{ statusLabel }}</dd>
        </div>
        <div class="client-fact">
          <dt>当前账号</dt>
          <dd>{{ accountLabel }}</dd>
        </div>
        <div class="client-fact">
          <dt>召唤师等级</dt>
          <dd>{{ levelLabel }}</dd>
        </div>
        <div class="client-fact">
          <dt>所在大区</dt>
          <dd>{{ regionLabel }}</dd>
        </div>
        <div class="client-fact">
          <dt>当前阶段</dt>
          <dd>{{ phaseLabel }}</dd>
        </div>
      </dl>
    </section>

    <p class="client-note">
      启动用的是系统创建进程，拉起后就与本应用无关；客户端就绪后会自动连上，无需手动刷新。
    </p>
  </div>
</template>

<style scoped>
/* hero：一条横向的「启动台」抬头。底色用强调色的极淡渐变撑出层次，
   而不是再加一层描边框——页面已经很素了，靠留白和层次区分即可。 */
.client-hero {
  display: flex;
  align-items: center;
  gap: 18px;
  padding: 22px 24px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background:
    radial-gradient(120% 160% at 0% 0%, color-mix(in srgb, var(--accent) 10%, transparent) 0%, transparent 62%),
    var(--surface);
}
.client-hero__mark {
  flex: none;
  width: 58px;
  height: 58px;
  border-radius: 14px;
  object-fit: contain;
}
.client-hero__body {
  display: grid;
  gap: 4px;
  min-width: 0;
  flex: 1;
}
.client-hero__eyebrow {
  color: var(--text-muted);
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.14em;
}
.client-hero h1 {
  margin: 0;
  font-size: 22px;
  font-weight: 700;
  line-height: 1.15;
}
.client-hero__meta {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.client-status {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  color: var(--text-secondary);
  font-size: 11px;
}
.client-status[data-connected="true"] {
  color: var(--green);
}
.client-hero__version {
  padding: 1px 7px;
  border-radius: 999px;
  background: var(--surface-muted);
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 10px;
}
.client-hero__action {
  flex: none;
}

/* 自适应网格：这一页条目少，单列细行会显得像条款；铺成卡片才有「启动台」的样子。 */
.client-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(290px, 1fr));
  gap: 12px;
  margin-top: 14px;
}
.client-card {
  display: grid;
  gap: 12px;
  align-content: start;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
  transition: border-color 0.15s ease, box-shadow 0.15s ease, transform 0.15s ease;
}
.client-card:hover {
  border-color: var(--line-strong);
  box-shadow: 0 6px 18px color-mix(in srgb, var(--ink) 7%, transparent);
  transform: translateY(-1px);
}
/* 优先级最高的那条（不带 id 启动时会被拉起）给一圈强调色，省得用户猜。 */
.client-card[data-recommended="true"] {
  border-color: color-mix(in srgb, var(--accent) 45%, var(--line));
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--accent) 18%, transparent);
}
.client-card__head {
  display: flex;
  align-items: center;
  gap: 12px;
}
.client-card__icon {
  flex: none;
  width: 46px;
  height: 46px;
  border-radius: 12px;
  object-fit: contain;
}
.client-card__icon--fallback {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--accent);
  background: var(--accent-soft);
}
.client-card__title {
  display: grid;
  gap: 6px;
  min-width: 0;
}
.client-card__title strong {
  font-size: 14px;
  font-weight: 700;
  line-height: 1.3;
}
.client-card__tags {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}
.client-tag {
  padding: 1px 7px;
  border-radius: 999px;
  background: var(--surface-muted);
  color: var(--text-muted);
  font-size: 10px;
}
.client-tag--accent {
  color: var(--accent);
  background: var(--accent-soft);
  font-weight: 700;
}
/* 路径是这一页的真正内容，给足行数；两行之后才截断，并靠 title 兜住全文。 */
.client-card__hint {
  margin: 0;
  color: var(--text-secondary);
  font-size: 11px;
  line-height: 1.6;
}
.client-card__path {
  display: -webkit-box;
  overflow: hidden;
  padding: 8px 10px;
  border-radius: 8px;
  background: var(--surface-muted);
  color: var(--text-secondary);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11px;
  line-height: 1.5;
  word-break: break-all;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
}
.client-card__foot {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: auto;
}
.client-card__launch {
  flex: 1;
}
.client-empty {
  display: grid;
  justify-items: center;
  gap: 8px;
  margin-top: 14px;
  padding: 44px 20px;
  border: 1px dashed var(--line-strong);
  border-radius: 12px;
  color: var(--text-muted);
  text-align: center;
}
.client-empty p {
  margin: 0;
  color: var(--text-primary);
  font-size: 14px;
  font-weight: 700;
}
.client-empty small {
  max-width: 460px;
  font-size: 11px;
  line-height: 1.7;
}
/* 运行状态：点完「启动」之后这一页就是用来回答「成了吗」的，所以把连接结果
   摊成一排事实格。横向铺开而不是纵向堆叠，顺带把页面下半部撑起来。 */
.client-runtime {
  display: grid;
  gap: 12px;
  margin-top: 16px;
  padding: 16px 18px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
}
.client-runtime__head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 12px;
}
.client-runtime__head h2 {
  margin: 0;
  font-size: 13px;
  font-weight: 700;
}
.client-runtime__jump {
  color: var(--accent);
  font-size: 11px;
  font-weight: 600;
  text-decoration: none;
}
.client-runtime__jump:hover {
  text-decoration: underline;
}
.client-facts {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
  gap: 10px 18px;
  margin: 0;
}
.client-fact {
  display: grid;
  gap: 3px;
  min-width: 0;
}
.client-fact dt {
  color: var(--text-muted);
  font-size: 10px;
  letter-spacing: 0.04em;
}
.client-fact dd {
  margin: 0;
  overflow: hidden;
  font-size: 12px;
  font-weight: 600;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* 只有「已连接」是好事，其余状态一律中性/警告色，不抢眼。 */
.client-fact dd[data-state="connected"] {
  color: var(--green);
}
.client-fact dd[data-state="error"] {
  color: var(--red);
}
.client-fact dd[data-state="connecting"] {
  color: var(--amber);
}

.client-note {
  margin: 14px 0 0;
  color: var(--text-muted);
  font-size: 10px;
}

@media (max-width: 720px) {
  .client-hero {
    flex-wrap: wrap;
  }
  .client-hero__action {
    width: 100%;
  }
}
</style>
