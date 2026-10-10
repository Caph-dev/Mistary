# 计划 004：提供 Finder 目录上下文、精确范围与收藏

## 状态

- 状态：已完成（按操作者决定，真实 Finder／Automation／跨应用验收及真实同机性能测量暂缓）。
- 交付：Finder 上下文、严格目录范围、收藏管理与 Quick Switch 目录候选；见 [实施证据](evidence/004-finder-scope.md)。
- 实现提交：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`。
- P1；工作量 L；风险中；阶段 M1；依赖：003-search-session-actions.md 的会话与动作请求契约。与 005 的导航联合验收在 005，不反向依赖 005。
- 规划于：commit `6c024bbbf6b917c4a334f4569de070d887ecd66f`；2026-10-10。
- 以下保留实施规格；实际交付、自动验证及暂缓项以状态、完成标准和实施证据为准。

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

本计划的七组指定测试及 Release 构建已实际运行；新增测试和证据文件已创建，具体结果见实施证据。每条测试命令必须 exit 0、匹配到预期测试且全部通过；零测试不算通过。每步失败先报告关键错误，同类失败两次后咨询 advisor 或操作者，再调整方案。

使用 OILFIND_FREE=1 运行 Swift 验证。每个逻辑步骤后完成最窄检查；阶段末执行 OILFIND_FREE=1 swift build -c release。完成标准还包括：git diff --check 无空白错误，git status --short 中实现改动均属于列出的范围（以及本计划的状态/证据记录）。

```sh
git status --short
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/FinderContext.swift Sources/OilFindApp/DirectoryCandidates.swift Sources/OilFindApp/FavoritesStore.swift Sources/OilFindApp/ContextResolver.swift Sources/OilFindApp/SearchSession.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/SearchPresentation.swift Sources/OilFindApp/ResultsView.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/Permissions.swift Sources/OilFindApp/L10n.swift Resources/Info.plist Sources/OilFindCore/Searcher.swift Sources/OilFindCore/SearchCache.swift Sources/OilFindCore/SearchSources.swift Tests/OilFindCoreTests/DirectoryScopeTests.swift Tests/OilFindUITests/FinderContextTests.swift Tests/OilFindUITests/FavoritesStoreTests.swift
```

## 范围清单

- `Sources/OilFindApp/FinderContext.swift（新建）`
- `Sources/OilFindApp/DirectoryCandidates.swift（新建）`
- `Sources/OilFindApp/FavoritesStore.swift（新建）`
- `Sources/OilFindApp/ContextResolver.swift`
- `Sources/OilFindApp/SearchSession.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/SearchPresentation.swift`
- `Sources/OilFindApp/ResultsView.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/Permissions.swift`
- `Sources/OilFindApp/L10n.swift`
- `Resources/Info.plist`
- `Sources/OilFindCore/SearchScope.swift（新建，最小中性 scope 编译）`
- `Sources/OilFindCore/Searcher.swift`
- `Sources/OilFindCore/SearchCache.swift`
- `Sources/OilFindCore/SearchSources.swift`
- `Tests/OilFindCoreTests/DirectoryScopeTests.swift（新建）`
- `Tests/OilFindUITests/FinderContextTests.swift（新建）`
- `Tests/OilFindUITests/FavoritesStoreTests.swift（新建）`

## 为什么重要

Finder 当前目录和常用目录是文件工作流的上下文。必须区分真实目录、Recents 和搜索窗口；目录范围还应严格限制后代，不能用模糊路径命中或 UI 后过滤冒充。本计划交付目录候选与范围，不控制打开/保存对话框。

## 当前状态与证据

Sources/OilFindCore/Searcher.swift 当前选项为：

~~~swift
public var sort: SortKey = .relevance
public var ascending: Bool = false
public var kind: UInt8? = nil
public var pinyin: Bool = true
~~~

没有精确目录选项。Sources/OilFindCore/Query.swift 的 Matcher.path(components:) 是查询匹配；不能未经验证将其当成严格目录 containment。Sources/OilFindCore/SettingsPreferences.swift 的 ExcludedFolders.contains 使用组件边界 parent + "/"，可参考边界语义，但不是搜索 scope 实现。

SearchViewController 已按查询 generation 和来源版本提交结果。Searcher 大命中集合只排序前 5000 个，空查询 recent 最多 200 个。截断之后才按目录过滤会错过范围内候选或返回未排序后缀。

## 前置交付与接口契约

003 提供展示前捕获的不可变 SearchSession、scope 字段和绑定目标的 ActionRequest。目录输出对象包含 window identity、directory URL、观测时间、获取方式和可用状态，供 005 消费。

Finder 首先探测 AX 是否能可靠给出目录 URL；若不足，只在 FinderContext 的专用实现中使用 Finder scripting/Apple Events。Automation 与 AX 独立授权，Info.plist 按实际需要增加说明；字符串/路径作为 Apple Event 参数，不插入脚本源码。拒绝后回普通搜索，不重复弹窗。

捕获 Finder 前台真实目录，桌面显式使用 Desktop；Recents/搜索/不确定目标返回 unavailable。每窗口缓存仅存实际观察到的目录；关闭/替换窗口使缓存失效。不要宣称已枚举所有 Finder 窗口的真实目录。

目录 scope 在唤起时冻结，默认全盘，用户显式切换。定义为目录本身及其后代，按索引卷的名称比较规则匹配；不跟随索引外符号链接跨目录。/work 不包含 /workspace。包内/排除/权限覆盖仍遵守原索引选项。

最小核心扩展允许给 SearchOptions 增加默认 nil 的精确目录字段；路径规范化一次，在每个来源编译为目录条目/祖先判断或等价字节结构。候选、recent、topK 和 withEntryPredicates 全部先判断 scope。热循环不得逐项重建完整路径或 String。多来源在每个 store 独立解析，不持久化根 entryID。

SearchCache、增量 canNarrow、多来源缓存的有效性比较必须包含 scope。改变 scope、store/version/source online 状态清空或隔离缓存；不改 SoA、C 或持久化格式。每份已编译scope绑定sourceID、store对象身份/版本与目录身份；重扫/压实后重新解析，不跨store复用root entryID。解析失效时返回空结果或具名不可用状态，由用户显式切回全盘，不能自动扩大范围。若具体实现需要新核心文件，可先在本计划范围登记 SearchScope.swift 和对应测试，保持中性、不依赖 AppKit。

收藏在 Mistary 数据目录保存带版本的书签、来源/路径降级和手动名称；不存 UInt32 索引 ID，不绕过访问权限。删除收藏只移除配置，不删除文件。无索引覆盖时允许明确导航到仍可访问的收藏目录，但不伪装成文件搜索命中。

Quick Switch 本阶段只生成最近有效 Finder 目录与收藏候选，显示来源；未能判断“最近”时让用户选择。005 才执行送往对话框；本阶段可提供用户主动复制目录路径。

## 范围

仅范围清单，允许上述最小搜索 scope 扩展；Query.swift 和索引格式保持不变。范围外：Finder UI 注入、全局普通字母监听、对话框导航、外置卷自动发现、任意来源 provider。核心 scope 测试参照 Tests/OilFindCoreTests/M7SearchTests.swift 的 @testable import OilFindCore 与人工构建 IndexStore 模式；真实目录边界可参照 ResultsSelectionTests.swift 的临时目录/Scanner 模式。TestSupport.swift 只提供 CI 跳过助手，不能当作扫描夹具。

## 步骤与验证

### 1. 捕获与缓存真实 Finder 上下文

实现 fake Finder/Automation 接口，覆盖普通窗口、tab/窗口替换、Desktop、Recents、搜索、权限拒绝、退出和 stale 缓存。同一窗口多次观测更新目录；保持作用域与当前会话绑定。

验证：OILFIND_FREE=1 swift test --filter FinderContextTests；OILFIND_FREE=1 swift test --filter SearchSessionTests。预期：未知场景回普通模式；不会采用另一个窗口的目录冒充当前目录。

### 2. 在搜索过滤与缓存中实施精确目录 scope

先新增 core 测试：/work 与 /workspace，根目录，中文/大小写规则，未覆盖目录，符号链接，空查询，多来源，scope切换后的缓存，大结果中范围内命中位于原全盘排序前缀外。scope 必须在 topK/200 recent 前生效。withEntryPredicates 的 scope语义与搜索相同。

验证：OILFIND_FREE=1 swift test --filter DirectoryScopeTests；OILFIND_FREE=1 swift test --filter ResultRefreshTests。预期：全部结果满足范围，计数/排序正确，scope切换不复用全盘缓存，默认 nil 行为与基底一致。

### 3. 实施收藏与目录候选

持久化采用单份带版本配置与原子写入；书签解析/文件 I/O 在索引锁外。添加、编辑、排序、删除收藏；无权限/离线/已删除显示原因。空查询展示收藏与原最近修改入口，二者分组且可识别，最近修改不标为使用历史。

验证：OILFIND_FREE=1 swift test --filter FavoritesStoreTests；OILFIND_FREE=1 swift test --filter FinderContextTests。预期：重启解析收藏；过期/损坏书签不崩溃；删除配置不触碰真实目录。

### 4. 接入界面并测量 scope 成本

增加全盘/当前目录切换、捕获目录提示及 Quick Switch 候选菜单。Quick Look 与复制语义保留；真实 Finder 当前窗口跳转使用同一窗口身份校验，不回退到任意新窗口而声称当前窗口已跳转。

验证：OILFIND_FREE=1 swift test --filter ResultsSelectionTests；OILFIND_FREE=1 swift test --filter SearchEditingTests；OILFIND_FREE=1 swift build -c release。预期：默认查询快捷键不变，切 scope 保留合适选择，普通全盘性能与基底相比 p95 增幅建议不超过 10%；该目标需记录实际测量，不凭测试通过推断。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `FinderContextTests`、`SearchSessionTests`、`DirectoryScopeTests`、`ResultRefreshTests`、`FavoritesStoreTests`、`ResultsSelectionTests`、`SearchEditingTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [x] DirectoryScopeTests 覆盖大结果、空查询、缓存和边界；scope在候选排序前生效。
- [x] Finder 和收藏单测通过；有效目录/来源在界面可见；未知上下文有理由。
- [x] Quick Switch 交付候选而非虚报已完成导航；005 可独立消费，无依赖循环。
- [x] 字符串构造与文件 I/O 不进入 per-entry 热循环/持锁区。
- [ ] 真实 Finder／Automation 权限、跨应用操作与同机 p95 测量暂缓（操作者明确决定不作为本次完成门槛）；未验证事项已记录到 plans/evidence/004-finder-scope.md，不视为通过。

## 停止条件

scope 只能依靠截断后 UI 过滤时不能标完成；先确认核心最小扩展或咨询 advisor。Finder URL 不可确定时不得猜最近窗口；权限不足不能切换不相关窗口。新增通用核心 API前验证默认 nil 行为与原性能，不顺手重写 Searcher。

## 维护说明

008 历史候选也必须服从精确 scope；源重扫/压实后重新解析目录。Finder 或系统更新后重测窗口和权限行为。该阶段核心修改仅因严格 scope 正确性而加入，不重写搜索内核。
