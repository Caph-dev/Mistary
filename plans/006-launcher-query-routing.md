# 计划 006：加入应用别名、网页关键字与独立结果类型

## 状态

- 状态：待执行。
- P2；工作量 M；风险中；阶段 M2；硬依赖：003-search-session-actions.md 的执行器/代次。004 的收藏候选为集成输入，可后接；005 对话框能力不是硬依赖。
- 规划于：commit `6c024bbbf6b917c4a334f4569de070d887ecd66f`；2026-10-10。
- 本文件是实施规格，不是已实现/已测试报告。

## 执行约定

- 部署目标 macOS 14、Apple 芯片；Swift 5 语言模式、Swift tools 5.10、系统框架，不引入第三方包。
- 保留 COilFind、OilFindCore、OilFindApp、OilFind target；核心不依赖 AppKit，公开应用库不依赖私有模块。
- 不在扫描、搜索和事件热路径逐项创建 String 或堆分配；持索引读锁期间不做文件 I/O。
- 注释用英文，界面文案维护 L10n.swift 中英文对应项；复用现有 Theme 和控件。
- UI 单测参照 Tests/OilFindUITests/ResultsSelectionTests.swift：XCTest、@testable import OilFindApp、临时目录、Scanner 与 snapshot 控制器。用可注入接口测试副作用。
- 调试 --snapshot 只验证本应用界面，不能证明其他应用的 AX 兼容性；正式版不得包含新增探针。
- 先读 AGENTS.md 与 docs/ARCHITECTURE.md。不修改 site/、Pro/、许可证、无关改动或索引格式。
- 不自动安装、卸载、创建签名证书、操作真实用户文件或提交 Git；这些需要实施任务中的相应授权。不得打印或写入凭据。

## Git 与漂移检查

开始时查看 git status --short，保留已有改动。用下述命令查看范围内相对基底的变化，并核对本计划摘录。前置计划造成的变化是预期输入；验证其交付契约后记录实际 SHA，再开始。非前置变化影响关键假设时先报告，不按旧摘录强行覆盖。

不自动切分支、commit 或 push。仅在操作者授权实施后，于个人开发分支执行。本计划完成后只更新 plans/README.md 对应状态及证据位置。

## 验证规则

本文件中的实施命令本轮尚未运行。新测试类和证据文件均为待创建，不代表当前已存在。每条测试命令必须 exit 0、匹配到预期测试且全部通过；零测试不算通过。每步失败先报告关键错误，同类失败两次后咨询 advisor 或操作者，再调整方案。

使用 OILFIND_FREE=1 运行 Swift 验证。每个逻辑步骤后完成最窄检查；阶段末执行 OILFIND_FREE=1 swift build -c release。完成标准还包括：git diff --check 无空白错误，git status --short 中实现改动均属于列出的范围（以及本计划的状态/证据记录）。

```sh
git status --short
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/QueryRouter.swift Sources/OilFindApp/PaletteItem.swift Sources/OilFindApp/LauncherPreferences.swift Sources/OilFindApp/SearchSession.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/ResultsView.swift Sources/OilFindApp/SearchPresentation.swift Sources/OilFindApp/ActionExecutor.swift Sources/OilFindApp/IconProvider.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/L10n.swift Tests/OilFindUITests/QueryRouterTests.swift Tests/OilFindUITests/PaletteResultsTests.swift
```

## 范围清单

- `Sources/OilFindApp/QueryRouter.swift（新建）`
- `Sources/OilFindApp/PaletteItem.swift（新建）`
- `Sources/OilFindApp/LauncherPreferences.swift（新建）`
- `Sources/OilFindApp/SearchSession.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/ResultsView.swift`
- `Sources/OilFindApp/SearchPresentation.swift`
- `Sources/OilFindApp/ActionExecutor.swift`
- `Sources/OilFindApp/IconProvider.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/L10n.swift`
- `Tests/OilFindUITests/QueryRouterTests.swift（新建）`
- `Tests/OilFindUITests/PaletteResultsTests.swift（新建）`

## 为什么重要

应用启动和网页关键字可以复用搜索入口，但它们不是索引文件命中。需要应用层结果模型与明确命令路由，避免伪造 entryID、误吞文件查询或让旧异步搜索盖掉命令结果。

## 当前状态与证据

Sources/OilFindApp/SupplementarySearch.swift 的补充命中：

~~~swift
public let sourceID: String
public let entryID: UInt32
~~~

其协议只承载捕获来源中的条目。ResultsView.swift 的 ResultItem 强制包含 id、source、name/parentPath/path。当前应用已索引 .app（kind=2），无需先增加独立应用发现服务。SearchPresentation保留文件快照、来源和排序计数，不能因换结果模型丢掉它。

## 前置交付与结果契约

003 提供 query/session代次、不可变ActionRequest和accepted/verified结果。004若完成则可接入其收藏；未完成时基础实现只引用003与本计划类型，不导入004的FavoritesStore/DirectoryCandidates，不运行其测试。应用别名/网页功能仍可独立用，不用空收藏占位。005若已完成，保留对话框模式；未完成不引用其DialogAdapter，只沿用003模式契约。应用/网页命令要求用户显式切到普通/应用模式，不能在Save场景默默替换目录动作。

新增 PaletteItem 枚举或等价类型：file保存 SearchPresentation 行/来源快照；application保存应用URL与可用bundle标识；web保存已编码URL；后续声明式动作保留专用case。每种类型给显示文案、可用动作和稳定选择身份，不编造日期/大小/文件路径字段。

别名只扫描用户配置的小集合与 .app 命中；默认不全文件模糊匹配别名。配置使用应用URL，bundleID用于辅助识别；同bundle不同安装路径保留区别，去重按规范应用URL。缺失应用显示失效，不启动同bundle另一位置的应用替代。

QueryRouter在 Query.parse 前仅识别已注册关键字和空格分隔：g 后跟查询、wiki 后跟查询；明确展示“网页搜索”模式与目标。裸g仍可文件搜索；keyword+空白无内容显示等待输入，不打开空网页。trim、中文、引号、#、&、%按URL参数编码；没有远程建议请求。

注册关键字会与同前缀文件名存在冲突，提供显式“按文件搜索原输入”动作。命令显示当前解析模式，保存对话框默认只目录并不自动路由web。高级文件语法、粘贴路径、regex等仍完整走原 Query。

## 范围

仅上方文件。SupplementarySearch.swift、核心Query/索引/C保持不变；禁止为web/app新建假来源。范围外：全文、在线应用商店搜索、全盘模糊别名、插件平台、浏览器历史、终端命令执行。

## 步骤与验证

### 1. 实施路由和配置

先为裸关键字、空参数、中文URL编码、前缀冲突、regex/path原输入、Save模式与marked text写测试。配置存 Mistary 数据域，坏配置有可恢复错误；用户录入app通过系统选择器验证URL。

验证：OILFIND_FREE=1 swift test --filter QueryRouterTests。预期：完整关键字才路由，普通文件语法字节/语义不变，输入法组合期间不提前执行。

### 2. 增加结果类型并接入行与选择

文件case尽量包装原快照，保留来源校验/补充说明/图标。新行按类型显示，无意义列留空；拖动/Quick Look只对file/app允许的情况开放。命令切换使旧file query generation失效。

验证：OILFIND_FREE=1 swift test --filter PaletteResultsTests；OILFIND_FREE=1 swift test --filter ResultsSelectionTests；OILFIND_FREE=1 swift test --filter ResultRefreshTests。预期：去重正确，选择稳定，旧异步结果不覆盖web/app，文件动作不作用于webURL。

### 3. 接入应用启动、网页打开和设置

使用系统应用/URL API，启动请求accepted不表示app已完成启动。动作显示实际应用路径或搜索引擎。扩展ActionExecutor的新类型分派，不绕过query/session token。复制/预览只按该类型允许的动作提供。

验证：OILFIND_FREE=1 swift test --filter QueryRouterTests；OILFIND_FREE=1 swift test --filter ActionExecutorTests；OILFIND_FREE=1 swift test --filter SearchEditingTests。预期：调用参数符合类型，普通编辑优先，缺失app、无效URL与过期代次失败可见。

### 4. 回归构建与集成

验证：OILFIND_FREE=1 swift build -c release；python3 Tests/Scripts/test_open_core.py；git diff --check。预期：公开模块边界通过，默认全盘文件搜索不变。若004/005已完成，另运行FinderContextTests/DialogWorkflowTests，记录是否集成，不把未完成依赖写成测试通过。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `QueryRouterTests`、`PaletteResultsTests`、`ResultsSelectionTests`、`ResultRefreshTests`、`ActionExecutorTests`、`SearchEditingTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [ ] router、结果类型与执行器测试通过；别名与现有app去重。
- [ ] 有显式命令提示和强制文件搜索出口，Save场景不隐式执行web/app。
- [ ] 新结果不伪造SupplementaryHit或entryID，普通文件快照与动作保护保留。
- [ ] 007可仅依赖本阶段的PaletteItem和命令配置契约接入声明式动作。

## 停止条件

若所有结果必须重做核心SearchResult才能接入，先缩回应用层包装。关键字冲突没有明确退出方式或web打开在Save中自动发生时不能交付。别名要求全盘逐项String fuzzy时重新限定为小集合。

## 维护说明

新增关键字必须加入冲突、URL编码和模式测试。应用版本/路径变化不自动把使用记录转移到不同安装副本。后续动作case应复用003执行契约。
