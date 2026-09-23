# LOL-desktop-native

基于 [Native SDK](https://github.com/vercel-labs/native) 的《桌上英雄联盟》桌面版迁移工程。
项目复用现有 Vue 3 界面，通过 Native SDK WebView 运行；Zig 负责原生宿主和受权限控制的系统能力。

## 当前状态

- Vue 页面、路由、组件、样式、fixtures 和前端测试已从 `LOL-desktop` 迁移。
- Native SDK manifest 已切换到 `com.nobb2333.lol-desktop-native`，目标为 Windows 10/11、macOS 和 Linux。
- Vite 使用相对资源路径、压缩构建和稳定的 `frontend/dist` 输出目录。
- Native bridge 已覆盖前端调用的 `lol.*` 命令面，使用 `window.zero.invoke()`，并限制为应用和本地开发 origin。
- Zig 已按 `main` 宿主、`bridge` policy、`backend` runtime/handler、`backend/automation`、`backend/events`、`backend/input`、`lcu` transport/credentials 和 `storage` 拆分；运行时配置和数据保存到 Native SDK 解析出的当前用户应用数据目录。
- 本工程明确不引入 Electron：LCU lockfile 发现、loopback HTTPS、DTO 转换、查询轮询和自动化动作都在 Zig 原生层，Vue 只负责界面和交互。
- Native bridge 已覆盖配置、连接、实时会话、历史、英雄目录、资源、导出、快捷消息和自动化命令；没有 LCU 进程时返回可解释的 `LcuNotRunning`，不会把 Fixture 当作实时数据。
- LCU 凭据支持 `LeagueClientUx.exe` 命令行和 lockfile 发现；REST 使用 loopback HTTPS。应用级轮询持续观察 gameflow、champ-select、lobby、ready-check 和 spectator 资源，不要求停留在对局页面。
- SQLite snapshots 用于配置、已有战绩/英雄缓存和 BP 数据；玩家缓存按账号和大区隔离。“遇到过”从已有战绩派生，不限制最近一年，不新增长期玩家档案，旧相遇归档退出运行时读写。
- 状态、阵容、查询和动作使用独立原生通道，玩家资料最多四名同时加载并逐名发布。Windows HTTP 支持来源配额、总超时和取消，排队消息跨会话自动失效。
- Windows manifest shortcut 提供默认全局快捷键，页面监听配置文件中的自定义组合键；快捷消息在英雄选择阶段通过 LCU chat API 发送，游戏内阶段由 Zig 直接调用 Windows `SendInput` 发送 Unicode 键盘事件，不启动 PowerShell也不改写剪贴板。

## 开发

需要 Node.js 24.15.0（见 `.node-version`）、**pnpm 12**（前端依赖只能用 pnpm，见下）、Zig 0.16 和 Native SDK CLI。若 SDK 安装在全局目录，Zig 命令需要显式传入 `-Dnative-sdk-path=<SDK路径>`；默认路径是项目内的 `node_modules/@native-sdk/cli`。

常用入口统一收在仓库根的 `package.json`（对齐 `vercel-labs/native` 模板的脚本面），前端细节由脚本转发到 `frontend/`：

| 命令 | 用途 |
|---|---|
| `pnpm run check:static` | 版本 + 命令面 + lint + `vue-tsc`，秒级，适合提交前 |
| `pnpm run check` | `check:static` + 后端测试 + 前端测试 |
| `pnpm run test` | 后端测试（`zig build test`） |
| `pnpm run test:sandbox` | 后端测试的沙箱替代路径（`scripts/run-backend-tests.sh`） |
| `pnpm run frontend:build` | 构建前端 |
| `pnpm run frontend:dev` | 只起 Vite；浏览器预览自动走 fixture |
| `pnpm run frontend:test` | 前端测试（沙箱内改用 `frontend:test:sandbox`） |
| `pnpm run lint` | 前端 oxlint |
| `pnpm run format` / `format:check` | 前端 oxfmt + `zig fmt`（见下） |
| `pnpm run version:set 2.1.0` | 改版本并同步全部派生字段 |
| `pnpm run version:check` | 校验 `app.json.version` 与派生字段一致 |
| `pnpm run bridge:check` | 校验 `app.json` ↔ Zig 命令表 ↔ 前端调度器一致 |
| `pnpm run native:check` | `native check . --strict` |

> `format:check` **故意不在** `check` 里：仓库目前 CRLF/LF 混用，`zig fmt --check` 会把
> 一批本来就符合 Zig 风格、只是行尾为 CRLF 的文件判为「需格式化」，`oxfmt --check` 也会
> 报 90+ 个既有文件。要启用这道门之前，先单独跑一次 `pnpm run format` 并作为一次纯格式提交。

> 前端依赖**必须**用 pnpm：仓库提交的是 `frontend/pnpm-lock.yaml`。
> 用 `npm install --prefix frontend` 会把仓库根的 `package.json`（它只为
> `build.zig` 提供 `@native-sdk/cli`）以 `"lol-desktop-native-root": "file:.."`
> 写进 `frontend/package.json`，每次安装都会重新出现。

启动 Native WebView 壳和 Vite：

```sh
zig build dev -Dplatform=windows
```

本机没有 Windows SDK 时，可以先用无窗口平台验证构建图：

```sh
zig build -Dplatform=null
```

Native SDK 路径、开发端口、LCU 常规/2999 探测超时、证书策略、版本检查地址、Windows 管理员权限和打包目标优先读取 `config/native.json`，也可以显式传入
`-Dnative-sdk-path=...`。应用运行时不依赖项目自定义环境变量。
`scripts/build.*` 会先根据该文件同步 `app.json` 的开发 URL 和 origin，端口只需修改一处。

受控网络验证使用 `node scripts/verify-network.mjs -Dnative-sdk-path=<SDK路径>`；只读客户端验证使用 `zig build verify-runtime -Dplatform=null -Dnative-sdk-path=<SDK路径>`。后者仅在内存中缓存读取结果，不发送聊天或执行自动化。

本轮改造（版本单一源、命令面一致性防线、脚本面统一）与后续计划见 [改造方案](docs/REFACTOR_PLAN_2026-09-22.md)；上一轮后端竖切的进度见 [架构评估 2026-09-13](docs/ARCHITECTURE_REVIEW_2026-09-13.md)。

**能力边界**：哪些功能明确不做、为什么不做，见 [明确不做的功能](docs/NOT_PLANNED_2026-09-24.md)。这份文档同时标出了每条的可扩展落点——不做的原因是产品取向，不是做不到。

**对局时间线（赛事级）**的可行性调研、数据源证据与分阶段方案见 [时间线调研 2026-09-24](docs/MATCH_TIMELINE_RESEARCH_2026-09-24.md)。核心结论：现在读的本地接口**没有**伤害数据，「某一波团战的输出」必须换到 SGP 的 `DETAILS`；而换源之前必须先抓一份真实样本。

## 版本与命令面

- **应用版本只有一个手工维护来源：`app.json` 的 `version`。**
  Zig 侧（`main.zig` / `backend.zig`）通过 `build.zig` 生成的 `app_manifest_zon` 读取，
  前端 fixture 之外不再有源码副本。改版本用 `pnpm run version:set <SemVer>`，
  它会同步根/前端 `package.json`、`package-lock.json`、`build.zig.zon` 和浏览器预览 fixture；
  `pnpm run version:check` 会一并断言 `src/` 下没有硬编码的当前版本字面量。
- **命令面只有一个 Zig 真相来源：`src/backend.zig` 的 `command_table`。**
  每个命令的名字和并发通道写在同一行，`command_names`、`commandLane()`、bridge policy 和
  后端测试都从它派生。新增命令的顺序是：加 `command_table` 一行 → 在 `app.json` 的
  `bridge.commands` 声明 → 补前端 `services/native.ts` 适配函数与调度通道。
  `pnpm run bridge:check` 会校验 `app.json` ↔ Zig 命令表 ↔ 前端调度器三者一致。
  （2026-09-22 之前这里没有防线，`lol.get_jungle_path`、`lol.search_summoner`、
  `lol.get_player_tags`、`lol.update_player_tag` 四条命令在 Zig 注册了但清单一直没声明。）

## Bridge 约定

前端统一通过 `frontend/src/services/native.ts` 调用 `window.zero`。业务命令使用
`lol.<operation>` 命名空间，事件使用 `window.zero.on(name, callback)`。命令必须同时在
`src/backend.zig` 的 `command_table` 注册 handler、在 `app.json` 的 `bridge.commands` 中声明，
并绑定精确 origin；三者的一致性由 `pnpm run bridge:check` 守住。

LCU token、lockfile、SQLite 连接和 Windows 输入模拟永远不进入 Vue 页面。WebView2 页面没有
`fs`、进程枚举、全局键盘钩子或可绕过 LCU 自签名证书校验的网络权限，因此不能把这些逻辑
直接放进 Vue/浏览器 `fetch`；它们必须由 Zig bridge 处理。

## 数据目录

数据目录名称由 `config/native.json` 的 `dataDirName` 决定，不跟随 exe 的启动工作目录。Windows 默认数据根目录为
`%LOCALAPPDATA%\lol-desktop-native\Data`；配置、SQLite 数据库、导出和历史降级文件都位于该目录。
WebView2 用户数据位于 `%LOCALAPPDATA%\lol-desktop-native\Cache\WebView2`，不会在 exe 旁生成运行目录。
Native SDK 的 schema migration 与应用自己的 snapshots 表并行维护。

## 打包

```sh
zig build package -Dpackage-target=windows
native doctor --strict
```

也可以直接双击 `scripts/build.cmd`（macOS/Linux 使用 `scripts/build.sh`），脚本会构建前端和
ReleaseFast Native binary。默认配置的最终产物是：

```text
zig-out/package/lol-desktop-native.exe
```

这是可直接分发的单个 exe：前端 `dist`、Fixture 图标和 Windows `WebView2Loader.dll` 都已
嵌入二进制。首次启动会自动解包到当前用户的运行缓存目录（Windows 为
`%LOCALAPPDATA%/lol-desktop-native/runtime/<应用版本>-<内容哈希>`，两者都由构建期注入），因此 exe 不依赖旁边的
`resources/frontend/dist` 或 DLL。若需要查看 Native SDK 的原始 staging 目录，使用
`scripts/build.ps1 -NoArchive`（或 `scripts/build.sh --no-archive`）；此模式不会删除
`bin/`、`resources/` 等调试文件。

Windows 默认启用 `windows.requireAdministrator`，与 Rust 版 Release 行为一致，确保游戏以管理员权限运行时 `SendInput` 不会被系统拦截。关闭该配置可以免除 UAC，但此时游戏内快捷发送可能不可用。

Windows 发布前必须在 Windows 主机验证 WebView2、LCU 本地 HTTPS、WebSocket、全局快捷键和
输入模拟。Native SDK 当前为 pre-1.0，升级 SDK 时需要重新执行 `native check` 和完整集成测试。
