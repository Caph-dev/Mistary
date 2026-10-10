# 计划 002：验证 Accessibility 对话框导航并输出兼容清单

## 状态

- 状态：待执行。
- P1；工作量 M；风险高；阶段 AX 实验；依赖：001-product-isolation.md 的独立应用身份和禁用更新契约。
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
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/AXProbe.swift Sources/OilFindApp/DialogNavigation.swift Sources/OilFindApp/AccessibilityClient.swift Sources/OilFindApp/Permissions.swift Sources/OilFindApp/Application.swift Tests/OilFindUITests/DialogNavigationTests.swift
```

## 范围清单

- `Sources/OilFindApp/AXProbe.swift（新建、DEBUG only）`
- `Sources/OilFindApp/DialogNavigation.swift（新建）`
- `Sources/OilFindApp/AccessibilityClient.swift（新建）`
- `Sources/OilFindApp/Permissions.swift`
- `Sources/OilFindApp/Application.swift`
- `Tests/OilFindUITests/DialogNavigationTests.swift（新建）`
- `plans/evidence/002-ax-compatibility.md（实施时新建）`

## 为什么重要

Mistary 首版价值依赖搜索结果能回到原打开/保存对话框。API 存在不证明具体应用提供可控 AX 树。以 2–4 个专注开发日作为实验预算，先得出支持与不支持的边界，再进入生产接入；不把实验预算当作交付承诺。

## 当前状态与证据

Sources/OilFindApp/Permissions.swift 只检查 Full Disk Access；它没有 AX 或 Automation 权限逻辑。Sources/OilFindApp/Application.swift 的 DEBUG 分支已有 --snapshot 入口，结构如下：

~~~swift
if arguments.contains("--snapshot") {
    do { try Snapshot.run(arguments, appExtension: appExtension); exit(0) }
    catch { fputs("Oil Find snapshot: \(error)\n", stderr); exit(1) }
}
~~~

上游错误文案在 001 后可能已改。新增探针使用相同 DEBUG 边界，正式包不得识别 --ax-probe。当前不存在对话框适配器；拟定的新文件和状态是规格。

## 前置交付与实验契约

001 已提供 build/debug/Mistary.app，独立 bundle ID、数据域与签名；没有旧更新/授权清理。实验不能通过恢复上游入口绕过身份检查。

新增调试参数 --ax-probe，只在操作者明确启用后观察并操作当前目标；不持续抓取所有应用文本。保存探针证据时脱敏实际路径和文档名，不记录完整控件值树。

导航状态：captured → validated → targetReady → pathControl → navigating → verified，终态另有 cancelled/failed。生产接入前不依赖这些类型名，保留语义契约。

每个目标包含宿主 PID、AX 对象实际进程、原窗口/sheet 身份、模式、会话代次。只允许预期的 Mistary → 原目标焦点交接。原目标退出、替换、意外焦点切换或权限撤销即取消；PID 单独不够。

串行 AX 队列使用有限消息超时与每步截止时间，不阻塞主线程。取消后不再派发后续步骤；迟到响应不能推进状态机；已派发请求/事件可能完成，不能承诺撤回。每次发送前核对目标，但仍保留检查与派发间竞态的限制说明。

## 范围

仅上述文件；不改核心搜索、Finder UI、全局键盘监听、正式菜单或文件动作。DialogNavigation 与 AccessibilityClient 仅建最小可注入接口和实验适配器，不建设通用自动化平台。

AX 以角色/属性/标识识别，避免写死中文/英文按钮标题。禁止屏幕坐标、仅固定 sleep 的成功判断、自动 Open/Save、覆盖确认、未知前台窗口输入。Finder Sync 不作为通用 UI 注入方案。

## 步骤与验证

### 1. 实现权限检查和测试接口

增加不触发提示的 AX 状态检查；探针显式请求时才提示。Full Disk Access、AX、Automation 分别记录。若使用 Finder Apple Events，权限处理交给 004，不能当作 AX 已覆盖。拒绝或撤销后普通搜索继续可用。

验证：OILFIND_FREE=1 swift test --filter DialogNavigationTests。预期：fake 权限拒绝时零导航调用，授权提示只在显式请求发生；创建并匹配到实际测试。

### 2. 用 fake AX 实现状态机

注入目标识别、读写属性、执行动作、截止时间与取消信号。记录调用序列，覆盖原目标被替换、响应超时、取消后迟到回调、预期焦点交接、意外焦点变化和辅助进程。先读取再有限写入，验证观察状态后才能继续下一步。

验证：OILFIND_FREE=1 swift test --filter DialogNavigationTests。预期：取消后调用序列不增长，迟到回调不复活会话，超时不占主线程，失败包含具名原因。

### 3. 加入 DEBUG 探针并验证构建边界

探针只列必要角色和能力；在临时测试目录准备带空格、中文、符号链接的样本。Open 导航到目录且在适配器支持时选中文件；Save 只导航目录，记录并保持原文件名。若必须合成按键，限定于核实过的控件；Secure Input/不可访问控件则失败，不尝试全局盲按。

验证：OILFIND_FREE=1 scripts/build-app.sh --debug；OILFIND_FREE=1 swift build -c release；OILFIND_FREE=1 swift test --filter SearchEditingTests。预期：调试包含显式探针，正式代码路径无探针入口，普通编辑/搜索不受权限拒绝影响。

### 4. 运行实验并记录关卡结果

先用 TextEdit 的 Open/Save 与 Preview 实际可用的 Open 模式，再用自己的常用编辑器/浏览器；不要将 Preview 的 Export 直接记成标准 Save。记录 macOS、应用版本、语言、窗口或 sheet、实际进程、模式、可识别/可导航/可选文件/保持文件名、权限状态、测试次数及失败次数。每项成功至少重复 10 次，次数是验收目标而非保证长期可靠。

手动验证拒绝/撤销权限、关闭/替换对话框、宿主退出、换窗口、取消、超时、多显示器及中文/英文界面。全程不自动提交 Open、Save 或覆盖。证据写到 plans/evidence/002-ax-compatibility.md；没有运行的格项标为未验证。

验证：OILFIND_FREE=1 swift test --filter DialogNavigationTests；git diff --check。预期：单测通过，证据包含实际结果和以下唯一结论之一。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `DialogNavigationTests`、`SearchEditingTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准与关卡

- [ ] fake 状态机测试与构建通过；正式包无 AX 探针入口。
- [ ] 手动兼容清单明确应用版本、Open/Save 模式、操作粒度、次数和失败原因。
- [ ] Save 原文件名不变，自动提交次数为零；取消后无新派发。
- [ ] 结论为 PASS / PARTIAL / FAIL，并注明批准进入 005 的操作集合。
- PASS：至少两个常用应用有可重复导航，其中至少一个真实 Save 面板保留文件名；验证目标失效路径。
- PARTIAL：只有部分 app/模式/操作通过；005 仅对清单内操作自动导航，其余手动交接。
- FAIL：预算内没有可靠导航；005 走手动交接路线，不能继续声称完整对话框增强。实验计划可标“已完成，结论 FAIL”，不是技术实现完成。

## 停止条件

发现自动提交 Save/Open、焦点不受控、影响真实文档，立即停止写入探针。预算耗尽时记录 PARTIAL/FAIL，不不断扩展适配器。未知 API 参数先查 Apple 官方文档或咨询 advisor，不猜补通用兼容能力。

## 维护说明

macOS 或目标应用升级后重跑清单；旧结果不能代表新版本。参考 Apple 的 AXIsProcessTrustedWithOptions 和 Finder Sync 官方文档；权限提示为异步，发起提示不等于已获授权。
