@preconcurrency import CoreML
@preconcurrency import Foundation

enum SharpModelResources {
    enum Error: LocalizedError {
        case missingBundledModelResource(modelName: String)
        case cannotCreateCacheDirectory(URL)
        case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .missingBundledModelResource(let modelName):
                return "Could not find Core ML model resource \"\(modelName)\" in the app bundle."
            case .cannotCreateCacheDirectory(let url):
                return "Could not create model cache directory at: \(url.path)"
            case let .insufficientDiskSpace(requiredBytes, availableBytes):
                let requiredGB = Double(requiredBytes) / (1024 * 1024 * 1024)
                let availableGB = Double(availableBytes) / (1024 * 1024 * 1024)
                return String(format: "Not enough free device storage for the SHARP model (need ~%.1f GB free, only ~%.1f GB available). Free up storage and try again.", requiredGB, availableGB)
            }
        }
    }

    static let modelName = "sharp"
    static let odrTags: Set<String> = [ "sharp-coreml" ]

    static func cachedCompiledModelExists() -> Bool {
        (try? cachedCompiledModelURL())
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static func deleteCachedCompiledModel() throws {
        let url = try cachedCompiledModelURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func cachedCompiledModelURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let cacheDir = base.appendingPathComponent("SharpModel", isDirectory: true)

        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDir) {
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            } catch {
                throw Error.cannotCreateCacheDirectory(cacheDir)
            }
        }

        return cacheDir.appendingPathComponent("\(modelName).mlmodelc", isDirectory: true)
    }

    static func availableDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])

        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let capacity = values?.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return nil
    }

    static func ensureCompiledModelAvailable(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let compiledURL = try cachedCompiledModelURL()
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            progress(1)
            return compiledURL
        }

        do {
            progress(0)
#if os(macOS)
            // NSBundleResourceRequest (ODR) is not available on macOS.
            // On macOS, expect the model to be present in the app bundle.
            progress(0.2)
            let sourceURL = try findModelResourceURL()
            let compiledSourceURL = try compileIfNeeded(sourceURL)
            progress(0.85)
            try replaceItem(at: compiledURL, with: compiledSourceURL)
            cleanupTemporaryCompiledModelIfNeeded(sourceURL: sourceURL, compiledSourceURL: compiledSourceURL)
            progress(1)
            return compiledURL
#else
            if let available = availableDiskBytes() {
                // ODR download (~1.3GB) + cache copy + Core ML plan caches can require multiple GB.
                // Be conservative so we fail early with a clear error message.
                let required: Int64 = 6 * 1024 * 1024 * 1024
                if available < required {
                    throw Error.insufficientDiskSpace(requiredBytes: required, availableBytes: available)
                }
            }

            let request = NSBundleResourceRequest(tags: odrTags)
            request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent
            defer { request.endAccessingResources() }

            try await beginAccessingResources(request)
            progress(0.6)
            let sourceURL = try findModelResourceURL()
            let compiledSourceURL = try compileIfNeeded(sourceURL)
            progress(0.85)
            try replaceItem(at: compiledURL, with: compiledSourceURL)
            cleanupTemporaryCompiledModelIfNeeded(sourceURL: sourceURL, compiledSourceURL: compiledSourceURL)
            progress(1)
            return compiledURL
#endif
        } catch {
            throw error
        }
    }

#if !os(macOS)
    private static func beginAccessingResources(_ request: NSBundleResourceRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            request.beginAccessingResources { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
#endif

    private static func findModelResourceURL(bundle: Bundle = .main) throws -> URL {
        if let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") {
            return url
        }
        if let url = bundle.url(forResource: modelName, withExtension: "mlpackage") {
            return url
        }

        let candidates = (bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []) +
            (bundle.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil) ?? [])
        if let fallback = candidates.first(where: { $0.deletingPathExtension().lastPathComponent == modelName }) {
            return fallback
        }

        throw Error.missingBundledModelResource(modelName: modelName)
    }

    private static func compileIfNeeded(_ modelURL: URL) throws -> URL {
        if modelURL.pathExtension == "mlmodelc" {
            return modelURL
        }
        return try MLModel.compileModel(at: modelURL)
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func cleanupTemporaryCompiledModelIfNeeded(sourceURL: URL, compiledSourceURL: URL) {
        guard sourceURL != compiledSourceURL else { return }

        let tmpPath = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let compiledPath = compiledSourceURL.resolvingSymlinksInPath().path
        guard compiledPath.hasPrefix(tmpPath) else { return }

        try? FileManager.default.removeItem(at: compiledSourceURL)
    }
}
