# Clawdesk 2.0 开发任务清单（2026-10-30 验证版）

基准：`origin/main` 提交 `6d9b728`（同步上游 v0.16.0 对齐之后的最新 main）。
本文档把《Clawdesk 与 Clawd-on-Desk 全面对比审查》与《Clawdesk 2.0 升级方案》落成
可执行任务，每项断言先在当前 main 代码上核实，标注证据位置，再排期。
审查中与当前代码不符的结论已剔除。

执行约束沿用 2.0 方案第二十一节：不推倒 BloubEngine、不引入 Electron、
不破坏旧主题、不把逻辑继续堆进 PetWindowController/PetCanvasView、
每项修复带回归测试。

---

## 一、验证结论（2026-10-30，基准 6d9b728）

| # | 审查断言 | 结论 | 证据 |
|---|---|---|---|
| P0-01 | 隐藏宠物会被指针定时器重新显示 | **确认** | `PetWindowController.swift:244-248`：petState 为 idle/miniIdle/miniPeek 时 `orderFrontRegardless()` 无 `petHidden` 守卫 |
| P0-02 | 隐藏后渲染/指针轮询/漫游仍运行 | **确认** | `applyPetVisibility()`(:611) 只 orderOut；animation/pointer/roam 定时器无 petHidden 守卫 |
| P0-03 | 点击立即进入拖动、微抖即移动窗口 | **确认** | `PetCanvasView.swift:600` mouseDown 立即 `onDragBegan`；`:610` mouseDragged 无阈值调用 `onDrag`；4pt 仅用于点击识别(:608) |
| P0-04 | 普通点击可触发 Mini Mode | **确认** | `PetCanvasView.swift:614` mouseUp 无条件 `onDragEnded` → `endDrag()`(:485) 评估 `shouldEnterMiniMode`(:496) |
| P1-01 | Reaction 任务相互竞争 | **确认** | `showReaction()`(:556-566) 每次新建无主 Task，先到期的恢复会截断后一个反应（现状已恢复最新逻辑状态，“恢复旧状态”部分不成立） |
| P1-02 | 相同状态不重播一次性动画 | **确认** | `setPetVisualState`(:451) 同值去重；`PetCanvasView.petState` didSet(:49) 同值守卫 |
| P1-03 | 反应动画可覆盖 error/permission | **确认** | agent 触发的 `celebrateArrivals`(:553)、`showTestReaction`(:631) 无优先级守卫 |
| P1-04 | 睡眠期间维持高帧率 | **确认** | `.sleeping`(BloubState.swift:590) 与 `.miniSleep`(:1169) `settlesAt: nil` + 0.6s 循环弹跳；`BloubSettleTests` 把“永不 settle”固化为契约 |
| P1-05 | Headless 会话污染动画分级 | **确认** | `EventStateReducer.swift:186` `sessionsByID.count` 含 headless；`PetWindowController.swift:104` `activeSessionCount = sessions.count` 未过滤 |
| P1-06 | 多显示器用外接矩形约束 | **确认** | `clampedToAttachedScreens`(:509) union；`applyScale`(:969-981) 底部中心锚点后无再约束；启动恢复仅判相交(:518-521) |
| 性能-1 | 主题动画同步解码、先解码后限预算、无负缓存 | **确认** | `PetCanvasView.swift:483-516`：draw 路径同步解码至多 180 帧，`:506` 解码后才查 64MB，失败结果不缓存 |
| 性能-2 | 主题动画用全局时钟，状态进入不从第 0 帧开始 | **确认** | `currentFrame(in:)`(:572-582) 以全局 `assetClock` 取帧；程序化引擎本身按状态本地时间重启，不受影响 |
| 主题-1 | 多候选资源取首个存在者，无稳定随机变体 | **确认** | `ThemeCatalog.assetURL`(:205-208) |
| 交互-1 | hitTest 用 Bloub 轮廓，与自定义主题图片不符 | **确认** | `PetCanvasView.hitTest`(:293) 用引擎 bodyPath |
| 交互-2 | Roam 定时器 5s 与注释“每 4s”不一致；漫游缺 petHidden 守卫 | **确认** | `PetWindowController.swift:197-199` 间隔 5s；`checkRoam`(:889) 守卫链无 petHidden |

审查中未被证实/已在演进中处理的点：恢复动作引用的是最新逻辑状态而非触发时旧状态；
hover peek 已有任务取消与状态守卫；文档口径里“9 月 3 日审查”指 GitHub 侧旧版报告。

---

## 二、第一阶段：基础逻辑修复（本次实施）

按 AGENTS.md 流程：先补行为测试，再改实现，最后 `swift test` + `scripts/build-app.sh`。

| 编号 | 任务 | 主要文件 | 验收 |
|---|---|---|---|
| P0-01/02 | 隐藏即全停：指针定时器守卫 `petHidden`；隐藏时停渲染/指针/漫游定时器并取消漫游与空闲彩蛋，显示时恢复 | PetWindowController.swift | 隐藏后任何状态变化、鼠标移动、Roam 计时都不会重新显示或绘制 |
| P0-03 | 新增 `PetPressGesture`（Domain）：按下只记录，移动过 4pt 阈值才视为拖动开始，`onDragBegan/onDrag` 仅在真实拖动中发出 | PetInteractionGeometry.swift、PetCanvasView.swift | 点击不动窗口、不播放拖动姿态；≥4pt 才开始拖动 |
| P0-04 | `onDragEnded` 仅在真实拖动释放时发出 → 点击不再评估边缘吸附/Mini | 同上 | 点击贴近边缘不进入 Mini；双击不误切 |
| P1-01 | Reaction 生成号所有权：新反应/真实状态变更使旧恢复任务失效 | PetWindowController.swift | 连续通知不互相截断；反应结束恢复最新逻辑状态 |
| P1-02 | `setPetVisualState(_:restartIfSame:)` + `PetCanvasView.replayCurrentState()` | PetWindowController/PetCanvasView | 相同一次性状态可重播 |
| P1-03 | 装饰性反应（新会话庆祝、测试结果）在 `.error`/`.attention`/待授权时让位 | PetWindowController.swift | 错误与权限状态不被开心动画覆盖；用户主动点击仍响应 |
| P1-04 | `.sleeping`/`.miniSleep` 改为 2s 内衰减到静态深睡姿态（`settlesAt: 2.0`），更新 `BloubSettleTests` 契约 | BloubState.swift | 睡眠 2s 后渲染降档至 idle 频率；唤醒起始姿态保持不变 |
| P1-05 | liveSessionCount 与 activeSessionCount 均排除 headless（保底 max(1)） | EventStateReducer.swift、PetWindowController.swift | 单个可见会话工作时显示 typing 而非 building/juggling |
| P1-06 | 新增 `DisplayTopology.clampLooseOrigin`：union 钳制后若窗体与任何真实显示器无交叠，吸附到最近显示器；`applyScale` 后再约束 | Domain/DisplayTopology.swift、PetWindowController.swift | 错位双屏死区内不会丢失宠物；缩放不会推出屏幕 |
| 交互-2 | Roam 轮询间隔对齐 4s；`checkRoam` 增加 petHidden 守卫 | PetWindowController.swift | 文档与行为一致 |

第二阶段遗留（本次不做，见第三节）：隐藏时深度睡眠 0-2 FPS、资源异步解码、独立动画时间线。

## 三、第二阶段：动画运行时（P1）

| 任务 | 说明 | 新模块 |
|---|---|---|
| 独立动画时间线 | 每次动画实例持有 startTime/loopMode/playbackSpeed/generation；程序化引擎继续用单调时钟 | `PetAnimationRuntime`、`PetAnimationPlayer` |
| 资源异步加载 | 后台解码、按显示尺寸下采样（已有 per-frame 下采样保留）、解码中预算检查、失败负缓存、加载期间保留原生 Bloub | `ThemeAssetLoader` |
| 渲染调度器 | 按资源真实帧间隔调度；睡眠 1-2 FPS、深睡/隐藏 0 FPS；Reduce Motion | `PetRenderScheduler` |
| 状态仲裁 | AgentActivity/PetVisualState/VisualTier 分层（2.0 方案第三节）；一次性事件 PetAnimationEvent | `PetStateCoordinator`、`PetVisualResolver` |
| 逐动画 hitbox | 透明像素/配置矩形/SVG 轮廓，替换引擎轮廓命中 | `PetHitTestResolver` |
| 显示拓扑完整版 | 按屏维护 frame/visibleFrame/scaleFactor；拔出重选最近屏；足够可见面积判定 | `DisplayTopology` 扩展 |
| Mini Mode 升级 | 窗口滑出/收回、Sleep Peek、露出比例与时长主题化、镜像 | `PetMiniModeController` |

## 四、第三阶段：主题 Manifest v2 与安全

- `ThemeManifestV2`：canvas/capabilities/rendering/eyeTracking 全参数/clips(锚点、hitRegions、playbackSpeed、loop)/reactions/idleEasterEggs/completionVisualMap/accessories(head+mouth)/miniMode.offsetRatio·glyphFlips·sleepPeek/itemOverrides；旧格式走 `ThemeCompatibilityAdapter`。
- `ThemeSecurityValidator`：SVG 禁脚本/foreignObject/外链/危险 CSS url、节点数与尺寸上限；ZIP 禁路径穿越/符号链接、限数量/总大小/压缩比/深度；临时目录校验后原子安装。
- 资源变体稳定随机（对应 `createStableVisualPicker`）。
- 自定义主题能力声明：petTint/bodyShape/expressions/eyeTracking/accessories，设置界面按能力显隐。

## 五、第四阶段：表现力

- Idle 动画池（Look Around/Curious/Stretch/Yawn/Play/…，权重+冷却+去重，`IdleAnimationCycle` 扩展）。
- 交互反应矩阵（点击方位、长按压扁、拖动惯性、落地回弹；运动参数驱动而非固定动画）。
- Roam 方向感（moveDirection/velocity/facing/landingImpact，`BloubMotion` 扩展）。
- 配饰系统（head/mouth 槽、锚点跟随形变、镜像、逐动画显隐）。
- Pet 设置页 + 动画预览器 + 开发者模式（注入状态预览、调试 HUD）。

## 六、第五阶段：生态（最后）

主题商店/在线目录/导出分享/社区管理/离线缓存；均不得成为启动依赖。

## 七、测试计划

本次新增/修改：`BloubSettleTests`（深睡 settle 契约）、`PetPressGestureTests`、
`DisplayTopologyTests`、`EventStateReducerTests`（headless 分级）。
后续按 2.0 方案第十九节补齐：PetStateCoordinator/PetAnimationRuntime/PetScheduler/
PetVisibility/PetDrag/PetReaction/PetMiniMode/PetDisplayTopology/ThemeManifestV2/
ThemeCompatibility/ThemeSecurity/ThemeAssetLoader/ThemeCache/ThemeHitTest/
PetSessionState 等测试文件，以及“相同输入相同时间 ⇒ 相同姿态”的确定性快照。
