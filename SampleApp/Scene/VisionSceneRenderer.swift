#if os(visionOS)

import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

/// VisionSceneRenderer manages rendering for visionOS immersive spaces.
/// It's marked @unchecked Sendable because it manages thread safety manually:
/// - LayerRenderer access is confined to the render thread
/// - Model loading uses async/await
/// - State changes are synchronized through the RendererTaskExecutor
final class VisionSceneRenderer: @unchecked Sendable {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "VisionSceneRenderer")

    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var model: ModelIdentifier?
    private var modelRenderer: (any ModelRenderer)?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider

    private let fixedPlacementDistanceMeters: Float = 1.5

    private var modelWorldAnchorID: UUID?
    private var modelOriginFromAnchorTransform: simd_float4x4?
    private var modelCalibrationTransform = matrix_identity_float4x4
    private var preferOriginAtUserViewpoint = false
    private var axisGizmoRenderer: AxisGizmoRenderer?

    private var anchorUpdatesTask: Task<Void, Never>?
    private var anchorPlacementTask: Task<Void, Never>?

    private var lastDeviceOriginFromAnchorTransform = matrix_identity_float4x4

#if targetEnvironment(simulator)
    private let supportsWorldAnchors = false
#else
    private let supportsWorldAnchors = true
#endif

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }

    deinit {
        anchorUpdatesTask?.cancel()
        anchorPlacementTask?.cancel()
    }

    /// Static entry point for starting the renderer.
    static func startRendering(_ layerRenderer: LayerRenderer, model: ModelIdentifier?) {
        let renderer = VisionSceneRenderer(layerRenderer)
        Task {
            do {
                try await renderer.load(model)
            } catch {
                log.error("Error loading model: \(error.localizedDescription)")
            }
            renderer.startRenderLoop()
        }
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        resetWorldAnchorPlacement()

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            do {
                let metadata = try SplatPLYMetadata.read(from: url)
                preferOriginAtUserViewpoint = (metadata.forwardAxisHint == .positiveZ)
                modelCalibrationTransform =
                    metadata.forwardAxisHint == .positiveZ
                    ? matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(1, 0, 0)) // OpenCV(+Z forward, +Y down) -> renderer(-Z forward, +Y up)
                    : matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1)) // legacy default
                Self.log.info("PLY forward axis hint: \(String(describing: metadata.forwardAxisHint)), meanZ(sample): \(metadata.sampledMeanZ ?? .nan)")
            } catch {
                preferOriginAtUserViewpoint = false
                modelCalibrationTransform = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
                Self.log.warning("Unable to read PLY metadata; using legacy calibration. Error: \(error.localizedDescription)")
            }

            let splat = try SplatRenderer(device: device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          sampleCount: 1,
                                          maxViewCount: layerRenderer.properties.viewCount,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            modelRenderer = splat
        case .sampleBox:
            modelRenderer = try SampleBoxRenderer(device: device,
                                                  colorFormat: layerRenderer.configuration.colorFormat,
                                                  depthFormat: layerRenderer.configuration.depthFormat,
                                                  sampleCount: 1,
                                                  maxViewCount: layerRenderer.properties.viewCount,
                                                  maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }

        if axisGizmoRenderer == nil {
            do {
                axisGizmoRenderer = try AxisGizmoRenderer(device: device,
                                                          colorFormat: layerRenderer.configuration.colorFormat,
                                                          depthFormat: layerRenderer.configuration.depthFormat,
                                                          sampleCount: 1,
                                                          maxViewCount: layerRenderer.configuration.layout == .layered ? layerRenderer.properties.viewCount : 1)
            } catch {
                Self.log.error("Unable to create AxisGizmoRenderer: \(error.localizedDescription)")
                axisGizmoRenderer = nil
            }
        }
    }

    func startRenderLoop() {
        Task(executorPreference: RendererTaskExecutor.shared) {
            do {
                try await self.arSession.run([self.worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }

            await self.renderLoop()
        }
    }

    private func viewports(drawable: LayerRenderer.Drawable, deviceOriginFromAnchorTransform: simd_float4x4) -> [ModelRendererViewportDescriptor] {
        let defaultPlacementMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        let calibrationMatrix = modelCalibrationTransform

        return drawable.views.enumerated().map { (index, view) in
            let originFromView = deviceOriginFromAnchorTransform * view.transform
            let userViewpointMatrix = originFromView.inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: index)
            let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                   y: Int(view.textureMap.viewport.height))
            let placementMatrix: simd_float4x4
            if let modelOriginFromAnchorTransform {
                placementMatrix = modelOriginFromAnchorTransform
            } else {
                // Fallback path (including Simulator, where WorldAnchor isn't supported):
                // keep the model stable relative to the viewer until we can world-lock it.
                placementMatrix =
                    preferOriginAtUserViewpoint
                    ? originFromView
                    : (originFromView * matrix4x4_translation(0, 0, -fixedPlacementDistanceMeters))
            }
            return ModelRendererViewportDescriptor(viewport: view.textureMap.viewport,
                                                   projectionMatrix: projectionMatrix,
                                                   viewMatrix: userViewpointMatrix * placementMatrix * calibrationMatrix,
                                                   screenSize: screenSize)
        }
    }

    private func encodeClear(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer) {
        let passDescriptor = MTLRenderPassDescriptor()

        guard let colorAttachment = passDescriptor.colorAttachments[0] else {
            Self.log.error("Missing render pass color attachment 0")
            return
        }
        colorAttachment.texture = drawable.colorTextures[0]
        colorAttachment.loadAction = .clear
        colorAttachment.storeAction = .store
        colorAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let depthTexture = drawable.depthTextures.first {
            passDescriptor.depthAttachment.texture = depthTexture
            passDescriptor.depthAttachment.loadAction = .clear
            passDescriptor.depthAttachment.storeAction = .dontCare
            passDescriptor.depthAttachment.clearDepth = 1.0
        }

        if let rasterizationRateMap = drawable.rasterizationRateMaps.first {
            passDescriptor.rasterizationRateMap = rasterizationRateMap
        }

        passDescriptor.renderTargetArrayLength =
            layerRenderer.configuration.layout == .layered ? drawable.views.count : 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            Self.log.error("Failed to create clear render command encoder")
            return
        }
        encoder.endEncoding()
    }

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()

        // Use first drawable for timing/anchor calculations
        let primaryDrawable = drawables[0]
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: primaryDrawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        if let deviceAnchor {
            lastDeviceOriginFromAnchorTransform = deviceAnchor.originFromAnchorTransform
            let primaryViewTransform = primaryDrawable.views.first?.transform ?? matrix_identity_float4x4
            ensureModelWorldAnchorPlacedIfNeeded(deviceAnchor: deviceAnchor, viewTransform: primaryViewTransform)
        }

        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError("Failed to create command buffer")
            }

            drawable.deviceAnchor = deviceAnchor

            // Signal semaphore when the last drawable's command buffer completes
            if index == drawables.count - 1 {
                let semaphore = inFlightSemaphore
                commandBuffer.addCompletedHandler { _ in
                    semaphore.signal()
                }
            }

            let viewports = self.viewports(drawable: drawable,
                                           deviceOriginFromAnchorTransform: lastDeviceOriginFromAnchorTransform)

            let didRender: Bool
            do {
                didRender = try modelRenderer?.render(viewports: viewports,
                                                      colorTexture: drawable.colorTextures[0],
                                                      colorStoreAction: .store,
                                                      depthTexture: drawable.depthTextures[0],
                                                      rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                                      renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                                                      to: commandBuffer) ?? false
            } catch {
                Self.log.error("Unable to render scene: \(error.localizedDescription)")
                didRender = false
            }

            // CompositorServices requires presenting each drawable before ending submission.
            // If we didn't render anything (e.g. model failed to load), clear and still present.
            if !didRender {
                encodeClear(drawable: drawable, commandBuffer: commandBuffer)
            }

            axisGizmoRenderer?.encode(viewports: viewports,
                                      colorTexture: drawable.colorTextures[0],
                                      depthTexture: drawable.depthTextures.first,
                                      rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                      renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                                      to: commandBuffer)
            drawable.encodePresent(commandBuffer: commandBuffer)

            commandBuffer.commit()
        }

        frame.endSubmission()
    }

    func renderLoop() async {
        while !Task.isCancelled {
            autoreleasepool {
                if layerRenderer.state == .invalidated {
                    Self.log.warning("Layer is invalidated")
                    return
                } else if layerRenderer.state == .paused {
                    layerRenderer.waitUntilRunning()
                    return
                } else {
                    self.renderFrame()
                }
            }
            if layerRenderer.state == .invalidated {
                return
            }

            await Task.yield()
        }
    }

    private func resetWorldAnchorPlacement() {
        modelWorldAnchorID = nil
        modelOriginFromAnchorTransform = nil

        anchorUpdatesTask?.cancel()
        anchorUpdatesTask = nil

        anchorPlacementTask?.cancel()
        anchorPlacementTask = nil
    }

    private func ensureModelWorldAnchorPlacedIfNeeded(deviceAnchor: DeviceAnchor, viewTransform: simd_float4x4) {
        guard supportsWorldAnchors else { return }
        guard modelOriginFromAnchorTransform == nil else { return }
        guard modelRenderer != nil else { return }
        guard anchorPlacementTask == nil else { return }
        guard modelWorldAnchorID == nil else { return }

        let originFromView = deviceAnchor.originFromAnchorTransform * viewTransform
        let originFromModel =
            preferOriginAtUserViewpoint
            ? originFromView
            : (originFromView * matrix4x4_translation(0, 0, -fixedPlacementDistanceMeters))

        anchorPlacementTask = Task(executorPreference: RendererTaskExecutor.shared) { [weak self] in
            guard let self else { return }
            defer { anchorPlacementTask = nil }
            do {
                let anchor = WorldAnchor(originFromAnchorTransform: originFromModel)
                modelWorldAnchorID = anchor.id
                try await worldTracking.addAnchor(anchor)
                modelOriginFromAnchorTransform = originFromModel
                startListeningForAnchorUpdates(anchorID: anchor.id)
                let placementDescription =
                    preferOriginAtUserViewpoint
                    ? "at user viewpoint (dataset camera origin)"
                    : "\(fixedPlacementDistanceMeters)m in front of the user"
                Self.log.info("Placed WorldAnchor for model \(placementDescription) (id: \(anchor.id))")
            } catch {
                Self.log.error("Failed to add WorldAnchor; falling back to fixed transform. Error: \(error.localizedDescription)")
            }
        }
    }

    private func startListeningForAnchorUpdates(anchorID: UUID) {
        guard anchorUpdatesTask == nil else { return }

        anchorUpdatesTask = Task(executorPreference: RendererTaskExecutor.shared) { [weak self] in
            guard let self else { return }
            defer { anchorUpdatesTask = nil }
            do {
                for await update in worldTracking.anchorUpdates {
                    if Task.isCancelled { break }
                    guard update.anchor.id == anchorID else { continue }
                    switch update.event {
                    case .added, .updated:
                        modelOriginFromAnchorTransform = update.anchor.originFromAnchorTransform
                    case .removed:
                        Self.log.warning("WorldAnchor was removed (id: \(anchorID))")
                        modelWorldAnchorID = nil
                        modelOriginFromAnchorTransform = nil
                    @unknown default:
                        break
                    }
                }
            }
        }
    }
}

final class RendererTaskExecutor: TaskExecutor {
    static let shared = RendererTaskExecutor()
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

#endif // os(visionOS)
