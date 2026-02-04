import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isPickingFile = false

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    @State var immersiveSpaceIsShown = false
    @State private var selectedModelForImmersive: ModelIdentifier? = nil

    private func openVolumetricWindow(value: ModelIdentifier) {
        selectedModelForImmersive = value
        openWindow(id: "volumetricViewer", value: value)
    }

    private func openImmersiveIfPossible() {
        guard let selectedModelForImmersive else { return }
        Task {
            switch await openImmersiveSpace(value: selectedModelForImmersive) {
            case .opened:
                immersiveSpaceIsShown = true
            case .error, .userCancelled:
                break
            @unknown default:
                break
            }
        }
    }
#endif

    var body: some View {
#if os(macOS) || os(visionOS)
        mainView
#elseif os(iOS)
                NavigationStack(path: $navigationPath) {
                    mainView
                        .navigationDestination(for: ModelIdentifier.self) { modelIdentifier in
                    ModelViewerView(modelIdentifier: modelIdentifier)
                        }
                }
#endif // os(iOS)
    }

    @ViewBuilder
    var mainView: some View {
        VStack {
            Spacer()

            Text("MetalSplatter SampleApp")

            Spacer()

            Button("Read Scene File") {
                isPickingFile = true
            }
            .padding()
            .buttonStyle(.borderedProminent)
            .disabled(isPickingFile)
            .fileImporter(isPresented: $isPickingFile,
                          allowedContentTypes: [
                            UTType(filenameExtension: "ply")!,
                            UTType(filenameExtension: "splat")!,
                            UTType(filenameExtension: "spz")!,
                          ]) {
                isPickingFile = false
                switch $0 {
                case .success(let url):
                    _ = url.startAccessingSecurityScopedResource()
                    Task {
                        // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                        try await Task.sleep(for: .seconds(10))
                        url.stopAccessingSecurityScopedResource()
                    }
                    #if os(visionOS)
                    openVolumetricWindow(value: ModelIdentifier.gaussianSplat(url))
                    #else
                    openWindow(value: ModelIdentifier.gaussianSplat(url))
                    #endif
                case .failure:
                    break
                }
            }

            Spacer()

            Button("Show Sample Box") {
                #if os(visionOS)
                openVolumetricWindow(value: ModelIdentifier.sampleBox)
                #else
                openWindow(value: ModelIdentifier.sampleBox)
                #endif
            }
            .padding()
            .buttonStyle(.borderedProminent)

            Spacer()

#if os(visionOS)
            Button("Enter Immersive Space") {
                openImmersiveIfPossible()
            }
            .disabled(immersiveSpaceIsShown || selectedModelForImmersive == nil)

            Spacer()

            Button("Dismiss Immersive Space") {
                Task {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                }
            }
            .disabled(!immersiveSpaceIsShown)

            Spacer()
#endif // os(visionOS)
        }
    }
}
