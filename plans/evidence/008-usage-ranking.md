# 008：使用历史与有界候选排序实施证据

日期：2026-10-11。

## 状态与前置

- 已完成（按操作者授权，真机日用与全盘性能验收暂缓）。自动验证与测量结果见下文；暂缓项未记为通过。
- 实现提交：`413853ccc85d1eee473cbf7e2304c5b3cf9bec26`。
- 开始时工作区干净，HEAD 为 `6f9e5d5`，沿用个人开发分支 `feat/006-launcher-query-routing`。操作者明确授权 commit、push。
- 003：`35ccb53a668bdcdac9abf46b3fb1090db67ca513`；004：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`；006：`fc53d01b347d81b7faad5fcd8f633652b12582a6`；007：`8974b820e10d5a74e1f20ba2bf05534e1b145282`。已核对动作完成事件、严格 scope、file/application/web 身份与自定义动作统计扩展点。005 手动路线保留，自动对话框支持集合仍为空。
- 核对了规划基底到 HEAD 的范围内漂移，属于上述前置实现，没有覆盖旧计划摘录或修改核心查询算法。

## 交付行为

- `UsageStore` 在独立的 Mistary 数据目录保存单份 version=1 `usage.json`，原子替换，最多 1000 条目标／活动记录，读取上限 16 MiB。损坏或未知版本文件显示错误并阻止自动覆盖；显式清除后恢复。临时文件收尾由 Foundation 原子写入负责，夹具核实目录无残留。
- `HistoryIdentity` 保存 sourceID、路径、书签、可用的卷 UUID，以及 link/destination 的 inode 与 birth time；不持久化 entryID、store 或版本。先校验原路径，再尝试不弹 UI、不挂载卷的 bookmark 解析；校验失败不继承权重。书签的 `/private/var` 规范路径按身份校验重新映射到索引使用的 `/var` 路径；文件 I/O 全部在索引锁外。
- 重扫、压实用当前 store 的 hash 重新解析路径。hash 尚未就绪时暂停历史提升；不遍历全盘 String 补身份。删除、离线、权限不足保留历史但不提升；设置显示可用／不可用状态。
- macOS 默认书签在原路径复用后不保证找回移动后的旧文件。本机夹具观察到这种情况，此时显示 missing；可正确解析到新位置时仍须通过原身份校验。SDK `NSURL.h` 明确说明旧 `NSURLBookmarkCreationPreferFileIDResolution` 无效果，未使用该已废弃选项。
- `ActionExecutor` 集中记录完成事件。请求捕获 query、usage epoch、目标身份与 navigation parent identity；receipt 保证每次执行最多记录一次。普通文件、应用和 web 打开在 accepted 记“已发起”；目录导航只在 verified 记“已导航”，文件导航记其父目录；手动复制路径在 clipboard verified 记“已复制”。失败、取消、预览、Finder 定位、复制名称、新建／改名／废纸篓不增加使用排序权重。
- 发起、导航、复制分别聚合。复制既不增加 launch 次数，也不刷新原打开记录的 lastUsed、query 或 context。Quick Switch 和手动路径复制捕获当前输入；文件行动作使用所显示查询快照，后来的选择与输入不能改写归因。
- 007 的 `recordsUsage` 现在可显式开启：自定义动作记录 API／进程启动 accepted，退出结果另行报告，退出失败不伪装启动失败；重复启动事件只记一次，未启动的失败／取消不记。默认 false，Terminal 仍 unsupported。
- web 仅保存关键字 ID 与次数／时间，不保存 URL、查询正文或书签；文件历史保存路径、书签和最多 8 个、每个最多 512 UTF-8 bytes 的查询。设置明确说明保存内容，可关闭与清除。
- 清除与开关变更推进 epoch，拒绝操作在清除／关闭前捕获的迟到回调；关闭再开启也不接收旧动作。revision 使面板缓存失效，立即作废在途 ranking generation；提交同时检查 usage revision、查询 token 与来源／store/version 快照。
- `UsageRanker` 最多解析前 200 条历史，加正常排序前缀 200 项和有界收藏。使用既有 `withEntryPredicates`，按 Clause AND、alternatives OR、Atom negation 组合，额外检查 kind、pinyin、strict scope、在线来源和可用性。日期查询沿用本次已解析 Query，不重新解释时间。
- 非空历史项必须属于原名称查询的完整匹配 ID 集合；部分 ID 快照暂停提升。补充搜索不伪装历史命中。个人排序只在 relevance 开启，先精确名称，再同查询使用，再上限 24 的频率／近期／上下文加分与稳定 tie-break；name/size/modified 完全保留原顺序。
- `SearchPresentation` 保留底层完整 ID 数组，只保存小规模个人前缀位置与逆向映射。前缀之后按原顺序跳过已输出 ID，支持随机行访问与选择身份反查；前缀外提升不重复，剩余匹配不丢失。文件匹配 total 和核心 sortedCount 不被个人排序改变；应用层独立 `rankingMode=personalBounded` 与 `personalPrefixCount`。页脚显示“使用排序候选 N 项，共 T 个文件”。
- 空查询保留收藏入口，将有效最近使用项放在最近修改之前，各行清晰标注来源分组。可加入最近修改 top 200 外的有效文件，但不增加底层 recent total；未索引应用通过独立 application 行显示，去重已索引应用和别名，不增加文件 total。强制文件路由、kind、scope 与显式排序均限制应用历史入口。
- 设置沿用原控件与中英文 L10n，提供开关、清除、最近记录活动和可用性。必要范围扩展仅为 `ActionDefinitions.swift` 接通 007 开关，以及 `ResultsView.swift` 展示分组标签。

## 自动验证

计划具名六类逐条执行，均有非零匹配并通过；不把另一 test target 的 0 tests 计作测试证据。最终 Debug 联合验证 **148 项，零失败**：OilFindUITests 137、OilFindCoreTests 11；随后新增补充通道候选边界测试，排序／补充搜索复验 25 项通过。最终累计覆盖 **149 个不同测试**（联合运行加随后定向复验，并非最终版本单次运行 149 项）。UsageStoreTests 17、UsageRankingTests 20，共 37 项新增测试；具名六类合计 74 项，补充回归 75 项。

```sh
OILFIND_FREE=1 swift test --filter UsageStoreTests
OILFIND_FREE=1 swift test --filter UsageRankingTests
OILFIND_FREE=1 swift test --filter ActionExecutorTests
OILFIND_FREE=1 swift test --filter DirectoryScopeTests
OILFIND_FREE=1 swift test --filter ResultRefreshTests
OILFIND_FREE=1 swift test --filter SearchEditingTests
```

覆盖重启、真实临时目录移动／同路径替换、失效书签、symlink destination、删除、压实、新 store、离线与权限拒绝、损坏／未知文档、1000 上限、原子文件无残留、重复事件、关闭／清除迟到完成、web 隐私、自定义 opt-in、导航适配器成功／失败与父目录归因。

排序覆盖 OR/NOT、祖先排除、regex/path/ext/size/dm、kind、pinyin、strict scope、明确排序、收藏、源离线、hash 未就绪与部分 snapshot；200,100 匹配的 sortedCount=5000 保持不变，所有 ID 恰好一次，suffix 与原序去前缀后相同；多来源、补充命中、空查询 top 200 外历史与 supplementary 去重、结果位置反查、真实控制器选择及执行目标均检查。控制器受控队列测试覆盖 clear 期间旧查询／旧 ranking 不提交、缓存重开后重新排序、disable 恢复原序且选择稳定。

补充回归：DialogWorkflowTests 22、PaletteResultsTests 20、QueryRouterTests 6、CommandActionsTests 16、ResultsSelectionTests 1、SupplementarySearchTests 5、LanguageTests 5，共 75 项通过。最终 Debug 命令：

```sh
OILFIND_FREE=1 swift test --filter 'UsageStoreTests|UsageRankingTests|ActionExecutorTests|DirectoryScopeTests|ResultRefreshTests|SearchEditingTests|DialogWorkflowTests|PaletteResultsTests|QueryRouterTests|CommandActionsTests|ResultsSelectionTests|SupplementarySearchTests|LanguageTests'
```

```text
OilFindUITests.xctest passed: Executed 137 tests, with 0 failures
OilFindCoreTests.xctest passed: Executed 11 tests, with 0 failures
```

复制与网页记录在截取最多尝试解析的 200 条符合条件历史记录**之前**排除，250 条复制＋250 条网页夹具不会挤掉打开记录的解析窗口；复制后空查询相对顺序不变。全局 1000 条存储上限仍按近期活动淘汰，未承诺大量复制永远不会通过该上限移除更旧的打开历史。个人正常前缀取核心原 sortedCount，不把 supplementary 独有行纳入个人候选。来源根目录的空索引名会转换为可显示目录名，精确路径用于捕获动作，空查询夹具验证可复制原目标。

最终复验命令及输出：

```sh
OILFIND_FREE=1 swift test -c release --filter 'UsageStoreTests|UsageRankingTests' # 36 项；随后新增 1 项见下行
OILFIND_FREE=1 swift test --filter 'UsageRankingTests|SupplementarySearchTests' # 25 项，零失败
OILFIND_FREE=1 swift test -c release --filter UsageRankingTests # 20 项，零失败
OILFIND_FREE=1 swift test --filter UsageRankingTests/testEmptyQueryIncludesUsageOutsideModified200WithGroupsAndNoDuplicates # 1 项，零失败；补测 source root 行
OILFIND_FREE=1 swift test -c release --filter UsageRankingTests/testEmptyQueryIncludesUsageOutsideModified200WithGroupsAndNoDuplicates # 1 项，零失败
OILFIND_FREE=1 swift build -c release # Build complete! (29.92秒)
scripts/build-app.sh --debug # Build complete! (7.93秒)
codesign --verify --deep --strict build/debug/Mistary.app
python3 Tests/Scripts/test_open_core.py # Ran 2 tests / OK
git diff --check
git diff --cached --check
```

全部已完成命令 exit 0，Release 覆盖新增 37 个不同测试；最后 source root 断言另有 Release 复验。没有修改 C、核心、索引格式、site/ 或 Pro/。

中间失败均已修正：WebKeyword.id 类型对齐为 String；NOT 正确翻转原子匹配值；bookmark 的 /var alias 对齐与路径复用失败关闭；Scanner 构造的测试 store 补显式 buildHash；复制独立活动避免提升打开近期权重。一次前台构建达到工具 60 秒时限，改用后台有退出码的验证脚本完成，不将超时计为通过。

## 本应用界面验证

使用现有 DEBUG `--snapshot` 和隔离的内存设置模型，未读取真实用户历史。中英文 light/dark 两张 1080×1200 快照均实际读取，使用历史标题、记录开关、完整隐私说明和清除按钮可见，没有新增 UI 文案截断。

```sh
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-008-visuals/settings-zh.png --state settings --settings-scroll 0.50 --language zh --appearance light
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-008-visuals/settings-en.png --state settings --settings-scroll 0.50 --language en --appearance dark
```

快照不提交为仓库产物，不证明其他应用或填充真实历史后的日用交互。调试包 ad-hoc 签名，没有安装、创建证书、增加 Release 探针或第三方依赖。

## 性能与限制

测量环境：macOS 26.6.2 (25G83)、arm64；系统 Swift/Xcode 工具链，Swift 5 语言模式。使用合成索引和临时历史，没有访问或修改真实用户文件。

此前 Release 测量：200,100 个同名类别匹配，搜索 p95 2.561 ms；搜索＋个人排序 p95 4.775 ms；排序本身 p95 2.247 ms。1000 条真实 bookmark payload 文档约 2.28 MB，原子记录 p95 15.322 ms；解析 200 个候选 p95 5.786 ms。

排序／补充边界最终 Release 复验：搜索 p95 2.725 ms、搜索＋排序 p95 5.243 ms、排序本身 p95 2.658 ms。完整历史／排序 Release 复验中的对应值：搜索 p95 22.597 ms、搜索＋排序 p95 34.167 ms、排序 p95 17.709 ms；1000 条记录文档 2,281,083 bytes，原子记录 p95 166.014 ms、解析 200 项 p95 120.589 ms。此前另一次同机 Release 值为 8.039／13.796／5.938 ms 与 46.087／18.520 ms。时延在不同轮次明显波动，没有受控系统负载基线，不能用最小的一轮宣称达标。

- 合成结果的相对增幅超过建议 ≤10%；测量包括完整匹配集合 membership 定位成本，不声称已达到全盘 p95 门槛。没有历史／收藏时 ranker 直接返回，显式排序直接绕过。
- 当前历史持久化同步原子写入，避免排队清除竞态，满 1000 条文档的主线程记录成本见实际测量，166.014 ms 的 p95 足以产生可见停顿风险。需要日用 UI 延迟实测后再决定是否另做有序异步 persistence；没有把记录上限当作响应性能保证。
- 合成测量不是全盘同机基线，不包含真实多卷、TCC、第三方应用或复杂 query 的系统延迟。

## 按操作者授权暂缓

- [ ] 真实文件／应用／浏览器日用打开及跨重启、真实磁盘移动与挂载、TCC 撤销的持续验证。
- [ ] 真实 Finder、Open／Save 面板的导航验收；002 仍未判定，未开放自动导航。
- [ ] 真实全盘同机 p95 基线与完整面板提交成本；≤10% 尚未验收。
- [ ] 满历史文件下的日用主线程写盘、频繁动作、窗口焦点和输入法延迟验收。

以上暂缓项不阻止按本轮授权将 008 标为已完成；性能阈值与未验证的跨应用能力没有记为通过。
