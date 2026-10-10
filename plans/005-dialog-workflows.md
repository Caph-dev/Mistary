# 计划 005：将搜索结果送回原打开或保存对话框

## 状态

- 状态：待执行。
- P1；工作量 L；风险高；阶段 M1；依赖：002-ax-feasibility.md 的真实兼容结论、003-search-session-actions.md 的目标快照、004-finder-scope-favorites.md 的目录候选。
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
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/DialogAdapter.swift Sources/OilFindApp/DialogNavigation.swift Sources/OilFindApp/AccessibilityClient.swift Sources/OilFindApp/ContextResolver.swift Sources/OilFindApp/SearchSession.swift Sources/OilFindApp/ActionExecutor.swift Sources/OilFindApp/SearchPanel.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/DirectoryCandidates.swift Sources/OilFindApp/Permissions.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/L10n.swift Tests/OilFindUITests/DialogWorkflowTests.swift Tests/OilFindUITests/DialogNavigationTests.swift
```

## 范围清单

- `Sources/OilFindApp/DialogAdapter.swift（新建）`
- `Sources/OilFindApp/DialogNavigation.swift`
- `Sources/OilFindApp/AccessibilityClient.swift`
- `Sources/OilFindApp/ContextResolver.swift`
- `Sources/OilFindApp/SearchSession.swift`
- `Sources/OilFindApp/ActionExecutor.swift`
- `Sources/OilFindApp/SearchPanel.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/DirectoryCandidates.swift`
- `Sources/OilFindApp/Permissions.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/L10n.swift`
- `Tests/OilFindUITests/DialogWorkflowTests.swift（新建）`
- `Tests/OilFindUITests/DialogNavigationTests.swift`

## 为什么重要

搜索的终点由唤起场景决定：普通场景打开文件，Open 场景交回原文件面板，Save 场景只换目录。本计划把已验证实验接入生产，保留最终确认和受控降级；没有实证支持的应用不能开启自动导航。

## 当前状态与证据

Sources/OilFindApp/SearchPanel.swift 的窗口类型是：

~~~swift
styleMask: [.borderless, .nonactivatingPanel]
~~~

SearchViewController 的 Return 当前直接 openSelected，⌘Return 定位 Finder；其 hideIfInactive 在没有 Quick Look/menu/dragging 时失焦隐藏。没有 Open/Save 模式、权限设置或原对话框目标。003 已增加会话/执行器，004 已提供目录候选；以这两份交付接口为实施输入，而不是直接复制旧控制器代码。

## 前置交付与模式决策

002 的实际清单至少含系统/应用版本、Open/Save、窗口/sheet/进程、可导航/选文件/保留文件名、失败证据及 PASS/PARTIAL/FAIL。缺清单不得直接启用自动化。

- PASS：只对清单中的已验证操作开启适配器；仍不承诺所有应用。
- PARTIAL：自动导航按 app、模式与操作能力启用，不支持部分始终显示手动交接。
- FAIL：实现搜索、目录收藏与显式复制路径的手动流程，记录产品能力收缩。不得自动激活未知目标或继续发键。

003 提供原窗口/控件身份、会话/查询/动作代次和不可变文件请求；004 提供有效的 Finder 目录和收藏，导航在这里消费，004不依赖本计划。

## 功能规格

普通模式沿用文件打开。Open 模式 Return 导航到选中文件所在目录，仅支持时选中文件；显示“已导航”或“目录已就绪，需手动选文件”的准确结果，不自动确认 Open、不绕过原格式过滤。文件不可访问或来源离线时停止。

Save 模式默认文件夹过滤；Return 仅导航到目录，读取并保持原文件名，不点击 Save、不触发覆盖确认。若用户显式选择文件，仅允许“使用所在目录”。保存文件名为空也要保持；不自动建议新文件名。

动作菜单的 Quick Switch 显示捕获 Finder 目录的来源和时间，由用户选择后送往原目标。未知或 stale 候选不导航。快捷键不在本阶段另占新全局热键。

导航由短状态机执行，预期焦点交接明确；原目标退出、对话框替换、意外焦点变化、权限撤销或每步超时取消。取消后不再派发后续操作，迟到回调丢弃；已发送动作不可撤回。非主线程 AX 队列仍可能短暂占用，不能因此冻结搜索 UI。

失败显示具名原因与“复制路径”按钮；按钮由用户显式点击才写剪贴板。普通 Return 在未识别场景可以普通打开，但已识别对话框导航失败不得静默改成普通打开。暴露“普通搜索”显式退出方式。

## 范围

只改范围内组件和测试。不改核心算法/索引格式、全局键盘监听、Finder Sync、外部应用 UI。不从实验失败扩大到坐标点击或无限重试。原应用最终确认由用户负责。

## 步骤与验证

### 1. 接入识别、设置与能力提示

展示前捕获可靠目标，仅对清单内 app/模式识别为可自动导航。设置独立开关和 AX 权限状态；拒绝/撤销后普通搜索保留。低置信识别显示手动模式，不能用“当前前台”代替原目标。

验证：OILFIND_FREE=1 swift test --filter DialogWorkflowTests；OILFIND_FREE=1 swift test --filter SearchSessionTests。预期：PASS/PARTIAL/FAIL分别走已声明路线，未知目标无自动输入。

### 2. 实施 Open/Save 动作分派

ActionExecutor 固定本次结果和会话，再将路径转换为相应导航请求。Open 文件必须仍有效；Save仅目录；二者由同一 DialogAdapter 返回 verified/失败。自动发 Return 只能用于已核实的“前往文件夹”局部导航控件，绝不能落到 Open/Save 提交按钮。

验证：OILFIND_FREE=1 swift test --filter DialogWorkflowTests；OILFIND_FREE=1 swift test --filter DialogNavigationTests；OILFIND_FREE=1 swift test --filter ActionExecutorTests。预期：fake记录的提交 Open/Save 次数为0，文件名原值不变，失效/取消后派发计数不增长。

### 3. 接入 Quick Switch 与失败恢复

接入 DirectoryCandidates，显示多个有效目录让用户明确选择；目录变更不自动推进会话。取消后面板可继续搜索或显式复制路径，不改用户剪贴板。检验预期面板隐藏不会取消合法焦点交接，但意外激活其他窗口会停止。

验证：OILFIND_FREE=1 swift test --filter DialogWorkflowTests；OILFIND_FREE=1 swift test --filter FinderContextTests；OILFIND_FREE=1 swift test --filter ResultsSelectionTests。预期：正确来源目录送往原目标，迟到事件不改新会话，失败有可见恢复动作。

### 4. 真实应用联合验收

重新运行002清单内 app/模式的打开、保存、Quick Switch，至少10次每支持操作；覆盖中文/空格路径、原文件名、权限撤销、目标关闭/替换、切窗口、超时和取消。实验版本变化需重新取证。用临时文档，不在自动验收中提交打开/保存。

验证：OILFIND_FREE=1 swift build -c release；OILFIND_FREE=1 scripts/build-app.sh --debug；git diff --check。预期：生产与调试构建通过；计划证据写 plans/evidence/005-dialog-workflows.md，逐项给实际成功/失败/未验证，不用 snapshot 证明跨应用行为。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `DialogWorkflowTests`、`SearchSessionTests`、`DialogNavigationTests`、`ActionExecutorTests`、`FinderContextTests`、`ResultsSelectionTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [ ] 有明确已支持 app/版本/模式/操作清单；未支持路线可用且不自动输入。
- [ ] 保存文件名始终保持，零自动 Open/Save/覆盖；file/target/session校验通过。
- [ ] Quick Switch 在真实原目标完成导航，或明确标记为手动交接。
- [ ] 权限拒绝/撤销、目标失效、取消/迟到回调测试与实际流程有记录。
- [ ] 若002为FAIL，README标“完成手动路线”，不能写“全自动对话框完成”；完整M1自动目标仍待实现。

## 停止条件

发生任何误提交、不可控焦点或向未知窗口发键，立即停用该适配器并报告。操作只有固定延时/坐标保证时不得纳入清单。接口需要绕过源/会话校验时先修依赖契约，不在导航层放宽校验。

## 维护说明

macOS、目标应用或签名变更后重新检查权限与清单；不要用版本过时证据扩大支持范围。后续常驻窗口模式也不能让旧对话框上下文永远有效。
