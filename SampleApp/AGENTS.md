# 仓库指南

本目录 `SampleApp/` 是 MetalSplatter 的示例 App（Xcode 工程），用于演示在 iOS、macOS、visionOS 上加载并渲染 splat 场景文件，并 作为 端到端 验证入口。

## 项目结构与模块组织

- `App/`：应用入口与常量（如 `SampleApp.swift`、`Constants.swift`）。
- `Scene/`：SwiftUI 界面与渲染承载层（如 `ContentView.swift`、`MetalKitSceneView.swift`、`VisionSceneRenderer.swift`）。
- `Model/`：模型与渲染器适配（如 `ModelRenderer.swift`、`SplatRenderer+ModelRenderer.swift`）。
- `Util/`：数学与工具（如 `MatrixMathUtil.swift`）。
- `Assets.xcassets/`、`Info.plist`：资源与应用配置；macOS 额外使用 `MetalSplatterSampleApp-macOS.entitlements`。
- 工程文件：`MetalSplatter_SampleApp.xcodeproj`（同目录还有 `SampleApp.xcodeproj` 软链接）。

## 构建、运行与开发命令

建议直接用 Xcode 打开 `MetalSplatter_SampleApp.xcodeproj` 运行；若使用命令行：

```sh
xcodebuild -list -project SampleApp/MetalSplatter_SampleApp.xcodeproj
xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release build
```

常用 schemes（以 `xcodebuild -list` 输出为准）：`MetalSplatter SampleApp`、`MetalSplatter`、`PLYIO`、`SplatIO`、`SplatConverter`、`SampleBoxRenderer`。

## 运行与签名要点

- iOS / visionOS：在 Xcode 的 Signing & Capabilities 设置 Team 与 Bundle ID（否则无法安装到真机/头显）。
- macOS：如需额外权限，检查 `MetalSplatterSampleApp-macOS.entitlements` 是否与 Capabilities 一致。
- 配置变更：若你修改了 `Info.plist` 或 `Assets.xcassets`，请同步验证三端（iOS、macOS、visionOS）启动是否正常。

提示：README 提到 Debug 加载大文件会显著变慢，优先用 Release；需要更接近真实帧率时，尽量不要附加调试器运行。

## 平台入口与关键代码位置

- App 入口：`App/SampleApp.swift`
  - macOS：`WindowGroup(for: ModelIdentifier.self)` 打开单独窗口渲染。
  - iOS：在 `ContentView` 内用 `NavigationStack` push 到 `MetalKitSceneView`。
  - visionOS：`ImmersiveSpace(for: ModelIdentifier.self)` + `CompositorLayer(configuration:)`，渲染入口是 `VisionSceneRenderer.startRendering(...)`。
- 文件导入：`Scene/ContentView.swift` 使用 `fileImporter`，当前允许扩展名：`ply` / `splat` / `spz`。
- 文件权限：导入后会调用 `startAccessingSecurityScopedResource()`，并在后台任务里延时释放；修改该逻辑时请确保不会泄漏访问权限或过早释放导致读取失败。
- 模型标识：`Model/ModelIdentifier.swift`（`gaussianSplat(URL)` 与 `sampleBox`）。

## 代码风格与命名规范

- 本目录没有独立的 lint/format 配置；修改时保持现有文件的排版与命名风格一致。
- 只在必要时调整工程设置（如签名、Capabilities、资源引用），避免“顺手重排”导致难以 review 的 diff。

## 验证清单

- 包层单测：在仓库根目录运行 `swift test`（验证 PLYIO/SplatIO/MetalSplatter 等包目标）。
- 示例 App：至少验证一次加载与渲染路径（打开 App → 选择/加载 文件 → 渲染画面 与 交互）并记录平台与配置（Debug/Release）。
- 命令行工具：可用 `swift run SplatConverter --help` 确认依赖解析与构建环境正常。

## 提交与 Pull Request 规范

- 若变更涉及签名/entitlements/Info.plist/Assets，请在 PR 中说明变更原因与验证方式（平台 + 配置 + 截图/录屏）。
