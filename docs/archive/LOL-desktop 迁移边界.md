# LOL-desktop 迁移边界

## 结论

`LOL-desktop-native` 继续使用 Native SDK + Zig，不引入 Electron。目标是让发布包保持小，
并让日常增量编译只重编译修改过的 Zig 模块。

当前 Native 版本已经完成宿主、bridge、LCU transport、SQLite，以及自动化、事件和 Windows
输入平台模块的拆分，并注册前端现有的全部 `lol.*` 调用。配置、LCU lockfile/HTTPS 查询、
账号、腾讯 SGP 战绩、英雄/资源、导出、快捷消息和自动化由 Zig handler 提供；没有运行中的
LCU 时返回结构化错误，不会把 Fixture 当作实时数据。事件采用 Native bridge REST polling，
LCU token 不进入 WebView。

首页账号/战绩/资源、champ-select 逐玩家段位/近期战绩/评分、active game 的 2999 Live Client
Data、spectator roster、跨阶段同局快照保留与单 exe 发布均已迁移。对局源会在 gameflow 短暂为
`Lobby`/`None` 时继续短超时探测，避免游戏启动后阵容被清空。WebSocket 模块目前提供协议解析；
Native SDK 的 Windows host 没有 WebSocket transport，因此生产运行使用 REST 变更轮询：普通
状态为 1 秒，开启自动接受/选人/禁用后为 250ms。这是请求模型差异，不是业务字段降级。

Windows 初始窗口尺寸也按 Rust 配置的逻辑像素语义处理：`app.json` 仍只声明一次
`1440x900`，Zig 在主 HWND 出现后按显示器 DPI 换算客户区物理尺寸。125% DPI 下目标客户区
为 `1800x1125`，不会再退化成逻辑 `1152x720`。窗口、窗口类、任务栏和 EXE 资源统一使用
`assets/icon.ico`；启动阶段短时重试覆盖 Native SDK 创建 HWND 晚于 `app.start` 的时序。

## 分层

| 能力 | 归属 | 说明 |
| --- | --- | --- |
| Vue 页面、路由、状态展示、格式化 | `frontend/` TypeScript | 可在浏览器 fixture 模式独立测试 |
| LCU lockfile/进程发现、HTTPS、事件轮询 | Zig | token 只在原生层；Windows 进程 API 放平台模块 |
| LCU DTO 映射、对局分析、数据合并 | Zig | champ-select、active game、spectator、多源缓存与玩家近期战绩已落地 |
| SQLite snapshots、配置文件和历史降级缓存 | Zig | 数据目录由 `config/native.json` 的 `dataDirName` 决定；不依赖项目环境变量 |
| 快捷键、输入模拟、窗口/进程控制 | Native SDK/Zig | manifest 默认全局快捷键；Windows 游戏内消息使用原生 `SendInput` |
| bridge | Native SDK | 每个 `lol.*` 命令都要有 manifest policy、Zig handler 和测试 |

## WebView2 限制

WebView2 是渲染器，不是 Node.js 运行时。页面脚本不能直接使用 `fs`、`child_process`、进程
枚举、全局键盘钩子或 Windows 输入 API。LCU 使用本地自签名 HTTPS，浏览器页面的 origin/CORS
和证书校验也不适合作为直接客户端。页面只能调用 `window.zero.invoke()`，由 Zig handler
执行受权限控制的操作并返回 JSON。

## LeagueAkari 的复用策略

可以复用它的 LCU endpoint、WebSocket 事件订阅、DTO 命名和缓存失效策略；这些属于协议和业务
知识，与 Electron 无关。不要直接复制它的 Electron main/preload、TypeORM 或 Node native
addon。迁移时先写 Zig 版本的纯解析/映射测试，再接入 Native bridge，这样能保持编译快速并
避免把 Node 运行时带进发布包。

## 已落地的桥接能力

1. `get_config`、`save_config`、`set_data_mode`：配置文件和 SQLite snapshots 双写/恢复。
2. `refresh_connection`：LCU lockfile/进程发现、loopback HTTPS、真实账号/段位/大区；`get_live_lobby` 和 `get_live_roster` 覆盖 champ-select、2999 active game、spectator 与跨阶段快照保留。
3. `get_match_history`、`get_champions`、`get_asset`：LCU 数据源、分页和前端 DTO 映射，带 SQLite 缓存。
   对局历史在 LCU 为空或失败时回退腾讯 SGP；英雄统计兼容 OP.GG raw/normalized、
   snake_case/camelCase、位置别名和主位置字段，空响应不会覆盖有效缓存。
4. `get_encounters`、`get_bp_history`、导出命令：SQLite snapshots 优先，JSON 文件兼容旧数据；
   用户可见 DTO 与 Rust 页面一致，底层使用通用 snapshot 表而不是复制 Rust 的关系表结构。
5. 快捷键、快捷消息、准备检查、自动选人/禁用：动态全局快捷键、LCU chat/action API、全局 polling 调度和 Windows 原生输入已落地；打开对局速看直接显示并聚焦 Native 主窗口。

## 对局实现对照

| Rust 行为 | Native 对应实现 |
| --- | --- |
| ChampSelect 完整十人阵容 | champ-select session + current summoner 定向，逐玩家 enrichment |
| 游戏开始后继续显示阵容 | 2999 Live Client Data、gameflow session、spectator metadata 多源选择 |
| LCU 战绩缺失时仍显示十局 | 腾讯 SGP entitlement 回退，并写入玩家历史缓存 |
| 阶段切换不清空数据 | ChampSelect -> GameStart/InProgress 同局快照交接；快速阵容只覆盖动态字段 |
| 游戏类型中文显示 | `queueId` 优先映射；`CLASS`、`CLASSIC`、`League of Legends` 仅作后备值 |
| 最近一局、BP、开黑与评分 | 最近完整比赛保留，BP/队伍摘要/开黑关系随 enrichment 合并 |

真实运行快照已验证 `InProgress`、队列 `440`（灵活排位）、双方各五人、十名玩家均有最近
十局且 `recentMatch` 存在。bridge 单次响应约 250 KiB，低于 Native 1 MiB 上限。

## 有意保留的实现差异

1. Rust 直接消费 LCU WebSocket；当前 Native SDK Windows host 未提供该 transport，因此 Zig 使用
   250ms/1s REST 变更轮询，并把事件转换为同一前端刷新语义。
2. Rust 的 encounters/BP 使用专用关系表；Native 使用 SQLite `snapshots` 通用表，但返回的
   前端 DTO、排序、历史回退和导出行为一致。
3. Rust 使用 Tauri updater 插件；Native 的 `check_update` 请求 `config/native.json` 中的发布
   元数据 URL。目前两个前端都只显示检查结果，不在页面内静默安装。
