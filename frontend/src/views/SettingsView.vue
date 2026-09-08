<script setup lang="ts">
import { Check, Database, FolderOpen, MonitorCog, Palette, RefreshCw, Server, Shield } from "@lucide/vue";
import { NButton, NInput, NSelect, NSwitch, useMessage } from "naive-ui";
import { computed } from "vue";
import ModeSwitch from "../components/ModeSwitch.vue";
import PageHeader from "../components/PageHeader.vue";
import { useAppStore } from "../stores/app";

const app = useAppStore();
const message = useMessage();
const themes = [{ key: "mint", name: "薄荷" }, { key: "paper", name: "纸张" }, { key: "night", name: "夜航" }];
const saveLabel = computed(() => app.configSaveState === "saving" ? "保存中…" : app.configSaveState === "error" ? "保存失败" : app.configSaveState === "dirty" ? "等待保存" : "已自动保存");
async function retrySave() { try { await app.retryConfigSave(); message.success("设置已保存"); } catch { /* 状态已显示在页面 */ } }
// 路由使用 hash 模式，#settings-* 会被 vue-router 当成不存在的路由拦截，无法触发原生锚点跳转。
// 这里拦截点击并手动滚动到对应分区，滚动容器是 .content-scroll，scrollIntoView 会一并滚动。
function scrollToSection(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
}
</script>

<template>
  <div class="page-shell settings-page">
    <PageHeader title="设置" eyebrow="应用设置" meta="所有修改立即自动保存；失败时保留当前编辑内容并允许重试">
      <div class="save-indicator" :data-state="app.configSaveState">
        <i class="save-dot" />
        <span>{{ saveLabel }}</span>
        <NButton v-if="app.configSaveState === 'error'" text size="tiny" @click="retrySave">重试</NButton>
      </div>
    </PageHeader>

    <!-- 分区锚点导航 -->
    <nav class="settings-nav" aria-label="设置分区">
      <a href="#settings-data" class="settings-nav__item" @click.prevent="scrollToSection('settings-data')">
        <Database :size="15" />
        <span>数据与缓存</span>
        <i class="settings-nav__arrow">›</i>
      </a>
      <a href="#settings-appearance" class="settings-nav__item" @click.prevent="scrollToSection('settings-appearance')">
        <Palette :size="15" />
        <span>外观与窗口</span>
        <i class="settings-nav__arrow">›</i>
      </a>
      <a href="#settings-connection" class="settings-nav__item" @click.prevent="scrollToSection('settings-connection')">
        <Server :size="15" />
        <span>连接方式</span>
        <i class="settings-nav__arrow">›</i>
      </a>
      <a href="#settings-ai" class="settings-nav__item" @click.prevent="scrollToSection('settings-ai')">
        <MonitorCog :size="15" />
        <span>应用信息</span>
        <i class="settings-nav__arrow">›</i>
      </a>
    </nav>

    <div class="settings-body">
      <!-- 数据源与缓存 -->
      <section id="settings-data" class="settings-section">
        <header class="settings-section__header">
          <div class="settings-section__icon-wrap">
            <Database :size="17" />
          </div>
          <div>
            <span class="eyebrow">数据来源</span>
            <h2>数据源与缓存</h2>
            <p>实时模式优先连接当前 League Client；本地缓存只在请求失败或过期时作为回退。</p>
          </div>
        </header>

        <div class="settings-rows">
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>当前数据模式</strong>
              <small>演示模式使用示例数据；实时模式连接当前客户端</small>
            </div>
            <div class="settings-row__control"><ModeSwitch /></div>
          </div>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>数据优先级</strong>
              <small>英雄名称和资源以 League Client 为准</small>
            </div>
            <div class="settings-row__control">
              <span class="settings-policy">LCU 客户端 → SQLite 缓存 → OP.GG</span>
            </div>
          </div>
          <label class="settings-row">
            <div class="settings-row__label">
              <strong>请求超时</strong>
              <small>远端请求超时后继续使用 SQLite 旧快照</small>
            </div>
            <div class="settings-row__control">
              <input v-model.number="app.config.providers.requestTimeoutSeconds" class="settings-input" type="number" min="1" max="30" />
              <span class="settings-unit">秒</span>
            </div>
          </label>
          <label class="settings-row">
            <div class="settings-row__label">
              <strong>缓存有效期</strong>
              <small>到期后后台重新同步，不阻塞已缓存页面</small>
            </div>
            <div class="settings-row__control">
              <input v-model.number="app.config.providers.cacheTtlMinutes" class="settings-input" type="number" min="1" />
              <span class="settings-unit">分钟</span>
            </div>
          </label>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>显示训练 / 自定义记录</strong>
              <small>关闭后过滤训练、自定义、未完成和待定记录；首页与战绩页会继续补足最近 10 条完整对局</small>
            </div>
            <div class="settings-row__control">
              <NSwitch :value="!app.config.providers.hideUnfinishedMatches" @update:value="app.config.providers.hideUnfinishedMatches = !$event" />
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>仅显示排位数据</strong>
              <small>单双排与灵活组排</small>
            </div>
            <div class="settings-row__control">
              <NSwitch v-model:value="app.config.providers.rankedOnly" aria-label="仅显示排位数据" />
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>游戏结束后自动清空对局面板</strong>
              <small>结算、点赞和确认界面仍保留完整信息；返回大厅后才隐藏</small>
            </div>
            <div class="settings-row__control">
              <NSwitch v-model:value="app.config.providers.clearLobbyAfterGame" />
            </div>
          </div>
        </div>

        <!-- 路径信息 -->
        <div class="settings-paths">
          <div class="settings-path-item">
            <FolderOpen :size="13" />
            <div>
              <span class="settings-path-item__label">应用数据目录</span>
              <code class="settings-path-item__value">{{ app.bootstrap.appDataPath }}</code>
            </div>
          </div>
          <div class="settings-path-item">
            <FolderOpen :size="13" />
            <div>
              <span class="settings-path-item__label">对局导出目录</span>
              <code class="settings-path-item__value">{{ app.bootstrap.appDataPath }}/exports</code>
            </div>
          </div>
          <div class="settings-path-item">
            <Database :size="13" />
            <div>
              <span class="settings-path-item__label">SQLite 数据库</span>
              <code class="settings-path-item__value">{{ app.bootstrap.databasePath }}</code>
            </div>
          </div>
          <div class="settings-path-item">
            <Shield :size="13" />
            <div>
              <span class="settings-path-item__label">配置文件</span>
              <code class="settings-path-item__value">{{ app.bootstrap.configPath }}</code>
            </div>
          </div>
        </div>
      </section>

      <!-- 外观与窗口 -->
      <section id="settings-appearance" class="settings-section">
        <header class="settings-section__header">
          <div class="settings-section__icon-wrap">
            <Palette :size="17" />
          </div>
          <div>
            <span class="eyebrow">外观与窗口</span>
            <h2>外观与窗口</h2>
            <p>薄荷是默认主题；对局页可以收起导航，把空间留给十人数据。</p>
          </div>
        </header>

        <div class="settings-rows">
          <div class="settings-row settings-row--top">
            <div class="settings-row__label">
              <strong>主题</strong>
              <small>颜色层级影响胜负、阵营和风险扫描</small>
            </div>
            <div class="settings-row__control">
              <div class="theme-picker">
                <button
                  v-for="theme in themes"
                  :key="theme.key"
                  type="button"
                  class="theme-btn"
                  :class="{ 'is-active': app.config.appearance.theme === theme.key }"
                  @click="app.config.appearance.theme = theme.key"
                >
                  <i class="theme-swatch" :class="'theme-swatch--' + theme.key" />
                  <span>{{ theme.name }}</span>
                  <Check v-if="app.config.appearance.theme === theme.key" :size="13" class="theme-btn__check" />
                </button>
              </div>
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>深色模式</strong>
              <small>适合夜间长时间查看对局</small>
            </div>
            <div class="settings-row__control">
              <NSwitch v-model:value="app.config.appearance.colorMode" checked-value="dark" unchecked-value="light" />
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>紧凑布局</strong>
              <small>减少普通页面间距，不改变对局页信息列</small>
            </div>
            <div class="settings-row__control">
              <NSwitch v-model:value="app.config.appearance.compact" />
            </div>
          </div>
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>导航栏</strong>
              <small>默认收起；点击顶部或侧栏按钮可展开</small>
            </div>
            <div class="settings-row__control">
              <NButton size="small" secondary @click="app.toggleSidebar()">
                {{ app.sidebarCollapsed ? "当前收起，点击展开" : "当前展开，点击收起" }}
              </NButton>
            </div>
          </div>
        </div>
      </section>

      <!-- 连接方式 -->
      <section id="settings-connection" class="settings-section">
        <header class="settings-section__header">
          <div class="settings-section__icon-wrap">
            <Server :size="17" />
          </div>
          <div>
            <span class="eyebrow">账号与客户端</span>
            <h2>账号与客户端连接</h2>
            <p>Mac 开发时由 Windows 端持有 LCU 凭据，SSH 只负责发现端口并转发。</p>
          </div>
        </header>

        <div class="settings-rows">
          <label class="settings-row">
            <div class="settings-row__label">
              <strong>连接方式</strong>
              <small>本机或 SSH 转发</small>
            </div>
            <div class="settings-row__control">
              <NSelect v-model:value="app.config.connection.kind" :options="[{ label: 'Windows 本机', value: 'local' }, { label: 'SSH 转发', value: 'ssh' }]" />
            </div>
          </label>
          <label class="settings-row" :class="{ 'settings-row--disabled': app.config.connection.kind !== 'ssh' }">
            <div class="settings-row__label">
              <strong>SSH 目标</strong>
              <small>例如 hl-windows</small>
            </div>
            <div class="settings-row__control">
              <NInput v-model:value="app.config.connection.sshTarget" placeholder="hl-windows" :disabled="app.config.connection.kind !== 'ssh'" />
            </div>
          </label>
          <label class="settings-row" :class="{ 'settings-row--disabled': app.config.connection.kind !== 'ssh' }">
            <div class="settings-row__label">
              <strong>身份文件</strong>
              <small>Mac 侧 SSH 私钥路径</small>
            </div>
            <div class="settings-row__control">
              <NInput v-model:value="app.config.connection.identityFile" placeholder="~/.ssh/windows_hl_connect" :disabled="app.config.connection.kind !== 'ssh'" />
            </div>
          </label>
          <label class="settings-row" :class="{ 'settings-row--disabled': app.config.connection.kind !== 'ssh' }">
            <div class="settings-row__label">
              <strong>转发端口</strong>
              <small>填 0 自动探测 29999–30049；也兼容外部 SSH 脚本指定端口</small>
            </div>
            <div class="settings-row__control">
              <input v-model.number="app.config.connection.forwardedPort" class="settings-input" type="number" min="0" max="65535" :disabled="app.config.connection.kind !== 'ssh'" />
            </div>
          </label>
        </div>
      </section>

      <!-- 应用信息 -->
      <section id="settings-ai" class="settings-section">
        <header class="settings-section__header">
          <div class="settings-section__icon-wrap">
            <MonitorCog :size="17" />
          </div>
          <div>
            <span class="eyebrow">应用信息</span>
            <h2>应用信息</h2>
            <p>查看当前本地安装版本。</p>
          </div>
        </header>

        <div class="settings-rows">
          <div class="settings-row">
            <div class="settings-row__label">
              <strong>应用版本</strong>
              <small>版本与配置均来自当前本地安装</small>
            </div>
            <div class="settings-row__control">
              <code class="settings-version">v{{ app.bootstrap.appVersion }}</code>
            </div>
          </div>
        </div>
      </section>
    </div>

    <!-- 保存状态底栏 -->
    <footer class="settings-foot">
      <RefreshCw :size="14" />
      <span>{{ saveLabel }}</span>
      <span v-if="app.configSaveError" class="settings-foot__error">{{ app.configSaveError }}</span>
      <NButton v-if="app.configSaveState === 'error'" size="small" type="primary" @click="retrySave">重试保存</NButton>
    </footer>
  </div>
</template>

<style scoped>
.settings-page { max-width: 960px; }

/* 保存状态指示器 */
.save-indicator {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 5px 10px;
  border: 1px solid var(--line);
  border-radius: 20px;
  font-size: 11px;
  color: var(--text-secondary);
  background: var(--surface-raised);
}
.save-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--text-muted);
  flex: 0 0 6px;
}
.save-indicator[data-state="saving"] .save-dot { background: var(--amber); }
.save-indicator[data-state="dirty"] .save-dot { background: var(--blue); }
.save-indicator[data-state="saved"] .save-dot { background: var(--green); }
.save-indicator[data-state="error"] { border-color: var(--red); color: var(--red); }
.save-indicator[data-state="error"] .save-dot { background: var(--red); }

/* 导航 */
.settings-nav {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 6px;
  margin-bottom: 16px;
}
.settings-nav__item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  border: 1px solid var(--line);
  border-radius: 7px;
  color: var(--text-secondary);
  background: var(--surface);
  font-size: 12px;
  text-decoration: none;
  transition: color 0.15s, border-color 0.15s, background 0.15s;
}
.settings-nav__item svg { color: var(--accent); flex: 0 0 auto; }
.settings-nav__item span { flex: 1; }
.settings-nav__item:hover { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }
.settings-nav__arrow { color: var(--text-muted); font-style: normal; font-size: 14px; margin-left: auto; }

/* body */
.settings-body { display: grid; gap: 12px; }

/* section */
.settings-section {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  overflow: hidden;
  scroll-margin-top: 16px;
}
.settings-section__header {
  display: flex;
  align-items: flex-start;
  gap: 14px;
  padding: 18px 20px 14px;
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
}
.settings-section__icon-wrap {
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border: 1px solid var(--line);
  border-radius: 7px;
  color: var(--accent);
  background: var(--accent-soft);
  flex: 0 0 32px;
}
.settings-section__header .eyebrow { display: block; margin-bottom: 3px; }
.settings-section__header h2 { margin: 0 0 5px; font-size: 15px; font-weight: 600; letter-spacing: -0.01em; }
.settings-section__header p { margin: 0; color: var(--text-secondary); font-size: 11px; line-height: 1.55; }

/* rows */
.settings-rows { display: grid; }
.settings-row {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
  gap: 16px 24px;
  min-height: 62px;
  padding: 12px 20px;
  border-bottom: 1px solid var(--line);
}
.settings-row:last-child { border-bottom: 0; }
.settings-row--top { align-items: flex-start; padding-top: 16px; }
.settings-row--disabled { opacity: 0.5; }
.settings-row__label { min-width: 0; }
.settings-row__label strong { display: block; font-size: 13px; font-weight: 500; }
.settings-row__label small { display: block; margin-top: 3px; color: var(--text-secondary); font-size: 11px; line-height: 1.4; }
.settings-row__control {
  display: flex;
  align-items: center;
  gap: 8px;
  justify-content: flex-end;
  min-width: 0;
}
.settings-row__control .n-base-selection,
.settings-row__control .n-input { width: min(100%, 320px); }

/* 输入与单位 */
.settings-input {
  height: 32px;
  width: 90px;
  padding: 0 10px;
  border: 1px solid var(--line);
  border-radius: 5px;
  color: var(--text-primary);
  background: var(--surface-raised);
  outline: none;
  font-size: 13px;
  text-align: right;
}
.settings-input:focus { border-color: var(--accent); }
.settings-input:disabled { opacity: 0.45; cursor: not-allowed; }
.settings-unit { font-size: 12px; color: var(--text-secondary); white-space: nowrap; }

/* 策略标签 */
.settings-policy {
  color: var(--accent);
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
}

/* 版本 */
.settings-version {
  font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
  color: var(--text-secondary);
}

/* 路径区域 */
.settings-paths {
  display: grid;
  gap: 0;
  border-top: 1px solid var(--line);
  background: var(--surface-muted);
}
.settings-path-item {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 10px 20px;
  border-bottom: 1px solid var(--line);
  font-size: 11px;
}
.settings-path-item:last-child { border-bottom: 0; }
.settings-path-item svg { flex: 0 0 auto; color: var(--text-muted); margin-top: 2px; }
.settings-path-item__label { display: block; color: var(--text-secondary); margin-bottom: 3px; }
.settings-path-item__value {
  display: block;
  color: var(--text-primary);
  font: 11px ui-monospace, SFMono-Regular, Menlo, monospace;
  word-break: break-all;
}

/* 主题 */
.theme-picker { display: flex; gap: 6px; }
.theme-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 32px;
  padding: 0 10px;
  border: 1px solid var(--line);
  border-radius: 6px;
  color: var(--text-secondary);
  background: var(--surface-raised);
  cursor: pointer;
  font-size: 12px;
  transition: border-color 0.15s, color 0.15s, background 0.15s;
}
.theme-btn.is-active { border-color: var(--accent); color: var(--accent); background: var(--accent-soft); }
.theme-swatch { width: 12px; height: 12px; border-radius: 3px; flex: 0 0 12px; }
.theme-swatch--mint { background: #0f766e; }
.theme-swatch--paper { background: #b45309; }
.theme-swatch--night { background: #475569; }
.theme-btn__check { margin-left: 2px; }

/* 底部栏 */
.settings-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 12px;
  padding: 11px 16px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface-muted);
  color: var(--text-secondary);
  font-size: 11px;
}
.settings-foot svg { flex: 0 0 auto; color: var(--text-muted); }
.settings-foot__error { flex: 1; color: var(--red); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

@media (max-width: 860px) {
  .settings-nav { grid-template-columns: repeat(2, 1fr); }
  .settings-row { grid-template-columns: 1fr; min-height: unset; }
  .settings-row__control { justify-content: flex-start; }
  .theme-picker { flex-wrap: wrap; }
}
@media (max-width: 560px) {
  .settings-nav { grid-template-columns: 1fr 1fr; }
}
</style>
