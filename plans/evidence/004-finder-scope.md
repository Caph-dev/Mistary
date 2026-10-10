# 004 Finder、目录范围与收藏实施证据

状态：已完成（按操作者决定，真实 Finder／Automation／跨应用验收及真实同机性能测量暂缓）。

实施提交：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`。

前置交付：003 的实现提交 `35ccb53a668bdcdac9abf46b3fb1090db67ca513`；开始时 HEAD 为 `109a4b5`，工作区干净，沿用当前个人 fork 的 `main`。操作者明确授权实施、标记完成、commit 与 push。

## 实际交付

- `SearchOptions.directoryScope` 默认 nil，保持全盘入口。`DirectoryScope` 仅做绝对路径组件与 NFC 规范化，不解析文件系统符号链接。新建的中性 `SearchScope.swift` 在每个 store 的读锁内解析目录，使用卷的名称比较规则和 parent 链；编译结果只存在于当前锁内查询，不跨来源、版本或重扫复用 entryID。请求目录是来源根目录的祖先时覆盖该来源，不相交／未覆盖／已删除／符号链接目录返回空范围。
- 范围过滤发生在批量名称评分、带否定名称评分、普通 matcher、recent 200 条和 topK 排序之前，也用于 `withEntryPredicates` 与补充命中合并。缓存与增量收窄比较 scope。多来源缓存绑定 sourceID、store 对象及在线状态；绑定代次保护 lookup 和 insert，旧任务无法在重新绑定或清空后写回。
- Finder 上下文在面板取焦点前捕获。目录观察包含窗口 UUID、URL、观察时间及获取方式；本次会话默认全盘，用户显式切换范围，路径随后冻结。其他应用唤起时，可保留最近一次 Finder 候选，但先校验原 AX 窗口仍在、document 路径不变且无搜索状态；无法重新验证的 Automation／Desktop 旧观察不被复用。窗口导航不在本次实现范围。
- 系统探测优先读取 AXDocument，并检查搜索字段、读取失败与检查上限。采样结束重读窗口、document 和搜索状态，同窗口标签页变化也会拒绝。必要时使用固定、只读的 Finder AppleScript；脚本不插入外部路径，读取前台窗口 target 并再次核对窗口 ID 与 target。脚本窗口必须与 AX 焦点窗口的唯一标题对应，不确定或重复标题返回 unavailable。
- Desktop 仅在 Finder 无 Finder window 且 AX 无焦点窗口时返回显式桌面路径。Recents、搜索窗口、非 file URL、无法确认的窗口、切换窗口和退出均返回具名原因。缓存只保留当前实际观察到的窗口；新观测失败即清空，不用其他窗口或旧目录填补。没有宣称取得全部 Finder 窗口的真实目录。
- AX 与 Automation 独立检查，自动捕获不请求权限。目录菜单的显式授权入口可请求权限，并提示回 Finder 重新唤起；Info.plist 增加 Apple Events 使用说明。当前进程真实权限状态、拒绝弹窗和撤销行为未进行真机验证。
- 收藏使用 Mistary 数据目录中的 `favorites.json`，版本为 1，保存书签、降级路径、手动名称及可选来源 ID，不保存索引 ID。原子写入一份配置；写入失败不改变内存列表。损坏、重复 ID、非绝对降级路径或未知版本拒绝覆盖。书签解析无 UI、无自动挂载；损坏书签可降级到路径，仍检查目录与权限。
- 设置支持添加、改名、上移／下移和移除收藏；移除只改变配置。空查询将收藏与最近修改分组，前三个收藏可直接选择，其他收藏可从目录菜单访问。候选显示 Finder／收藏来源、索引覆盖及不可用原因；未索引目录仍可明确复制路径，不伪装为搜索结果。
- Quick Switch 提供候选、显式选定搜索范围及复制目录路径，不执行打开／保存对话框导航。005 可消费 `DirectoryCandidate` 和绑定 Finder 身份的 `FinderDirectory`，无反向依赖。

## 自动验证

下列七条命令均 exit 0，每类实际匹配非零测试数，合计 41 项、零失败。Swift 同时启动两个测试 target 时，另一个 target 的零匹配不计为验证结果。

- `OILFIND_FREE=1 swift test --filter DirectoryScopeTests`：11 项。边界、根目录、中文／大小写、词法规范化、hash 未就绪、无覆盖、符号链接、recent 200 限额、批量／普通 matcher、21 万条全盘命中中的范围 topK、缓存／收窄、来源上下线、旧任务写回、目录删除重建及压实、多来源祖先 scope、条目 predicates。
- `OILFIND_FREE=1 swift test --filter FinderContextTests`：12 项。窗口／tab 更新、替换／进程重启、拒绝和 stale 缓存、最近目录的存活验证及系统 AX 窗口列表／document／搜索读取失败、Desktop 和会话冻结、AX 读取错误、同窗口 document／搜索变化、搜索检查期间跨窗口焦点切换、固定脚本只编译不运行、补充命中 containment、scope 切换后动作失效及面板结果复用。
- `OILFIND_FREE=1 swift test --filter FavoritesStoreTests`：7 项。真实临时目录的书签与重启、改名排序移除、不删除目录内文件、损坏／未知版本配置保护、损坏书签降级、权限／缺失原因、目录移动与已冻结 scope、写入失败、离线与未索引候选、空查询分组。
- `OILFIND_FREE=1 swift test --filter SearchSessionTests`：6 项。
- `OILFIND_FREE=1 swift test --filter ResultRefreshTests`：3 项。
- `OILFIND_FREE=1 swift test --filter ResultsSelectionTests`：1 项。
- `OILFIND_FREE=1 swift test --filter SearchEditingTests`：1 项。

补充回归命令 `OILFIND_FREE=1 swift test --filter 'SupplementarySearchTests|SearchSourcesUITests|ActionExecutorTests|M7SearchTests'` exit 0：补充搜索 5 项、多来源 UI 4 项、动作执行器 22 项、默认搜索／Unicode fuzz／取消与缓存 3 项，共 34 项、零失败。连同计划指定检查，共 75 项 Swift 测试。

其他检查：

- `OILFIND_FREE=1 swift build -c release`：exit 0，`Build complete!`。构建报告未修改的 `IndexManager.swift:130` 捕获所有权 warning，本次没有扩大范围处理该 warning。
- `python3 Tests/Scripts/test_open_core.py`：2 项、OK，exit 0。
- `git diff --check`：exit 0。
- 改动仅涉及 004 登记的实现文件、三个新增测试类及本计划／入口／证据；未改变 Query.swift、索引格式、C 热路径、site/、Pro/ 或许可证。

测试过程中修正了误置协议成员的编译错误、AppleScript 保留术语变量、URL 尾部分隔符断言，以及新增收藏项导致旧菜单末项变化的回归。最终命令重新执行并通过，没有将这些失败记作通过。

## 暂缓的真实验收

以下项目按操作者明确要求暂缓，不作为本次完成门槛，也不视为通过：

- 真实 Finder 普通窗口、标签页、同名窗口、Desktop、Recents、搜索窗口及关闭／退出的系统兼容性；AXDocument 是否可靠、静态脚本在实际系统上的 target 类型与窗口对应。
- 打包应用中的 AX／Finder Automation 首次授权、拒绝、撤销、签名更新后的权限保持及捕获耗时。编译脚本和 fake AX／Finder 测试不能替代这些验收。
- Finder、Quick Look、拖拽、菜单焦点及真实剪贴板接收方的跨应用操作。
- 真实离线卷、重新挂载、目录移动后书签解析及不可读目录的系统错误分类；自动测试只使用临时目录和可注入错误。
- 同机真实索引上全盘默认 nil 与 scope 查询的 p50／p95、内存成本和相对基底增幅。没有声称达到“不超过 10%”目标；21 万条夹具只证明排序／截断正确性。

002 的 AX 支持关卡仍未判定，005 的自动导航支持集合仍为空。本次未安装或卸载应用、创建证书、触碰真实用户文件，也未执行跨应用导航。

## 维护边界

父 entryID 小于子 entryID 的假设来自 `docs/ARCHITECTURE.md`，并核对了 `IndexStore.insert` 的尾部追加、`IndexStore.compacted` 的顺序映射与 `IndexUpdater` 的移除／重新插入流程；没有引入 ID 原地重挂父节点。新增回归实际删除重建目录并压实，确认 scope 重新解析。若后续改变该索引不变量，祖先判断及无 hash 的子目录查找必须同步调整。

008 的历史候选应复用相同 scope 谓词，不能先截断再在 UI 过滤。真实 Finder 验收后才扩大可识别窗口集合；无法确定的目标继续返回 unavailable。
