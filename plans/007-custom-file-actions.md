# 计划 007：加入指定应用、声明式命令和单文件操作

## 状态

- 状态：待执行。
- P2；工作量 L；风险中到高；阶段 M2；依赖：003-search-session-actions.md 的不可变ActionRequest；006-launcher-query-routing.md 的PaletteItem和配置。004只为保存目录scope的集成输入。
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
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/ActionDefinitions.swift Sources/OilFindApp/CommandRunner.swift Sources/OilFindApp/FileActions.swift Sources/OilFindApp/SavedFiltersStore.swift Sources/OilFindApp/PaletteItem.swift Sources/OilFindApp/ActionExecutor.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/L10n.swift Sources/OilFindApp/Permissions.swift Resources/Info.plist Tests/OilFindUITests/CommandActionsTests.swift Tests/OilFindUITests/FileActionsTests.swift Tests/OilFindUITests/SavedFiltersTests.swift
```

## 范围清单

- `Sources/OilFindApp/ActionDefinitions.swift（新建）`
- `Sources/OilFindApp/CommandRunner.swift（新建）`
- `Sources/OilFindApp/FileActions.swift（新建）`
- `Sources/OilFindApp/SavedFiltersStore.swift（新建）`
- `Sources/OilFindApp/PaletteItem.swift`
- `Sources/OilFindApp/ActionExecutor.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/L10n.swift`
- `Sources/OilFindApp/Permissions.swift`
- `Resources/Info.plist`
- `Tests/OilFindUITests/CommandActionsTests.swift（新建）`
- `Tests/OilFindUITests/FileActionsTests.swift（新建）`
- `Tests/OilFindUITests/SavedFiltersTests.swift（新建）`

## 为什么重要

文件结果应该直接承载自己的常用操作。先支持少量声明式动作与单文件改动，避免每次切回Finder，也避免过早引入插件系统。所有执行仍绑定003的发起目标；路径必须作为数据传递，不能拼进shell源码。

## 当前状态与证据

Sources/OilFindApp/SearchViewController.swift 当前上下文菜单来自固定数组：

~~~swift
["open", "reveal", "preview", "-", "copyPath", "copyName", "-", "trash"]
~~~

目前打开使用 NSWorkspace.shared.open，废纸篓使用 NSWorkspace.shared.recycle。没有指定应用、终端、可配置命令、新建目录、重命名和保存过滤器。SettingsWindow.swift 的 SettingsModel 是 ObservableObject，界面文案集中在 L10n，继续沿用该结构。

## 前置交付与动作契约

003提供不可变请求、在线/快照校验和accepted/verified/cancelled/failed。006提供file/application/web结果、配置持久化和选择身份。不得把web命中送入文件修改动作；对话框模式的Return仍由005负责，本阶段动作通过显式菜单触发。

ActionDefinition为声明式、版本化配置：ID、名称、适用结果类型/场景、需要权限、可用状态和执行描述。支持applicationURL、URL template或明确absolute executable + arguments数组，不用动态代码加载。占位符只替换到单个argv元素，不拆词，不插入shell command。

指定应用打开使用明确applicationURL与文件URL；不能偷偷改系统默认应用。终端首版选择可接收directoryURL的显式终端应用，优先验证系统Terminal；不拼“cd 路径”脚本。若无法通过该应用的受支持打开目录协议完成，标不支持，让用户配置自己的明确脚本与argv；不静默打开替代终端。只有选定实现确需Apple Events时才请求Automation。

CommandRunner用Process的executableURL、arguments和可选currentDirectoryURL，禁止默认 /bin/sh -c、eval、未经授权的shell解释。启动和结束状态分开，stdout/stderr有大小上限，错误提示不暴露环境变量/凭据。用户显式触发一次执行，不在查询键入时运行。脚本内部行为属于用户指定脚本，本阶段不生成远程下载或任意插件。

新建目录/单文件重命名只接受一个合法leaf名称，不含路径分隔、NUL、.或..；保持父目录与来源校验。目标已存在时失败，不覆盖。检查存在之后仍有竞态，必须使用经核实的“不覆盖”文件系统操作语义，不能只有exists预检查。大小写-only rename按卷规则测试；不可靠时报告明确不支持，不用有风险的临时覆盖绕过。

修改在File I/O队列执行；成功后通过现有FSEvents/索引刷新反映，不在持读锁时改盘。创建失败/rename失败保留原文件及选择；不用永久删除实现撤销。动作发起后权限/来源变化需要重新验证。

保存过滤器记录原始文件查询、sort/kind/pinyin与可选目录scope，启用时重新parse完整语法及相对日期，不保存编译Regex对象或entryID。不保存web/自定义命令输入为“文件过滤器”。目录scope采用004的规范化契约；004未完成时基础实现仅使用无scope配置，不引用其DirectoryCandidates/FavoritesStore或核心scope扩展，不运行004测试，界面明确尚未支持保存scope。004集成后新增scope用例，不能把scope字段静默丢弃后按全盘激活。

## 范围

仅范围清单；不改核心文件系统监听和持久化格式。范围外：多选、批量改名、剪切/移动、动态插件、网络服务、全局命令热键、付费或授权接口。

## 步骤与验证

### 1. 实施声明式动作与参数绑定

配置校验只允许具名类型/占位符/有效URL或可执行路径。先用fake Process/Workspace验证空格、引号、$、反引号、换行、中文、多个占位符作为独立参数。没有权限或不适用的动作显示禁用原因。

验证：OILFIND_FREE=1 swift test --filter CommandActionsTests；OILFIND_FREE=1 swift test --filter ActionExecutorTests。预期：路径不会拆词或执行shell插值，键入查询零进程启动，过期目标零调用。

### 2. 实施指定应用和终端能力

选择指定应用，记录具体URL；检查文件/目录类型与应用可用。用临时目录手动验证所选终端协议，记录支持应用版本。API接受请求只返回accepted；没有观察证据不能显示“目录已成功打开”。默认不需要Automation的实现不增加权限提示。

验证：OILFIND_FREE=1 swift test --filter CommandActionsTests；OILFIND_FREE=1 swift build -c release。预期：调用正确应用URL和目录URL，app缺失/不支持协议失败可见，不回退到不相关应用。

### 3. 实施单文件创建/重命名

先建临时扫描夹具，覆盖名称合法性、冲突、权限拒绝、源删除/替换、符号链接、只读来源、大小写规则、执行期间变更和FSEvents刷新。真实动作只操作临时夹具。执行器校验捕获目标，文件系统层用不覆盖语义。

验证：OILFIND_FREE=1 swift test --filter FileActionsTests；OILFIND_FREE=1 swift test --filter ResultRefreshTests。预期：目标冲突绝不覆盖，失败后原文件内容仍完整，索引刷新不使动作作用于另一行。

### 4. 实施保存过滤器并接入设置

提供保存、编辑、删除和激活入口；空/无效查询明确处理。保存当前原查询而非拼装后的scope字符串，日期条件激活时重新解释。与现有拼音、类型、排序设置共存，维护中英文文案。

验证：OILFIND_FREE=1 swift test --filter SavedFiltersTests；OILFIND_FREE=1 swift test --filter QueryRouterTests；OILFIND_FREE=1 swift test --filter SearchEditingTests。预期：重启还原配置，损坏/旧版本配置有错误，不改变web路由；有004时scope不会丢失或扩为全盘。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `CommandActionsTests`、`ActionExecutorTests`、`FileActionsTests`、`ResultRefreshTests`、`SavedFiltersTests`、`QueryRouterTests`、`SearchEditingTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [ ] 参数、权限、动作类型和目标快照测试通过；所有命令显式触发。
- [ ] 指定应用和终端有真实支持证据；unsupported不是虚报成功。
- [ ] 新建/重命名使用不覆盖语义，包含竞态/冲突/失败保留原文件的测试。
- [ ] 保存过滤器在激活时完整重新parse并遵守目录scope。
- [ ] 记录plans/evidence/007-actions.md及使用的终端协议/权限，不写用户脚本秘密。

## 停止条件

终端只能依靠未验证shell拼接时先禁用该动作。重命名无法保证不覆盖时不能开放给真实用户文件。需要多选或重构FSWatcher才可完成时收缩到单文件并报告，不扩范围。

## 维护说明

新增动作必须声明适用类型、权限、结果语义及usage统计策略。未来多选计划应复用这些请求/文件系统保护，不能另建弱校验路径。
