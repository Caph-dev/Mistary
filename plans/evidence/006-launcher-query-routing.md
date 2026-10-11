# 006：应用别名、网页关键字与结果类型实施证据

日期：2026-10-11。

## 状态与前置

- **已完成（按操作者决定，真实应用／浏览器／输入法日用验收暂缓）**。本次完成门槛为实现、自动验证和本应用快照；暂缓项没有记为通过。
- 实现提交：`fc53d01b347d81b7faad5fcd8f633652b12582a6`。
- 开始时工作区干净，HEAD 为 `2c9277c`；开发分支为 `feat/006-launcher-query-routing`。
- 003 实现基底：`35ccb53a668bdcdac9abf46b3fb1090db67ca513`，复用 session/query/action token、不可变目标、一次性派发与 accepted/verified 语义。
- 004 实现基底：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`，保留 Finder 上下文、目录范围与收藏；FinderContextTests 已纳入验证。
- 005 仍待执行，没有 DialogWorkflowTests；没有宣称完成对话框导航集成。

## 已交付行为

- `QueryRouter` 在文件 Query.parse 前，只识别启用且完整的关键字加空白。默认 `g` 与 `wiki`；裸关键字、未注册关键字、路径、regex 等仍保留原输入交给文件解析。`g kind:pdf` 按明确网页命令处理，其参数为 `kind:pdf`。
- 空参数显示引擎与等待输入，没有可执行 URL。参数先 trim，再用 URLComponents 编码，覆盖中文、引号、换行、`#`、`&`、`%` 和 `+`；`+` 编为 `%2B`，避免搜索引擎的表单解码将其当空格。没有远程建议请求。
- 命令显示「网页搜索」模式、引擎、结果以及 Enter 打开提示；提供「按文件搜索原输入」按钮。强制文件路由在来源刷新与相同输入重搜时保持，到用户修改输入或切换模式才解除。
- 仅普通／应用模式启用应用别名与网页路由。提供显式模式选择；Save 默认 kind=1，Open／Finder／Save 不隐式路由命令，模式变化立即使旧请求失效。005 的外部窗口自动导航仍 unavailable。
- `PaletteItem.file` 包装原 SearchPresentation 及行，保留文件来源、版本、补充说明与图标；application/web 保存各自实际 URL，不构造假 entryID 或 SupplementaryHit。文件结果保持惰性读取。
- 别名只检索最多 128 个配置项。与索引中 `.app` 命中按规范化具体路径去重，同 bundle ID 的不同安装路径保留区别。索引中的应用仍保留其原文件快照和动作校验。规范化处理 dot components 与目录尾部斜杠，不按 bundle ID 迁移安装副本。
- 应用别名只参与无目录 scope、无高级文件语法、类型为全部或应用的查询，避免绕过文件过滤与目录范围。缺失应用候选显示失效，启动前检查所选 URL、bundle ID 和文件身份；没有同 bundle 的另一安装位置回退逻辑。
- 新行不伪造日期或大小。网页只允许打开，无文件复制、Quick Look、拖动、删除或 Finder 定位；应用别名支持启动、Finder 定位、文件／路径／名称复制及拖动，未开放 Quick Look 或删除。右键菜单按类型列出动作；非文件行不显示原文件专用底栏提示。
- `PaletteActionRequest` 捕获动作 ID、session/query/action token、类型和值，执行器复用一次性 receipt。应用启动按 URL 调用 NSWorkspace.openApplication；等待回调时返回 nil，系统响应后发出 accepted 或 failed，启动没有 verified 事件。晚到的成功或失败事件仍可记录，但不能隐藏或改变新会话的界面。
- 旧排队查询、已计算但待主线程提交的文件结果、旧菜单请求和延迟文件动作均被代次校验拒绝；别名插入、移除与补充结果刷新保持文件选择身份。重新唤起时核对 kind、排序、升降序、pinyin 和目录 scope，移除最后一个别名不复用遗留应用行。
- `LauncherPreferences` 将 version=1 配置原子写入 `~/Library/Application Support/Mistary/launcher.json`，最多 128 个别名、16 个关键字，读取上限 1 MiB。损坏或未知版本文档报告错误并阻止覆盖；设置提供备份原始字节后重置的恢复入口。
- 设置支持系统应用选择器录入、别名修改／移除、网页关键字与引擎／HTTPS endpoint／查询参数修改及启停。L10n 文案中英文成对维护，语言变更更新命令提示。

007 可复用 PaletteItem、LauncherPreferences 和 PaletteActionRequest 的类型／代次契约增加声明式动作专用 case；本阶段没有用文件 case 伪装命令，也没有提前实现脚本执行。

## 自动验证

以下十条筛选命令均实际逐条运行，exit 0，核对对应具名 suite 非零测试数与零失败。最后在完整代码上又以联合 filter 运行全部十类：**80 tests，0 failures**。

```sh
OILFIND_FREE=1 swift test --filter QueryRouterTests          # 6
OILFIND_FREE=1 swift test --filter PaletteResultsTests       # 20
OILFIND_FREE=1 swift test --filter ResultsSelectionTests     # 1
OILFIND_FREE=1 swift test --filter ResultRefreshTests        # 3
OILFIND_FREE=1 swift test --filter ActionExecutorTests       # 22
OILFIND_FREE=1 swift test --filter SearchEditingTests        # 1
OILFIND_FREE=1 swift test --filter FinderContextTests        # 12
OILFIND_FREE=1 swift test --filter SearchSessionTests        # 6
OILFIND_FREE=1 swift test --filter SearchSourcesUITests      # 4
OILFIND_FREE=1 swift test --filter SupplementarySearchTests  # 5
```

最后联合筛选输出：

```text
Test Suite 'OilFindUITests.xctest' passed at 2026-10-11 08:09:25.793.
Executed 80 tests, with 0 failures (0 unexpected)
```

Swift 还会启动未匹配的核心测试 target 并打印 0 tests；没有把这部分算作验证通过。计数来自上述每个具名 UI suite。

新增测试覆盖：路由冲突、空参数、完整原输入、参数编码与表单解码、场景与组字保护、配置恢复、应用 URL 去重与不同安装副本、选择及文件动作绑定、待提交旧查询、强制文件路由的实际来源刷新、最后别名删除、过滤／scope／重开缓存、缺失／替换应用、bundle ID 变化、Workspace 接受／拒绝／重复回调／新旧会话隔离、网页文件动作与拖动禁用、应用菜单与拖动，以及单元格元数据清空。

其他命令均 exit 0：

```sh
OILFIND_FREE=1 swift build -c release
python3 Tests/Scripts/test_open_core.py  # Ran 2 tests / OK
scripts/build-app.sh --debug
git diff --check
```

Release 输出 `Build complete! (16.00秒)`，为 **Release 编译**，没有打包或签名 Release 应用。原有 `IndexManager.swift:130` weak capture 警告不属于本计划改动。调试包为 `build/debug/Mistary.app`，使用 ad-hoc 签名，没有安装或创建证书。

测试过程中修正了夹具建表 API／初始化捕获错误和标签索引错误；首次结果测试还发现应用 URL 尾部斜杠身份不一致，已修正并回归通过。中间失败不计为验收成功。

## 本应用界面验证

用 CLI 只扫描本次生成的临时目录（两个测试文件），创建临时索引；用现有 DEBUG `--snapshot` 入口生成四张图并检查中英文网页和设置布局。未读取真实用户索引，未发起网页或应用打开。

```sh
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-006-visuals.mvZkI1/web-zh.png --db /tmp/mistary-006-visuals.mvZkI1/fixture.oilfind --query 'g 中文 & # % +' --language zh --appearance light
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-006-visuals.mvZkI1/web-en.png --db /tmp/mistary-006-visuals.mvZkI1/fixture.oilfind --query 'wiki launcher query routing' --language en --appearance dark
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-006-visuals.mvZkI1/waiting-zh.png --db /tmp/mistary-006-visuals.mvZkI1/fixture.oilfind --query 'g ' --language zh --appearance light
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-006-visuals.mvZkI1/settings-en.png --state settings --settings-scroll 0.8 --language en --appearance light
```

搜索快照 1600×1120；设置快照 1080×1200。快照检查后修正了网页底栏中的文件提示、设置标签换行和强制文件搜索按钮样式；自动测试通过真实 NSButton 点击验证了出口接线与路由保持。临时图像不提交，临时索引和扫描夹具在验证后清理；路径只是本次会话本地证据，不是持久发布地址。

## 按操作者决定暂缓的真实测试

- [ ] 系统选择器选择真实应用、启动实际目标、应用抢焦点与面板重开；同 bundle ID 的两个真实安装副本及已经运行的副本行为。
- [ ] 默认浏览器实际打开 Google／Wikipedia，检查中文、引号和保留字符得到预期搜索内容；fake URL 调用与编码断言不等于真实网站验收。
- [ ] 实际中文输入法连续组字、候选确认和 Return；NSTextView marked-text 测试不代替真机输入法。
- [ ] 与真实 Finder／Open／Save 面板结合使用，验证显式模式切换与回到原场景；005 未实现，不批准自动对话框导航。
- [ ] 同机真实索引上的响应耗时与日用体验；当前临时夹具和快照没有性能验收结论。
- [ ] 稳定签名后的实际权限保持；调试包 ad-hoc 不能证明权限持续性。

这些项目保持「未验证／暂缓」，不阻止按本次操作者定义将 006 标记为已完成。

## 范围与复核

实现只修改 006 范围中的应用层文件与两个新增测试文件；未改 core/C、SupplementarySearch、site、Pro、索引格式或许可证。另更新 006 计划、入口状态与本证据。

已咨询 advisor。最终源码附件因本机配置被过滤，advisor 未能审阅完整 diff；不能称为完整独立代码审查。对其指出的缓存复用与异步提交风险已自行核对并补充确定性回归，最终测试、编译和范围检查如上。
