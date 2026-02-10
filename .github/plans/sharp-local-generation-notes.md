# SHARP（CoreML）本地生成 PLY：排查记录与开发教训

更新时间：2026-02-10  
范围：`SampleApp` 的 “Image → 3D Scene（SHARP）→ 导出/渲染 PLY” 流程（iOS / macOS / visionOS）

## 背景与目标

- 目标功能：用户选择一张图片 → 使用 SHARP CoreML 在本地推理 → 生成 3D Gaussian Splats 的 `.ply` → 支持保存与在 SampleApp 内渲染查看。
- 目标平台：主要面向 visionOS / iOS，同时 macOS 作为生成与调试的主环境。

## 现状结论（最重要）

1) **iPhone 13（4GB RAM）无法稳定本地跑通 SHARP 推理生成 PLY**
- 在 `CPU+GPU` 路径上直接触发 iOS 进程内存上限被系统杀：`EXC_RESOURCE (RESOURCE_TYPE_MEMORY: high watermark ... limit≈2098MB)`。
- 在 `CPU-only` 路径上，CoreML 构建执行计划阶段出现 BNNS/MIL 编译失败与巨额内存分配失败（~1.2GB 一次性申请）等问题。
- `maxOutputPoints` / “降低输出点数”只影响 **写 PLY/渲染**，对 **CoreML 推理阶段峰值**帮助有限，因此不能作为“低内存设备可跑”的根本解法。

2) **visionOS Simulator 不支持/不稳定**
- 观测到 Espresso / MPSGraph backend 的兼容性错误与内存爆炸；**即使强制 `cpuOnly` 也可能无法加载/执行**。
- 结论：**不要把 visionOS Simulator 当作 CoreML 推理可用环境**。推荐将其定位为：
  - UI / 交互 / 渲染（打开 PLY、相机控制、手势、性能）验证；
  - 推理仅在真机或 macOS/云端完成。
- 在 App 体验上应当 **显式禁用** 并提示“请真机运行/使用 macOS 生成 PLY”。

3) **macOS 可作为可用闭环**
- macOS 上模型可加载、推理并生成大 PLY；iOS 端建议先以“导入 PLY → 渲染查看”为主路径。

## 已观测到的典型错误（用于回归对照）

- BNNS / MLProgram 推理失败（iOS，`CPU+NE` 或 `CPU` 等路径可能出现）  
  - 关键字：`Error(s) occurred executing a BNNS Op`  
  - 现象：`Unable to compute the prediction using ML Program...`

- MIL → BNNS 编译失败 + 内存分配失败（iOS，`CPU-only`）  
  - 关键字：`Error(s) occurred compiling MIL to BNNS graph`  
  - 现象：`Memory allocation error ... 1207959552 bytes`

- iOS 进程被系统杀（iOS，`CPU+GPU`）  
  - 关键字：`EXC_RESOURCE ... high watermark memory limit exceeded (limit≈2098 MB)`

## 关键经验与教训

### 1) “能编译/能跑 Simulator” ≠ “能跑真机”
- CoreML 后端、内存上限、Metal/BNNS/MPSGraph 支持情况在真机与 Simulator 差异很大。
- 对 App Store 上线场景：必须把“真机低端/中端设备”作为第一优先级验证对象。

### 1.1) visionOS Simulator 的特殊教训：推理不可依赖
- Simulator 不等同于真机硬件能力集合（尤其是 Neural Engine / GPU 路径）。
- 常见症状：
  - `MpsGraph backend validation on incompatible OS`
  - `Espresso compiled without MPSGraph engine`
  - 模型加载/推理阶段内存暴涨（甚至远超真机表现）
- 正确策略：
  - 在 Simulator 里提供“生成按钮”的 UI，但实际走 mock / 预生成 PLY（或直接禁用推理入口）；
  - 把“本地生成”的验证放到真机（Vision Pro / 高内存 iPhone）或 macOS 环境。

### 2) 低内存设备的正确策略：**能力探测 + 体验降级 + 兜底路径**
- 不能让用户点击一次就被系统杀进程（会被认为是严重稳定性问题）。
- 推荐做法：
  - 基于物理内存（例如 `< 8GB`）默认禁用本地生成；
  - 明确提示替代路径：在 macOS/云端生成 PLY，然后 iOS/visionOS 仅导入渲染；
  - Debug 下可以提供 “Force enable” 仅用于开发验证，但 Release 必须保证稳定。

### 3) “降低输出点数”并不能解决推理峰值
- 推理阶段的峰值来自模型构建执行计划、权重/中间张量、后端编译缓存等。
- 输出抽样（`maxOutputPoints`）主要用于：
  - 减少 PLY 写入时间与内存抖动；
  - 减少渲染压力；
  - **不能**作为“让模型在 4GB 设备跑起来”的手段。

### 4) 大文件/大数据写入要避免隐式复制
- 生成大 PLY 时，任何“按块写但内部复制数组”的实现都可能导致内存飙升。
- 对策：
  - 写入 API 必须做到真正的 streaming（避免 `Array(...)` 拷贝、避免 `dropFirst` 产生新数组）；
  - 热路径避免频繁小对象分配（例如每次数值读取创建 `[Int]` 索引数组）。

### 5) 需要把“可观测性”作为第一等公民
- `os.Logger` 记录：模型加载、推理开始/结束、输出点数、写入路径、关键阶段内存（resident/virtual）。
- Debug 下可以采样 `during_prediction` 的内存，快速判断峰值发生在哪一步。

## 对产品方向的建议（待决）

### 方案 A：云端 API 生成（iPhone 也能用）
适用：目标是让 iPhone 13 这类设备也拥有“照片→PLY”能力。

需要提前明确的约束：
- 隐私与合规：用户图片上传、存储策略、保留时长、删除策略、日志脱敏。
- 成本：推理 GPU/CPU 成本、带宽成本；是否需要登录与配额。
- 体验：上传进度、失败重试、后台任务、弱网降级。
- 输出：返回 `.ply` 或 `.spz`；是否返回预览缩略图；是否可断点续传。

建议的 MVP 流程：
1. iOS/visionOS：选择照片 → 上传 → 等待任务完成 → 下载 `.ply` → 自动打开渲染  
2. macOS：保留本地生成能力（开发/高级用户/离线模式）

### 方案 B：本地仅支持高内存设备（iOS/visionOS ≥ 8GB）
适用：完全离线、无云成本，但会明显限制可用机型范围。

实现重点：
- 在 UI 上明确告知设备要求；
- 对不支持设备提供“导入 PLY 渲染”路径，保证功能闭环。

## 下一步行动清单（建议）

- [ ] 明确是否引入云端 API（以及是否允许 macOS 做局域网代理推理作为“非云”中间态）。
- [ ] 在 Release 下对 iOS/visionOS < 8GB 设备默认禁用本地生成（仅保留导入渲染）。
- [ ] 在文档中写清“推荐流程”：macOS 生成 → AirDrop / Files 导入 → iOS 渲染。
- [ ] 若要推进云端：先定输出格式（PLY/SPZ）、接口契约、隐私/数据保留策略，再实现客户端。
