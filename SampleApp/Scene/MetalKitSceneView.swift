#if os(iOS) || os(macOS) || os(visionOS)

import SwiftUI
import MetalKit

#if os(macOS)
import AppKit
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS) || os(visionOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif

struct MetalKitSceneView: ViewRepresentable {
    var modelIdentifier: ModelIdentifier?
    var interactionStore: ViewerInteractionStore? = nil

#if os(macOS)
    private final class InteractionMTKView: MTKView {
        var onScrollWheel: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onScrollWheel?(event.scrollingDeltaY)
            super.scrollWheel(with: event)
        }
    }
#endif

    class Coordinator {
        var renderer: MetalKitSceneRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

#if os(macOS)
    func makeNSView(context: NSViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#elseif os(iOS) || os(visionOS)
    func makeUIView(context: UIViewRepresentableContext<MetalKitSceneView>) -> MTKView {
        makeView(context.coordinator)
    }
#endif

    private func makeView(_ coordinator: Coordinator) -> MTKView {
        let metalKitView: MTKView
#if os(macOS)
        let view = InteractionMTKView()
        view.onScrollWheel = { deltaY in
            guard let interactionStore else { return }
            let factor = exp(-Float(deltaY) * 0.01)
            interactionStore.applyScale(factor: factor)
        }
        metalKitView = view
#else
        metalKitView = MTKView()
#endif

        if let metalDevice = MTLCreateSystemDefaultDevice() {
            metalKitView.device = metalDevice
        }

        let renderer = MetalKitSceneRenderer(metalKitView, interactionStore: interactionStore)
        coordinator.renderer = renderer
        metalKitView.delegate = renderer

        Task {
            do {
                try await renderer?.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }

        return metalKitView
    }

#if os(macOS)
    func updateNSView(_ view: MTKView, context: NSViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#elseif os(iOS) || os(visionOS)
    func updateUIView(_ view: MTKView, context: UIViewRepresentableContext<MetalKitSceneView>) {
        updateView(context.coordinator)
    }
#endif

    private func updateView(_ coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        Task {
            do {
                try await renderer.load(modelIdentifier)
            } catch {
                print("Error loading model: \(error.localizedDescription)")
            }
        }
    }
}

#endif // os(iOS) || os(macOS) || os(visionOS)
