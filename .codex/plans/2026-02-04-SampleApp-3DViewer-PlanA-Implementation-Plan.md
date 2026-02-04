# SampleApp 3D Viewer 交互（Plan A：Metal 渲染）实施计划

> 执行方式：建议使用 `executing-plans` 按批次实现与验收（每批 2–4 个 Task）。
>
> 目标平台：iOS 18+、macOS 15+、visionOS 2+（以 `Package.swift` 与 SampleApp 工程为准）。

## Goal（目标）

- 删除 SampleApp 中任何“自动旋转/公转”的代码路径。
- iOS + macOS：为用户导入的 `.ply/.splat/.spz` 渲染视图提供 **自由旋转 + 缩放（缩放模型）**。
- visionOS：
  - Volumetric Window：系统负责窗口平移/摆放；App 内实现 **自由旋转 + 缩放（缩放模型）**。
  - ImmersiveSpace（CompositorLayer + Metal）：保持现有 Metal 渲染管线；通过 CompositorServices 的空间输入事件实现 **自由旋转 + 缩放（缩放模型）**。

## Non-goals（非目标）

- 不做平移（pan）；visionOS 中“位置移动”交给 Volumetric Window 的系统抓取/摆放。
- 不实现 Plan B（把 splat 变成 RealityKit “真 3D Entity”）；但必须把 Plan B 作为后续阶段写入本计划文档末尾。

## Approach（方案）

- 继续复用现有 SampleApp 的 Metal 渲染路径：
  - iOS/macOS：`MetalKitSceneRenderer`
  - visionOS Immersive：`VisionSceneRenderer`（CompositorLayer + LayerRenderer render loop）
- 抽象一个**可注入、线程安全**的交互状态存储（不使用单例）：
  - 旋转用四元数 `simd_quatf`（自由旋转/arcball 累计）
  - 缩放用 `Float`（uniform scale，clamp）
- iOS/macOS：用 SwiftUI 手势更新交互状态；渲染侧每帧读取快照拼接 viewMatrix。
- visionOS Immersive：用 `LayerRenderer.onSpatialEvent` 接收空间输入（主线程回调），更新同一交互状态；渲染线程读取快照。

## Acceptance（验收）

1. SampleApp 启动后模型不会自动旋转（代码中也不存在自动旋转累加逻辑）。
2. iOS + macOS：拖拽能自由旋转；捏合/滚轮能缩放；切换模型会重置交互状态（rotation=identity, scale=1）。
3. visionOS：
   - Volumetric Window：可对导入的 splat 做旋转/缩放；窗口本身可被系统移动/摆放。
   - ImmersiveSpace：单手拖拽式空间输入可旋转；双手缩放式空间输入可缩放（交互映射见 Task 12）。
4. 验证命令全部通过：
   - `swift test`
   - `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=iOS" build`
   - `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "platform=macOS" build`
   - `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`

---

# Plan A（主方案）

## ✅P1：删除自动旋转（最高优先级）

### Task 1：定位并删掉自动旋转相关字段/函数（iOS/macOS 渲染器）

**Files:**
- Modify: `SampleApp/Scene/MetalKitSceneRenderer.swift`

**Steps:**
1. 删除 `rotation: Angle`、`lastRotationUpdateTimestamp`、`updateRotation()`，以及 `draw(in:)` 内对 `updateRotation()` 的调用。
2. 暂时保留 `viewMatrix` 中的旋转为 identity（下一批会接入交互状态）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "platform=macOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 2：定位并删掉自动旋转相关字段/函数（visionOS Immersive 渲染器）

**Files:**
- Modify: `SampleApp/Scene/VisionSceneRenderer.swift`

**Steps:**
1. 删除 `rotation: Angle`、`lastRotationUpdateTimestamp`、`updateRotation()`，以及 `renderFrame()` 内对 `updateRotation()` 的调用。
2. 暂时保留 `viewMatrix` 中旋转为 identity（下一批会接入交互状态）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 3：删除不再使用的旋转常量

**Files:**
- Modify: `SampleApp/App/Constants.swift`

**Steps:**
1. 删除与自动旋转强绑定的常量（例如 `rotationPerSecond`、`rotationAxis`），仅保留仍在使用的常量。
2. 若仍需要“初始朝向/校准”，用更明确的命名（例如 `commonUpCalibration` 继续放在各渲染器内）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=iOS" build`
- Expected: `BUILD SUCCEEDED`

---

## ✅P2：交互状态与 iOS/macOS 旋转 + 缩放

### Task 4：新增交互状态存储（可注入 + 线程安全）

**Files:**
- Create: `SampleApp/Model/ViewerInteractionStore.swift`

**Steps:**
1. 定义纯数据快照：
   - `struct ViewerInteractionSnapshot { var orientation: simd_quatf; var scale: Float }`
2. 定义 store（不使用单例）：
   - `final class ViewerInteractionStore`
   - `func snapshot() -> ViewerInteractionSnapshot`
   - `func reset()`
   - `func applyScale(factor: Float)`（内部 clamp，例如 `0.05...20`）
   - `func applyArcballDrag(from: CGPoint, to: CGPoint, in size: CGSize)`（自由旋转）
3. 线程安全策略：
   - 渲染线程高频读；手势线程写（iOS/macOS 主线程、visionOS `onSpatialEvent` 主线程）。
   - 用轻量锁保护快照读写（保证不会读到撕裂状态）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "platform=macOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 5：新增 arcball 数学（与 UI 解耦）

**Files:**
- Modify: `SampleApp/Model/ViewerInteractionStore.swift`

**Steps:**
1. 实现 2D 点到单位球向量映射（基于 view size，归一化到 [-1,1]）。
2. 计算两向量之间的四元数增量（防止数值问题：dot clamp 到 [-1,1]；零向量/NaN 直接忽略）。
3. 累计到 `orientation`（并对结果做 normalize）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=iOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 6：iOS/macOS 渲染器接入交互状态（替换旋转矩阵）

**Files:**
- Modify: `SampleApp/Scene/MetalKitSceneRenderer.swift`
- Modify: `SampleApp/Scene/MetalKitSceneView.swift`

**Steps:**
1. `MetalKitSceneRenderer` 增加依赖注入：初始化时接收 `ViewerInteractionStore`。
2. 每帧 `snapshot()`，拼接 `viewMatrix`：
   - `translationMatrix * rotationMatrix(from quaternion) * scaleMatrix * commonUpCalibration`
3. `MetalKitSceneView` 创建 renderer 时把 store 传进去（store 由更上层 View 注入）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "platform=macOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 7：新增 iOS/macOS 的交互 UI 包装层

**Files:**
- Create: `SampleApp/Scene/ModelViewerView.swift`
- Modify: `SampleApp/Scene/ContentView.swift`

**Steps:**
1. `ModelViewerView` 内部持有 `@StateObject`/`@State` 的 `ViewerInteractionStore`（但不做全局单例）。
2. 把 `MetalKitSceneView(modelIdentifier:)` 放在里面，并注入 store。
3. 在 `ModelViewerView` 外层挂 SwiftUI 手势：
   - `DragGesture`：把上一次点位缓存起来，持续调用 `applyArcballDrag(...)`
   - Magnification（pinch）：把手势值转换成 scale factor，调用 `applyScale(factor:)`
4. 增加 Reset（至少双击）：调用 `store.reset()`
5. `ContentView` 中 iOS push 的页面、macOS window 的页面统一使用 `ModelViewerView` 替换直接 `MetalKitSceneView`。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=iOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 8：macOS 补齐滚轮缩放（桌面 UX）

**Files:**
- Create: `SampleApp/Scene/ScrollWheelZoomOverlay.swift`（`NSViewRepresentable`）
- Modify: `SampleApp/Scene/ModelViewerView.swift`

**Steps:**
1. 用 `NSViewRepresentable` 创建透明 view 捕获 `scrollWheel(with:)`。
2. 将 `deltaY` 转换成 scale factor（例如 `exp(-deltaY * k)`），调用 `applyScale(factor:)`。
3. 仅在 `#if os(macOS)` 编译。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "platform=macOS" build`
- Expected: `BUILD SUCCEEDED`

---

## ❌P3：visionOS Volumetric Window（A 路线：Metal 渲染 + 旋转/缩放）

### Task 9：新增 Volumetric WindowGroup（仅 visionOS）

**Files:**
- Modify: `SampleApp/App/SampleApp.swift`

**Steps:**
1. 新增 `WindowGroup(for: ModelIdentifier.self, id: "volumetricViewer")`（仅 `#if os(visionOS)`）。
2. 设置 `.windowStyle(.volumetric)` 与合理 `.defaultSize(width:height:depth:in:)`。
3. window 内容用 `ModelViewerView`（复用 Task 7 的交互），并传入 `modelIdentifier.wrappedValue`。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 10：visionOS 文件导入后默认打开 volumetric viewer

**Files:**
- Modify: `SampleApp/Scene/ContentView.swift`

**Steps:**
1. visionOS 分支用 `@Environment(\\.openWindow)`，调用 `openWindow(id:"volumetricViewer", value: modelIdentifier)`。
2. 保留“进入沉浸空间”的按钮（用于 Task 13），两者都能打开同一个 `ModelIdentifier`。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`
- Expected: `BUILD SUCCEEDED`

---

## P4：visionOS ImmersiveSpace（A 路线：CompositorLayer + onSpatialEvent）

### Task 11：VisionSceneRenderer 接入 ViewerInteractionStore

**Files:**
- Modify: `SampleApp/Scene/VisionSceneRenderer.swift`

**Steps:**
1. 在 `VisionSceneRenderer` 内持有一个 `ViewerInteractionStore`（初始化时注入；不要用全局单例）。
2. `viewports(...)` 里使用 `snapshot()` 拼接 `viewMatrix`：
   - `userViewpointMatrix * translationMatrix * rotationMatrix(quat) * scaleMatrix * commonUpCalibration`

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`
- Expected: `BUILD SUCCEEDED`

### Task 12：用 `LayerRenderer.onSpatialEvent` 实现旋转/缩放输入映射

**Files:**
- Modify: `SampleApp/Scene/VisionSceneRenderer.swift`

**Steps:**
1. 在启动渲染 loop 前设置 `layerRenderer.onSpatialEvent = { @MainActor events in ... }`。
2. 事件处理规则（只做 Plan A 必需的“手势→参数”）：
   - 只处理 `phase == .active` 的事件；`.ended/.cancelled` 清理缓存。
   - 单指（collection 中 active event 计数 == 1）：用 `event.location`（2D）作为 arcball 拖拽点，驱动旋转。
   - 双指（active event 计数 == 2）：用两点距离比值 `dNew / dOld` 作为 scale factor，驱动缩放。
3. 维护 per-event 的上一次位置/距离（用 `event.id` 做 key）。
4. 所有写入都只更新 `ViewerInteractionStore`（渲染线程不直接读写事件状态）。

**Verify:**
- Run: `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`
- Expected: `BUILD SUCCEEDED`

---

# Plan B（后续阶段：真 3D Entity，可抓取模型本体）

> 目标：把用户导入的 splat（`.ply/.splat/.spz`）“模型本体”变成 RealityKit 世界中的可命中/可抓取对象，而不是通过 Metal 渲染结果进行交互代理。

## B1：Spike（技术验证，必须先做）

**Goal:**
- 在最小数据集上证明一条可行路径（性能/内存/交互命中三者至少满足一项可量化指标）。

**Candidate routes（候选路线，Spike 结束必须锁定其一）：**
1. **点精灵/广告牌实例化**：把 splat 转成大量 instance（billboard/point sprite），用 RealityKit/自定义材质渲染。
2. **分块实体 + 自定义渲染集成**：分块组织数据，结合 RealityKit 的渲染扩展点进行 GPU 驱动渲染。

**Acceptance:**
- demo 中能对“真实实体”直接旋转/缩放（`Entity.transform` / `Entity.scale`）。
- 给出性能数据（至少：最大可交互点数/帧率/内存占用）与风险列表。

## B2：工程化（在 B1 选型通过后）

- 文件加载与转换流水线（保持 `.ply/.splat/.spz` 支持）
- LOD/分块/剔除策略
- 交互命中（targeted entity / hit test）与 UI
- 端到端性能回归与 SampleApp 验证入口

