# 仓库指南

本仓库是 Swift Package（`swift-tools-version: 6.1`，`swiftLanguageModes: [.v6]`），用于在 Apple 平台上用 Metal 渲染 3D Gaussian Splats。最低平台由 `Package.swift` 定义：iOS 18、macOS 15、visionOS 2。

## 项目结构与模块组织

- `MetalSplatter/`：核心渲染库（含 `.metal` 着色器与资源）。
- `PLYIO/`：PLY 读写（独立可复用）。
- `SplatIO/`：基于 PLYIO 的 splat/ply/spz 解析与写入。
- `SplatConverter/`：命令行转换工具（SwiftPM 可执行产物）。
- `SampleApp/`：Xcode 示例工程（`SampleApp/MetalSplatter_SampleApp.xcodeproj`）。
- `SampleBoxRenderer/`：用于集成调试的替代渲染器。

## 构建、测试与开发命令

```sh
swift build
swift test
swift run SplatConverter --help
```

示例工程（查看 schemes/targets）：

```sh
xcodebuild -list -project SampleApp/MetalSplatter_SampleApp.xcodeproj
```

提示：示例 App 读取大文件时优先用 Release 配置（README 已提示 Debug 会显著变慢）。

## 本地开发建议

- Xcode 使用：可直接 打开 `Package.swift`（编辑/调试 SwiftPM 包），或 打开 `SampleApp/MetalSplatter_SampleApp.xcodeproj`（运行 示例 App）。
- 代码签名：若 运行 iOS / visionOS 目标，需 在 Signing & Capabilities 设置 Team 与 Bundle ID。
- 性能验证：大文件 加载/渲染 建议 用 Release；若 需要 真实帧率，尽量 不附加 调试器 运行。
- 变更 回归：优先 跑 `swift test`，再 用 SampleApp 做 手动 验证（加载/交互/渲染）。
- CLI 示例（以 `--help` 为准）：
  - `swift run SplatConverter <input-file> --describe --count 10`
  - `swift run SplatConverter <input-file> -f spz -o out.spz`

## 代码风格与命名规范

- 仓库未内置 SwiftLint / swift-format 配置；请保持既有文件的排版与命名风格一致。
- 修改 `Package.swift` 以可复现构建为准，避免“顺手重排”或引入隐式依赖。
- 新增非 Swift 源文件（如测试数据/资源/`.metal`）时，必要时在 target 的 `resources` 或 `exclude` 中显式声明。

## 测试指南

- 测试通过 SwiftPM 运行，目标命名为 `*Tests`，部分测试会使用 `TestData` 资源。
- 建议在提交前至少运行 `swift test`；必要时用 `swift test --filter <TestCase>/<testName>` 定位单测。

## 提交与 Pull Request 规范

- 变更应聚焦单一目的，PR 描述包含：动机、影响范围、验证方式（命令/截图/录屏）。
- 如涉及示例工程（`SampleApp/`），请在 PR 中注明验证的平台与配置（Debug/Release）。
