<script setup lang="ts">
import { ArrowDown, ArrowUp, Bot, Braces, Keyboard, Play, Plus, ShieldCheck, Sparkles, Trash2, Zap } from "@lucide/vue";
import { NButton, NInput, NInputNumber, NSelect, NSwitch, useMessage } from "naive-ui";
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { useQuery } from "@tanstack/vue-query";
import PageHeader from "../components/PageHeader.vue";
import AssetIcon from "../components/AssetIcon.vue";
import { backend } from "../services/backend";
import { useAppStore } from "../stores/app";
import type { ShortcutTarget } from "../types/domain";
import { renderShortcutTemplateExample, shortcutTemplateFields } from "../shortcuts/template";

const app = useAppStore();
const message = useMessage();
const champions = useQuery({ queryKey: computed(() => ["automation-champions", app.mode]), queryFn: backend.champions, enabled: computed(() => app.initialized), staleTime: 3600000 });
const championOptions = computed(() => (champions.data.value ?? []).map((champion) => ({ label: `${champion.name} · ${champion.alias}`, value: champion.id })));
const championById = computed(() => new Map((champions.data.value ?? []).map((champion) => [champion.id, champion])));
const automationRunning = ref(false);
const recordingShortcutId = ref<string | null>(null);
const debugShortcutId = ref<string | null>(null);
const debugLines = ref<Record<string, string[]>>({});
const debugErrors = ref<Record<string, string | null>>({});
const debugRunningId = ref<string | null>(null);
const placeholderFields = shortcutTemplateFields;
const autoPickStrategyOptions = [
  { label: "亮人后自动锁定", value: "show-and-lock-in" },
  { label: "只亮人，不锁定", value: "just-show" },
  { label: "立即锁定", value: "lock-in-immediately" },
];

async function runAutomation() {
  if (app.mode !== "live") {
    message.info("Fixture 模式只预览配置；切换到实时模式后才会写入 LCU");
    return;
  }
  automationRunning.value = true;
  try {
    const actions = await backend.runAutomation();
    if (!actions.length) message.info("当前阶段没有可执行动作");
    else actions.forEach((action) => message.info(action.reason));
  } catch (cause) {
    message.error(cause instanceof Error ? cause.message : String(cause));
  } finally {
    automationRunning.value = false;
  }
}

type AutoActionKey = "autoAccept" | "autoPick" | "autoBan";

function setAdvisoryMode(enabled: boolean) {
  app.config.automation.advisoryMode = enabled;
  if (!enabled) return;
  app.config.automation.autoAccept = false;
  app.config.automation.autoPick = false;
  app.config.automation.autoBan = false;
}

function setAutoAction(key: AutoActionKey, enabled: boolean) {
  app.config.automation[key] = enabled;
  if (enabled) app.config.automation.advisoryMode = false;
}

function addShortcut() {
  app.config.automation.shortcuts.push({ id: `custom-${Date.now()}`, label: "新快捷消息", key: "", target: "custom", template: "{name} {rank} {kda}", enabled: false });
}
function removeShortcut(index: number) { app.config.automation.shortcuts.splice(index, 1); }
function moveShortcut(index: number, direction: -1 | 1) {
  const next = index + direction;
  if (next < 0 || next >= app.config.automation.shortcuts.length) return;
  const [item] = app.config.automation.shortcuts.splice(index, 1);
  app.config.automation.shortcuts.splice(next, 0, item);
}

function toggleShortcutDebug(shortcutId: string) {
  debugShortcutId.value = debugShortcutId.value === shortcutId ? null : shortcutId;
}

function appendPlaceholder(shortcutId: string, key: string) {
  const shortcut = app.config.automation.shortcuts.find((item) => item.id === shortcutId);
  if (!shortcut) return;
  const placeholder = `{${key}}`;
  const separator = shortcut.template && !/[\s，：:；、-]$/.test(shortcut.template) ? "，" : "";
  shortcut.template += `${separator}${placeholder}`;
}

async function previewConfiguredShortcut(shortcutId: string) {
  const shortcut = app.config.automation.shortcuts.find((item) => item.id === shortcutId);
  if (!shortcut) return;
  debugShortcutId.value = shortcutId;
  debugRunningId.value = shortcutId;
  debugErrors.value[shortcutId] = null;
  try {
    await app.persistConfig();
    debugLines.value[shortcutId] = await backend.previewShortcut(shortcutId);
  } catch (cause) {
    debugLines.value[shortcutId] = [];
    debugErrors.value[shortcutId] = cause instanceof Error ? cause.message : String(cause);
  } finally {
    debugRunningId.value = null;
  }
}

async function startShortcutRecording(shortcutId: string) {
  if (recordingShortcutId.value === shortcutId) { await stopShortcutRecording(); return; }
  recordingShortcutId.value = shortcutId;
  try { await backend.setShortcutCapture(true); } catch (cause) { recordingShortcutId.value = null; message.error(cause instanceof Error ? cause.message : String(cause)); }
}
async function stopShortcutRecording() {
  recordingShortcutId.value = null;
  try { await backend.setShortcutCapture(false); } catch (cause) { message.error(cause instanceof Error ? cause.message : String(cause)); }
}
function recordedShortcut(event: KeyboardEvent) {
  const functionKey = /^F(?:[1-9]|1\d|2[0-4])$/i.test(event.key) ? event.key.toUpperCase() : null;
  const codeKey = event.code.startsWith("Key") ? event.code.slice(3).toUpperCase() : event.code.startsWith("Digit") ? event.code.slice(5) : ({ Space: "Space", Enter: "Enter", Tab: "Tab", Backquote: "Oemtilde", Minus: "Minus", Equal: "Equal", ArrowLeft: "Left", ArrowUp: "Up", ArrowRight: "Right", ArrowDown: "Down" } as Record<string, string>)[event.code];
  const key = functionKey ?? codeKey;
  if (!key) return null;
  return [event.ctrlKey && "Ctrl", event.shiftKey && "Shift", event.altKey && "Alt", event.metaKey && "Win", key].filter(Boolean).join("+");
}
function handleShortcutRecording(event: KeyboardEvent) {
  const shortcutId = recordingShortcutId.value;
  if (!shortcutId) return;
  event.preventDefault(); event.stopImmediatePropagation();
  if (event.key === "Escape") { void stopShortcutRecording(); return; }
  const shortcut = app.config.automation.shortcuts.find((item) => item.id === shortcutId);
  if (!shortcut) { void stopShortcutRecording(); return; }
  if ((event.key === "Backspace" || event.key === "Delete") && !event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey) { shortcut.key = ""; void stopShortcutRecording(); return; }
  const key = recordedShortcut(event);
  if (!key) return;
  shortcut.key = key;
  void stopShortcutRecording();
}
onMounted(() => window.addEventListener("keydown", handleShortcutRecording, true));
onBeforeUnmount(() => { window.removeEventListener("keydown", handleShortcutRecording, true); if (recordingShortcutId.value) void backend.setShortcutCapture(false); });
function removeChampion(target: "pick" | "ban", id: number) {
  const key = target === "pick" ? "pickChampionIds" : "banChampionIds";
  app.config.automation[key] = app.config.automation[key].filter((value) => value !== id);
}
const targetOptions: { label: string; value: ShortcutTarget }[] = [
  { label: "我方每位玩家", value: "ally" }, { label: "敌方每位玩家", value: "enemy" }, { label: "双方打野", value: "jungle" }, { label: "已知组队汇总", value: "premade" }, { label: "发送遇到记录", value: "encounter" }, { label: "本局所有玩家", value: "lobby" }, { label: "仅发送一次", value: "custom" },
];
const targetLabel = (target: ShortcutTarget) => targetOptions.find((option) => option.value === target)?.label ?? target;

</script>

<template>
  <div class="page-shell auto-page">
    <PageHeader title="自动化" eyebrow="AUTOMATION" meta="Fixture 模式也能配置完整的英雄选择流程">
      <NButton size="small" secondary :loading="automationRunning" @click="runAutomation">
        <template #icon><Zap :size="14" /></template>执行一次
      </NButton>
    </PageHeader>

    <!-- 主开关 Banner -->
    <div class="auto-master-toggle" :class="{ 'is-on': app.config.automation.enabled }">
      <div class="auto-master-toggle__left">
        <div class="auto-master-toggle__icon">
          <Bot :size="20" />
        </div>
        <div>
          <strong>自动化总开关</strong>
          <p>关闭时不会向客户端写入 Pick、Ban 或接受动作</p>
        </div>
      </div>
      <NSwitch v-model:value="app.config.automation.enabled" size="large" />
    </div>

    <!-- 运行状态 -->
    <div v-if="app.automationRuntimeError || app.automationStatus" class="auto-runtime-banner" :data-state="app.automationRuntimeError ? 'error' : 'ok'">
      <strong>{{ app.automationRuntimeError ? "执行失败" : "最近动作" }}</strong>
      <span>{{ app.automationRuntimeError || app.automationStatus }}</span>
    </div>

    <div class="auto-grid">
      <!-- 左列：动作控制 + 英雄池 -->
      <div class="auto-col">
        <!-- 动作开关卡片 -->
        <section class="auto-card">
          <header class="auto-card__head">
            <ShieldCheck :size="16" class="auto-card__icon" />
            <div>
              <span class="eyebrow">CONTROL PLANE</span>
              <h2>动作开关</h2>
            </div>
          </header>
          <div class="auto-rows">
            <div class="auto-row">
              <div class="auto-row__label">
                <strong>建议模式</strong>
                <p>开启后关闭自动接受、自动选人和自动禁用</p>
              </div>
              <NSwitch :value="app.config.automation.advisoryMode" @update:value="setAdvisoryMode" />
            </div>
            <div class="auto-row">
              <div class="auto-row__label">
                <strong>自动接受</strong>
                <p>进入队列确认后通过 LCU 接受；开启时自动退出建议模式</p>
              </div>
              <NSwitch :value="app.config.automation.autoAccept" :disabled="!app.config.automation.enabled" @update:value="setAutoAction('autoAccept', $event)" />
            </div>
            <div class="auto-row auto-row--sub">
              <div class="auto-row__label">
                <strong>接受延迟</strong>
                <p>0 秒表示立即接受，最长 5 秒</p>
              </div>
              <div class="auto-delay-wrap">
                <NInputNumber
                  v-model:value="app.config.automation.autoAcceptDelaySeconds"
                  size="small" :min="0" :max="5" :step="1" :precision="0"
                  :disabled="!app.config.automation.enabled || !app.config.automation.autoAccept"
                />
                <span class="auto-delay-unit">秒</span>
              </div>
            </div>
            <div class="auto-row">
              <div class="auto-row__label">
                <strong>自动选人</strong>
                <p>默认先亮出英雄，再按延迟锁定；可切换为仅亮人或立即锁定</p>
              </div>
              <NSwitch :value="app.config.automation.autoPick" :disabled="!app.config.automation.enabled" @update:value="setAutoAction('autoPick', $event)" />
            </div>
            <div class="auto-row auto-row--sub">
              <div class="auto-row__label">
                <strong>选人策略</strong>
                <p>亮人后留出时间让客户端渲染并允许手动调整</p>
              </div>
              <div class="auto-delay-wrap">
                <NSelect v-model:value="app.config.automation.autoPickStrategy" size="small" :options="autoPickStrategyOptions" :disabled="!app.config.automation.enabled || !app.config.automation.autoPick" />
                <NInputNumber v-model:value="app.config.automation.autoPickDelaySeconds" size="small" :min="0" :max="10" :step="1" :precision="0" :disabled="!app.config.automation.enabled || !app.config.automation.autoPick || app.config.automation.autoPickStrategy !== 'show-and-lock-in'" />
                <span class="auto-delay-unit">秒</span>
              </div>
            </div>
            <div class="auto-row">
              <div class="auto-row__label">
                <strong>自动禁用</strong>
                <p>使用右侧候选顺序，并跳过已被禁用或选取的英雄</p>
              </div>
              <NSwitch :value="app.config.automation.autoBan" :disabled="!app.config.automation.enabled" @update:value="setAutoAction('autoBan', $event)" />
            </div>
          </div>
        </section>

        <!-- 英雄池卡片 -->
        <section class="auto-card" style="margin-top: 12px;">
          <header class="auto-card__head">
            <Sparkles :size="16" class="auto-card__icon" />
            <div>
              <span class="eyebrow">CHAMPION POOL</span>
              <h2>自动选人 / 自动禁用</h2>
            </div>
            <div class="champion-pool-stat">
              <strong>{{ championOptions.length }}</strong>
              <span>{{ champions.isFetching.value ? "刷新中" : "可用英雄" }}</span>
            </div>
          </header>

          <div class="champion-pool-body">
            <div class="champion-pool-section">
              <label class="pool-label">
                <span class="pool-label__title">自动选人候选</span>
                <small class="pool-label__hint">按顺序尝试；一号位不可用时继续尝试下一位</small>
              </label>
              <NSelect v-model:value="app.config.automation.pickChampionIds" multiple filterable :options="championOptions" placeholder="选择 1–3 个备选英雄" />
              <div class="champion-list">
                <article v-for="(id, index) in app.config.automation.pickChampionIds" :key="`pick-${id}`" class="champion-item">
                  <span class="champion-item__order">{{ index + 1 }}</span>
                  <AssetIcon kind="champion" :id="id" :name="championById.get(id)?.name ?? `英雄 #${id}`" :fallback-url="championById.get(id)?.iconUrl" size="md" />
                  <div class="champion-item__info">
                    <strong>{{ championById.get(id)?.name ?? `英雄 #${id}` }}</strong>
                    <small>{{ championById.get(id)?.alias ?? "LCU 目录" }} · 选人备选</small>
                  </div>
                  <button type="button" class="champion-item__remove" title="移除候选" @click="removeChampion('pick', id)"><Trash2 :size="13" /></button>
                </article>
                <p v-if="!app.config.automation.pickChampionIds.length" class="pool-empty">尚未设置选人候选</p>
              </div>
            </div>

            <div class="champion-pool-divider"></div>

            <div class="champion-pool-section">
              <label class="pool-label">
                <span class="pool-label__title">自动禁用候选</span>
                <small class="pool-label__hint">每次动作只提交一个仍可用的英雄</small>
              </label>
              <NSelect v-model:value="app.config.automation.banChampionIds" multiple filterable :options="championOptions" placeholder="选择多个禁用备选" />
              <div class="champion-list">
                <article v-for="(id, index) in app.config.automation.banChampionIds" :key="`ban-${id}`" class="champion-item">
                  <span class="champion-item__order champion-item__order--ban">{{ index + 1 }}</span>
                  <AssetIcon kind="champion" :id="id" :name="championById.get(id)?.name ?? `英雄 #${id}`" :fallback-url="championById.get(id)?.iconUrl" size="md" />
                  <div class="champion-item__info">
                    <strong>{{ championById.get(id)?.name ?? `英雄 #${id}` }}</strong>
                    <small>{{ championById.get(id)?.alias ?? "LCU 目录" }} · 禁用备选</small>
                  </div>
                  <button type="button" class="champion-item__remove" title="移除候选" @click="removeChampion('ban', id)"><Trash2 :size="13" /></button>
                </article>
                <p v-if="!app.config.automation.banChampionIds.length" class="pool-empty">尚未设置禁用候选</p>
              </div>
            </div>

            <p class="pool-note">英雄目录来自 LCU；无客户端时使用 Fixture / 缓存目录。选择顺序就是自动化规则的优先级，配置会立即保存。</p>
          </div>
        </section>
      </div>

    </div>

    <section class="panel shortcut-panel">
      <header class="panel-heading"><div><span class="eyebrow">SHORTCUTS</span><h2>快捷消息</h2><p class="panel-copy">快捷键由后台监听，不会抢占游戏按键，也不会把本应用切到前台。选人 / 准备阶段通过 LCU 聊天发送；游戏内直接向当前游戏窗口模拟键盘输入。模板修改后立即自动保存并生效。</p></div><NButton size="small" secondary @click="addShortcut"><template #icon><Keyboard :size="14" /></template>添加消息</NButton></header>
      <div v-if="app.shortcutRegistrationError" class="shortcut-diagnostic"><Keyboard :size="14" /><span>{{ app.shortcutRegistrationError }}</span></div>
      <div class="shortcut-settings"><label><span>多条消息间隔<small>默认 250ms；发送异常时可适当调高</small></span><NInputNumber v-model:value="app.config.automation.shortcutSendIntervalMs" :min="250" :max="5000" :step="50" size="small"><template #suffix>ms</template></NInputNumber></label><label><span>逐场战绩数量<small>仅影响 {recent_games}</small></span><NInputNumber v-model:value="app.config.automation.shortcutRecentGameCount" :min="1" :max="10" size="small"><template #suffix>场</template></NInputNumber></label></div>
      <div class="shortcut-field-guide"><div class="shortcut-debug__subhead"><strong>模板参数</strong><span>示例值只展示格式；生成预览读取当前真实对局</span></div><div class="placeholder-fields"><div v-for="field in placeholderFields" :key="field.key" class="placeholder-field"><span>{{ field.label }}</span><code>{{ "{" + field.key + "}" }}</code><small>{{ field.description }}</small><em>示例：{{ field.example }}</em></div></div></div>
      <div class="shortcut-list">
        <template v-for="(shortcut, index) in app.config.automation.shortcuts" :key="shortcut.id">
          <article class="shortcut-row">
            <div class="shortcut-row__identity"><NSwitch v-model:value="shortcut.enabled" size="small" /><strong>{{ shortcut.label }}</strong><small>{{ targetLabel(shortcut.target) }}</small></div>
            <NInput v-model:value="shortcut.label" size="small" placeholder="名称" />
            <button class="shortcut-recorder" :class="{ recording: recordingShortcutId === shortcut.id }" type="button" :title="recordingShortcutId === shortcut.id ? '取消录制' : '录制快捷键'" @click="startShortcutRecording(shortcut.id)"><Keyboard :size="13" /><span>{{ recordingShortcutId === shortcut.id ? "请按组合键…" : shortcut.key || "点击录制" }}</span></button>
            <NSelect v-model:value="shortcut.target" size="small" :options="targetOptions" />
            <label class="shortcut-template"><small>该快捷消息的发送模板</small><NInput v-model:value="shortcut.template" type="textarea" :autosize="{ minRows: 2, maxRows: 5 }" size="small" placeholder="消息模板；换行会拆成多条发送" /><span class="shortcut-template__example"><b>即时示例</b><code>{{ renderShortcutTemplateExample(shortcut.template).join("\n") || "空模板不会发送内容" }}</code></span></label>
            <div class="shortcut-actions">
              <button type="button" title="查看模板字段与最终输出" :class="{ active: debugShortcutId === shortcut.id }" @click="toggleShortcutDebug(shortcut.id)"><Braces :size="13" /></button>
              <button type="button" title="上移" :disabled="index === 0" @click="moveShortcut(index, -1)"><ArrowUp :size="13" /></button>
              <button type="button" title="下移" :disabled="index === app.config.automation.shortcuts.length - 1" @click="moveShortcut(index, 1)"><ArrowDown :size="13" /></button>
              <button type="button" title="删除" @click="removeShortcut(index)"><Trash2 :size="13" /></button>
            </div>
          </article>
          <div v-if="debugShortcutId === shortcut.id" class="shortcut-debug">
            <header class="shortcut-debug__heading"><div><span class="eyebrow">DEBUG OUTPUT · {{ shortcut.label }}</span><h3><Braces :size="14" />该快捷消息的最终输出</h3></div><NButton size="small" secondary :loading="debugRunningId === shortcut.id" @click="previewConfiguredShortcut(shortcut.id)"><template #icon><Play :size="13" /></template>生成预览</NButton></header>
            <p class="shortcut-debug__copy">下面的字段只会追加到“{{ shortcut.label }}”模板；预览也只生成这条快捷消息实际会发送的内容。</p>
            <div class="shortcut-debug__subhead"><strong>可选字段</strong><span>字段值来自当前对局、近期战绩与本地记录</span></div>
            <div class="placeholder-fields"><button v-for="field in placeholderFields" :key="field.key" type="button" :title="`${field.description}；示例：${field.example}`" @click="appendPlaceholder(shortcut.id, field.key)"><Plus :size="11" /><span>{{ field.label }}</span><code>{{ "{" + field.key + "}" }}</code><small>{{ field.description }}</small><em>示例：{{ field.example }}</em></button></div>
            <div class="shortcut-debug__subhead shortcut-debug__subhead--preview"><strong>模板即时示例</strong><span>使用上方示例值替换，不访问 LCU</span></div>
            <div class="shortcut-preview"><ol v-if="renderShortcutTemplateExample(shortcut.template).length"><li v-for="(line, lineIndex) in renderShortcutTemplateExample(shortcut.template)" :key="`example-${lineIndex}-${line}`"><span>{{ lineIndex + 1 }}</span><code>{{ line }}</code></li></ol><p v-else class="shortcut-preview__empty">空模板不会发送内容</p></div>
            <div class="shortcut-debug__subhead shortcut-debug__subhead--preview"><strong>最终发送内容</strong><span>每一行代表一次独立发送</span></div>
            <div class="shortcut-preview"><p v-if="debugErrors[shortcut.id]" class="shortcut-preview__error">{{ debugErrors[shortcut.id] }}</p><ol v-else-if="debugLines[shortcut.id]?.length"><li v-for="(line, lineIndex) in debugLines[shortcut.id]" :key="`${lineIndex}-${line}`"><span>{{ lineIndex + 1 }}</span><code>{{ line }}</code></li></ol><p v-else class="shortcut-preview__empty">尚未生成“{{ shortcut.label }}”的预览</p></div>
          </div>
        </template>
        <p v-if="!app.config.automation.shortcuts.length" class="candidate-empty">尚未配置快捷消息</p>
      </div>
    </section>

    <!-- 底部说明条 -->
    <footer class="auto-footer">
      <Bot :size="16" />
      <div>
        <strong>自动化边界</strong>
        <span>不读取游戏内存、不修改段位与在线状态。LCU 写操作全部保留在 Rust 层，建议模式默认优先。</span>
      </div>
    </footer>
  </div>
</template>

<style scoped>
.auto-page { max-width: 1400px; }

/* 主开关 */
.auto-master-toggle {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 16px 20px;
  margin-bottom: 12px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  transition: border-color 0.2s, background 0.2s;
}
.auto-master-toggle.is-on {
  border-color: color-mix(in srgb, var(--accent) 50%, var(--line));
  background: color-mix(in srgb, var(--accent-soft) 60%, var(--surface));
}
.auto-master-toggle__left {
  display: flex;
  align-items: center;
  gap: 14px;
}
.auto-master-toggle__icon {
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  border-radius: 8px;
  color: var(--accent);
  background: var(--accent-soft);
  flex: 0 0 40px;
}
.auto-master-toggle__left strong {
  display: block;
  font-size: 14px;
  font-weight: 600;
}
.auto-master-toggle__left p {
  margin: 3px 0 0;
  color: var(--text-secondary);
  font-size: 11px;
}

/* 运行状态 */
.auto-runtime-banner {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  padding: 10px 16px;
  margin-bottom: 12px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface-raised);
  font-size: 11px;
}
.auto-runtime-banner strong { display: block; font-size: 12px; color: var(--text-primary); margin-bottom: 2px; }
.auto-runtime-banner span { color: var(--text-secondary); }
.auto-runtime-banner[data-state="error"] { border-color: color-mix(in srgb, var(--red) 40%, var(--line)); background: var(--red-soft); }
.auto-runtime-banner[data-state="error"] strong { color: var(--red); }

/* 单列布局：动作开关 → 英雄池 → 快捷消息 依次从上到下排列 */
.auto-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 12px;
  align-items: start;
}
.auto-col { display: grid; gap: 0; }

/* 卡片 */
.auto-card {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
  overflow: hidden;
}
.auto-card__head {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 16px 18px 14px;
  border-bottom: 1px solid var(--line);
  background: var(--surface-muted);
}
.auto-card__head--between {
  align-items: center;
  justify-content: space-between;
}
.auto-card__head-left { display: flex; align-items: center; gap: 12px; }
.auto-card__icon {
  color: var(--accent);
  flex: 0 0 auto;
  margin-top: 1px;
}
.auto-card__head .eyebrow { display: block; margin-bottom: 2px; }
.auto-card__head h2 { margin: 0; font-size: 14px; font-weight: 600; letter-spacing: -0.01em; }

/* 动作行 */
.auto-rows { display: grid; }
.auto-row {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 13px 18px;
  border-bottom: 1px solid var(--line);
}
.auto-row:last-child { border-bottom: 0; }
.auto-row--sub { background: var(--surface-muted); }
.auto-row__label { flex: 1; min-width: 0; }
.auto-row__label strong { display: block; font-size: 13px; font-weight: 500; }
.auto-row__label p { margin: 3px 0 0; color: var(--text-secondary); font-size: 11px; }
.auto-delay-wrap { display: flex; align-items: center; gap: 8px; flex: 0 0 auto; }
.auto-delay-wrap .n-input-number { width: 110px; }
.auto-delay-unit { color: var(--text-secondary); font-size: 12px; }

/* 英雄池 */
.champion-pool-stat {
  margin-left: auto;
  text-align: right;
}
.champion-pool-stat strong { display: block; font-size: 22px; font-weight: 700; color: var(--accent); line-height: 1; }
.champion-pool-stat span { font-size: 10px; color: var(--text-secondary); }
.champion-pool-body { padding: 16px 18px; }
.champion-pool-section { display: grid; gap: 8px; }
.champion-pool-divider { border-top: 1px dashed var(--line); margin: 16px 0; }
.pool-label { display: grid; gap: 3px; }
.pool-label__title { font-size: 12px; font-weight: 500; color: var(--text-primary); }
.pool-label__hint { font-size: 11px; color: var(--text-secondary); }
.champion-list { display: grid; gap: 4px; }
.champion-item {
  display: grid;
  grid-template-columns: 22px 34px 1fr auto;
  align-items: center;
  gap: 10px;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--surface-raised);
}
.champion-item__order {
  display: grid;
  place-items: center;
  width: 20px;
  height: 20px;
  border-radius: 4px;
  color: var(--accent);
  background: var(--accent-soft);
  font-size: 11px;
  font-weight: 700;
}
.champion-item__order--ban {
  color: var(--red);
  background: var(--red-soft);
}
.champion-item__info { min-width: 0; }
.champion-item__info strong { display: block; font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.champion-item__info small { display: block; margin-top: 2px; color: var(--text-secondary); font-size: 10px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.champion-item__remove {
  display: grid;
  place-items: center;
  width: 26px;
  height: 26px;
  padding: 0;
  border: 1px solid var(--line);
  border-radius: 5px;
  color: var(--text-muted);
  background: transparent;
  cursor: pointer;
  transition: color 0.15s, border-color 0.15s, background 0.15s;
}
.champion-item__remove:hover { color: var(--red); border-color: var(--red); background: var(--red-soft); }
.pool-empty {
  padding: 12px;
  border: 1px dashed var(--line);
  border-radius: 6px;
  color: var(--text-muted);
  font-size: 11px;
  text-align: center;
}
.pool-note { margin: 12px 0 0; color: var(--text-muted); font-size: 11px; line-height: 1.5; }

.shortcut-panel { margin-top: 9px; }
.shortcut-panel .panel-heading { align-items: center; }
.shortcut-panel .panel-copy { margin: 4px 0 0; }
.shortcut-diagnostic { display: flex; align-items: flex-start; gap: 7px; padding: 9px 14px; border-bottom: 1px solid color-mix(in srgb, var(--amber) 40%, var(--line)); color: var(--amber); background: var(--amber-soft); font-size: 9px; line-height: 1.45; }
.shortcut-diagnostic svg { flex: none; }
.shortcut-settings { display: flex; gap: 18px; padding: 10px 14px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.shortcut-settings label { display: flex; align-items: center; gap: 8px; color: var(--text-secondary); font-size: 10px; }
.shortcut-settings label > span { display: grid; gap: 2px; }.shortcut-settings label > span small { color: var(--text-muted); font-size: 8px; }
.shortcut-settings .n-input-number { width: 132px; }
.shortcut-field-guide { padding: 5px 14px 12px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.shortcut-help { display: flex; flex-wrap: wrap; gap: 4px; padding: 10px 14px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.shortcut-help code { padding: 3px 5px; border: 1px solid var(--line); border-radius: 3px; color: var(--accent); background: var(--surface); font: 9px ui-monospace, SFMono-Regular, Menlo, monospace; }
.shortcut-list { display: grid; }
.shortcut-row { display: grid; grid-template-columns: minmax(125px, .85fr) minmax(100px, .7fr) minmax(170px, 1fr) 115px minmax(220px, 1.7fr) auto; align-items: center; gap: 6px; min-height: 68px; padding: 7px 14px; border-bottom: 1px solid var(--line); }
.shortcut-row:last-of-type { border-bottom: 0; }
.shortcut-row__identity { display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: center; gap: 6px; min-width: 0; }
.shortcut-row__identity strong, .shortcut-row__identity small { grid-column: 2; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.shortcut-row__identity strong { font-size: 10px; }
.shortcut-row__identity small { color: var(--text-secondary); font-size: 8px; }
.shortcut-row__identity .n-switch { grid-row: span 2; }
.shortcut-actions { display: flex; gap: 3px; }
.candidate-remove, .shortcut-actions button { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 1px solid var(--line); border-radius: 3px; color: var(--text-muted); background: transparent; cursor: pointer; }
.candidate-remove:hover, .shortcut-actions button:hover:not(:disabled), .shortcut-actions button.active { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }
.shortcut-actions button:disabled { cursor: not-allowed; opacity: .3; }
.shortcut-actions button:last-child:hover { color: var(--red); }
.shortcut-recorder { display: flex; align-items: center; gap: 6px; width: 100%; min-width: 0; height: 28px; padding: 0 9px; border: 1px solid var(--line); border-radius: 3px; color: var(--text-secondary); background: var(--surface); cursor: pointer; }
.shortcut-recorder:hover, .shortcut-recorder.recording { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }
.shortcut-recorder svg { flex: none; }.shortcut-recorder span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.shortcut-template { display: grid; gap: 3px; min-width: 0; }.shortcut-template > small { color: var(--text-muted); font-size: 8px; }
.shortcut-template__example { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px; min-width: 0; padding: 4px 6px; border: 1px solid var(--line); border-radius: 3px; background: var(--surface-muted); font-size: 8px; }.shortcut-template__example b { color: var(--text-muted); font-weight: 500; }.shortcut-template__example code { overflow: hidden; color: var(--text-secondary); text-overflow: ellipsis; white-space: pre-wrap; }
.candidate-empty { margin: 7px 0 0; padding: 9px; color: var(--text-muted); border: 1px dashed var(--line); font-size: 10px; text-align: center; }
.shortcut-debug { padding: 14px; border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.shortcut-debug__heading, .shortcut-debug__actions { display: flex; align-items: center; gap: 8px; }
.shortcut-debug__heading { justify-content: space-between; margin-bottom: 10px; }.shortcut-debug__heading h3 { display: flex; align-items: center; gap: 6px; margin: 2px 0 0; font-size: 12px; }
.shortcut-debug__copy { margin: -2px 0 10px; color: var(--text-secondary); font-size: 9px; line-height: 1.55; }
.shortcut-debug__subhead { display: flex; justify-content: space-between; gap: 10px; margin: 8px 0 6px; color: var(--text-muted); font-size: 9px; }.shortcut-debug__subhead strong { color: var(--text-primary); font-size: 10px; }.shortcut-debug__subhead--preview { margin-top: 11px; }
.placeholder-fields { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 5px; }
.placeholder-fields button { display: grid; grid-template-columns: auto auto 1fr; align-items: center; gap: 5px; min-width: 0; padding: 6px 7px; border: 1px solid var(--line); border-radius: 4px; color: var(--text-secondary); background: var(--surface); text-align: left; cursor: pointer; }
.placeholder-field { display: grid; grid-template-columns: auto 1fr; gap: 4px 7px; min-width: 0; padding: 7px; border: 1px solid var(--line); border-radius: 4px; background: var(--surface); }.placeholder-field > span { color: var(--text-secondary); font-size: 9px; }.placeholder-field code { justify-self: end; color: var(--accent); font-size: 8px; }.placeholder-field small, .placeholder-field em { grid-column: 1 / -1; color: var(--text-muted); font-size: 8px; font-style: normal; line-height: 1.35; }.placeholder-field em { color: var(--text-secondary); }
.placeholder-fields button:hover:not(:disabled) { color: var(--accent); border-color: var(--accent); background: var(--accent-soft); }.placeholder-fields button:disabled { cursor: not-allowed; opacity: .45; }.placeholder-fields code { justify-self: end; color: var(--accent); font-size: 8px; }
.placeholder-fields small { grid-column: 1 / -1; overflow: hidden; color: var(--text-muted); font-size: 8px; text-overflow: ellipsis; white-space: nowrap; }
.placeholder-fields button em { grid-column: 1 / -1; overflow: hidden; color: var(--text-secondary); font-size: 8px; font-style: normal; text-overflow: ellipsis; white-space: nowrap; }
.shortcut-preview { min-height: 48px; margin-top: 9px; padding: 8px; border: 1px solid var(--line); border-radius: 4px; background: var(--surface); }.shortcut-preview ol { display: grid; gap: 5px; padding: 0; margin: 0; list-style: none; }
.shortcut-preview li { display: grid; grid-template-columns: 22px minmax(0, 1fr); align-items: start; gap: 7px; }.shortcut-preview li > span { display: grid; place-items: center; width: 20px; height: 20px; color: var(--text-muted); background: var(--surface-muted); font-size: 8px; }
.shortcut-preview code { overflow-wrap: anywhere; color: var(--text-primary); font: 9px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }.shortcut-preview__empty, .shortcut-preview__error { margin: 5px; font-size: 9px; }.shortcut-preview__empty { color: var(--text-muted); }.shortcut-preview__error { color: var(--red); }

/* 底部 */
.auto-footer {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  margin-top: 16px;
  padding: 13px 16px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface-muted);
  color: var(--text-secondary);
  font-size: 11px;
}
.auto-footer svg { flex: 0 0 auto; margin-top: 1px; color: var(--accent); }
.auto-footer strong { display: block; margin-bottom: 3px; font-size: 12px; font-weight: 500; color: var(--text-primary); }
@media (max-width: 1100px) { .shortcut-row { grid-template-columns: 1fr 1fr; }.shortcut-row__identity, .shortcut-template { grid-column: 1 / -1; }.shortcut-actions { justify-content: flex-start; }.shortcut-debug__heading { align-items: flex-start; flex-direction: column; } }
</style>
