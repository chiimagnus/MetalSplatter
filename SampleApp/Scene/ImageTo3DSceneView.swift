#if os(iOS) || os(macOS) || os(visionOS)

#if os(macOS)
import AppKit
#endif
import PhotosUI
import SwiftUI

struct ImageTo3DSceneView: View {
    let openModel: @MainActor (ModelIdentifier) -> Void

    @State private var processLocally = true
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var outputQuality: OutputQuality = .balanced
    @State private var didInitializeQuality = false

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

    private var devicePhysicalMemoryBytes: UInt64? {
#if os(iOS) || os(visionOS)
        let value = ProcessInfo.processInfo.physicalMemory
        return value > 0 ? value : nil
#else
        nil
#endif
    }

    private var devicePhysicalMemoryGB: Double? {
        guard let devicePhysicalMemoryBytes else { return nil }
        return Double(devicePhysicalMemoryBytes) / (1024 * 1024 * 1024)
    }

    private var requiresHighMemoryDeviceForLocalGeneration: Bool {
#if os(iOS) || os(visionOS)
        true
#else
        false
#endif
    }

    private var canSafelyRunLocalGeneration: Bool {
#if os(iOS) || os(visionOS)
        guard let bytes = devicePhysicalMemoryBytes else { return false }
        // SHARP is known to be unstable on < 8GB devices (Apple Research SHARP docs / common reports).
        return bytes >= UInt64(8) * 1024 * 1024 * 1024
#else
        true
#endif
    }

#if DEBUG
    @State private var forceEnableLocalGeneration = false
#endif

    private enum OutputQuality: String, CaseIterable, Identifiable {
        case full
        case balanced
        case low

        var id: String { rawValue }

        var title: String {
            switch self {
            case .full: "Full"
            case .balanced: "Balanced"
            case .low: "Low"
            }
        }
    }

    private enum ComputeMode: String, CaseIterable, Identifiable {
        case auto
        case cpuAndNeuralEngine
        case cpuAndGPU
        case cpuOnly
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: "Auto"
            case .cpuAndNeuralEngine: "CPU+NE"
            case .cpuAndGPU: "CPU+GPU"
            case .cpuOnly: "CPU"
            case .all: "All"
            }
        }

        var preference: SharpLocalSplatGenerator.ComputePreference {
            switch self {
            case .auto: .auto
            case .cpuAndNeuralEngine: .cpuAndNeuralEngine
            case .cpuAndGPU: .cpuAndGPU
            case .cpuOnly: .cpuOnly
            case .all: .all
            }
        }
    }

    private var isInferenceSupported: Bool {
#if os(visionOS) && targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    private var recommendedMaxOutputPoints: Int? {
#if os(iOS) || os(visionOS)
        let physical = ProcessInfo.processInfo.physicalMemory
        let gb = UInt64(1024 * 1024 * 1024)
        guard physical > 0 else { return nil }
        if physical < 4 * gb { return 150_000 }
        if physical < 6 * gb { return 300_000 }
        if physical < 8 * gb { return 600_000 }
        return nil
#else
        nil
#endif
    }

    private var maxOutputPoints: Int? {
        switch outputQuality {
        case .full:
            return nil
        case .balanced:
            return recommendedMaxOutputPoints
        case .low:
            if let recommendedMaxOutputPoints {
                return max(50_000, recommendedMaxOutputPoints / 2)
            }
            return 300_000
        }
    }

    @State private var computeMode: ComputeMode = .auto

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

                if hasLocalModel {
                    Button(role: .destructive) {
                        Task { await deleteCachedModel() }
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Downloaded Models")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating || isDownloadingModel)
                }

                if isDownloadingModel {
                    ProgressView(value: modelDownloadProgress) {
                        Text("Downloading models…")
                    }
                }
            }

            Text("Local processing uses on-device AI. Internet is only required to download the model once. Processing may take 1–2 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

#if os(iOS) || os(visionOS)
            if requiresHighMemoryDeviceForLocalGeneration && !canSafelyRunLocalGeneration {
                let gbText = devicePhysicalMemoryGB.map { String(format: "%.1f", $0) } ?? "unknown"
                Text("This device has ~\(gbText) GB RAM. Local SHARP generation often exceeds iOS memory limits on < 8 GB devices and may be killed by the OS. Recommended: generate the PLY on macOS and import it here to render.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                #if DEBUG
                Toggle("Force Enable Local Generation (Debug Only)", isOn: $forceEnableLocalGeneration)
                    .font(.footnote)
                    .disabled(isGenerating)
                #endif
            }
#endif

            Picker("Quality", selection: $outputQuality) {
                ForEach(OutputQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isGenerating)

            Picker("Compute", selection: $computeMode) {
                ForEach(ComputeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isGenerating)

            if recommendedMaxOutputPoints != nil, outputQuality == .full {
                Text("Full quality may be unstable on low‑memory devices. If you see memory termination, switch to Balanced/Low (fewer points).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("Select Photo")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!processLocally || isGenerating || !isInferenceSupported || !isLocalGenerationEnabled)

            if !isInferenceSupported {
                Text("Local SHARP inference is not supported on visionOS Simulator. Run on device to generate PLY.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
#if os(iOS) || os(visionOS)
            if requiresHighMemoryDeviceForLocalGeneration && !canSafelyRunLocalGeneration && !isLocalGenerationEnabled {
                Text("Local generation is disabled on this device to avoid OS termination. Use the macOS app to generate a PLY, then open it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
#endif

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
            if !didInitializeQuality {
                outputQuality = (recommendedMaxOutputPoints == nil) ? .full : .balanced
                if recommendedMaxOutputPoints != nil {
                    computeMode = .cpuAndNeuralEngine
                }
                didInitializeQuality = true
            }
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
        hasLocalModel = SharpModelResources.cachedCompiledModelExists()
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

    private func deleteCachedModel() async {
        await MainActor.run {
            errorMessage = nil
        }

        do {
            try SharpModelResources.deleteCachedCompiledModel()
            await MainActor.run {
                refreshLocalModelState()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
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
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SharpLocalSplatGenerator.Error.unsupportedImage
            }

            let result = try await generator.generate(from: data,
                                                      maxOutputPoints: maxOutputPoints,
                                                      computePreference: computeMode.preference,
                                                      progress: { value in
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

    private var isLocalGenerationEnabled: Bool {
#if DEBUG
        if requiresHighMemoryDeviceForLocalGeneration && !canSafelyRunLocalGeneration {
            return forceEnableLocalGeneration
        }
        return true
#else
        if requiresHighMemoryDeviceForLocalGeneration && !canSafelyRunLocalGeneration {
            return false
        }
        return true
#endif
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
