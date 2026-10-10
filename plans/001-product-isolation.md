# 计划 001：隔离 Mistary 身份、持久化与上游更新

## 状态

- 状态：已完成（按操作者决定，真实环境验收暂缓）。
- 实现提交：`2f5f32d2089ad9c902659a460b8310ca21bc97d3`；自动验证与未验证项见 [实施证据](evidence/001-isolation.md)。
- P1；工作量 M；风险高；阶段 M0；依赖：无。
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
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Package.swift Resources/Info.plist Sources/OilFind/main.swift Sources/OilFindApp/AppDelegate.swift Sources/OilFindApp/Application.swift Sources/OilFindApp/UpdateManager.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/L10n.swift scripts/build-app.sh scripts/install.sh scripts/uninstall.sh scripts/create-signing-cert.sh Sources/OilFindApp/ProductIdentity.swift Tests/OilFindUITests/ProductIsolationTests.swift Tests/Scripts/test_uninstall.py Tests/Scripts/test_install.py Tests/Scripts/test_product_identity.py
```

## 范围清单

- `Package.swift`
- `Resources/Info.plist`
- `Sources/OilFind/main.swift`
- `Sources/OilFindApp/AppDelegate.swift`
- `Sources/OilFindApp/Application.swift`
- `Sources/OilFindApp/UpdateManager.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/L10n.swift`
- `scripts/build-app.sh`
- `scripts/install.sh`
- `scripts/uninstall.sh`
- `scripts/create-signing-cert.sh`
- `Sources/OilFindApp/ProductIdentity.swift（新建）`
- `Tests/OilFindUITests/ProductIsolationTests.swift（新建）`
- `Tests/Scripts/test_uninstall.py`
- `Tests/Scripts/test_install.py（新建）`
- `Tests/Scripts/test_product_identity.py（新建）`

## 为什么重要

当前工作目录虽叫 Mistary，应用仍使用 Oil Find 的数据目录、更新源和授权清理。个人 fork 必须先隔离运行时身份，避免运行或安装 Mistary 时触碰原应用。该阶段建立后续实验可以使用的应用包，不实现任何新搜索功能。

## 当前状态与证据

Sources/OilFindApp/AppDelegate.swift 的启动路径包含：

~~~swift
LegacyAuthorizationCleanup.run()
UpdateManager.shared.start()
~~~

同文件的 dbURL 指向 Library/Application Support/Oil Find/index.oilfind；showRequest 为 com.oiloil.find.show，AppLog subsystem 也为上游身份。Sources/OilFindApp/Application.swift 在正常启动前调用 SystemUpdateFiles().registerLaunch；AppDelegate 启动后调用 cleanupAfterLaunch。

Resources/Info.plist 的 bundle ID 是 com.oiloil.find，scheme 为 oilfind。Package.swift 自动检测 Pro/Sources/OilFindPro；Sources/OilFind/main.swift 条件组装私有扩展。scripts/install.sh 会关闭 OilFind/Sift，并删除 Sift 数据；scripts/uninstall.sh 删除上游应用、偏好和 Keychain 项。

Tests/Scripts/test_uninstall.py 已 stub defaults、pgrep、rm、security、osascript，并包含上游授权保留/清理断言。改造时更新这些断言，并重新盘点所有外部副作用；不要把现有夹具误描述为真实卸载测试。

## 产品决策与交付契约

- 计划默认：显示名 Mistary；bundle ID me.caph.mistary；scheme mistary；通知 me.caph.mistary.show；日志 subsystem 同 bundle ID。
- Swift executable target 继续叫 OilFind；build 脚本将其复制为 Mistary.app/Contents/MacOS/Mistary，Info.plist executable 为 Mistary。这同时避免按进程名误关闭 Oil Find。
- 主索引位置为 ~/Library/Application Support/Mistary/index.oilfind；个人配置、收藏和历史随后也放在 Mistary 数据域。盘点缓存、Keychain、登录项：没有使用的项记录“未使用”，不要增加空功能。
- 默认不迁移、不清理、不读取旧 Oil Find 偏好或授权。用户以后明确要求迁移时另写方案。
- 个人产品没有更新源：关闭自动检查、手动检查、下载/安装、启动更新收据处理以及调试更新入口；保留底层更新库供已有核心测试使用，避免删除整套库。
- 构建默认不自动组装私有扩展；仅 manifest 与组装入口可涉及私有 target。ApplicationExtension 中性协议保留。
- build 输出分别为 build/Mistary.app 与 build/debug/Mistary.app。安装只操作 /Applications/Mistary.app；支持测试覆盖路径与外部命令注入，但生产默认值固定。
- 签名使用 MISTARY_SIGN_IDENTITY 或 Mistary Self-Signed；不复用 Oil Find Self-Signed。不自动生成证书；允许调试 ad-hoc，稳定版本权限保持需人工实测。

## 范围

仅修改上方范围清单。UpdateManager 中增加不可被偏好重新开启的产品禁用状态；菜单、设置和启动路径均遵守它。LegacyAuthorizationCleanup.swift、OilFindCore/Update/ 作为保留代码不必重写，只移除 Mistary 可达调用。现有 UI 测试若依赖更新菜单布局，可在本阶段最小更新对应断言，并在范围记录具体文件后再改。

范围外：核心索引/查询算法、site、Pro、许可证和授权系统重建、自动迁移、更新服务器、发布包 scripts/package.sh（当前首版不发布归档）。若要执行归档发布，先单列脚本隔离计划。

## 步骤与验证

### 1. 记录基线并建立身份夹具

盘点所有生产入口和产品身份；新增 ProductIdentity 为应用层唯一身份来源，plist/脚本通过测试核对一致性。新增临时路径与注入 UserDefaults 的隔离测试；不调用真实旧清理。先运行现有 SearchEditingTests 记录基线，随后创建 ProductIsolationTests。

验证：OILFIND_FREE=1 swift test --filter SearchEditingTests；OILFIND_FREE=1 swift test --filter ProductIsolationTests。预期：编辑快捷键不变，Mistary 与 Oil Find 域互不读写。

### 2. 隔离构建与所有启动/更新入口

修改 manifest 和组装入口使个人构建稳定使用公开 target。关闭 Application、AppDelegate、UpdateManager、菜单和设置中的更新可达路径；取消旧授权清理。更新中英文应用文案及数据、通知、日志身份。测试重启、普通唤起和 URL 入口不得启用更新。

验证：OILFIND_FREE=1 swift test --filter ProductIsolationTests；OILFIND_FREE=1 swift test -c release --filter ProductIsolationTests；python3 Tests/Scripts/test_open_core.py；OILFIND_FREE=1 swift build -c release。预期：debug与release身份断言通过，更新/授权副作用计数为零，公开模块边界仍通过。

### 3. 隔离构建、安装、卸载与签名脚本

更新打包映射、签名参数和证书脚本的名称/备份目录。只按 Mistary bundle ID/PID 退出目标；不得用 OilFind 进程名退出上游。卸载默认移入废纸篓，并确认目标路径；不删除任何 Oil Find/Sift 数据或 Keychain。重新设计个人卸载选项，不保留付费试用语义。

脚本测试使用临时 HOME/应用目录与 stub 外部命令，覆盖取消、错误参数、进程未退出、同名应用、安装与卸载。HOME 只能作为子进程测试环境传入，不在交互 shell 中覆盖。副作用日志不得泄露凭据。更新测试夹具以覆盖移入废纸篓的新路径。

验证：bash -n scripts/build-app.sh scripts/install.sh scripts/uninstall.sh scripts/create-signing-cert.sh；python3 Tests/Scripts/test_uninstall.py；python3 Tests/Scripts/test_install.py；python3 Tests/Scripts/test_product_identity.py。预期：exit 0；记录中的写入、删除、退出目标均只属于 Mistary。

### 4. 构建隔离应用包并记录身份

验证：OILFIND_FREE=1 scripts/build-app.sh --debug；plutil -lint build/debug/Mistary.app/Contents/Info.plist；codesign --verify --strict build/debug/Mistary.app。预期：正确新路径、executable 和 bundle ID，签名可验证。若只有 ad-hoc，明确标记，不声称权限能跨重建保留。

在授权的手动环境中验证两应用同时运行、快捷键不冲突、重启独立与权限重新授予。不要为验证真实卸载而删除原应用。记录 plans/evidence/001-isolation.md。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `SearchEditingTests`、`ProductIsolationTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [x] 所列测试/构建通过，新增类非零测试；脚本所有副作用均由夹具隔离。
- [x] 正式构建也无法检查、下载或安装上游更新；仅改默认开关不算完成。
- [x] 已实现旧授权、索引、偏好、通知、scheme、日志与登录项身份隔离；真实偏好域与登录项验收暂缓，未标为通过。
- [x] 卸载默认移入废纸篓，清理限定确认后的 Mistary 路径；脚本夹具通过，未执行真实卸载。
- [ ] 两款应用共存与稳定签名权限验收暂缓（操作者明确决定不作为本次完成门槛）；未验证项已记录。
- [x] 后续计划可直接使用 build/debug/Mistary.app；README 状态和实现 SHA 已更新。

## 停止条件

旧更新或授权行为仍可由 URL、设置或调试参数触发时不得进入 AX 实验。需要真实安装、证书创建或数据迁移而未获授权时，先交付构建和夹具结果再报告。核心更新测试因删除库而失败时收回该删除，保持最小应用层隔离。

## 维护说明

上游 cherry-pick 最容易重新引入更新、身份常量和旧安装逻辑。每次移植复跑身份与脚本回归。个人归档发布和自动更新另列计划；保留 MIT 原作者版权声明。
