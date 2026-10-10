# 002：AX 可行性实验实施证据

- 日期：2026-10-10。
- 状态：**已完成（按操作者决定，真机验收暂缓）**。代码、fake 测试与构建边界验证已交付；真实跨应用实验尚未开始。操作者先选择“暂缓真机验收”，随后明确要求将 002 标记为已完成并 commit/push，以实现与自动验证作为本次完成门槛；不批准 005 自动导航。当前运行的调试进程报告 AX 未授权，没有请求授权提示，也没有观察其他应用的 AX 树。
- AX 关卡：**未判定**，不能把权限阻塞归为 PASS / PARTIAL / FAIL。真机验收与关卡判定按操作者决定暂不作为本次计划完成门槛。
- 005 获验证支持的自动导航操作集合：**空**。当前不能启用任何按 app/模式划分的自动导航。
- 实施时 HEAD / 001 实现 SHA：`2f5f32d2089ad9c902659a460b8310ca21bc97d3`。
- 002 实现提交：`befa001c10413e677555058314ec7f6c642acdf7`（`feat: add guarded AX dialog navigation experiment`）。计划状态与本证据另行提交，提交记录可区分代码交付与操作者决定的计划关闭。
- 分支：`main`，沿用当前工作区；实施阶段未自动切分支、commit 或 push，交付后操作者明确授权 commit/push。开始时已有 `plans/001-product-isolation.md`、`plans/README.md`、`plans/evidence/001-isolation.md` 的修改；001 相关修改完整保留。
- 环境：macOS 26.6.2（25G83），arm64；部署目标 macOS 14、Swift tools 5.10、Swift 5 语言模式、系统框架。

## 前置交付与范围

001 的调试包 plist 与签名已核对：`build/debug/Mistary.app`、executable `Mistary`、bundle ID `me.caph.mistary`。产品隔离测试继续通过，没有恢复旧更新、授权清理、私有模块或上游应用入口。调试包为 ad-hoc；跨重建权限保持仍未验证，没有创建证书或安装应用。

本轮仅修改计划所列代码文件、新测试和 002 的状态/证据。`site/`、`Pro/`、许可证、核心索引/查询、索引格式、Finder UI、全局按键监听、正式菜单和文件动作没有改动。

## 实现与当前限制

### 权限

`Permissions.swift` 增加 `SystemAccessibilityPermission`：`isTrusted()` 无提示；只有显式调用 `requestTrust()` 才传递 `kAXTrustedCheckOptionPrompt`。普通搜索启动不构造 AX 客户端，也不请求新权限。

Full Disk Access、Accessibility 分开检查，Automation 单独记录 `notRequested`。没有使用 Apple Events，AX 授权不能代表 Automation 授权。发起权限提示是异步请求，不把提示 API 的调用成功视为已授权。

### 会话状态机

`DialogNavigation.swift` 提供可注入权限、AX 客户端、时钟以及每步截止时间的实验接口。流程为 captured → validated → targetReady → pathControl → navigating → verified；另有 cancelled/failed 终态及具名原因。

- AX 调用在专用串行队列执行，完成回调在主线程。独立 watchdog 为阻塞调用设置单调时间上限；注入时钟用于同步截止检查。
- watchdog 核对步骤代次与提交终态共用锁；旧步骤的计时器不能取消后来步骤。
- 取消/超时立即失效会话；返回后的过期响应不能推进状态、再次回调或派发后续步骤。旧 IPC 真正返回前，同一 navigator 的新请求返回 busy。
- 目标包含宿主 PID、实际 AX PID、窗口与面板身份、模式、会话代次。真实客户端另持 AX 元素及宿主/辅助进程 launchDate，以防 PID 复用。
- 只允许预期的 Mistary → 原目标焦点交接。退出、元素替换、意外焦点变化及权限撤销中止会话；交接完成后切回 Mistary 也属于意外变化。
- 发送前核对目标；所有低级 AX 请求均检查权限、会话/期限、宿主启动时间、允许的前台进程，并对实际请求的元素设置有限 messaging timeout。树遍历有节点/深度上限和总期限。
- Open 可请求文件选择，只有读回同一文件才算选中；当前真实适配器不支持选择文件，会独立报告 selectionUnsupported，不能把目录完成当成文件选择完成。Save 请求文件选择会在捕获前拒绝。

**取消不撤回外部副作用。** 检查与实际系统派发之间仍存在竞态；已交给目标进程的写入可能完成。`writeMayHaveCompleted` 是保守标记，写入后的超时报告 `resultUnknown`，不自动重试。

### 真实实验适配器的范围

`AccessibilityClient.swift` 当前为**人工辅助适配器，真实兼容性未验证**。它有意不假设任何应用提供通用的目录提交动作：

1. 操作者先手动打开原 Open/Save 面板，再手动打开 Go to Folder 子面板。
2. 只读探针按角色、属性名称、能力和 identifier 的 SHA256 token 列出控件，不输出标题、文本值、完整 URL、文件名或原始 identifier。缺失 identifier、重复 token 或不满足角色/归属的控件不允许匹配。
3. 显式指定原面板、嵌套子面板的可写路径字段、独立 AXBrowser 目录观察控件，以及 Save 文件名字段。路径框必须获得焦点，Secure Input 或 SecureTextField 会失败。
4. 只向已核对的路径框写目录 `AXValue`，读回该值。操作者手动确认 Go to Folder；适配器轮询子面板消失，再独立观察目录、原面板身份和 Save 原文件名。
5. 无可靠的目录 URL 或文件名观察能力时失败。AXBrowser 的 URL 是否确实表示当前目录仍须逐 app 验证；不能只凭属性存在认定兼容。

客户端不调用 `AXConfirm`、不合成按键、不点击原面板按钮。`submissionActionsSent = 0` 表示客户端没有发送 Open/Save/覆盖提交动作，**不是已测量所有目标应用均不会因 AXValue 改变自行提交的证明**。真实面板是否保持打开仍是验收项。

这套接口并未交付完整自动导航：路径子面板的打开与确认目前需要人工操作。拿不到真实 AX 样本前，没有写死按钮标题或猜测控件 identifier，没有扩展成通用自动化平台。缺少所需属性只能说明本适配器不支持，不能推导 AX 整体不可行。

### DEBUG 探针

`AXProbe.swift` 整个文件使用 `#if DEBUG`；`Application.swift` 的探针派发也只在 DEBUG 内。探针退出后不进入正常索引、菜单或持久化启动流程。

- `--ax-probe permissions`：无提示读取状态。
- `--ax-probe permissions --request-permission`：显式请求提示；不能与 inspect/navigate 合并。
- `--ax-probe fixtures`：只在系统临时目录创建带空格、中文、符号、符号链接的隔离样本。
- `--ax-probe inspect --pid <明确目标PID>`：只观察指定前台应用的当前窗口；焦点切换会中止，不发现或持续抓取其他应用。
- `--ax-probe navigate`：要求明确 PID、模式及控件 token。写入目录只能位于探针创建且具有标记的临时夹具内，不允许导航真实用户目录；Save 禁止文件选择。

Release 在正常应用初始化前拒绝 `--ax-*`，stderr 为 `Unsupported debug argument.`，exit 2。

## 已运行的自动验证

最终检查均 exit 0；只计实际匹配到的 suite，核心 target 的 0 tests 不计通过。

- `OILFIND_FREE=1 swift test --filter DialogNavigationTests`：初版 18 项、0 失败。后续补充 watchdog、真实调用结束等待、原面板关闭和 Secure Input 失败用例。
- `OILFIND_FREE=1 swift test --filter 'DialogNavigationTests|SearchEditingTests|ProductIsolationTests'`：最终 27 项、0 失败；其中导航 21 项、编辑 1 项、隔离 5 项。
- `OILFIND_FREE=1 swift test -c release --filter 'DialogNavigationTests|ProductIsolationTests'`：最终 25 项、0 失败；导航 20 项（不编译两个 DEBUG 探针用例，增加 Release 拒绝用例）、隔离 5 项。
- `OILFIND_FREE=1 scripts/build-app.sh --debug`：成功，独立 ad-hoc 签名；没有证书创建/安装。
- `OILFIND_FREE=1 swift build -c release`：成功。
- `plutil -lint build/debug/Mistary.app/Contents/Info.plist`、`codesign --verify --strict build/debug/Mistary.app`：通过。
- 对实际 Release executable 分别传 `--ax-probe permissions/inspect/navigate/fixtures`：4 次都 exit 2、stdout 为空，在应用初始化前被拒绝。
- 二进制边界补充检查：`--ax-probe`、人工确认说明、临时夹具标记共 3 个 DEBUG 标记在 Debug 存在、在 Release 不存在。结合预处理边界、实际参数拒绝和 Release 测试判定，单独的字符串缺失不能证明整个行为契约。
- 实际调试包 `--ax-probe fixtures`：exit 0；核对样本存在、链接指向同一临时目录、夹具标记正确。绝对随机临时路径没有写入本证据文件。
- `git diff --check`：通过。新增文件另检查行尾空白；范围与既有修改已核对。

单测覆盖权限拒绝零调用、显式提示、权限撤销、宿主退出、目标替换、路径控件替换、原面板意外关闭、预期焦点交接、意外焦点变化、辅助进程身份、Save 文件名保持/缺失/变化、目录未改变、文件选择支持/不支持、截止时间、Secure Input/不支持控件、取消和超时期间阻塞的迟到响应。测试等待旧工作线程结束后再核对调用序列与回调次数，没有用 fake 代替真实跨应用兼容性。

构建沿用既有 `IndexManager.swift:130` weak/implicit strong capture warning，未顺带修改核心代码。

失败与修正记录：

1. 首次编译：Swift 短路表达式的 throwing 调用缺少外层 `try`，且 SDK 不存在公开 `kAXSheetsAttribute`。改为先取 subrole、使用公开 `AXChildren` 和元素身份检查；重跑 18 项通过。
2. 增加文件所在目录检查后的回归：Open 文件选择用例 4 个断言失败。同一目录的 URL 因 trailing-slash 语义不同被误判，改为比较规范化文件系统路径；最终 27 项通过。没有通过撤掉目录边界修复测试。
3. Advisor 方案/结果审阅指出 watchdog 单次时钟条件与旧计时器竞态、写入不可撤回、独立目录观察及权限阻塞不能归为 FAIL。已落实约束及回归；Advisor 未取得完整新增源码，其意见不作为独立代码审查证明。

本地详细日志和权限/临时夹具 JSON 位于忽略目录 `build/debug/002-evidence/`；应用、样本、日志和构建产物不提交。可审阅的长期记录为本文件和测试源码。

## 实际权限状态

对本次构建的 app bundle executable 运行：

```sh
build/debug/Mistary.app/Contents/MacOS/Mistary --ax-probe permissions
```

exit 0，结果为：

```json
{
  "accessibility": false,
  "automation": "notRequested",
  "fullDiskAccess": false,
  "promptRequested": false
}
```

这证明该启动方式下的实际进程尚未获得 AX 信任，不代表操作者已经在系统设置明确拒绝。未用 LaunchServices 发起授权提示、未修改系统权限、未读取其他应用控件、未向真实 Open/Save 面板写入。授权后应对相同构建和实际启动方式复测，不依赖进程继承或 ad-hoc 重建后的权限假设。缺少 Full Disk Access 本身不构成 AX 实验必要条件；Automation 本轮不需要。

## 人工兼容清单

以下都是**未验证**，不是已执行失败，也不是通过。每项导航次数 0，失败次数不适用；所需至少 10 次成功重复仍未完成。

- **TextEdit 1.20 / Open**：版本来自已安装 bundle 的只读元数据。实际窗口/sheet、AX 进程、界面语言、可识别/可导航/选文件、权限状态与次数均未实测。
- **TextEdit 1.20 / Save**：版本已核对；真实 Save、原文件名保持、子面板确认后原面板仍打开、无自动提交尚未实测。
- **Preview 11.0 / Open**：版本已核对；实际支持的 Open 面板未实测。没有把 Export 记为标准 Save，也未声称 Preview Save 支持。
- **常用编辑器/浏览器**：具体目标及版本待操作者指定；未读其窗口、文本或网页内容。

系统语言偏好读取到 `zh-Hans-CN`、`en-CN`，不等于已分别验证中英文目标面板。

以下真实失效/环境路径全部未验证：拒绝权限、撤销权限、关闭/替换对话框、宿主退出、切换窗口、取消、超时、多显示器、中英文界面、辅助进程关联、空格/中文/符号/链接样本在目标面板中的行为。fake 已覆盖部分协议行为，不能替代这些项。

## 后续真机验收与关卡（按操作者决定暂缓）

探针与检查已准备好，后续需要操作者启用当前调试包的 AX 权限，并明确选择测试目标。计划契约原文：“新增调试参数 --ax-probe，只在操作者明确启用后观察并操作当前目标”。没有因“完成计划”的概括性请求而观察未知前台窗口或向其写入。

1. 固定本次构建，再显式运行 `--ax-probe permissions --request-permission`；操作者在系统设置授予权限，随后复查 permissions。权限请求异步，不因发起提示就继续写入。
2. 使用 `build/debug/002-evidence/fixtures.json` 记录的临时样本，准备 TextEdit 的真实 Open/Save 和 Preview 的 Open 面板；不要打开/覆盖真实文档。先取只读 inspect 样本，核对角色、控件唯一性、实际进程及面板归属。
3. 只在能力满足时执行人工辅助路径填入及独立验证。保留初始文件名，观察原面板仍打开，记录人工前置条件；每项成功至少重复 10 次。若能力不满足，记录精确失败原因，不扩大适配器猜测。
4. 再测试操作者指定的常用编辑器/浏览器与所有失效路径、多显示器、中英文条件；没有运行的项继续标未验证。任何意外提交或真实文档影响立即停止写入。
5. 按真实结果得出唯一 PASS/PARTIAL/FAIL，明确操作集合与是否需要人工辅助，再补充 002 与 README 的 AX 关卡结果。当前人工辅助适配器即使验证成功，也不能自动批准完整对话框自动化；005 只能消费明确核验过的操作，其他提供手动交接。
