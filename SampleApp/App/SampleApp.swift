#if os(visionOS)
import CompositorServices
#endif
import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup("MetalSplatter Sample App", id: "main") {
            ContentView()
        }

#if os(macOS)
        WindowGroup(for: ModelIdentifier.self) { modelIdentifier in
            ModelViewerView(modelIdentifier: modelIdentifier.wrappedValue)
        }
#endif // os(macOS)

#if os(visionOS)
        WindowGroup(id: "volumetricViewer", for: ModelIdentifier.self) { modelIdentifier in
            ModelViewerView(modelIdentifier: modelIdentifier.wrappedValue)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.8, height: 0.6, depth: 0.6, in: .meters)

        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let modelToLoad = modelIdentifier.wrappedValue
                VisionSceneRenderer.startRendering(layerRenderer, model: modelToLoad)
            }
        }
        .immersionStyle(selection: .constant(immersionStyle), in: immersionStyle)
#endif // os(visionOS)
    }

#if os(visionOS)
    var immersionStyle: ImmersionStyle {
        if #available(visionOS 2, *) {
            .mixed
        } else {
            .full
        }
    }
#endif // os(visionOS)
}
