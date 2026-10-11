# 005：打开／保存对话框工作流实施证据

- 日期：2026-10-11。
- 状态：**已完成（按操作者授权，完成手动路线；跨应用真机验收暂缓）**。
- 本次完成门槛为实施、自动验证与构建；操作者明确允许暂缓实际真机实测，并将 005 标记完成后 commit/push。
- AX 关卡仍为**未判定**；生产自动导航支持集合为**空**。没有把 002 的未授权状态认定为 FAIL，也没有将 fake 导航通过认定为 PASS。
- 实施前 HEAD：`a5da4c995c4f9c20919deed0d7bafc8c7b76fa59`。
- 实现提交：`fcb31c6944727ac95647e43bd49627008c6432d0`（`feat: add guarded manual open and save dialog workflows`）。本证据与计划状态另行提交。
- 分支：沿用 `feat/006-launcher-query-routing`，开始时工作区干净，未切分支。
- 环境：macOS 26.6.2（25G83），arm64；部署目标 macOS 14、Swift tools 5.10、Swift 5 模式、系统框架。

## 前置契约与漂移

已阅读项目 AGENTS.md、docs/ARCHITECTURE.md 和 005 规格，检查规划基底 `6c024bbbf6b917c4a334f4569de070d887ecd66f` 至 HEAD 的范围内差异。

- 002 实现：`befa001c10413e677555058314ec7f6c642acdf7`；[兼容证据](002-ax-compatibility.md) 明确真实清单未验证、自动操作支持集合为空。
- 003 实现：`35ccb53a668bdcdac9abf46b3fb1090db67ca513`；已存在原目标、会话／查询／动作代次及固定文件请求，导航此前 unavailable。
- 004 实现：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`；已存在目录 scope、Finder 快照和收藏候选。
- 006 实现：`fc53d01b347d81b7faad5fcd8f633652b12582a6`；先于 005 落地的模式选择和 typed launcher routing 是实际输入，保留这些行为并加入回归。

只修改 005 范围内应用文件、两个对话框测试文件及 005 状态／证据。没有修改 site/、Pro/、许可证、核心搜索算法、索引格式、全局热键或真实外部应用界面。未安装应用、创建证书、请求实际权限或操作用户文档。

## 当前生产支持清单

- 自动导航：无已验证 app／版本／模式／操作条目，清单为空。
- Open 手动交接：可使用；选择文件或目录后准备目录路径；文件名显示在提示中，复制仅在用户点击时发生，最终文件选择与 Open 由用户在原对话框确认。
- Save 手动交接：可使用；默认文件夹过滤；显式选择文件只使用其所在目录，不读写宿主文件名，不提交 Save 或覆盖确认。
- Quick Switch：可使用手动交接；目录候选由 004 提供，用户明确选择；显示 Finder 来源方法和捕获时间；无自动跳转。
- 只读场景识别：默认关闭，设置中可启用；需要 AX 信任。启发式识别只建立手动模式，不提供自动导航授权。具体真实 app 的识别兼容性尚未验证。
- 识别不支持的应用、未授权或超时：普通搜索保留；用户可从模式菜单显式选择 Open／Save 手动模式，也可点击“普通搜索”退出。

TextEdit、Preview 及其他编辑器／浏览器仍沿用 002 的**未验证**状态，005 真实导航次数均为 0。生产代码不构造 002 的人工辅助 SystemAccessibilityClient，不能将该客户端人工打开／确认路径子面板的实验当作自动适配器。

## 实现

### 识别与权限

`ContextResolver` 在面板取焦点前固定原应用，启用识别后将 AX 只读观察交给专用队列。`SystemDialogRecognition` 有 0.6 秒总截止时间、120 节点、10 层深度和最多 80 ms 的单次 AX messaging timeout；主线程 0.7 秒 watchdog 保证一次结果交付，迟到 IPC 不再改变场景。

Browser 与 Open／Save 按钮必须属于同一 sheet/dialog 容器，且只能有一个符合条件的容器；按钮标题只作为手动场景提示，没有获得任何写入能力。只读结果还检查原宿主和 focused window。不存在通用识别承诺，未知结果保持普通搜索。

`SearchPanel` 给每次展示分配代次，隐藏或新唤起使旧回调失效；重新唤起立即结束旧会话，随后才等待新识别。测试覆盖隐藏后结果返回、新结果先显示后旧结果迟到两种情况。

设置增加独立识别开关（默认 false）、AX 权限状态和显式授权按钮。没有因开启开关或普通搜索而请求授权。拒绝／撤销后普通搜索仍可用。

### 动作与导航边界

`ActionExecutor` 捕获文件身份、是否为文件夹、会话 token 和原上下文。Return、双击、上下文菜单及延迟动画完成均走固定请求；Open／Save 手动模式不会 fallback 到 NSWorkspace.open。离线来源、替换 store、失效文件和过期 session 按原契约停止。

`DialogAdapter` 的生产能力集合为空；注入接口只在明确 capability（app bundle/version、OS version、profile、mode）、原 PID/window、开关、权限都匹配时构造 navigator。没有“AX 已授权就自动支持”的路径。

`DialogNavigation` 新增已捕获 target 入口，执行时校验原 target，不重新抓取后来前台窗口。文件／目录检查在导航 worker 内执行，不持索引锁；每步再次检查原文件及路径身份、权限、截止时间和会话取消。会话／查询／来源更新使导航失效，旧回调不能更新新会话。

预期导航隐藏不会 endSession；成功结束会话，失败恢复原面板供继续搜索或显式复制。意外焦点变化、宿主退出／目标替换、取消及超时仍由 002 状态机停止。已发送的系统请求不能撤回，不自动重试结果未知的步骤。

Save 只发目录请求；Open 只有已批准选择能力时才请求选文件，目录成功而文件未选中明确报告“目录已就绪，需手动选文件”。导航协议没有提交 Open／Save／覆盖的动作。fake 保持空文件名和非空文件名的用例均通过，不能替代宿主实际行为验证。

### 手动恢复与 Quick Switch

交接区域展示状态、实际目录路径、“复制路径”和“普通搜索”。Open 提示保留被选文件名；Save 使用文件时显示所在目录。路径提示支持两行，中英文文案成对维护。按钮绑定同一 token，新会话不能复制旧恢复路径，导航中不可复制。

Quick Switch 只消费用户选择的候选。执行时重新核对收藏是否仍存在、路径与可用状态；Finder 还要求捕获时间不超过 120 秒，以及原 FinderContext 的即时验证闭包确认快照仍有效。陈旧／未知 Finder 不导航，显式复制旧路径仍允许。目录 scope、收藏、启动器不因导航自动改变。

004 已有的收藏解析和 Finder 即时观察仍使用其原线程约定，本轮没有重写该模块；导航新增的逐步文件身份校验在后台，AX IPC 不运行在主线程。

## 最终自动验证

以下命令均 exit 0，核对具名 suite 的非零测试数及零失败；核心 target 的 0 tests 不计入通过数量。

逐条运行计划指定筛选（均 `OILFIND_FREE=1 swift test --filter <suite>`）：

- DialogWorkflowTests：22 项。
- SearchSessionTests：6 项。
- DialogNavigationTests：23 项。
- ActionExecutorTests：22 项。
- FinderContextTests：12 项。
- ResultsSelectionTests：1 项。
- 合计 **86 项，0 失败**。最后的布局调整后重跑 DialogWorkflowTests 和 ResultsSelectionTests，底栏文案调整后再跑 DialogWorkflowTests，其他 suite 在逻辑实现完成后逐条通过。

补充验证：

- `OILFIND_FREE=1 swift test --filter 'QueryRouterTests|PaletteResultsTests|FavoritesStoreTests|SearchSourcesUITests|LanguageTests|ProductIsolationTests'`：**47 项，0 失败**。
- `OILFIND_FREE=1 swift test -c release --filter 'DialogWorkflowTests|DialogNavigationTests|ProductIsolationTests'`：**49 项，0 失败**，包括 Release 拒绝 AX debug 参数的既有边界。
- `python3 Tests/Scripts/test_open_core.py`：**2 项，0 失败**。
- `OILFIND_FREE=1 swift build -c release`：成功，最终布局改动后再次通过。
- `OILFIND_FREE=1 scripts/build-app.sh --debug`：成功，最终调试包 `build/debug/Mistary.app` 为 ad-hoc 签名，没有安装／证书创建。
- `plutil -lint build/debug/Mistary.app/Contents/Info.plist`、`codesign --verify --strict build/debug/Mistary.app`：通过。
- `git diff --check`：通过；提交前再次核对修改范围与新增文件。

回归覆盖：无批准 capability 时不构造 navigator、不发 AX 写入；显式手动 Open／Save 不普通打开、不自动复制；Save 文件默认目录筛选、显式文件只取父目录；延迟请求遇模式切换、来源离线、原文件删除或新会话时停止；原目标入口不 recapture；保持 Save 空／非空文件名；每步路径失效阻断后续写入；权限／宿主／系统环境门禁；取消后迟到 worker 不 handoff；收藏删除、过期或改变的 Finder 快照拒绝 Quick Switch；识别歧义／跨容器／无权限／陌生焦点拒绝；watchdog 一次回调和两种乱序展示；中英文布局无控件重叠。

## 本应用界面验证

仅验证本应用渲染，不代表第三方 AX 兼容性：

- 实际调试包运行 `--snapshot ... --state settings --language zh --appearance light` 和英文深色对应命令，两张设置快照 exit 0，1080×1200；检查开关、权限提示、授权按钮和说明。
- `MISTARY_DIALOG_SNAPSHOT_DIR="$PWD/build/debug/005-evidence" OILFIND_FREE=1 swift test --filter DialogWorkflowTests`：测试 snapshot controller 生成中文浅色／英文深色手动交接快照，1440×920，对应 720×460 面板；检查路径、两行说明、复制按钮与普通搜索按钮布局。
- 图片在忽略目录 `build/debug/005-evidence/`，不提交构建产物。测试只使用自己的随机临时文件夹。

## 失败与修正记录

- 首次测试编译失败：QueryRoute 不遵循 Equatable；改为匹配 .files 并核对其文本，不扩展生产类型。
- 日志计数 wrapper 首次遗漏单数 `1 test`，第二次正则转义错误；两次实际 Swift suite 均通过，wrapper 失败没有计为验证成功。咨询 Advisor 后改为独立读取具名 suite 的 passed／Executed 汇总行，核对脚本 exit 0，最终总数 86。
- 布局截图测试首次编译失败：对非 optional NSView 使用多余 `!`；移除后 22 项通过。
- Advisor 指出跨 sheet 证据拼接、乱序回调顺序覆盖不足以及新增同步文件检查问题；已按容器识别、补两个回调顺序，并将导航新增文件校验放到 worker。Advisor 意见为辅助审阅，不能替代实际测试／真实兼容性证据。
- 最终 Advisor 根据可见手动交接图指出底栏长状态被截断，改为短状态“请手动前往／Navigate manually”和“交接失败／Handoff failed”，详细原因保留在上方区域，重跑工作流与生成快照。
- Advisor 收到的 Git 上下文实际受用户配置限制为摘要，未获取完整 diff、新增源码或设置图片；tracked file attachments 被全局配置拒绝。本轮不记作 Advisor 独立代码验证通过，实际测试、构建和图片读取由实施者完成。
- Release 构建沿用原有 IndexManager weak/implicit strong capture warning，没有顺带修改核心。

## 真机验收暂缓

以下全部为**未执行／未验证**，没有记作失败或通过：

1. TextEdit、Preview 和操作者常用编辑器／浏览器的实际只读识别，以及 Open／Save／Quick Switch 跨应用交接。
2. 每个实际批准操作至少 10 次重复；中文／空格／符号路径、保存空／非空原文件名、原格式过滤、原面板保持打开和零误提交。
3. 实际权限拒绝／撤销、宿主关闭／退出／替换、意外切窗口、取消、超时、辅助进程、不同界面语言和多显示器。
4. ad-hoc 重建后的权限保持、低版本 macOS 14 实机、Finder／Automation 的真实目录快照验证，以及网络／离线文件系统下原有收藏解析的响应时间。

后续先完成 002 真机清单并判定 PASS／PARTIAL／FAIL，再按准确 app／OS／profile／模式／操作能力接入生产 navigator。当前完成的是手动路线和受约束接口，完整 M1 自动对话框目标仍待批准与实现；不得只添加 capability 常量便宣称自动兼容。
