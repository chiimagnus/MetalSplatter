# SampleApp 上架 TestFlight 实施计划

> 执行方式：建议使用 `executing-plans` 按批次实现与验收。

**Goal（目标）:** 让 `SampleApp/MetalSplatter_SampleApp.xcodeproj` 能稳定 Archive 并可上传到 TestFlight（iOS / visionOS），补齐提交所需的工程设置与必备文件（App Icon、Privacy Manifest、Info.plist 关键项）。

**Non-goals（非目标）:** 不包含 App Store Connect 上的元数据填写（截图、分级、价格、隐私问卷等），也不包含自动化 CI/CD 上架流程。

**Approach（方案）:**  
1) 先把 Xcode 工程里的基础发布配置补齐（Bundle ID、版本号、Info.plist 关键项、平台 SDK/Deployment Target）。  
2) 补齐 Apple 当前提交流程中常见的必需文件（App Icon、`PrivacyInfo.xcprivacy`）。  
3) 用 `xcodebuild` 在本地做 iOS 与 visionOS 的编译/Archive 验证。

**Acceptance（验收）:**  
- `xcodebuild ... -destination "generic/platform=iOS" archive` 成功产出 `.xcarchive`  
- `xcodebuild ... -destination "generic/platform=visionOS" archive` 成功产出 `.xcarchive`  
- App Icon 资源存在且构建不报 “Missing required icon”  
- 包内包含 `PrivacyInfo.xcprivacy`

---

## Plan A（主方案）

### P1：补齐发布必需配置（工程 + Info.plist）

#### Task 1: 修正工程的发布基础设置（SDK/平台/版本/加密声明）

**Files:**
- Modify: `SampleApp/MetalSplatter_SampleApp.xcodeproj/project.pbxproj`

**Steps:**
1) 设置 `SDKROOT = auto`，避免多平台构建被锁死在 `iphoneos`。  
2) 将 `IPHONEOS_DEPLOYMENT_TARGET` 与 `XROS_DEPLOYMENT_TARGET` 调整为合理版本（避免异常的 `26.0`）。  
3) 增加 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`（App Store Connect 常见导出合规项）。  
4) 设置 `ASSETCATALOG_COMPILER_APPICON_NAME`（按 SDK 分平台指向 iOS/visionOS 的 icon 资源）。

**Verify:**
- iOS build:  
  `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=iOS" build`
- visionOS build:  
  `xcodebuild -project SampleApp/MetalSplatter_SampleApp.xcodeproj -scheme "MetalSplatter SampleApp" -configuration Release -destination "generic/platform=visionOS" build`

#### Task 2: 把 `Assets.xcassets` 归类到 Resources（避免构建相位异常）

**Files:**
- Modify: `SampleApp/MetalSplatter_SampleApp.xcodeproj/project.pbxproj`

**Steps:**
1) 将 `Assets.xcassets` 从 “Compile Sources” 移到 “Copy Bundle Resources”。  

**Verify:**
- `xcodebuild ... build` 不再对资源相位报错/警告（以实际输出为准）

### P2：补齐提交必需文件（图标 + 隐私清单）

#### Task 3: 添加 iOS App Icon（`AppIcon.appiconset`）

**Files:**
- Create: `SampleApp/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `SampleApp/Assets.xcassets/AppIcon.appiconset/*.png`

**Verify:**
- iOS build/Archive 时不报 “AppIcon” 缺失相关错误

#### Task 4: 添加 visionOS App Icon（`AppIconVision.solidimagestack`）

**Files:**
- Create: `SampleApp/Assets.xcassets/AppIconVision.solidimagestack/**`

**Verify:**
- visionOS build/Archive 时不报 icon 缺失相关错误

#### Task 5: 添加 Privacy Manifest（`PrivacyInfo.xcprivacy`）并打包进 app

**Files:**
- Create: `SampleApp/PrivacyInfo.xcprivacy`
- Modify: `SampleApp/MetalSplatter_SampleApp.xcodeproj/project.pbxproj`

**Verify:**
- 产物包内存在 `PrivacyInfo.xcprivacy`（可用 `xcodebuild archive` 后检查 `.app` 包内容）

### P3：可选清理/检查点

#### Task 6（可选）: 添加/引用 Entitlements 文件（仅当你需要启用特定能力时）

**Files:**
- Create: `SampleApp/MetalSplatterSampleApp.entitlements`
- Modify: `SampleApp/MetalSplatter_SampleApp.xcodeproj/project.pbxproj`

**Verify:**
- iOS/visionOS build 通过

