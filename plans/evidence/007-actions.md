# 007：自定义动作与单文件操作实施证据

日期：2026-10-11。

## 状态与前置

- **已完成（按操作者授权，跨应用与终端真机验收暂缓）**。完成门槛为实现、自动验证和本应用设置快照；暂缓项没有记为通过。
- 实现提交：`8974b820e10d5a74e1f20ba2bf05534e1b145282`。
- 开始时工作区干净，HEAD 为 `f556997`；沿用个人开发分支 `feat/006-launcher-query-routing`。操作者明确授权 commit、push。
- 003 实现：`35ccb53a668bdcdac9abf46b3fb1090db67ca513`；复用不可变目标、session/query/action token、一次性 receipt 和动作结果语义。
- 004 实现：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`；保存过滤器已集成严格 DirectoryScope，不是无 scope 的临时实现。
- 006 实现：`fc53d01b347d81b7faad5fcd8f633652b12582a6`；保留 file/application/web 类型与路由。005 手动路线实现 `fcb31c6944727ac95647e43bd49627008c6432d0` 已集成，自动对话框导航仍未开放。

## 已交付行为

- `ActionDefinitions` 原子持久化 version=1 文档到 `~/Library/Application Support/Mistary/actions.json`，最多 128 项、读入最多 1 MiB。验证动作 ID、名称、适用 itemTypes、modes、permissions、enabled 和 execution；损坏或未知版本配置可见报错并阻止覆盖。
- execution 支持具体 application URL、HTTPS URL template、绝对 executable URL + arguments 数组 + 可选 currentDirectory。占位符限定 `{path}`、`{url}`、`{name}`、`{directory}`；一次扫描替换，插入的路径数据不会再被解析成占位符。每个 argv 元素保持完整，应用不生成 shell 源码或隐式 `/bin/sh -c`。
- HTTPS template 对替换数据做组件编码，固定 scheme/host，不接受 URL 凭据；文件名中的 `&`、`#`、`+` 等不能改变 URL 结构。web 类型不接收文件修改；只显示明确适用的自定义动作，保留默认网页仅 Open 的菜单。
- `CustomActionRequest` 固定菜单打开时的动作定义、文件／应用身份、URL 和 token。修改或删除配置不会把旧请求解释成另一条命令。菜单显示禁用状态及原因，执行前重验权限、适用类型、可执行文件／应用可用性和捕获目标；组字与过期目标不派发。
- `CommandRunner` 使用 Foundation Process 的 executableURL、arguments、currentDirectoryURL。命令只在显式菜单操作后运行，查询键入、结果刷新和打开菜单均不运行。排队后回主线程复验会话／来源／目标，在同一个主线程执行块中启动 Process，不再异步排队启动；测试验证排队期间结束会话时零文件副作用。
- stdout/stderr 并发持续排空，每条流最多保留 64 KiB；截断后继续读取，UI 与日志不展示输出内容。默认超时 30 秒，从 Process.run 成功时用 DispatchTime 单调时钟计时，先向直接子进程发送 SIGTERM，短暂等待后用 SIGKILL；测试验证忽略 SIGTERM 的直接子进程确实退出。
- 进程启动发出 accepted；正常退出发出 verified，非零退出、启动失败、超时分别有明确失败。这里 verified 只验证退出码，不证明脚本的外部效果。后代继承管道时，主进程退出后读取最多再等待 0.5 秒，然后标记截断、停止非阻塞读取并等待两个 reader 退出及关闭 descriptor；设置非阻塞或读取失败会报告 commandOutputFailed；测试在 runner 返回后观察到测试后代的心跳继续变化。超时只终止直接子进程，不承诺终止脚本启动的所有后代；截止点从启动计算，但监控任务若遇调度积压，终止可能晚于截止点，不是严格实时的运行上限。
- `Open With…` 使用系统应用选择器，记录所选具体 `.app` URL，并调用 NSWorkspace 的文件 URL + application URL API。没有改变系统默认应用，也没有回退到另一个安装位置。Workspace 的响应只产生 accepted，不能显示“目标应用已读取文件”。
- **Terminal 支持集合为空**。菜单明确禁用并显示未验证协议的原因，配置中的 terminal 执行描述也返回 terminalUnsupported。没有拼接 `cd`，没有静默换终端，没有为 007 新增 Apple Events／Automation 请求或 Info.plist 权限。已有 Finder 权限属于 004。
- 新建目录和单文件改名通过 `FileMutation` 捕获原请求及父目录身份，在串行 File I/O 队列运行；等待队列后复验主线程拥有的来源／会话，可取消 permit 在第二次队列等待中仍接受失效通知，worker 开始操作前原子领取 permit；后台只读取不可变快照并重验磁盘身份。完成事件回主线程，实际修改成功后即使会话已结束仍保留 verified，旧事件不更新新会话界面。
- 名称只允许单个合法 leaf，拒绝空值、`.`、`..`、`/`、`:`、NUL 和超长名称。不修改符号链接文件或直接符号链接父目录；没有永久删除撤销逻辑。
- 固定父目录 descriptor，使用 `mkdirat` 排他创建目录、`renameatx_np(..., RENAME_EXCL)` 原子拒绝已有目标。核实依据为本机 SDK `usr/include/sys/stdio.h` 和 `man renamex_np`。没有 exists 检查后用普通 rename 覆盖的回退。系统不支持排他操作则明确失败；大小写不敏感卷上的仅大小写改名明确不支持，不使用临时覆盖绕过。
- 文件操作失败保留原文件及原选择；成功由既有 FSEvents 路径更新索引，没有改核心监听或索引格式。真实临时夹具验证创建、改名、新路径出现、旧路径消失，旧请求不能再执行到刷新后的另一行。
- `SavedFiltersStore` 原子持久化 version=1 文档到 `filters.json`，记录原始文件查询、sort、ascending、kind、pinyin、可选目录 scope，不持久化 entryID 或编译 regex。支持搜索菜单保存／激活，设置中编辑／删除。
- 激活先重新完整 Query.parse，重新解释相对日期；明确切回 ordinary 模式，恢复完整选项并强制文件路由，避免 application/save 模式覆盖 kind 或关键字把文件查询路由成 web。scope 使用 004 的词法规范化，检查实际目录和在线来源的索引可用性；缺失、未索引或离线 scope 拒绝激活，原会话保持，不扩大为全盘。
- 设置沿用 grouped Form、现有控件与 L10n。自定义动作通过声明式 JSON 数组添加、编辑、删除，提供生成命令示例按钮；所有执行仍由搜索菜单显式触发。保存过滤器使用结构化字段编辑名称、查询、排序、类型、拼音与目录范围。
- 新动作声明权限和结果语义；`recordsUsage` 当前固定 false，发出独立 CustomActionEvent，使用历史留给 008。

## 权限与文件系统边界

- 配置声明不等于进程沙盒。用户配置的脚本以当前用户权限运行；processExecution 没有额外的系统 TCC 授权类别。宿主可注入能力拒绝；生产路径实际检查 executable 可执行／普通文件状态，fileRead 声明还检查目标可读性。文件修改由文件系统最终返回 EACCES、EPERM、EROFS 等，报告权限拒绝。
- 排他操作保证不覆盖目标；固定 descriptor 和紧邻操作的身份检查降低源替换风险，但 POSIX 没有“比对 inode 并原子 rename”的 API。操作前校验与系统调用之间仍有源目录项替换竞态，不能声称完全消除。改名后再次校验 inode，不一致时报告 mutationNotVerified，不尝试删除或覆盖来还原。
- 全部文件副作用测试使用本轮临时夹具。权限拒绝／只读分支用注入 errno 验证；没有把它写成真实只读卷或 TCC 撤销已验收。

## 自动验证

指定七类已逐条执行并核对非零测试数。最终代码后联合验证覆盖下列类：**143 个不同测试，零失败**。

```sh
OILFIND_FREE=1 swift test --filter CommandActionsTests  # 16
OILFIND_FREE=1 swift test --filter ActionExecutorTests  # 22
OILFIND_FREE=1 swift test --filter FileActionsTests     # 15
OILFIND_FREE=1 swift test --filter ResultRefreshTests   # 3
OILFIND_FREE=1 swift test --filter SavedFiltersTests    # 8
OILFIND_FREE=1 swift test --filter QueryRouterTests     # 6
OILFIND_FREE=1 swift test --filter SearchEditingTests   # 1
```

新增三类共 39 项；指定测试共 71 项。补充回归为 DialogWorkflowTests 22、FinderContextTests 12、PaletteResultsTests 20、ResultsSelectionTests 1、SearchSessionTests 6、DirectoryScopeTests 11，共 72 项。

最终联合命令及输出：

```sh
OILFIND_FREE=1 swift test --filter 'CommandActionsTests|ActionExecutorTests|FileActionsTests|ResultRefreshTests|SavedFiltersTests|QueryRouterTests|SearchEditingTests|PaletteResultsTests|FinderContextTests|DialogWorkflowTests|ResultsSelectionTests|SearchSessionTests|DirectoryScopeTests'
```

```text
OilFindUITests.xctest passed: Executed 132 tests, with 0 failures
OilFindCoreTests.xctest passed: Executed 11 tests, with 0 failures
```

离线多来源 scope 激活拒绝已在 SavedFiltersTests 8 项中验证。每个具名 suite 的测试数均核对；筛选时未匹配 target 输出的 0 tests 没有计入验证。

其他实际命令均 exit 0：

```sh
OILFIND_FREE=1 swift build -c release  # Build complete! (18.50秒)
scripts/build-app.sh --debug          # Build complete! (4.37秒)
codesign --verify --deep --strict build/debug/Mistary.app
python3 Tests/Scripts/test_open_core.py  # Ran 2 tests / OK
git diff --check
```

调试包为 `build/debug/Mistary.app`，ad-hoc 签名；没有安装、创建证书或打包签名 Release 应用。没有新增 Release 探针、第三方依赖、核心／索引格式变更、site／Pro 改动。

中间失败已修正并重新验证：Swift 文案转义及 selector 歧义、测试日期 matcher／SearchPresentation API 引用、菜单原末项契约及非文件菜单隔离；FSEvents 夹具起初使用 `/var` 别名而真实事件为 `/private/var`，按已有 M2Tests 的 `realpath` 模式修正后真实监听通过。进程测试起初的亚秒总耗时门槛过紧，改为观察返回后后代仍更新心跳，并单独验证安装 SIGTERM trap 后就绪的直接子进程确实被强制终止。提交前复核进一步消除命令校验后再次排队启动的窗口，并增加文件修改 permit 来覆盖校验后的队列失效；两处均有可控调度用例；文件测试通过真实 ActionExecutor 的 permit 注册／取消接线，不替换其失效回调。诊断探针均已移除。

## 本应用界面验证

使用现有 DEBUG --snapshot 入口，快照设置模型为隔离的内存配置，没有读取真实用户动作／过滤器，也没有运行配置命令。三张 1080×1200 图已实际读取检查，自定义动作中英文 light/dark 文案与按钮无截断，保存过滤器提示可见。

```sh
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-007-visuals.WoUYBh/settings-zh.png --state settings --settings-scroll 0.85 --language zh --appearance light
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-007-visuals.WoUYBh/settings-en.png --state settings --settings-scroll 0.85 --language en --appearance dark
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-007-visuals.WoUYBh/settings-filters-en.png --state settings --settings-scroll 1 --language en --appearance light
```

快照为本轮本地临时图像，不提交为仓库产物；不证明系统选择器或其他应用兼容。

## 按操作者决定暂缓

- [ ] 真实应用选择器和目标应用接收文件／目录；不同应用版本、已有运行实例、取消与焦点交接。
- [ ] 系统 Terminal 的受支持 directory URL 打开协议及准确应用版本。验收前保持 unsupported；没有批准任何终端兼容性。
- [ ] 用户真实脚本的日用效果、权限撤销、真实只读卷与各卷大小写规则；自动测试只证明临时夹具和注入分支。
- [ ] 实际输入法、Finder、Open／Save 场景下的菜单／模态交互，填写后的过滤器设置编辑布局；快照为空配置，不代替这些日用验收。

以上真机项不阻止按操作者授权将 007 标为已完成；Terminal、自动对话框导航及其他未验证能力没有因此开放。
