# 009：常驻面板、位置记忆与联合验收证据

日期：2026-10-11。

## 完成范围与前置

- 已完成（实现与自动验证；按操作者授权，真机联合验收、性能验收及稳定签名暂缓）。本记录不把暂缓项记为通过。
- 最终实现及测试提交：`7534316213de033c6e218e7e6814d29671b06288`。后续完成状态提交仅修改计划和证据文档；该 SHA 是实际接受下述检查的代码版本。
- 起始 HEAD：`db00cf05f0d5d741c08ea6c553e52475fb5dd910`；沿用现有 `main`。工作区已有 `plans/README.md` 的真机清单入口与未跟踪 `plans/manual-acceptance-checklist.md`，已保留清单内容，仅同步 009 已实现的状态描述，人工用例未勾选。
- 操作者明确要求完成 009、允许需要真机实测部分暂缓，并授权 commit、push；这是本轮对原计划自动提交及完整人工验收限制的例外。
- 已读项目 AGENTS.md、docs/ARCHITECTURE.md，并核对基底 `6c024bbbf6b917c4a334f4569de070d887ecd66f` 至 HEAD 的漂移。003 会话契约：`35ccb53a668bdcdac9abf46b3fb1090db67ca513`；004 范围／目录：`e4b7dd35f5b9fc6581a7635b625ec9bcd62d87f9`；005 手动路线：`fcb31c6944727ac95647e43bd49627008c6432d0`；006 路由：`fc53d01b347d81b7faad5fcd8f633652b12582a6`；007 动作：`8974b820e10d5a74e1f20ba2bf05534e1b145282`；008 历史：`413853ccc85d1eee473cbf7e2304c5b3cf9bec26`。未修改核心、C、索引格式、site/ 或 Pro/。

## 交付行为

- `PanelPreferences` 可注入独立 UserDefaults 或纯内存配置。正式偏好保存于 `me.caph.mistary`，键为 `panelKeepOpen`、`panelPlacement`；默认瞬时模式。frame 与屏幕标识使用 Codable 保存，损坏、非有限坐标或非正尺寸回到安全默认。
- 初次默认 frame 为 800×560，按鼠标所在屏幕的 visibleFrame 居中。已保存位置优先恢复到原屏幕，原屏幕消失时选择可用屏幕并 clamp；尺寸下限为 480×360，但显示区域更小时以实际 visibleFrame 为上限。负坐标、屏幕顺序、分辨率和缩放变化均由注入几何测试覆盖。
- 没有可用屏幕时不显示、不覆盖已存位置；屏幕恢复后再次唤起会恢复原位置。屏幕参数通知在可见时重新限制位置；程序化恢复使用 applyingFrame 避免同步 delegate 通知误保存。
- 顶部中央 100×14 pt 为专用拖动区域，以短横线提示，调用原生 `performDrag`。搜索框和结果区不启用背景拖窗；用户移动／尺寸变化保存 placement。窗口仍为非激活浮动 NSPanel，保留 collectionBehavior 和动画代次。
- 设置增加中英文“失焦后保持打开”开关。普通失焦在瞬时模式隐藏，在常驻模式保留窗口。菜单、Quick Look、结果拖拽、手柄拖动、模态动作、待打开动作和预期导航交接沿用保护规则，交互结束后重新评估。Escape、⌘W、窗口 close、面板已经 key 时重复快捷键仍结束会话并隐藏。
- 常驻 Open／Save 场景在普通失焦或捕获 120 秒后 unavailable：撤销 action generation，清掉 target、dialog、准备路径与 adapter token，取消待打开动作；不绑定后来出现的前台应用。定时器更新可见提示，`isCurrent` 在动作执行时再次检查时间，不能因睡眠或 timer 延迟继续使用旧场景。
- unavailable 后允许显式切普通模式继续搜索；保留窗口非 key 时全局热键／菜单／reopen 重新捕获。异步场景识别仍受 presentation generation 约束，hide 或更新的捕获使旧回调无效。
- 修正 `resumeDialog` 的查询刷新：恢复交接窗口保留当前查询和 token，不再调用 panelWillShow/startSearch，使刚准备好的手动路径仍能显式复制。新的全局唤起继续正常刷新。

## 自动验证

环境：macOS 26.6.2（25G83）、arm64；macOS 14 部署目标、Swift 5 语言模式。全部 Swift 命令使用 `OILFIND_FREE=1`，未用 CI=true 跳过本机相关检查。只把 XCTest 的非零测试数计作通过，附带的 Swift Testing 零匹配输出不计数。

计划具名测试均实际匹配并通过：PanelBehaviorTests **21**、SearchSessionTests **6**、ResultsSelectionTests **1**、SearchEditingTests **1**、ResultRefreshTests **3**、DialogWorkflowTests **22**，共 54 个不同测试；最终全量亦包含这些测试。

```sh
OILFIND_FREE=1 swift test --filter PanelBehaviorTests
OILFIND_FREE=1 swift test --filter SearchSessionTests
OILFIND_FREE=1 swift test --filter ResultsSelectionTests
OILFIND_FREE=1 swift test --filter SearchEditingTests
OILFIND_FREE=1 swift test --filter ResultRefreshTests
OILFIND_FREE=1 swift test --filter DialogWorkflowTests
OILFIND_FREE=1 swift test
python3 Tests/Scripts/test_open_core.py
python3 Tests/Scripts/test_product_identity.py
python3 Tests/Scripts/test_install.py
python3 Tests/Scripts/test_uninstall.py
OILFIND_FREE=1 swift build -c release
git diff --check
git diff --cached --check
```

最终全量输出（2026-10-11 13:13～13:14）：

```text
OilFindUITests.xctest passed: Executed 248 tests, with 0 failures
OilFindCoreTests.xctest passed: Executed 116 tests, with 0 failures
```

合计 **364 项，零失败，exit 0**。脚本分别 Ran 2 / 5 / 13 / 8 tests，全部 OK、exit 0，共 **28 项**。安装／卸载只操作脚本夹具，未安装／卸载真实应用或清理真实数据。最终 Release 编译 exit 0，`Build complete! (20.23秒)`；保留原有 IndexManager 捕获 ownership、CommandRunner 未使用 self 警告，未为消除警告扩大 scope。

21 项新增覆盖：默认／持久化／损坏偏好、负坐标、多显示器移除与顺序、缩放与最小尺寸、无屏幕再唤起、手柄 hitTest 与持久化、两种模式的失焦与显式关闭、菜单与两种拖动的保护、预期交接、连续 10 轮动画反转和编辑焦点、非 key 重捕获、过期异步识别、注入时钟动作时过期、路径清理与复制拒绝、实际 executor／Quick Switch 拒绝新导航、迟到打开回调、真实临时索引手动准备路径后隐藏／恢复／复制、注入设置和 close。Quick Look 的真实控件交互仍属下方人工补测，既有保护代码未被移除。

中间失败据实保留：

- 新增 L10n 键曾与原 `panel.settings` 重名，测试启动发生 duplicate-key 崩溃；已改为 `panel.preferences`。随后修正 hitTest 父视图坐标及交接恢复查询刷新，并补集成断言。
- 目录 URL 尾斜杠使夹具等值断言失败，改为精确 path 比较；一次修改脚本丢掉 key-path 反斜杠导致编译错误，已用闭包改正。最终 21 项通过。
- 13:10 的全量运行中 UI 248 项通过、核心 116 项发生 **2 个断言失败**，均在 `M4Tests.testT52UpdateConfig` 第 88／93 行，轮询重建中 `isRescanning`。未修改该测试或核心；定向复跑 1 项通过，13:14 最终完整 364 项通过。原因未确定，仅能说明该轮失败未在后续运行复现，不能宣称已修复或已确认是既有 flake。

本机临时日志：`/tmp/mistary-009-panel-tests.log`、`/tmp/mistary-009-full-tests.log`（保留失败轮）、`/tmp/mistary-009-rebuild-retest.log`、`/tmp/mistary-009-full-final.log`、`/tmp/mistary-009-release-final.log` 与四个 `/tmp/mistary-009-test_*.py.log`。临时文件不提交，关键结果已摘录于本文件。

## 应用包与界面

```sh
OILFIND_FREE=1 scripts/build-app.sh
OILFIND_FREE=1 scripts/build-app.sh --debug
codesign --verify --deep --strict build/debug/Mistary.app
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-009-settings-zh.png --state settings --language zh
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-009-settings-en.png --state settings --language en
build/debug/Mistary.app/Contents/MacOS/Mistary --snapshot /tmp/mistary-009-panel.png --state indexing --language zh
```

- **正式打包未完成**：首条命令 Release 编译完成后因缺少签名身份 exit 1，准确错误为 `Release requires MISTARY_SIGN_IDENTITY or an existing Mistary Self-Signed certificate.`。未创建证书、未绕过签名门槛；不能将 unsigned Release 目录当成交付稳定包。
- 调试包成功，`build/debug/Mistary.app` 使用 ad-hoc 签名；签名校验 exit 0。Info.plist 实测 bundle id `me.caph.mistary`、版本 `1.4.1`。ad-hoc 不证明跨重建的权限保持。
- 三张截图生成 exit 0，均直接读取像素检查。中英文设置中的新增开关和完整提示可读；英文底部已有辅助功能行处于视口边缘，Form 可滚动，不据此声称整个设置页面都已检查。面板短横线可见，未遮挡搜索输入。截图使用内存模型／索引中样本，不读取用户真实文档。
- 快照只证明本应用渲染；不能证明第三方 AX、输入法、原生拖动事件顺序、多屏或全屏行为。没有在生产入口增加探针。
- Advisor 核对了可见验证输出和三张截图，没有报告新的明确阻断项；由于完整实现和新增测试未向 Advisor 披露，不能声称完整源码已通过 Advisor 审查。

## 暂缓的真实联合验收与性能

按操作者本轮明确授权，下列项目仍为 **未验收／暂缓**，009 的完成状态限定为实现与自动验证。

- 常驻／瞬时模式真实失焦、Escape／⌘W／热键、中文 marked text、菜单、Quick Look、结果与手柄原生拖动。
- 多显示器物理断开、分辨率／缩放切换、主屏变化、跨 Space／全屏，以及最低 macOS 14 实机。
- 至少 3 个真实日用日：当前实际记录 **0 日**，没有编写虚构任务、成功次数或 Finder 替代情况；后续按 [真机清单](../manual-acceptance-checklist.md) I／K1 记录。
- 同机同索引对照基底的搜索 p95 增幅 ≤10%、热键到可输入 p95 <100 ms、冷暖／短查询／大结果集的样本与背景负载均 **未测**。本次没有有效对照或测量值；[008](008-usage-ranking.md) 已记录的排序增幅和同步写盘问题保留，不能因 009 测试通过改称达标。
- 稳定签名 Release 包、真实安装／升级／卸载、登录项与权限保持，待独立签名身份就绪后补测。

005 仍为 **显式手动 Open／Save 路径交接**，不会自动提交 Open、Save 或覆盖。生产自动导航支持集合 **为空**，002 AX 关卡 **未判定**；Terminal **unsupported**。原手动识别没有可靠的原对话框 window identity，**同一宿主内关闭／替换对话框不能即时验证**。本次普通失焦与 120 秒过期仅限制场景寿命，不证明在这两分钟内对话框一直有效。将来启用自动路线必须回到 002／005 完成原目标身份与实际兼容验证。
