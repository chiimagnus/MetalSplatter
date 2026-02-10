#if os(iOS) || os(macOS) || os(visionOS)

#if os(macOS)
import AppKit
#endif
import PhotosUI
import SwiftUI
import ImageIO

struct ImageTo3DSceneView: View {
    let openModel: @MainActor (ModelIdentifier) -> Void

    @State private var processLocally = true
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var isDownloadingModel = false
    @State private var modelDownloadProgress: Double = 0
    @State private var hasLocalModel = false

    @State private var isGenerating = false
    @State private var generationProgress: Double = 0

    @State private var generatedPLYURL: URL?
    @State private var generatedPointCount: Int?
    @State private var exportPLYURL: URL?
    @State private var isExportingPLY = false

    @State private var errorMessage: String?

    private let generator = SharpLocalSplatGenerator()

    private var isInferenceSupported: Bool {
#if os(visionOS) && targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Image to 3D Scene")
                .font(.headline)

            VStack(spacing: 12) {
                Toggle("Process Locally", isOn: $processLocally)
                    .disabled(isGenerating)

                Button {
                    Task { await downloadModels() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text(hasLocalModel ? "AI Models Ready" : "Download AI Models (~1.3 GB)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!processLocally || isDownloadingModel || hasLocalModel || isGenerating)

                if isDownloadingModel {
                    ProgressView(value: modelDownloadProgress) {
                        Text("Downloading models…")
                    }
                }
            }

            Text("Local processing uses on-device AI. Internet is only required to download the model once. Processing may take 1–2 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("Select Photo")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!processLocally || isGenerating || !isInferenceSupported)

            if !isInferenceSupported {
                Text("Local SHARP inference is not supported on visionOS Simulator. Run on device to generate PLY.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let generatedPLYURL {
                Button {
                    openModel(.gaussianSplat(generatedPLYURL))
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Render Generated PLY")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)

#if os(macOS)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([generatedPLYURL])
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Reveal in Finder")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)
#endif

                Button {
                    Task { await exportPLY(generatedPLYURL) }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save Generated PLY")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)

                Button {
                    Task { await generator.unloadModel() }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Unload Model")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)

                if let generatedPointCount {
                    Text("Generated \(generatedPointCount) points.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isGenerating {
                ProgressView(value: generationProgress) {
                    Text("Generating PLY…")
                }
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        }
        .onAppear {
            refreshLocalModelState()
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task { await generateFromSelectedPhoto(newValue) }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil },
                                            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .modifier(PLYFileMover(isPresented: $isExportingPLY, fileURL: exportPLYURL) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }

            if let exportPLYURL {
                try? FileManager.default.removeItem(at: exportPLYURL)
                self.exportPLYURL = nil
            }
        })
    }

    @MainActor
    private func refreshLocalModelState() {
        do {
            let url = try SharpModelResources.cachedCompiledModelURL()
            hasLocalModel = FileManager.default.fileExists(atPath: url.path)
        } catch {
            hasLocalModel = false
        }
    }

    private func downloadModels() async {
        await MainActor.run {
            isDownloadingModel = true
            modelDownloadProgress = 0
            errorMessage = nil
        }

        do {
            _ = try await SharpModelResources.ensureCompiledModelAvailable(progress: { value in
                Task { @MainActor in
                    modelDownloadProgress = value
                }
            })
            await MainActor.run {
                refreshLocalModelState()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isDownloadingModel = false
        }
    }

    private func generateFromSelectedPhoto(_ item: PhotosPickerItem) async {
        await MainActor.run {
            isGenerating = true
            generationProgress = 0
            errorMessage = nil
            generatedPLYURL = nil
            generatedPointCount = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let cgImage = CGImage.fromImageData(data) else {
                throw SharpLocalSplatGenerator.Error.unsupportedImage
            }

            let result = try await generator.generate(from: cgImage, progress: { value in
                Task { @MainActor in
                    generationProgress = value
                }
            })

            await MainActor.run {
                generatedPLYURL = result.plyURL
                generatedPointCount = result.pointCount
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isGenerating = false
            selectedPhotoItem = nil
        }
    }

    private func exportPLY(_ url: URL) async {
        await MainActor.run {
            errorMessage = nil
        }

        do {
            let exportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(UUID().uuidString)")
                .appendingPathExtension("ply")
            if FileManager.default.fileExists(atPath: exportURL.path) {
                try FileManager.default.removeItem(at: exportURL)
            }
            try FileManager.default.copyItem(at: url, to: exportURL)

            await MainActor.run {
                exportPLYURL = exportURL
                isExportingPLY = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension CGImage {
    static func fromImageData(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private struct PLYFileMover: ViewModifier {
    @Binding var isPresented: Bool
    var fileURL: URL?
    var onCompletion: (Result<URL, any Swift.Error>) -> Void

    func body(content: Content) -> some View {
        if let fileURL {
            content.fileMover(isPresented: $isPresented, file: fileURL, onCompletion: onCompletion)
        } else {
            content
        }
    }
}

#endif // os(iOS) || os(macOS) || os(visionOS)
