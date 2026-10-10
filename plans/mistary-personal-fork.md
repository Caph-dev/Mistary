---
template: doc
theme: blueprint
title: Mistary 个人版开发方案
subtitle: 从 Oil Find 6c024bb 出发，补齐 macOS 文件工作流
source: 当前源码、用户提供的对比页、Apple 官方文档
base: 6c024bbbf6b917c4a334f4569de070d887ecd66f
---

建议把 Mistary 定义为「知道当前场景的文件启动器」。
复用现有文件名搜索内核，优先支持打开／保存对话框。
随后增加 Finder 目录上下文、常用动作和使用历史。

这是一份开发方案，尚未实现或实测跨应用控制。
下列性能、兼容性和工期均为建议目标。

## A 产品边界与取舍

```callout info 首版目标
从任何应用唤起 Mistary，快速找到文件或目录。
将结果交给当前场景，减少导航和切换窗口。
首版完成后，就用于自己的日常工作。
```

个人版有三个约束。

- 时间有限，功能价值取决于自己的使用频率。
- 当前内核已经提供文件名索引和高级查询。
- 跨应用导航的难点是焦点、权限和兼容性。

据此，优先解决三个任务。

1. 在打开对话框中找到目标文件。
2. 在保存对话框中跳到目标目录。
3. 在 Finder 与工作应用间复用目录。

首版继续支持 macOS 14 和 Apple 芯片。
保留 Swift、AppKit、SwiftUI 与现有 C target。
新增代码只用系统框架。

开发前选定自己的常用应用作为支持清单。
默认实验对象可用 TextEdit、Preview 和 Finder。
再加入浏览器与编辑器；它们的兼容性待实测。
不承诺通用支持所有应用。

**暂缓的功能**：全文、OCR、网络卷、剪贴板历史。
侧栏计数、内嵌预览、主题系统也可后置。
这些功能不决定核心文件工作流是否成立。
外置本地卷按实际需求另列阶段。

双击 Control 和 Finder 直接打字唤起暂缓。
首版沿用可配置的全局组合快捷键。
这样能先验证价值，再增加键盘监听成本。

## B 基底与身份隔离

基底为 `6c024bbbf6b917c4a334f4569de070d887ecd66f`。
提交标题为 `Oil Find 1.4.1: extension menu item`。
调研时位于 `main`，工作区没有未提交改动。

建议从该提交建立 `personal/mistary` 分支。
需要独立管理时，再建立个人私有 fork。
首版固定基底；后续按需移植上游修复。
保留 MIT 许可证与原作者版权声明。

**源码 target 名称先保留** `OilFindCore`、`OilFindApp`。
运行时产品身份改为 Mistary，避免全仓库重命名。
目录名已经是 Mistary，不代表运行时身份已隔离。

首次运行前，完成下面的隔离。

- 显示名、应用包和可执行文件映射。
- 独立 bundle ID，例如 `me.caph.mistary`。
- URL scheme 使用 `mistary`。
- 数据放在 `~/Library/Application Support/Mistary/`。
- 偏好域、单实例通知、日志与登录项。
- 构建产物、安装目的地和卸载路径。
- 使用独立、稳定的本机签名身份。
- 检查全局热键冲突；两款应用可设置不同按键。

示例 bundle ID 是建议，尚未写入源码。
稳定签名有利于维护权限授权；需重建实测。
改身份后预期需要重新授予相应权限。

**必须处理三个现有启动和安装行为。**

1. 禁用 `LegacyAuthorizationCleanup.run()`。
2. 禁用自动、手动更新与上游更新安装入口。
3. 停用启动时的上游更新收据清理。

旧清理代码指向 Oil Find 的 `license.json`。
它还删除 `com.oiloil.find.trial` Keychain 条目。
现有安装脚本还会清理旧 Sift 数据。
Mistary 的安装／卸载不得沿用这些清理动作。

个人版先使用公开 commit 中的能力。
`Pro/` 不在公开提交里，不能视作已有依赖。
基线验证时使用 `OILFIND_FREE=1`。
个人构建应显式排除自动发现的私有 target。
无需开发付费、授权、官网或发布服务。

**本阶段验收**：两款应用能独立运行和重启。
安装、升级、卸载 Mistary 不触及 Oil Find 数据。
Mistary 不请求上游更新清单，也不执行旧清理。
卸载测试使用临时目录中的隔离夹具。

## C 首版交互与场景

只保留一个搜索面板，增加明确的场景提示。
使用现有 Quick Look，无需先做内嵌预览栏。

**普通应用中唤起**：文件与应用搜索。
Return 使用默认打开方式。
动作菜单提供指定应用、复制与终端动作。

**Finder 中唤起**：显示捕获的目录上下文。
全盘搜索仍是默认；用户可切到当前目录。
作用域在唤起时固定，不随背后窗口悄悄变化。
选中文件可定位；选中目录可显式跳转当前窗口。

Finder 的 Recents、搜索结果可能没有单一目录。
无法确定时回到普通搜索，并显示原因。
桌面上下文单独识别，不推断最近窗口的目录。
首版不拦截 Finder 中每个普通字母键。

**打开对话框中唤起**：提示「发送到打开对话框」。
搜索文件名后，导航到目标文件所在目录。
适配器支持时，选中目标文件。
用户仍在原对话框点击 Open 或按 Return。
不在后台自动提交打开动作。

文件格式限制仍由原应用和对话框决定。
首版单选，不绕过类型过滤与访问权限。

**保存对话框中唤起**：默认只显示文件夹。
Return 跳到该文件夹，保留原来的保存文件名。
不点击 Save，不替用户确认覆盖文件。
选中文件时只能显式选择「使用所在目录」。

**Quick Switch**：将 Finder 目录用于对话框。
缓存每个有效 Finder 窗口最近观察到的目录。
优先选择最近使用的有效目录，并显示来源。
无法判断时，提供目录列表由用户选择。
首版通过动作菜单触发；专用快捷键随后加入。

**收藏与最近使用**：空查询显示少量固定目录。
使用历史阶段完成后，再加入最近执行的项目。
目前空查询是最近修改文件，不能当作使用历史。

**复制语义**：分别提供「复制文件」和「复制路径」。
现有复制路径已写入文件 URL 与文本。
先验证 Finder 粘贴，再决定是否调整写入格式。
剪切／移动留到多选阶段，采用 macOS 操作习惯。

快捷键先保留现有 Return、⌘Return 与 ⌘Y。
候选动作菜单可用 ⌘K，最终检查快捷键冲突。
保留 Tab 切换文件类型，避免改变既有肌肉记忆。

## D Accessibility 实验与停止条件

macOS Accessibility，简称 AX，是候选控制路径。
它允许获得目标应用的可访问控件并执行动作。
实际能否识别和导航，取决于目标应用的 AX 树。
不能靠公开 API 名称推断完整兼容性。

首轮实验预算为 **2–4 个专注开发日**。
这是验证预算，不是对话框功能交付承诺。

实验需要记录这些事实。

- macOS 版本、应用版本及对话框类型。
- 独立窗口、sheet、可能存在的辅助进程。
- 能否可靠识别原窗口和目标对话框。
- 能否打开并写入“前往文件夹”控件。
- 跳转后是否能观察到预期目录。
- 保存文件名是否保持原值。
- 是否始终没有提交 Open、Save 或覆盖确认。

先支持两个实际常用应用，再扩展支持清单。
只验证中文和英文环境中可识别的结构。
优先用角色、属性和标识，避免写死按钮文案。
不按屏幕坐标点击，也不依靠固定等待时长。

```sequence num
用户 -> ContextResolver: 按全局热键
ContextResolver -> SearchSession: 捕获目标与作用域
SearchSession -> Mistary面板: 展示场景和搜索结果
用户 -> ActionExecutor: 选择文件或目录
ActionExecutor -> DialogAdapter: 校验会话和原目标
DialogAdapter -> 原对话框: 分步导航并确认状态
原对话框 --> 用户: 保留最终打开或保存确认
```

面板取得焦点前捕获目标上下文。
会话保存 PID、窗口／sheet 引用、目录与代次。
必要时记录实际控制对象所属进程。
PID 单独不足以标识原对话框。

导航采用短状态机。

`captured → validated → targetReady → pathControl → navigating → verified`

每一步设超时，并校验目标和预期控件。
只允许状态机预期的焦点交接。
目标退出、窗口消失或意外焦点切换时取消。

AX 调用在独立串行队列执行，限制消息等待时间。
结果回主线程前再次验证会话代次。
跨应用等待不得阻塞输入和文件搜索。

优先读取／写入 AX 属性和执行可用 AX 动作。
若某一步必须合成按键，只在已核实的目标中执行。
Secure Input 或不可访问控件出现时停止自动导航。
避免向未知前台窗口发送路径和 Return。

权限按功能请求。

- 文件覆盖仍沿用 Full Disk Access 机制。
- 用户启用对话框增强时，请求 Accessibility。
- 若使用 Apple Events，另处理 Automation 授权。
- 只有加入全局键盘监听后，才评估 Input Monitoring。

权限拒绝不影响普通搜索、打开与手动复制路径。
AX 授权不等于磁盘权限；书签也不绕过权限。

失败时显示原因，并提供显式「复制路径」。
不自动改剪贴板，不切到无关窗口继续执行。
若无法稳定控制常用对话框，首版收缩为手动交接。
保留 Mistary 搜索与收藏，用户手动粘贴目录。

Finder Sync 只适合特定菜单、徽标和工具栏能力。
Apple 明确不把它定位为通用 Finder UI 修改工具。
因此不能把它当作注入任意搜索条的解决方案。

## E 应用层架构与落点

首版在 `OilFindApp` 内增加场景与动作组件。
个人 fork 可直接改应用层，不必做通用插件系统。
继续保持核心不依赖 AppKit。

```tree list
Mistary
  复用 OilFindCore / COilFind | 保留搜索与索引热路径
    Query / Searcher / SearchCache | 查询、排序与缓存
    IndexManager / Scanner / FSWatcher | 扫描与实时更新
    IndexStore | SoA、稳定下标与持久化
  扩展 OilFindApp | 新增个人工作流
    SearchSession | 模式、作用域、目标、查询代次
    ContextResolver | 捕获前台应用与 Finder 目录
    DialogAdapter | AX 识别、导航、状态验证
    ActionExecutor | 统一动作与执行结果
    QueryRouter | 后续加入命令前缀分流
    UsageStore / Ranker | 后续加入使用历史
```

**实际改动入口**如下。

- `AppDelegate.swift`：身份、启动行为和上下文捕获。
- `SearchPanel.swift`：唤起模式、位置与失焦策略。
- `SearchViewController.swift`：场景提示和动作分派。
- `ResultsView.swift`：动作菜单，后续加入结果类型。
- `SearchPresentation.swift`：文件结果保留原快照。
- `Permissions.swift`：增加独立的能力权限状态。
- `SettingsWindow.swift`：收藏、兼容开关和动作配置。
- `L10n.swift`：维护中英文对应项。

新组件建议先放在 `Sources/OilFindApp/`。
测试放进 `Tests/OilFindUITests/`。
需要更多组件时再按 Context、Actions 等目录归组。
注释保持英文；不增加无关重构。

先把已有打开、定位、复制和废纸篓接入执行器。
执行器再根据会话选择普通打开或对话框导航。
动作声明目标类型、场景、权限与是否允许多选。
执行完成返回 accepted、verified、cancelled 或 failed。

accepted 表示系统 API 接受了请求。
verified 表示已观察到预期导航状态。
两者都不能宣称目标应用已成功读取文件内容。

保留当前离线来源保护与执行前二次校验。
普通动作需要核对来源在线状态和 store 快照。
刷新不能将旧选中项替换成另一个文件后执行。
菜单、拖动、Quick Look 期间继续保护面板状态。

当前 `ApplicationExtension` 不足以承载全部功能。
`SupplementaryHit` 只引用 sourceID 与 entryID。
它适合已有索引条目的附加命中。
网页、命令和独立应用结果应使用新的应用层类型。
不要为这些结果伪造文件索引条目。

首版只做文件工作流，不必立即改通用结果模型。
到命令阶段再引入 `PaletteItem` 这样的结果枚举。
文件 case 保存现有结果快照引用。
其他 case 保存应用标识、URL 或声明式命令。
跨查询结果用同一个 session／query 代次管理。

## F 命令、应用与使用排序

这些能力在对话框工作流稳定后加入。

**应用启动**：先复用已经索引的 `.app`。
应用模式筛选 app 类型，增加手动别名。
例如 `vs` 映射自己的编辑器，`term` 映射终端。
别名只覆盖小规模应用和收藏，不扫描全部文件。
若以后增加应用发现 provider，按应用 URL 去重。
同时处理 bundle ID 相同但安装路径不同的情况。

**网页关键字**：先做 `g 内容` 与 `wiki 内容`。
QueryRouter 在文件语法解析前识别注册关键字。
只有带分隔空格的完整关键字才进入命令模式。
界面明确显示将要打开的搜索引擎。
对查询参数做 URL 编码，不自动获取远程建议。
普通文件查询与原有高级语法继续走 Query。

**文件动作**：首批加入指定应用打开与终端动作。
再加入新建目录、重命名和保存的目录过滤器。
动作使用明确 executable 与参数数组。
文件路径作为独立参数传递，不拼接 shell 字符串。
脚本动作只显式执行自己的脚本及 argv。

网页用 URL 模板；应用用 application URL。
不先建设动态插件、脚本商城或本地 HTTP 服务。

多选后续统一支持复制、拖出与移到废纸篓。
批处理报告每项结果，避免重命名冲突覆盖文件。
macOS 文件移动另做清晰的粘贴／移动语义。

**使用历史**只记录 Mistary 中执行的动作。
不把磁盘修改时间或系统全局最近文档当作历史。
本地保存查询、目标、动作、时间和使用次数。
设置中提供关闭记录和清除历史。

历史目标采用书签、来源标识与路径降级。
不持久化 store 内的 UInt32 entryID。
重扫、压实和卷变化都可能使下标失效。
解析书签后仍需检查存在、权限和真实目标。

书签过期时更新；路径被替换时不要盲继承权重。
已删除或无法解析的条目从有效候选中移除。

排序先用简单、可解释的规则。

1. 满足当前完整查询和来源／目录限制。
2. 精确名称或显式别名优先。
3. 同查询成功使用过的项目在同等匹配中前移。
4. 再用近期、频率和目录上下文打破平局。
5. 名称／时间／大小显式排序不受历史干扰。

给历史与上下文加分设上限。
避免频繁使用的弱命中长期压住精确文件名。
选中项按稳定目标保持，更新不得夺走键盘选择。

不要只给首屏结果重新排序。
大结果集当前只排序前 5000 项，其余保留候选。
空查询则只返回最多 200 个最近修改文件。
历史候选需独立解析、匹配完整条件，再合并去重。
优先复用 `Searcher.withEntryPredicates` 的过滤语义。

不要在每个磁盘条目上读取历史或创建 String。
先在应用层重排小候选集合，再测是否需要改核心。

## G 分阶段开发与验收

```timeline v
M0 | 隔离身份与建立基线 | 首次运行前完成
AX 实验 | 验证对话框可行性 | 预算 2–4 个专注开发日
M1 | 单选文件工作流 | 对话框、Finder 上下文、目录收藏
M2 | 启动器与动作 | 应用别名、网页关键字、指定应用
M3 | 使用历史与体验 | 排序、位置记忆、常驻面板模式
可选 M4 | 扩展个人需求 | 多选、外置卷、双击 Control
```

M0、AX 实验和 M1 组成可日用首版。
粗估需要 8–15 个专注开发日，视 AX 结果调整。
这是规划区间，未经实现测量。
不把所有后续功能塞进同一次交付。
每阶段独立可用，开发完即在自己的机器试用。

**M0 验收**：完成身份和安装路径隔离。
建立同机基线，保留日志与性能测量方法。
记录热键、搜索、预览、复制和实时更新表现。

**AX 实验验收**：输出实际兼容清单。
覆盖原生打开面板、保存面板与 Finder 窗口。
覆盖拒绝权限、目标退出、换窗口和中文路径。
保存文件名保持不变；所有测试都不提交保存。

区分预期焦点交接与意外焦点切换。
取消后不再派发后续操作；迟到回调不推进状态机。
已派发的 AX 请求或事件可能完成，不能承诺撤回。
每次派发前校验目标，仍有校验与发送之间的竞态。

**M1 验收**：在清单中的应用完成真实流程。
打开：搜索 → 导航／选择 → 用户确认。
保存：搜索目录 → 跳转 → 原文件名保持。
Finder：捕获目录 → 切换作用域 → 定位目标。
Quick Switch：看到目录来源后送入原对话框。
失败：显示原因 → 用户选择复制路径。

**M2 验收**：应用别名与文件命中去重。
关键字命令不破坏已有 regex、path 等语法。
带空格、引号、美元符号的路径作为单个参数。
动作菜单显示实际目标和执行结果。

**M3 验收**：重启和重扫后仍能解析历史目标。
删除、改名、移动、过滤与离线来源均有测试。
历史加分不覆盖精确命中和显式排序。
增加持久窗口模式；瞬时模式仍按既有失焦规则隐藏。
记忆位置并将移除显示器后的窗口移回可见区域。

新增测试类建议如下，均为待创建。

- `SearchSessionTests`：上下文捕获、代次与失效。
- `DialogNavigationTests`：状态机、取消、超时、文件名。
- `ActionExecutorTests`：来源校验、分派与参数。
- `QueryRouterTests`：命令前缀和文件语法冲突。
- `UsageRankingTests`：身份解析、完整过滤与稳定排序。

用可注入的 AX 接口测试状态机。
真实系统兼容性仍需手动验收。
`--snapshot` 只证明 Mistary 自身界面状态。
它不能证明第三方对话框已正确导航。

实施时先运行这些现有回归测试。

```sh
OILFIND_FREE=1 swift test --filter SearchEditingTests
OILFIND_FREE=1 swift test --filter ResultsSelectionTests
OILFIND_FREE=1 swift test --filter ResultRefreshTests
```

按阶段运行新增测试，例如 M1 完成后。

```sh
OILFIND_FREE=1 swift test --filter SearchSessionTests
OILFIND_FREE=1 swift test --filter DialogNavigationTests
OILFIND_FREE=1 swift test --filter ActionExecutorTests
OILFIND_FREE=1 swift build -c release
OILFIND_FREE=1 scripts/build-app.sh --debug
```

以上是实施时的验证命令，本轮尚未执行。
新测试必须先创建；改名后检查构建脚本仍可使用。
发布个人稳定版本前运行完整 Swift 测试。
安装／卸载脚本变更需补临时目录测试。
现有脚本测试含上游身份断言，应按 fork 更新。

性能与相同机器上的基底对照。
建议目标：普通搜索 p95 增幅不超过 10%。
短查询与大结果集分开测，控制索引与测量条件。
热键到可输入面板建议 p95 小于 100 ms。
AX 失败不拖住界面，不以固定延时冒充成功。
这些目标尚未验证，可按实际机器调整。

## H 证据、未知项与下一步

本轮读取了用户给出的 Listary 对比 HTML。
也核对了当前架构、应用代码、脚本和测试。
未重新验证对比页中所有 Listary 版本与价格信息。
其比较内容只作为需求输入。

**已核实的源码事实**。

- `SearchPanel.swift`：当前为单个瞬时面板。
- `SearchViewController.swift`：固定文件动作与失焦隐藏。
- `SupplementarySearch.swift`：补充结果引用索引条目。
- `Searcher.swift`：空查询最近修改，限 200 个。
- `Searcher.swift`：大结果集排序前缀为 5000 个。
- `AppDelegate.swift`：数据目录与通知仍属 Oil Find。
- `LegacyAuthorizationCleanup.swift`：清理上游授权遗留。
- `UpdateClient.swift`：清单指向上游网站。
- `scripts/install.sh`：存在旧 Sift 清理动作。
- `Resources/Info.plist`：身份为 `com.oiloil.find`。

读取后对五项关键事实执行了静态断言，全部通过。
这不等于应用构建通过，也不等于 AX 已兼容。
未启动应用、修改源码或执行安装／卸载。
未审计私有 Pro 实现、官网服务或系统所有权限路径。

**Apple 正文依据**。

- [AX 信任检查](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)。
- [Finder Sync 的能力与用途](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)。
- [Finder 中按路径前往目录](https://support.apple.com/guide/mac-help/go-directly-to-a-specific-folder-mchlp1236/mac)。

这些正文支持 API 和平台边界。
它们不证明第三方打开／保存面板的实际兼容性。
浏览器、编辑器、自定义对话框需用自己的机器验证。

**下一步建议**：先实现 M0，再做 AX 实验。
实验成功后，完成 M1 并连续用于自己的真实任务。
再根据“哪些操作仍需切回 Finder”选择下一阶段。
