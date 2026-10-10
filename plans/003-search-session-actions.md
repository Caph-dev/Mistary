# 计划 003：建立搜索会话与绑定目标快照的动作执行器

## 状态

- 状态：已完成（按操作者决定，跨应用真机验收暂缓）。
- 交付：搜索会话、绑定目标快照的动作执行器与动作菜单；自动验证及未验证项见 [实施证据](evidence/003-search-session-actions.md)。
- 实现提交：本次实施提交（完整 SHA 由提交后的记录补充）。
- P1；工作量 M；风险中；阶段 M1 基础；依赖：001-product-isolation.md。002 仅为后续导航适配依据，不是本计划硬依赖。
- 规划于：commit `6c024bbbf6b917c4a334f4569de070d887ecd66f`；2026-10-10。
- 以下保留实施规格；已完成内容和实际验证以状态、完成标准及实施证据为准。

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

已在 2026-10-10 执行本计划的测试与构建，结果见实施证据；下文保留验证要求。每条测试命令必须 exit 0、匹配到预期测试且全部通过；零测试不算通过。每步失败先报告关键错误，同类失败两次后咨询 advisor 或操作者，再调整方案。

使用 OILFIND_FREE=1 运行 Swift 验证。每个逻辑步骤后完成最窄检查；阶段末执行 OILFIND_FREE=1 swift build -c release。完成标准还包括：git diff --check 无空白错误，git status --short 中实现改动均属于列出的范围（以及本计划的状态/证据记录）。

```sh
git status --short
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/SearchSession.swift Sources/OilFindApp/ContextResolver.swift Sources/OilFindApp/ActionExecutor.swift Sources/OilFindApp/AppDelegate.swift Sources/OilFindApp/SearchPanel.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/SearchPresentation.swift Sources/OilFindApp/ResultsView.swift Sources/OilFindApp/FooterBar.swift Sources/OilFindApp/L10n.swift Tests/OilFindUITests/SearchSessionTests.swift Tests/OilFindUITests/ActionExecutorTests.swift
```

## 范围清单

- `Sources/OilFindApp/SearchSession.swift（新建）`
- `Sources/OilFindApp/ContextResolver.swift（新建）`
- `Sources/OilFindApp/ActionExecutor.swift（新建）`
- `Sources/OilFindApp/AppDelegate.swift`
- `Sources/OilFindApp/SearchPanel.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/SearchPresentation.swift`
- `Sources/OilFindApp/ResultsView.swift`
- `Sources/OilFindApp/FooterBar.swift`
- `Sources/OilFindApp/L10n.swift`
- `Tests/OilFindUITests/SearchSessionTests.swift（新建）`
- `Tests/OilFindUITests/ActionExecutorTests.swift（新建）`

## 为什么重要

现有动作直接读取当前选中行，没有跨应用目标会话。要将文件送回原窗口，必须把场景和文件身份固定到发起时，并让延迟回调校验同一目标。先保留所有普通文件动作，再给 Finder、对话框和命令接入稳定契约。

## 当前状态与证据

Sources/OilFindApp/SearchViewController.swift 的 openSelected 中：

~~~swift
results.pressOpen { [weak self] in
    guard self?.allowOnlineAction() == true else { return }
    guard NSWorkspace.shared.open(url) else { NSSound.beep(); return }
    self?.hidePanel?()
}
~~~

url 先被捕获，而 allowOnlineAction 随后读取 results.selectedItem。执行动画期间换行可能使校验对象与打开对象不同，新增测试必须覆盖这条路径。现有保护还检查来源在线及 store 相同，不能在整理执行器时丢失。

SearchPanel.show 先 orderFrontRegardless/makeKey，再 panelWillShow 和输入框 focus。AppDelegate.handleHotKey 调 panel.toggle。上下文捕获必须发生在任何 makeKey/activate 前，而不能从面板展示后的前台状态推断原目标。SearchPresentation 保存来源与索引快照，提供 isCurrent 和 index 定位方法。

## 前置交付与接口契约

001 已建立独立身份、数据域及公开构建。保留其关闭更新/授权清理的行为。

SearchSession 建议包含 sessionID、queryGeneration、actionGeneration、invocationSource、模式、捕获目标、目录 scope。模式为普通/应用/Finder/Open/Save，未可靠识别时为普通。尚未实施的 Finder/AX 识别通过可注入接口返回 unavailable。

ActionRequest 固定 actionID、session token 和文件目标快照：sourceID、store 引用/版本、entryID、发起时 URL、可获取的资源身份。每次执行前和延迟动画回调前都验证该份快照。当前选择变化不能让新选中项替旧目标完成校验；失效时取消并提示重搜。合法目标仍可执行捕获文件，但不能悄悄执行新选中项。

动作结果定义：accepted 为系统 API 接受请求；verified 为可观察的目标导航/文件系统操作状态；cancelled 为未继续派发；failed 含具名原因。普通 NSWorkspace.open 的 accepted 不代表目标应用已读取文件内容。复制/废纸篓/定位的成功语义分别定义，供后续 UsageStore 消费。

失焦隐藏、菜单 tracking、拖拽、Quick Look 与按压动画需要共同管理；会话结束/查询更新/来源替换使不再有效的请求失效。不能把每个面板 hide 都当作目标失效，005 导航会有预期隐藏。

## 范围

只修改范围清单，不改变查询算法、索引格式或 SupplementaryHit 公共接口，不引入网页/命令结果、多选或新文件修改动作。普通复制路径允许离线只读元数据；打开/预览/定位/删除需要在线与当前目标校验。执行器按动作声明需求，避免错误地把所有离线文本复制禁掉。

## 步骤与验证

### 1. 建立可注入会话与前台捕获

新增最小模式/目标/代次数据结构和 fake ContextResolver。统一热键、菜单、reopen 等用户唤起入口：展示前捕获，重复 toggle 隐藏不覆盖已有目标；indexing/onboarding 自动展示不得推断可导航的外部目标。

验证：OILFIND_FREE=1 swift test --filter SearchSessionTests。预期：捕获早于窗口取焦点，过期代次不提交；无权限/未知窗口降级普通模式。

### 2. 移动普通动作到执行器

逐个接入打开、定位、复制文件/路径/名称、Quick Look 和废纸篓，保留系统 API。文件复制与路径复制提供独立语义；现有 copyPath 同时写 NSURL 与字符串，先用夹具和 Finder 手动粘贴验证再决定格式。文字编辑选区的 ⌘C/⌘X/⌘V 仍优先交给 editor。

验证：OILFIND_FREE=1 swift test --filter ActionExecutorTests；OILFIND_FREE=1 swift test --filter SearchEditingTests。预期：捕获目标与校验目标一致，剪贴板格式符合动作，编辑选区不被文件动作覆盖。

### 3. 接入状态提示与动作菜单

保留 Return、⌘Return、⌘Y、Tab、Escape 语义；增加显式场景和失败提示。动作菜单候选快捷键 ⌘K 需先检查现有 handleKey 冲突与输入法 marked text。本阶段所有上下文动作默认 unavailable，不伪造成功。

验证：OILFIND_FREE=1 swift test --filter ActionExecutorTests；OILFIND_FREE=1 swift test --filter ResultsSelectionTests；OILFIND_FREE=1 swift test --filter ResultRefreshTests。预期：动画期间换行、源下线、store 替换、同路径文件被替换、删除/改名均不会执行错误目标。

### 4. 验证生命周期与回归

验证：OILFIND_FREE=1 swift test --filter SearchSessionTests；OILFIND_FREE=1 swift build -c release；OILFIND_FREE=1 scripts/build-app.sh --debug。预期：普通搜索/快速唤起不变，菜单、拖动、Quick Look 不因执行器而过早隐藏；暂不支持的场景提示真实原因。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `SearchSessionTests`、`ActionExecutorTests`、`SearchEditingTests`、`ResultsSelectionTests`、`ResultRefreshTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [x] 会话在展示前捕获，所有用户唤起入口有测试；程序自动展示不绑定任意外部窗口。
- [x] 延迟动作校验发起时同一文件快照；目标变更和 source/store 替换回归通过。
- [x] 操作需求和 accepted/verified/cancelled/failed 语义明确，有可注入系统 API。
- [x] 现有编辑、选择与刷新测试通过；离线文本复制和在线操作规则保留。
- [x] 004 可提交目录上下文，005 可提交导航动作，006 可扩展结果类型而不绕过校验；接口和限制见实施证据，当前所有目标窗口导航仍 unavailable。
- [ ] 跨应用真机验收暂缓（操作者明确决定不作为本次完成门槛）；Finder 粘贴、Quick Look/拖拽/菜单焦点与真实废纸篓等未验证项独立记录，不视为已通过。

## 停止条件

若需要从 app 核心引入 AppKit 或重做 SoA 才能建立会话，先报告并缩回应用层。动画、菜单或刷新导致错误对象执行时不得交付后续功能。来源验证无法确认时取消动作，不通过重新读取当前选中行“修复”目标。

## 维护说明

新增动作一律接受不可变请求并说明校验/完成语义；历史只根据执行器事件计数。以后增加多选需捕获整个集合，不能逐次从 UI 读取选择。
