#if os(iOS) || os(macOS) || os(visionOS)

import SwiftUI

struct ModelViewerView: View {
    let modelIdentifier: ModelIdentifier?

    @State private var interactionStore = ViewerInteractionStore()
    @State private var lastDragLocation: CGPoint?
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            MetalKitSceneView(modelIdentifier: modelIdentifier, interactionStore: interactionStore)
                .contentShape(Rectangle())
                .gesture(dragGesture(in: proxy.size))
                .simultaneousGesture(magnificationGesture)
                .onTapGesture(count: 2) {
                    interactionStore.reset()
                }
                .onChange(of: modelIdentifier) { _, _ in
                    interactionStore.reset()
                }
        }
        .navigationTitle(modelIdentifier?.description ?? "No Model")
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = value.location
                if let lastDragLocation {
                    interactionStore.applyArcballDrag(from: lastDragLocation, to: current, in: size)
                }
                lastDragLocation = current
            }
            .onEnded { _ in
                lastDragLocation = nil
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastMagnification
                lastMagnification = value
                interactionStore.applyScale(factor: Float(delta))
            }
            .onEnded { _ in
                lastMagnification = 1
            }
    }
}

#endif // os(iOS) || os(macOS) || os(visionOS)
