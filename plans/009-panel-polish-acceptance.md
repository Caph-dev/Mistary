# 计划 009：增加常驻面板、位置记忆并完成日用验收

## 状态

- 状态：待执行。
- P2；工作量 M；风险中；阶段 M3 收尾；窗口行为硬依赖003会话生命周期。最终日用验收依赖004/005/006/007/008；005手动路线须据实标注。
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
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/PanelPreferences.swift Sources/OilFindApp/SearchPanel.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/SearchSession.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/L10n.swift Tests/OilFindUITests/PanelBehaviorTests.swift
```

## 范围清单

- `Sources/OilFindApp/PanelPreferences.swift（新建）`
- `Sources/OilFindApp/SearchPanel.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/SearchSession.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/L10n.swift`
- `Tests/OilFindUITests/PanelBehaviorTests.swift（新建）`
- `plans/evidence/009-daily-acceptance.md（实施时新建）`

## 为什么重要

首版是瞬时搜索面板，窗口位置每次冷启动重置，失焦后自动隐藏。个人长期使用可以增加保持打开模式与位置记忆，但不能使旧对话框上下文永远有效。本计划先独立完善窗口，再按实际阶段完成联合日用验收。

## 当前状态与证据

Sources/OilFindApp/SearchPanel.swift 初始化：

~~~swift
isMovable = false; hidesOnDeactivate = false
~~~

show在cold时按鼠标所在屏幕重新居中并限定尺寸。SearchViewController.hideIfInactive在非key且无Quick Look/menu/dragging时隐藏。SearchPanel使用非激活浮动面板、动画generation，toggle在已可见/key时隐藏；这些行为不应被常驻模式随意替换。

## 前置交付与窗口规格

003提供会话/目标代次与可取消动作，窗口hide和导航handoff分开。004提供scope/收藏，005提供已支持自动导航或明确手动路线；006/007提供命令与动作，008提供最近使用。这些是联合验收依赖，窗口偏好代码可先独立完成。

默认继续瞬时模式：失焦隐藏，但保持菜单、拖动、Quick Look的例外。保持打开模式仅改变普通失焦隐藏，不把NSPanel改成必须激活应用的主窗口。Escape、⌘W与重复全局热键仍明确关闭/隐藏；不能因常驻而禁用用户关闭。

保持打开后旧Open/Save目标在原窗口失效、非预期切换或会话过期时变为unavailable。用户再次全局唤起/显式刷新场景时捕获新目标，不能偷用新前台替换正在执行请求的目标。允许用户切普通模式继续搜索，禁用旧导航动作。

增加专用可拖动区域，避免拖搜索框/结果行而改变位置。记忆普通面板frame与显示器标识；下次按策略恢复有效屏幕内位置，屏幕移除/分辨率变化/缩放时clamp到visibleFrame，保留合理最小尺寸。缺少可用屏幕时延迟恢复，不强制无效尺寸。跨Space/全屏保持现有collectionBehavior。

窗口偏好放Mistary域；不改系统窗口位置或Oil Find设置。窗口行为没有新增权限，不加入双击Control或字母监听。

## 范围

仅范围内文件；不改核心搜索、AX控制流程或其他应用窗口。联合验收发现前置功能缺陷时记录并回到对应计划修复，不能在窗口任务中静默扩大scope。

## 步骤与验证

### 1. 实施窗口偏好和恢复策略

把模式、frame、screen identity与默认值做可注入PanelPreferences。使用fake屏幕几何测试不同分辨率、负坐标、多显示器、主屏变化、屏幕移除与无屏幕。为普通拖动增加不干扰输入/结果的区域。

验证：OILFIND_FREE=1 swift test --filter PanelBehaviorTests。预期：恢复frame处于有效visibleFrame；默认瞬时；配置损坏回安全默认；没有改系统其他窗口。

### 2. 接入失焦与会话生命周期

区分expected handoff、普通失焦、菜单/Quick Look/dragging与显式close。保持打开时意外目标切换会禁用导航，旧回调不能恢复已过期会话。动画反向、热键连续toggle和输入法marked text按原行为处理。

验证：OILFIND_FREE=1 swift test --filter PanelBehaviorTests；OILFIND_FREE=1 swift test --filter SearchSessionTests；OILFIND_FREE=1 swift test --filter ResultsSelectionTests。预期：瞬时模式回归保持，常驻可关闭，旧导航失效，连续toggle不丢动画状态或键盘焦点。

### 3. 验证交互和跨应用回归

覆盖⌘C编辑选区、Return/⌘Return、Tab、⌘Y、Escape、菜单、拖动、Quick Look、多屏幕和全屏Space。005如果自动路线通过，运行其真实兼容清单；手动路线只验证显式复制/路径交接，不标自动通过。

验证：OILFIND_FREE=1 swift test --filter SearchEditingTests；OILFIND_FREE=1 swift test --filter ResultRefreshTests；OILFIND_FREE=1 swift test --filter DialogWorkflowTests；OILFIND_FREE=1 swift build -c release。预期：所需阶段已实施时测试非零并通过；缺少前置测试时标“联合验收未就绪”，不以零匹配算成功。

### 4. 完成稳定版本与真实任务验收

前置阶段完成后运行 OILFIND_FREE=1 swift test、python3 Tests/Scripts/test_open_core.py、python3 Tests/Scripts/test_product_identity.py、python3 Tests/Scripts/test_install.py、python3 Tests/Scripts/test_uninstall.py、OILFIND_FREE=1 scripts/build-app.sh。预期：全部exit0，正式bundle身份正确，调试探针不在生产入口；脚本仅夹具模拟，不真卸载。

连续至少3个日常使用日记录自己的真实任务：Open/Save目录导航或手动路线、Finder scope与Quick Switch、应用/网页、指定应用/终端、收藏/过滤器、最近使用和多显示器恢复。次数为规划验收目标，不能未经使用写“已完成”。记录系统/app版本、权限、成功/失败和仍需切回Finder的操作。

同机同索引对照基底记录搜索p95与热键到可输入p95；建议目标分别增幅≤10%与<100ms。测量需记录样本数、短查询/大结果集/冷暖状态，时间阈值不写成易波动CI断言。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `PanelBehaviorTests`、`SearchSessionTests`、`ResultsSelectionTests`、`SearchEditingTests`、`ResultRefreshTests`、`DialogWorkflowTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [ ] 窗口/会话/编辑/选择回归通过，常驻与瞬时模式可切换且可关闭。
- [ ] 多显示器恢复可见，菜单/Quick Look/拖动保持正常，原对话框过期不能继续导航。
- [ ] 联合全量Swift、公开边界、身份和脚本夹具测试通过；真实日用记录存在。
- [ ] 明确首版是自动支持清单路线或手动交接路线，未实现/未验证项仍标出。
- [ ] plans/evidence/009-daily-acceptance.md保存测量/问题与最终实际SHA，不含秘密或真实文档内容。

## 停止条件

缺任何前置交付时可完成窗口子任务，最终联合验收标未完成。常驻模式导致旧对话框请求继续执行或不可关闭时不得交付。性能异常先按对应阶段定位，不以重写核心/移除验证检查补救。

## 维护说明

新增窗口样式、显示器策略或macOS版本后重跑几何/全屏测试；新增AX应用后更新实际兼容清单。M4功能须从backlog另拟独立计划，不能混入本阶段。
