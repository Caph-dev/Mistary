# 001：Mistary 产品隔离实施证据

- 日期：2026-10-10。
- 状态：实现与列出的自动验证完成；真实环境共存、偏好域与权限验收待完成。计划入口保持“进行中”，不将未执行的人工项目标为通过。
- 规划基底与实施时实际 HEAD：`6c024bbbf6b917c4a334f4569de070d887ecd66f`。
- 工作分支：`main`。实施验证时未自动换分支、提交或推送，以上 SHA 为验证基底。后续操作者明确授权 commit/push；包含本次实现的提交见 Git 历史。
- 开始时仅 `plans/` 未跟踪；相对规划基底的范围内已提交漂移为零。已有计划文件保留。
- 环境：macOS 26.6.2（25G83），arm64；项目部署目标仍为 macOS 14，Swift tools 5.10、Swift 5 语言模式，系统框架。

## 实现交付

1. `ProductIdentity.swift` 集中应用层身份：Mistary、`me.caph.mistary`、`mistary`、`me.caph.mistary.show`。AppLog、语言通知、索引路径和界面显示引用它；plist 和脚本另由测试核对。索引为 `~/Library/Application Support/Mistary/index.oilfind`。保留原 Swift target 名字，包内 executable 改为 `Contents/MacOS/Mistary`。
2. manifest 不再探测或装配私有 target；组装入口仅 `Application.run()`。保留中性 `ApplicationExtension`。公开模块边界测试通过，未修改 `Pro/`。
3. 移除启动旧授权清理、更新启动收据登记和启动后清理。`UpdateManager` 的生产检查、下载、安装、网站和错误报告入口均不执行副作用，无更新客户端、安装器、收据或定时器。设置 `automatic = true` 立即回到 false，不读写传入的更新偏好。菜单不提供更新操作，设置显示双语禁用说明。
4. Debug 与 Release 在 `NSApplication` 启动前拒绝 `--update*` 参数；`UpdateExercise.swift` 从 app target 排除。DEBUG Snapshot 移除更新状态/参数、上游更新 manifest 和上游缓存回退。保留 `prepareSnapshot` 仅供 DEBUG 现有 UI 测试，更新操作依然为空。保留核心更新库及原清理函数供已有临时夹具测试，生产入口不可达。
5. 构建输出为 `build/Mistary.app` 与 `build/debug/Mistary.app`。签名选择 `MISTARY_SIGN_IDENTITY` 或现有 `Mistary Self-Signed`；拒绝显式旧 `Oil Find Self-Signed`，忽略旧 `OILFIND_SIGN_IDENTITY`。仅 DEBUG 可自动回退 ad-hoc，并明确提示权限持久性未验证；Release 要求可用签名身份，缺少签名或指定 `-` 时失败。自动门禁只拒绝已知上游名称与显式 ad-hoc，不能证明任意指纹/别名选中的证书独立。没有创建证书。
6. 安装默认只操作 `/Applications/Mistary.app`，由 PATH、`MISTARY_APPLICATIONS_DIR`、`MISTARY_SOURCE_APP`、`MISTARY_BUILD_SCRIPT` 支持夹具注入。先验证源包身份/签名，再在目标卷的 `.Mistary-install.*` 中复制与验签；按 NSRunningApplication 的精确 bundle ID 退出所有 Mistary 实例，超时或识别/退出失败停止。再验证旧目标并移到同卷暂存备份。替换期间设置显式 pending 状态，错误退出及可捕获 INT/TERM/HUP 共用 EXIT 恢复：新目标尚未就位时将备份恢复原路径；恢复失败或目标出现时保留备份并输出位置。退出时将暂存内容（包括成功替换后的旧包）移入废纸篓；失败则保留暂存路径并返回失败。未按 OilFind/Sift 名字关闭应用。已测 SIGTERM 中断；不承诺 SIGKILL、断电或所有并发安装竞态的自动恢复。
7. 卸载明确列出路径并要求 `y`；默认只将应用移入废纸篓，保留索引和设置。`--with-data` 限定 Mistary 目录，先将偏好通过 `defaults export me.caph.mistary` 备份到废纸篓内的独立目录，再通过 preferences service 删除精确 Mistary 域，最后将独立索引目录移入废纸篓。备份或移动失败停止后续操作。不存在付费试用参数或 Keychain 清理。

## 范围增补与保留项

除计划原范围外，实施时声明了四个必要增补：

- `Sources/OilFindApp/WelcomeWindow.swift`：欢迎页硬编码产品名改为 L10n 产品名。
- `Sources/OilFindApp/Snapshot.swift`：移除默认读取上游缓存和更新快照入口；否则 DEBUG 包仍能越过隔离。
- `Tests/OilFindUITests/ApplicationMenuTests.swift`：最小调整撤下更新菜单后的布局断言。
- `Tests/OilFindUITests/LanguageTests.swift`：设置标题断言改为 Mistary；只在 DEBUG 测试更新快照，使 Release 隔离测试能编译全部测试 target。

未修改核心索引、查询、持久化格式、`site/`、`Pro/`、许可证或归档发布脚本 `scripts/package.sh`。后者仍属于后续独立隔离计划，不能用于本次 Mistary 归档发布。

残留旧名盘点：

- `LegacyAuthorizationCleanup.swift` 中的旧文件、Keychain 服务常量保留用于原测试；应用启动无调用。
- `OilFindCore/Update/` 保留，M18Tests 通过；生产 UpdateManager 不构造这些服务。
- 三个 DispatchQueue label 保留旧 `com.oiloil.find.*`；它们仅是进程内调试标签，不是通知、偏好、日志 subsystem、文件或登录项身份。
- 应用图标资源保留原图案；未进行品牌视觉重做。
- 缓存：图标 NSCache 为进程内缓存；默认 DEBUG 上游磁盘缓存回退已撤下。无新增 Mistary 磁盘缓存功能。
- Keychain：Mistary 生产功能未使用；旧清理 helper 不可达，脚本没有 security 删除/清理。
- 登录项：已有 `SMAppService.mainApp` 使用实际主 bundle；没有新增 helper 或硬编码上游登录项 ID。实际注册、独立性和重启行为未做人工验证。

## 自动验证结果

以下最终检查均 exit 0；Swift 筛选以实际匹配的 suite 计数，其他 target 的 0 tests 不计为测试通过。

- 基线 `OILFIND_FREE=1 swift test --filter SearchEditingTests`：1 项，0 失败。
- 初次 `OILFIND_FREE=1 swift test --filter ProductIsolationTests`：5 项，0 失败。
- 最终 `OILFIND_FREE=1 swift test --filter 'ProductIsolationTests|ApplicationMenuTests|LanguageTests|SearchEditingTests|M18Tests'`：UI 14 项、核心 M18 12 项，均 0 失败。隔离类为其中 5 项，编辑快捷键 1 项。
- `OILFIND_FREE=1 swift test -c release --filter ProductIsolationTests`：5 项，0 失败。
- `OILFIND_FREE=1 swift build -c release`：成功。
- `python3 Tests/Scripts/test_open_core.py`：2 项，OK。
- `bash -n scripts/build-app.sh scripts/install.sh scripts/uninstall.sh scripts/create-signing-cert.sh`：成功。
- `python3 Tests/Scripts/test_uninstall.py`：8 项，OK；包含取消、EOF、错误/多余参数、同名异域、应用符号链接、查询/退出/超时失败、应用移动失败、设置备份失败、未运行实例和带数据卸载。
- `python3 Tests/Scripts/test_install.py`：13 项，OK；包含源/目标身份、目标链接、源签名失败、复制失败、退出失败、替换失败恢复、恢复失败保留位置、废纸篓失败、五次启动失败，以及两次移动之间向临时安装脚本发送真实 SIGTERM 的恢复与恢复失败保留备份测试。
- `python3 Tests/Scripts/test_product_identity.py`：5 项，OK；包含默认 manifest（去除 OILFIND_FREE 环境后仍只装配公开 target）、启动代码审计、plist 及 executable 映射、独立签名选择，以及 Release 无签名/显式 ad-hoc/显式上游身份拒绝。
- `git diff --check`：成功。最终路径范围检查符合原范围、上述四个增补与 `plans/README.md`、本证据文件。

夹具隔离方式：临时 HOME 仅通过子进程 env 传入；临时应用/数据目录；PATH stub 记录 osascript/defaults/ditto/mv/codesign/open 等外部操作；真实 plutil 仅解析临时 plist。中断用例只向夹具启动的临时 Bash 子进程发送 SIGTERM。所有场景核对 Oil Find/Sift 文件标记不变，其他 PID 列表不变；security/rm/pgrep 调用会让夹具失败。临时注入 UserDefaults suite 与临时索引标记证明所测代码的隔离契约，不能证明真实标准偏好域或进程的人工共存。

失败记录：

1. 首次 Python 脚本测试：生成 stub 时换行转义被展开，出现 `SyntaxError: unterminated string literal`，导致多个 suite 失败。修复生成的日志字符串后，以 `set -e` 重跑三个脚本 suite，均通过；此后扩展安装恢复测试再次通过。
2. 首次 Release 隔离测试：`LanguageTests.swift:110` 调用了仅 DEBUG 存在的 `prepareSnapshot`，编译失败。将仅快照相关准备与断言放入 `#if DEBUG`，随后 Release 隔离类 5 项与 Release build 通过；搜索语言断言保留在两配置。
3. 构建沿用已有 `IndexManager.swift:130` weak/implicit strong capture warning；基线已存在，未顺带改核心代码。

## 真实构建包与快照

命令：

```sh
OILFIND_FREE=1 scripts/build-app.sh --debug
plutil -lint build/debug/Mistary.app/Contents/Info.plist
codesign --verify --strict build/debug/Mistary.app
codesign -dv --verbose=2 build/debug/Mistary.app
```

结果：plist OK，签名验证 exit 0。签名详情：

```text
Executable=.../build/debug/Mistary.app/Contents/MacOS/Mistary
Identifier=me.caph.mistary
Format=app bundle with Mach-O thin (arm64)
Signature=adhoc
TeamIdentifier=not set
```

分别对真实调试包 executable 与 Release `.build/out/Products/Release/OilFind` 运行 `--update-exercise`、`--update-launch`、`--update-manifest`、`--update-notes`：每个配置 4 次均 exit 2，stderr 为 `Mistary does not support updates.`，未进入正常应用启动。

只读 JXA bundle ID 进程查询在本机成功执行，返回空列表。未调用真实 terminate 或 trash。

DEBUG 快照命令：

```sh
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot build/debug/001-settings-en.png --state settings --language en
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot build/debug/001-welcome-zh.png --state welcome --language zh
```

均 exit 0，分别生成 1080×1200 与 840×820 PNG。已查看图片：设置页显示个人版禁用更新说明，没有更新 toggle/检查按钮；欢迎页标题 Mistary。快照不使用真实索引，不能替代共存、权限或 AX 验收。图片和 app 包都留在忽略的 `build/` 中，不提交构建产物。

## 人工验收记录与限制

以下均为 **未验证**，不是失败记录，也不是通过：

- 实际 Mistary app bundle 的 `UserDefaults.standard` 持久域标记、真实重启后偏好隔离。注入 suite、plist 一致性和源代码审计不替代这个检查；不依赖临时 HOME 推断 cfprefsd 的真实行为。
- 两款应用同时运行、分别唤起和分别退出；目前两者默认都是 `⇧⌘F`，共存前须在 Mistary 自身设置改为独立快捷键。不宣称修改 bundle ID 就消除了快捷键冲突。
- 实际 Mistary 登录项注册、独立重启行为与上游登录项保留。
- 新 bundle 的完全磁盘访问权限授予、撤销以及稳定签名重建后的权限保持。
- 真实安装/卸载。当前只有临时夹具证据，没有动 `/Applications` 中的应用、旧用户数据或 Keychain。
- 独立证书的实际创建与私钥/签名 requirement 审核；codesign strict 只能证明完整性，不能证明证书独立于上游。当前包为 ad-hoc，不能声称权限跨重建保持。

计划限制原文：“不自动安装、卸载、创建签名证书、操作真实用户文件或提交 Git；这些需要实施任务中的相应授权。”本轮先交付可用调试包和自动检查；后续操作者明确授权 Git 提交与推送，未另行授权真实安装/卸载、证书创建或真实用户文件操作。人工验收中涉及真实偏好写入、正常索引生成或系统登录项/权限变更的操作应先确认授权范围；单纯读取 bundle 元数据、进程列表与交付构建无需额外授权。后续可直接使用 `build/debug/Mistary.app`；尚未执行 AX 实验。
