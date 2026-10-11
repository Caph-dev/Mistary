# 计划 008：持久化使用历史并合并有界排序候选

## 状态

- 状态：已完成（按操作者授权，真机日用与全盘性能验收暂缓）。
- 证据：[008-usage-ranking.md](evidence/008-usage-ranking.md)。
- 实现提交：`413853ccc85d1eee473cbf7e2304c5b3cf9bec26`。
- P2；工作量 L；风险中；阶段 M3；依赖：003的动作事件、004的精确scope、006的结果身份。007仅为新增动作的统计集成输入，不是基础历史硬依赖。
- 规划于：commit `6c024bbbf6b917c4a334f4569de070d887ecd66f`；2026-10-10。
- 本文件保留实施规格；实际实现、自动验证、性能测量与暂缓项以证据文件为准。

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
git diff --stat 6c024bbbf6b917c4a334f4569de070d887ecd66f..HEAD -- Sources/OilFindApp/UsageStore.swift Sources/OilFindApp/UsageRanker.swift Sources/OilFindApp/HistoryIdentity.swift Sources/OilFindApp/ActionExecutor.swift Sources/OilFindApp/PaletteItem.swift Sources/OilFindApp/SearchPresentation.swift Sources/OilFindApp/SearchViewController.swift Sources/OilFindApp/SettingsWindow.swift Sources/OilFindApp/L10n.swift Tests/OilFindUITests/UsageStoreTests.swift Tests/OilFindUITests/UsageRankingTests.swift
```

## 范围清单

- `Sources/OilFindApp/UsageStore.swift（新建）`
- `Sources/OilFindApp/UsageRanker.swift（新建）`
- `Sources/OilFindApp/HistoryIdentity.swift（新建）`
- `Sources/OilFindApp/ActionExecutor.swift`
- `Sources/OilFindApp/PaletteItem.swift`
- `Sources/OilFindApp/SearchPresentation.swift`
- `Sources/OilFindApp/SearchViewController.swift`
- `Sources/OilFindApp/SettingsWindow.swift`
- `Sources/OilFindApp/L10n.swift`
- `Tests/OilFindUITests/UsageStoreTests.swift（新建）`
- `Tests/OilFindUITests/UsageRankingTests.swift（新建）`

## 为什么重要

当前空查询显示最近修改文件，不能回答“我刚才用过什么”。个人搜索需要收藏与自己执行过的结果，且重扫后仍指向同一对象。历史不能让不满足查询或目录范围的文件进入结果，也不能假装全库精确排序。

## 当前状态与证据

Sources/OilFindCore/Searcher.swift 的recent使用：

~~~swift
pushTop(Ranked(id: UInt32(i), score: 0), limit: 200, heap: &heap, options: recentOptions, store: store)
~~~

大集合在total > 200_000时仅排序前5000，保留所有候选ID与sortedCount；不能给首屏排序后称全局最优。Searcher.withEntryPredicates可同步评估输入atoms，持读锁；Sources/OilFindApp/SearchPresentation.swift按source/store/id/path定位结果。索引对象内下标稳定，压实生成新store，entryID不适合作为持久身份。

## 前置交付与统计契约

003提供带actionID、目标身份、query/session代次和结果的唯一执行完成事件；一次动作最多记一次，不从UI选中/按键计数。004提供strict scope和缓存条件，006提供file/app/web类型身份；007已完成时仅新增声明式动作映射。

默认统计：普通文件/应用打开和web打开在API accepted时计入“已发起”；目录导航在verified时计入“已导航”；手动复制路径单独记“已复制”，不冒充打开。取消/失败不增加使用权重；新建/改名/废纸篓不默认将已删除/旧路径提升为启动结果。自定义进程区分启动accepted和退出结果，显式配置是否进入使用历史。

记录只来源于Mistary动作，不导入系统全局历史。配置可关闭记录和清除历史；关闭后不写新数据，清除后不从内存异步回写旧数据。网页搜索参数可能敏感，web查询正文默认不持久化；若提供额外记录开关，说明内容与删除范围。

文件身份保存bookmarks、source稳定标识、路径和可取得的volume/resource身份，重启在索引锁外解析。移动/改名尽量保持身份；删除/离线/权限不足保留不可用状态或移出有效候选；原路径被新文件复用时不继承旧权重。新建store后用路径/身份重新resolve，不持久化entryID。

本阶段先固定有界集合：最多1000条历史记录，最多200个可解析历史候选参与当前查询，加当前正常搜索排序前缀与收藏/别名。数值为实施默认，可集中配置；不扫描全盘String求相似度。超出候选集合不承诺全库最优排名。

额外候选逐一解析后，复用withEntryPredicates评估完整Clause AND / alternative OR / negated Atom语义，再检查kind/pinyin/来源/精确scope/可用性。不能把Query所有atoms扁平AND；不能只对名称打分。未覆盖索引的文件历史不进入非空文件查询，但有效目录收藏仍可在专用入口显示。

仅relevance排序加个人权重：完整匹配 → 精确名称/显式别名 → 同查询使用 → 有上限的近期/频率/上下文加分 → 稳定tie-break。name/size/modified显式排序沿用原顺序，不注入会破坏其完整性的历史候选。空查询分组展示收藏/最近使用/最近修改，不能把修改时间冒充使用时间。

结果合并采用应用层视图，保持稳定选择身份。普通文件候选按本次sourceID、store身份和entryID去重；跨重扫先按持久身份解析到当前store，不跨store直接比较entryID。正常前缀与历史候选同一目标只出现一次。

具体遍历契约：先输出有界个人排序前缀，再按原搜索顺序输出剩余文件ID；输出后缀时跳过所有已经输出的前缀ID。从原前缀以外提升的历史命中不得在后缀再次出现，未提升的命中不得丢失。一次提交内用捕获快照和小集合membership映射，不把遍历过程中来源更新拼进同一视图。

文件匹配总数保持底层搜索快照的total，提升已匹配历史项不增加total。核心SearchResult/其原sortedCount不修改；应用层另有rankingMode=personalBounded与personalPrefixCount，表示只对指定候选集合重排。该模式页脚明确显示“使用排序候选N项，共T个文件”，不能把N称为全库排序前N或把原sortedCount当个人排序完成数。非个人模式继续使用原排序计数。命令/收藏等独立组不加到文件匹配total。

额外历史文件必须已通过完整条件且能在当前完整匹配ID集合中定位；不能靠加入新行伪增总数。若来源快照只提供部分ID，先解决完整遍历契约或暂停提升，不用total掩盖不可浏览的结果。不要把补充历史结果塞成假的SupplementaryHit。

## 范围

仅范围内应用层组件/测试，不改C、扫描、索引格式或SearchOptions算法。004 scope若缺少withEntryPredicates一致性，先补其契约，不在本计划重复私有matcher。文件I/O在锁外，持锁同步回调不跨async保存Unsafe指针。

## 步骤与验证

### 1. 实施身份与版本化历史存储

写临时目录/注入时钟/来源夹具，覆盖重启、书签过期、移动、删除、同路径替换、store压实/重扫、离线、权限不足、损坏JSON、记录上限和原子写入。采用单份持久文件，临时文件收尾删除，不生成双份主索引。

验证：OILFIND_FREE=1 swift test --filter UsageStoreTests。预期：新store不复用旧ID，替代文件不继承权重，关闭/清除后迟到写入不复活历史。

### 2. 接入执行事件与统计时点

集中订阅ActionExecutor结果，按上述策略记accepted/verified而非“实际打开成功”；query记录区分文件原查询与web隐私策略。重复回调、取消后的回调、选择变化都不能多记或错记。

验证：OILFIND_FREE=1 swift test --filter UsageStoreTests；OILFIND_FREE=1 swift test --filter ActionExecutorTests。预期：一次操作最多一条，失败/取消权重零，web正文默认不落盘。

### 3. 实施完整过滤和有界候选合并

写候选位于正常排序前缀外、空查询200最近修改之外的测试；同时覆盖OR、NOT、path/regex/ext/time、kind、拼音、strict scope、源下线和显式排序。每个历史候选复用同一查询时间与来源快照。权重采用可解释分段比较并设上限，精确命中始终优先。

验证：OILFIND_FREE=1 swift test --filter UsageRankingTests；OILFIND_FREE=1 swift test --filter DirectoryScopeTests；OILFIND_FREE=1 swift test --filter ResultRefreshTests。预期：不匹配完整条件的历史不会泄入结果，选择不跳，显式排序不变。额外遍历整个合并视图，断言每个匹配ID恰好出现一次、数量等于原total、提升后的命中不在后缀重复；personalPrefixCount与rankingMode页脚准确，核心原sortedCount不被篡改。

### 4. 接入空查询与历史设置

提供收藏/最近使用/最近修改的清晰入口、关闭/清除记录设置和不可用提示。查询中异步解析用同一代次，旧回调不得改新结果。测量普通全盘搜索与历史候选解析成本。

验证：OILFIND_FREE=1 swift test --filter UsageRankingTests；OILFIND_FREE=1 swift test --filter SearchEditingTests；OILFIND_FREE=1 swift build -c release。预期：功能回归通过；普通搜索p95相对同机基线增幅建议≤10%，记录实际值，不以单测代替性能证据。

## 测试计划

采用“步骤与验证”中列出的具名用例；在本计划范围内创建注明为新增的测试文件，其余复用现有类。测试类名单为 `UsageStoreTests`、`ActionExecutorTests`、`UsageRankingTests`、`DirectoryScopeTests`、`ResultRefreshTests`、`SearchEditingTests`。

新行为通过可注入权限、系统API、时钟和临时文件夹具验证；不要用真实用户数据作副作用单测。每条筛选命令核对非零测试数与零失败。跨应用、终端或日用场景的人工证据独立记录，不能用fake、字符串断言或snapshot替代。

## 完成标准

- [x] 使用身份跨重启/重扫可解析，移动/路径复用和清除竞态测试通过。
- [x] 统计时点准确标为发起/导航/复制，失败与取消不增加权重。
- [x] 候选严格复用完整query、scope和filters，OR/NOT和大结果回归存在。
- [x] 精确命中优先、显式排序不变、选择稳定；前缀之外提升后完整遍历无重复、无遗漏，总数不变，个人候选前缀计数与核心sortedCount分开。
- [x] 本地历史可关闭/清除，web正文默认不落盘；证据写plans/evidence/008-usage-ranking.md。

## 停止条件

完整过滤需要复制另一套查询语言时先咨询，不能只写名称过滤交付。书签不能可靠区分旧文件和新同路径文件时，不继承权重并显示不可用。需要全盘per-entry String/文件I/O才可排序时收回该实现，保持有界候选方案。

## 维护说明

新增动作需定义统计策略，新增Query原子需补完整过滤等价测试；缓存切scope时重置个人排序代次。若以后要全库最优个性化排序，另立核心设计与性能计划。
