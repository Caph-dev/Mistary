# 003 搜索会话与动作执行器实施证据

## 交付状态

- 已完成实现与自动验证；按操作者明确要求，跨应用真机验收暂缓，不作为本次完成门槛。
- 日期：2026-10-10；环境：macOS 26.6.2、arm64、Swift 5 语言模式、macOS 14 部署目标。
- 实施基线：`daf37a3`。001 实现：`2f5f32d2089ad9c902659a460b8310ca21bc97d3`；002 实现：`befa001c10413e677555058314ec7f6c642acdf7`。已有变化属于前置计划，工作区起始干净。
- 实现提交：`35ccb53a668bdcdac9abf46b3fb1090db67ca513`；本记录提交仅补充实际实现 SHA。
- 构建产物：`build/debug/Mistary.app`，ad-hoc 签名。未安装、卸载、创建证书或操作真实用户文件。
- 实现只涉及计划列出的应用层文件与两个新增 UI 测试文件；另更新 003 计划、计划入口和本证据。未修改核心、查询算法、索引格式、SupplementaryHit、site、Pro 或许可证。

## 实现契约

`SearchPanel.show` 在 orderFront/makeKey/focus 前调用可注入的 ContextResolver。热键、菜单、reopen 共用此入口；可见面板的重复展示保留 session ID 与目标。重复 toggle 的隐藏只结束会话。indexing/welcome/interaction 自动展示使用普通模式，无外部目标；onboarding 即使由热键完成也不绑定外部窗口，自动 indexing 展示不覆盖已可见的用户会话。

生产 resolver 只捕获外部前台应用的 PID/bundle ID，尚不识别 Finder、Open/Save 或具体窗口，因此模式始终降级 ordinary，目录 scope 为 nil。捕获不请求 AX 权限，不消费 002 的实验导航。可注入 resolver 可提交类型化模式、窗口身份与目录；这只是后续计划的接口，不能视为真实兼容性证据。

SearchSession 保存 session ID、query/action generations、invocation source、模式、目标及 directory scope。查询、来源变化、结束/重开使旧请求失效；查询结果提交也校验 session token。`submitContext(_:for:)` 只接受当前 token，提交上下文后递增代次。`hide(endingSession: false)` 保留会话供后续预期焦点交接使用；普通隐藏结束会话。

ActionRequest 固定 action ID、session token、source ID、store 强引用/捕获版本、entry ID、URL/name 与可获取的文件身份。打开前及按压动画回调前检查同一快照；菜单条目在建立时绑定请求，之后换行不会替换目标。合法的旧目标仍打开捕获文件；失效目标取消，不重新读取当前选择来修补。

在线操作在派发前核对来源在线、相同 store、live entry 与相同路径，并比较 lstat/stat 的 device/inode/birth time 以及解析后的符号链接路径。I/O 在索引锁外进行，离线来源不会进行身份读取。捕获 store version 作为证据，但无关条目的版本更新不取消合法文件。store 替换、目标删除/改名/祖先路径变化、原路径文件或符号链接目标替换均有回归。

普通打开、Finder 定位、Quick Look、文件复制、路径/名称复制、废纸篓全部进入执行器。拖拽导出复用 copyFile 的在线校验。文件复制为 URL-only；路径复制保留既有 URL＋字符串格式；名称复制为字符串。离线路径与名称复制只读索引元数据，仍要求有效会话、来源/store/entry/path。编辑器有选区时普通 ⌘C/⌘X/⌘V 优先文本编辑，⌘⌥C 仍复制名称。

动作结果通过 ActionEvent 和控制器 `onActionEvent` 提供：

- open/reveal/preview 的 `accepted` 是终态，表示系统请求已派发/接受，不证明目标应用读到了内容。Finder 定位 API 没有可观察返回值，只能记录派发。
- copyFile/copyPath/copyName 的 `verified` 表示剪贴板写入返回成功且读回类型/值匹配；不代表 Finder 已成功粘贴。
- trash 先发出 `accepted`，随后仅发出一次终态。只有系统无错误、原路径明确 ENOENT、返回目的地的文件身份匹配时才 `verified`；仅返回 mapping 不算成功。失败提供具名原因。结束会话不会抹掉已派发操作的完成事件，也不重试。
- `cancelled(reason)` 表示未继续派发；`failed(reason)` 表示系统/剪贴板拒绝或无法验证已派发操作。共享 receipt 防止同一请求被重复派发/重复计数；另有按 URL 的在途集合，两个不同 trash 请求针对同一文件时只派发一次，回调结束后释放该目标，已有新增回归。trash 的 accepted 与终态共用 action ID，后续历史消费者须按动作语义去重。

Quick Look provider 读取捕获并验证的请求。有意方向键选择生成新预览请求，自动刷新只校验已有目标，失效则关闭。菜单 tracking、拖拽、Quick Look 与 pending open 都暂缓失焦隐藏；菜单关闭后延迟检查隐藏，给菜单动作派发机会。异步失焦检查绑定发起时 session ID，旧回调不能结束新会话。

Return、⌘Return、⌘Y、Tab、Escape 保留原语义；新增 ⌘K 与右键使用同一绑定请求的菜单。输入法 marked text 不触发动作菜单。底栏显示场景、动作快捷键和双语具名失败，保留既有离线来源提示。所有目标窗口导航项禁用且说明暂不可用。

## 自动验证结果

以下命令均已实际执行、exit 0，筛选到非零预期测试：

```sh
OILFIND_FREE=1 swift test --filter SearchSessionTests
# Executed 6 tests, with 0 failures
OILFIND_FREE=1 swift test --filter ActionExecutorTests
# Executed 22 tests, with 0 failures
OILFIND_FREE=1 swift test --filter SearchEditingTests
# Executed 1 test, with 0 failures
OILFIND_FREE=1 swift test --filter ResultsSelectionTests
# Executed 1 test, with 0 failures
OILFIND_FREE=1 swift test --filter ResultRefreshTests
# Executed 3 tests, with 0 failures
```

计划指定的五类合计 33 个不同测试（ActionExecutorTests 最后另加在途废纸篓去重用例并独立运行 22 项）。补充回归：

```sh
OILFIND_FREE=1 swift test --filter 'ActionExecutorTests|SearchSourcesUITests|SupplementarySearchTests|LanguageTests|ApplicationMenuTests|ProductIsolationTests'
# Executed 43 tests, with 0 failures
# 其中 ActionExecutorTests 21；其他五类分别 4、5、5、3、5，共 22。
```

两组去重合计 55 个测试。后一次组合运行覆盖了离线失败提示的最终修复；最终 ActionExecutorTests 独立运行另覆盖新增的废纸篓去重用例。没有把未选中的 core target 所报告的零测试当作验证。

```sh
OILFIND_FREE=1 swift build -c release
# Build complete!
OILFIND_FREE=1 scripts/build-app.sh --debug
# Build complete!; build/debug/Mistary.app; Debug ad-hoc signature
plutil -lint build/debug/Mistary.app/Contents/Info.plist
# OK
codesign --verify --strict build/debug/Mistary.app
# exit 0
python3 Tests/Scripts/test_open_core.py
# Ran 2 tests; OK
git diff --check
# exit 0
```

构建存在已有 `IndexManager.swift:130` weak/implicit strong capture warning；本计划没有修改该核心文件。未引入新的编译错误。

中英文界面快照使用临时目录，仅包含 `readme.txt`：用 oilfind-cli scan 生成独立 fixture.oilfind，再用调试包 `--snapshot --db <fixture> --query readme --language zh/en`。两张均生成 1600×1120 PNG，已查看：场景、结果统计、⌘K 与其他快捷键在标准 800×560 面板中可见，无重叠。快照、索引和临时文件未提交。

本地原始日志及快照位置（临时文件，可能被系统清理；上方记录为持久证据）：

- 五类独立筛选：`/var/folders/fc/qdm51jvd7f11661zwl42j58r0000gn/T/mistary-003-final.Lc5GWMyDBc/{SearchSessionTests,ActionExecutorTests,SearchEditingTests,ResultsSelectionTests,ResultRefreshTests}.log`。
- 最终动作筛选（22 项）：`/var/folders/fc/qdm51jvd7f11661zwl42j58r0000gn/T/mistary-003-trash.TAVlNV7Ph9`。
- 最终补充回归：`/var/folders/fc/qdm51jvd7f11661zwl42j58r0000gn/T/mistary-003-checked.5cwcWQQFjc/regressions.log`。
- 快照：`/var/folders/fc/qdm51jvd7f11661zwl42j58r0000gn/T/mistary-003-snapshot.Qixb0peIDT/search-{zh,en}.png`。

初次新测试编译发现 internal 测试 API 的 import 问题；随后修正重复 show 的 token 断言与改名夹具，并用测试修复重复隐藏、菜单动画抢先隐藏和离线底栏提示回归。上方只列最终通过结果，早期失败没有记为通过。

## 后续集成与未验证边界

- 004 可以通过 resolver/`submitContext` 提交 Finder 目录及 scope；本阶段不实施目录过滤算法。
- 005 可以持有 token、目标窗口身份和候选文件快照，使用预期隐藏接口；当前 contextNavigation 始终 unavailable，002 AX 关卡仍未判定，不批准任何自动导航。
- 006 可扩展请求 payload/结果身份，但必须保留 session token、独立捕获/校验、receipt 和 ActionEvent 语义；本阶段没有网页/命令结果，也没有伪造 SupplementaryHit。
- 按操作者要求暂缓：真实 Finder 文件/路径粘贴、跨应用菜单和失焦、Quick Look 方向键与真实窗口焦点、拖拽到外部应用、真实废纸篓行为、连续热键日用、AX/Finder 权限与兼容性、稳定签名权限保持。fake、NSWindow 单测和本应用 snapshot 不能替代这些验收。
- 文件身份检查无法消除系统路径 API 检查与使用之间的 TOCTOU；不承诺原子地打开同一文件或证明外部应用读取内容。符号链接目标替换能在检查时被发现；废纸篓验证无法取得可靠身份时报告未验证，不伪造成功。
