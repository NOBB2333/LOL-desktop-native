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

需要 Node.js 24.15.0（见 `.node-version`）、npm/pnpm、Zig 0.16 和 Native SDK CLI。若 SDK 安装在全局目录，Zig 命令需要显式传入 `-Dnative-sdk-path=<SDK路径>`；默认路径是项目内的 `node_modules/@native-sdk/cli`。

```sh
npm install --prefix frontend
npm run build --prefix frontend
npm run typecheck --prefix frontend
npm test --prefix frontend
native check . --strict
zig build test -Dplatform=null
```

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

改造状态、实测边界和本轮分发产物见 [改造结果与验收方案](docs/IMPROVEMENT_PLAN.md)。

## Bridge 约定

前端统一通过 `frontend/src/services/native.ts` 调用 `window.zero`。业务命令使用
`lol.<operation>` 命名空间，事件使用 `window.zero.on(name, callback)`。命令必须同时在
`src/main.zig` 注册 handler、在 `app.json` 的 `bridge.commands` 中声明，并绑定精确 origin。

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
`%LOCALAPPDATA%/lol-desktop-native/runtime/2.0.0`），因此 exe 不依赖旁边的
`resources/frontend/dist` 或 DLL。若需要查看 Native SDK 的原始 staging 目录，使用
`scripts/build.ps1 -NoArchive`（或 `scripts/build.sh --no-archive`）；此模式不会删除
`bin/`、`resources/` 等调试文件。

Windows 默认启用 `windows.requireAdministrator`，与 Rust 版 Release 行为一致，确保游戏以管理员权限运行时 `SendInput` 不会被系统拦截。关闭该配置可以免除 UAC，但此时游戏内快捷发送可能不可用。

Windows 发布前必须在 Windows 主机验证 WebView2、LCU 本地 HTTPS、WebSocket、全局快捷键和
输入模拟。Native SDK 当前为 pre-1.0，升级 SDK 时需要重新执行 `native check` 和完整集成测试。
