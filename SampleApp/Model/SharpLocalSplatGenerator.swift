import CoreGraphics
@preconcurrency import CoreML
import Foundation
import SplatIO
import simd
import os
import ImageIO
#if canImport(Mach)
import Mach
#endif

actor SharpLocalSplatGenerator {
    private static let log = Logger(subsystem: "MetalSplatterSampleApp", category: "SharpLocalSplatGenerator")

    enum Error: LocalizedError {
        case unsupportedModelInputs([String])
        case unsupportedModelOutputs([String])
        case unsupportedImage
        case unsupportedMultiArrayDataType(MLMultiArrayDataType)
        case unsupportedOnVisionOSSimulator
        case insufficientDeviceMemory(requiredBytes: UInt64, physicalBytes: UInt64)
        case predictionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModelInputs(let inputs):
                return "Unsupported model inputs: \(inputs.joined(separator: ", "))"
            case .unsupportedModelOutputs(let outputs):
                return "Unsupported model outputs: \(outputs.joined(separator: ", "))"
            case .unsupportedImage:
                return "Unsupported image."
            case .unsupportedMultiArrayDataType(let type):
                return "Unsupported MLMultiArray data type: \(type)"
            case .unsupportedOnVisionOSSimulator:
                return "SHARP Core ML inference is not supported on visionOS Simulator. Please run on a real device."
            case let .insufficientDeviceMemory(requiredBytes, physicalBytes):
                let requiredGB = Double(requiredBytes) / (1024 * 1024 * 1024)
                let deviceGB = Double(physicalBytes) / (1024 * 1024 * 1024)
                return String(format: "This device may not have enough RAM for local SHARP processing (requires ~%.0f GB, device has ~%.0f GB). Try generating the PLY on macOS and rendering the PLY here.", requiredGB, deviceGB)
            case .predictionFailed(let message):
                return message
            }
        }
    }

    struct GenerationResult: Sendable {
        var plyURL: URL
        var pointCount: Int
    }

    private var model: MLModel?
    private var modelComputeUnits: MLComputeUnits?

    func unloadModel() {
        if model != nil {
            let units = modelComputeUnits
            Self.log.info("Unloading Core ML model (computeUnits=\(String(describing: units), privacy: .public)).")
        }
        model = nil
        modelComputeUnits = nil
    }

    func generate(from imageData: Data,
                  disparityFactor: Float = 1.0,
                  allowLowMemoryDevice: Bool = false,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerationResult {
        try await generateInternal(disparityFactor: disparityFactor,
                                   allowLowMemoryDevice: allowLowMemoryDevice,
                                   progress: progress,
                                   sourceImageProvider: { inputSize in
            let maxPixelSize = max(Int(inputSize.width), Int(inputSize.height))
            guard let cgImage = CGImage.fromImageData(imageData, maxPixelSize: maxPixelSize) else {
                throw Error.unsupportedImage
            }
            return cgImage
        })
    }

    func generate(from sourceImage: CGImage,
                  disparityFactor: Float = 1.0,
                  allowLowMemoryDevice: Bool = false,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> GenerationResult {
        try await generateInternal(disparityFactor: disparityFactor,
                                   allowLowMemoryDevice: allowLowMemoryDevice,
                                   progress: progress,
                                   sourceImageProvider: { _ in sourceImage })
    }

    private func generateInternal(disparityFactor: Float,
                                  allowLowMemoryDevice: Bool,
                                  progress: (@Sendable (Double) -> Void)?,
                                  sourceImageProvider: (CGSize) throws -> CGImage) async throws -> GenerationResult {
#if os(visionOS) && targetEnvironment(simulator)
        Self.log.warning("Attempted to run inference on visionOS Simulator; not supported.")
        throw Error.unsupportedOnVisionOSSimulator
#endif

        Self.log.info("Starting generation. disparityFactor=\(disparityFactor, privacy: .public)")
        let compiledURL = try await SharpModelResources.ensureCompiledModelAvailable(progress: { value in
            progress?(min(value * 0.2, 0.2))
        })
        Self.log.info("Compiled model URL: \(compiledURL.path, privacy: .public)")

        let (model, io) = try await loadModelAndIO(compiledModelURL: compiledURL)
        Self.log.info("Model IO resolved. imageInput=\(io.imageInputName, privacy: .public), disparityInput=\(io.disparityInputName ?? "(none)", privacy: .public)")
        let inputSize = inferInputSize(model: model, imageInputName: io.imageInputName) ?? CGSize(width: 1536, height: 1536)
        Self.log.info("Using model input size: \(Int(inputSize.width))x\(Int(inputSize.height))")
        logMemory("after_load_model")

        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        Self.log.info("Device physical memory: \(physicalMemory, privacy: .public) bytes")

#if os(iOS) || os(visionOS)
        let required = UInt64(8) * 1024 * 1024 * 1024
        if !allowLowMemoryDevice && physicalMemory > 0 && physicalMemory < required {
            Self.log.warning("Insufficient device memory for local SHARP processing. required=\(required, privacy: .public), physical=\(physicalMemory, privacy: .public)")
            throw Error.insufficientDeviceMemory(requiredBytes: required, physicalBytes: physicalMemory)
        }
#endif

        let sourceImage = try sourceImageProvider(inputSize)
        Self.log.info("Decoded source image. image=\(sourceImage.width)x\(sourceImage.height)")
        logMemory("after_decode_image")

        guard let resized = sourceImage.resized(to: inputSize) else {
            throw Error.unsupportedImage
        }
        logMemory("after_resize_image")

        let inputImageValue = try featureValue(for: resized, description: io.imageInputDescription)
        var inputs: [String: MLFeatureValue] = [ io.imageInputName: inputImageValue ]
        if let disparityInputName = io.disparityInputName, let disparityInputDescription = io.disparityInputDescription {
            inputs[disparityInputName] = featureValue(forDisparityFactor: disparityFactor, description: disparityInputDescription)
        }

        progress?(0.25)
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let computeUnitCandidates = predictComputeUnitCandidates()
        Self.log.info("Starting prediction (computeUnitsCandidates=\(String(describing: computeUnitCandidates), privacy: .public)).")
        let predictionStart = Date()
        let output = try await predictWithFallback(compiledModelURL: compiledURL, provider: provider)
        let predictionSeconds = Date().timeIntervalSince(predictionStart)
        Self.log.info("Prediction finished in \(predictionSeconds, privacy: .public)s.")
        logMemory("after_prediction")
        progress?(0.35)

        let tensors = try resolveOutputs(io: io, output: output)
        let pointCount = tensors.positions.pointCount
        Self.log.info("Resolved outputs. pointCount=\(pointCount, privacy: .public)")

        // Release the model as early as possible to reduce steady-state memory use after inference.
        // Core ML may still retain internal caches, but this helps drop our strong reference.
        self.model = nil

        let outURL = try generatedPLYURL()
            .appendingPathComponent("sharp-\(UUID().uuidString)")
            .appendingPathExtension("ply")

        Self.log.info("Writing PLY to: \(outURL.path, privacy: .public)")
        let writer = try SplatPLYSceneWriter(to: .file(outURL))
        try await writer.start(sphericalHarmonicDegree: 0, binary: true, pointCount: pointCount)

        let chunkSize = 2048
        var written = 0
        while written < pointCount {
            let nextCount = min(chunkSize, pointCount - written)
            var points: [SplatPoint] = []
            points.reserveCapacity(nextCount)

            for i in 0..<nextCount {
                let idx = written + i
                let position = tensors.positions.xyz(pointIndex: idx)
                let scales = tensors.scales.xyz(pointIndex: idx).clamped(min: 1e-8)
                let rotation = tensors.rotations.quaternion(pointIndex: idx).normalized
                let rgbLinear = tensors.colors.xyz(pointIndex: idx).clamped(to: 0...1)
                let rgb = SIMD3(linearRGBToSRGB(rgbLinear.x),
                                linearRGBToSRGB(rgbLinear.y),
                                linearRGBToSRGB(rgbLinear.z))
                let alpha = tensors.opacities.alpha(pointIndex: idx).clamped(to: 1e-6...(1 - 1e-6))

                let sh0 = (rgb - SIMD3<Float>(repeating: 0.5)) * SplatPoint.Color.INV_SH_C0

                let point = SplatPoint(position: position,
                                       color: .sphericalHarmonicFloat([sh0]),
                                       opacity: .linearFloat(alpha),
                                       scale: .linearFloat(scales),
                                       rotation: rotation)
                points.append(point)
            }

            try await writer.write(points)
            written += nextCount
            progress?(0.35 + (Double(written) / Double(pointCount)) * 0.65)
        }

        try await writer.close()
        logMemory("after_write_ply")
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber {
            Self.log.info("PLY write complete. bytes=\(fileSize.intValue, privacy: .public)")
        } else {
            Self.log.info("PLY write complete.")
        }
        return GenerationResult(plyURL: outURL, pointCount: pointCount)
    }

    private func loadModelAndIO(compiledModelURL: URL) async throws -> (MLModel, SharpModelIO) {
        let preferredUnits: MLComputeUnits

#if targetEnvironment(simulator)
        preferredUnits = .cpuOnly
#else
        #if os(macOS)
        // Match upstream (sharp.swift).
        preferredUnits = .all
        #elseif os(iOS)
        // Prefer Neural Engine on iOS to reduce GPU memory pressure and avoid BNNS-only failures.
        preferredUnits = .cpuAndNeuralEngine
        #else
        preferredUnits = .cpuAndNeuralEngine
        #endif
#endif

        let model = try loadModel(compiledModelURL: compiledModelURL, computeUnits: preferredUnits)
        let io = try resolveIO(model: model)
        return (model, io)
    }

    private func loadModel(compiledModelURL: URL, computeUnits: MLComputeUnits) throws -> MLModel {
        if let model, modelComputeUnits == computeUnits {
            return model
        }

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        Self.log.info("Loading model with computeUnits=\(String(describing: computeUnits), privacy: .public)")
        let model = try MLModel(contentsOf: compiledModelURL, configuration: config)
        self.model = model
        self.modelComputeUnits = computeUnits
        return model
    }

    private func predictWithFallback(compiledModelURL: URL, provider: MLDictionaryFeatureProvider) async throws -> MLFeatureProvider {
        let computeUnitCandidates = predictComputeUnitCandidates()
        var lastError: Swift.Error?
        for units in computeUnitCandidates {
            do {
                Self.log.info("Attempting prediction with computeUnits=\(String(describing: units), privacy: .public)")
                let model = try loadModel(compiledModelURL: compiledModelURL, computeUnits: units)
                return try await predictSync(model: model, provider: provider)
            } catch {
                lastError = error
                Self.log.error("Prediction failed with computeUnits=\(String(describing: units), privacy: .public): \(error.localizedDescription, privacy: .public)")
                unloadModel()
            }
        }

        throw Error.predictionFailed(lastError?.localizedDescription ?? "Core ML prediction failed.")
    }

    private func predictComputeUnitCandidates() -> [MLComputeUnits] {
#if targetEnvironment(simulator)
        [ .cpuOnly ]
#else
        #if os(iOS)
        [ .cpuAndNeuralEngine, .all, .cpuOnly ]
        #elseif os(macOS)
        [ .all ]
        #else
        [ .cpuAndNeuralEngine, .all, .cpuOnly ]
        #endif
#endif
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T
}

private func predictSync(model: MLModel, provider: MLDictionaryFeatureProvider) async throws -> MLFeatureProvider {
    let modelBox = UncheckedSendableBox(value: model)
    let providerBox = UncheckedSendableBox(value: provider)

    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                do {
                    let output = try modelBox.value.prediction(from: providerBox.value)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func generatedPLYURL() throws -> URL {
    let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
    let dir = base.appendingPathComponent("GeneratedScenes", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
}

private struct SharpModelIO {
    var imageInputName: String
    var imageInputDescription: MLFeatureDescription
    var disparityInputName: String?
    var disparityInputDescription: MLFeatureDescription?

    var outputNames: SharpOutputNames
}

private struct SharpOutputNames {
    var positions: String
    var scales: String
    var rotations: String
    var colors: String
    var opacities: String
}

private func resolveIO(model: MLModel) throws -> SharpModelIO {
    let description = model.modelDescription
    let inputsByName = description.inputDescriptionsByName

    let imageInputs = inputsByName.filter { _, desc in
        desc.type == .image || desc.type == .multiArray
    }
    guard let imageCandidate = imageInputs.first(where: { $0.key == "image" }) ?? imageInputs.first else {
        throw SharpLocalSplatGenerator.Error.unsupportedModelInputs(Array(inputsByName.keys).sorted())
    }

    let disparityCandidate = inputsByName.first(where: { name, desc in
        if name == "disparity_factor" { return true }
        switch desc.type {
        case .double, .int64, .multiArray:
            return name.localizedCaseInsensitiveContains("disparity")
        default:
            return false
        }
    })

    let outputsByName = description.outputDescriptionsByName
    let outputNames = try resolveOutputNames(outputsByName: outputsByName)

    return SharpModelIO(imageInputName: imageCandidate.key,
                        imageInputDescription: imageCandidate.value,
                        disparityInputName: disparityCandidate?.key,
                        disparityInputDescription: disparityCandidate?.value,
                        outputNames: outputNames)
}

private func resolveOutputNames(outputsByName: [String: MLFeatureDescription]) throws -> SharpOutputNames {
    if outputsByName.keys.contains("mean_vectors_3d_positions"),
       outputsByName.keys.contains("singular_values_scales"),
       outputsByName.keys.contains("quaternions_rotations"),
       outputsByName.keys.contains("colors_rgb_linear"),
       outputsByName.keys.contains("opacities_alpha_channel") {
        return SharpOutputNames(positions: "mean_vectors_3d_positions",
                                scales: "singular_values_scales",
                                rotations: "quaternions_rotations",
                                colors: "colors_rgb_linear",
                                opacities: "opacities_alpha_channel")
    }

    let multiArrayOutputs = outputsByName.compactMap { name, desc -> (String, [Int], MLFeatureDescription)? in
        guard desc.type == .multiArray, let constraint = desc.multiArrayConstraint else { return nil }
        return (name, constraint.shape.map { Int(truncating: $0) }, desc)
    }

    func find(rank: Int, lastDim: Int, nameHint: String? = nil) -> String? {
        multiArrayOutputs.first(where: { name, shape, _ in
            guard shape.count == rank, shape.last == lastDim else { return false }
            guard let nameHint else { return true }
            return name.localizedCaseInsensitiveContains(nameHint)
        })?.0
    }

    let rotations = find(rank: 3, lastDim: 4, nameHint: "rot") ?? find(rank: 2, lastDim: 4, nameHint: "rot")
    let positions = find(rank: 3, lastDim: 3, nameHint: "pos") ?? find(rank: 3, lastDim: 3, nameHint: "mean")
    let scales = find(rank: 3, lastDim: 3, nameHint: "scale") ?? find(rank: 3, lastDim: 3, nameHint: "singular")
    let colors = find(rank: 3, lastDim: 3, nameHint: "color")

    let opacitiesHinted = multiArrayOutputs.first(where: { name, shape, _ in
        guard shape.count == 2 else { return false }
        return name.localizedCaseInsensitiveContains("opacity") || name.localizedCaseInsensitiveContains("alpha")
    })?.0
    let opacitiesFallback = multiArrayOutputs.first(where: { _, shape, _ in
        shape.count == 2
    })?.0
    let opacities = opacitiesHinted ?? opacitiesFallback

    guard let positions, let scales, let rotations, let colors, let opacities else {
        throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs(outputsByName.keys.sorted())
    }

    return SharpOutputNames(positions: positions,
                            scales: scales,
                            rotations: rotations,
                            colors: colors,
                            opacities: opacities)
}

private struct SharpTensorSet {
    var positions: MultiArrayXYZ
    var scales: MultiArrayXYZ
    var rotations: MultiArrayQuat
    var colors: MultiArrayXYZ
    var opacities: MultiArrayAlpha
}

private func resolveOutputs(io: SharpModelIO, output: MLFeatureProvider) throws -> SharpTensorSet {
    func requireMultiArray(_ name: String) throws -> MLMultiArray {
        guard let value = output.featureValue(for: name)?.multiArrayValue else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs([name])
        }
        return value
    }

    return SharpTensorSet(positions: try MultiArrayXYZ(try requireMultiArray(io.outputNames.positions)),
                          scales: try MultiArrayXYZ(try requireMultiArray(io.outputNames.scales)),
                          rotations: try MultiArrayQuat(try requireMultiArray(io.outputNames.rotations)),
                          colors: try MultiArrayXYZ(try requireMultiArray(io.outputNames.colors)),
                          opacities: try MultiArrayAlpha(try requireMultiArray(io.outputNames.opacities)))
}

private func inferInputSize(model: MLModel, imageInputName: String) -> CGSize? {
    let desc = model.modelDescription.inputDescriptionsByName[imageInputName]
    if let constraint = desc?.imageConstraint {
        return CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
    }

    if let constraint = desc?.multiArrayConstraint {
        let shape = constraint.shape.map { Int(truncating: $0) }
        if shape.count >= 4, let w = shape.last, let h = shape.dropLast().last {
            return CGSize(width: w, height: h)
        }
    }

    return nil
}

private func featureValue(for image: CGImage, description: MLFeatureDescription) throws -> MLFeatureValue {
    switch description.type {
    case .image:
        if let constraint = description.imageConstraint,
           let pixelBuffer = image.makePixelBuffer(width: constraint.pixelsWide, height: constraint.pixelsHigh) {
            return MLFeatureValue(pixelBuffer: pixelBuffer)
        }
        guard let pixelBuffer = image.makePixelBuffer(width: image.width, height: image.height) else {
            throw SharpLocalSplatGenerator.Error.unsupportedImage
        }
        return MLFeatureValue(pixelBuffer: pixelBuffer)
    case .multiArray:
        let shape = description.multiArrayConstraint?.shape.map { Int(truncating: $0) } ?? [1, 3, image.height, image.width]
        let target = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        guard let pixelBuffer = image.makePixelBuffer(width: image.width, height: image.height) else {
            throw SharpLocalSplatGenerator.Error.unsupportedImage
        }
        try target.copyRGBFloat32CHW(from: pixelBuffer)
        return MLFeatureValue(multiArray: target)
    default:
        throw SharpLocalSplatGenerator.Error.unsupportedModelInputs([description.name])
    }
}

private func featureValue(forDisparityFactor value: Float, description: MLFeatureDescription) -> MLFeatureValue {
    switch description.type {
    case .double:
        return MLFeatureValue(double: Double(value))
    case .int64:
        return MLFeatureValue(int64: Int64(value))
    case .multiArray:
        if let array = try? MLMultiArray(shape: [1], dataType: .float32) {
            array[0] = NSNumber(value: value)
            return MLFeatureValue(multiArray: array)
        }
        return MLFeatureValue(double: Double(value))
    default:
        return MLFeatureValue(double: Double(value))
    }
}

private struct MultiArrayReader {
    var array: MLMultiArray
    var shape: [Int]
    var strides: [Int]
    private var float32Ptr: UnsafePointer<Float32>?
    private var float16Ptr: UnsafePointer<UInt16>?
    private var doublePtr: UnsafePointer<Double>?

    init(_ array: MLMultiArray) throws {
        self.array = array
        self.shape = array.shape.map { Int(truncating: $0) }
        self.strides = array.strides.map { Int(truncating: $0) }

        switch array.dataType {
        case .float32:
            self.float32Ptr = UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float32.self))
        case .float16:
            self.float16Ptr = UnsafePointer(array.dataPointer.assumingMemoryBound(to: UInt16.self))
        case .double:
            self.doublePtr = UnsafePointer(array.dataPointer.assumingMemoryBound(to: Double.self))
        default:
            throw SharpLocalSplatGenerator.Error.unsupportedMultiArrayDataType(array.dataType)
        }
    }

    func float(at indices: [Int]) -> Float {
        var linearIndex = 0
        for (i, idx) in indices.enumerated() {
            linearIndex += idx * strides[i]
        }
        return float(linearIndex: linearIndex)
    }

    func float(linearIndex: Int) -> Float {
        switch array.dataType {
        case .float32:
            return Float(float32Ptr?[linearIndex] ?? 0)
        case .float16:
            return halfToFloat(float16Ptr?[linearIndex] ?? 0)
        case .double:
            return Float(doublePtr?[linearIndex] ?? 0)
        default:
            return 0
        }
    }
}

private func halfToFloat(_ bits: UInt16) -> Float {
    // IEEE 754 binary16 to binary32 conversion (no Float16 dependency; works on x86_64).
    let sign = UInt32(bits & 0x8000) << 16
    let exp = UInt32(bits & 0x7C00) >> 10
    let mant = UInt32(bits & 0x03FF)

    let fbits: UInt32
    switch exp {
    case 0:
        if mant == 0 {
            fbits = sign
        } else {
            // Subnormal
            var e: UInt32 = 127 - 15 + 1
            var m = mant
            while (m & 0x0400) == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x03FF
            fbits = sign | (e << 23) | (m << 13)
        }
    case 0x1F:
        // Inf/NaN
        fbits = sign | 0x7F80_0000 | (mant << 13)
    default:
        let e = exp + (127 - 15)
        fbits = sign | (e << 23) | (mant << 13)
    }

    return Float(bitPattern: fbits)
}

private struct MultiArrayXYZ {
    private var reader: MultiArrayReader
    private let pointStride: Int
    private let componentStride: Int
    private let baseOffset: Int
    private let pointCountValue: Int

    init(_ array: MLMultiArray) throws {
        let reader = try MultiArrayReader(array)
        guard reader.shape.count == 3 || reader.shape.count == 2 else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs([array.description])
        }
        let lastDim = reader.shape.last ?? 0
        guard lastDim == 3 else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs([array.description])
        }

        self.reader = reader
        if reader.shape.count == 3 {
            // [1, N, 3] (or similar)
            self.baseOffset = 0
            self.pointStride = reader.strides[1]
            self.componentStride = reader.strides[2]
            self.pointCountValue = reader.shape[1]
        } else {
            // [N, 3]
            self.baseOffset = 0
            self.pointStride = reader.strides[0]
            self.componentStride = reader.strides[1]
            self.pointCountValue = reader.shape[0]
        }
    }

    var pointCount: Int {
        pointCountValue
    }

    func xyz(pointIndex: Int) -> SIMD3<Float> {
        let base = baseOffset + pointIndex * pointStride
        return SIMD3(reader.float(linearIndex: base + 0 * componentStride),
                     reader.float(linearIndex: base + 1 * componentStride),
                     reader.float(linearIndex: base + 2 * componentStride))
    }
}

private struct MultiArrayQuat {
    private var reader: MultiArrayReader
    private let pointStride: Int
    private let componentStride: Int
    private let baseOffset: Int

    init(_ array: MLMultiArray) throws {
        let reader = try MultiArrayReader(array)
        guard reader.shape.count == 3 || reader.shape.count == 2 else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs([array.description])
        }
        let lastDim = reader.shape.last ?? 0
        guard lastDim == 4 else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs([array.description])
        }

        self.reader = reader
        if reader.shape.count == 3 {
            // [1, N, 4]
            self.baseOffset = 0
            self.pointStride = reader.strides[1]
            self.componentStride = reader.strides[2]
        } else {
            // [N, 4]
            self.baseOffset = 0
            self.pointStride = reader.strides[0]
            self.componentStride = reader.strides[1]
        }
    }

    func quaternion(pointIndex: Int) -> simd_quatf {
        let base = baseOffset + pointIndex * pointStride
        let w = reader.float(linearIndex: base + 0 * componentStride)
        let x = reader.float(linearIndex: base + 1 * componentStride)
        let y = reader.float(linearIndex: base + 2 * componentStride)
        let z = reader.float(linearIndex: base + 3 * componentStride)
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    }
}

private struct MultiArrayAlpha {
    private var reader: MultiArrayReader
    private let pointStride: Int
    private let baseOffset: Int

    init(_ array: MLMultiArray) throws {
        let reader = try MultiArrayReader(array)
        guard reader.shape.count == 2 || reader.shape.count == 1 else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelOutputs([array.description])
        }
        self.reader = reader
        if reader.shape.count == 1 {
            self.baseOffset = 0
            self.pointStride = reader.strides[0]
        } else {
            // Accept either [1, N] or [N, 1]. Default to [N, 1] if ambiguous.
            if reader.shape[0] == 1 {
                // [1, N] -> index [0, pointIndex]
                self.baseOffset = 0
                self.pointStride = reader.strides[1]
            } else {
                // [N, 1] -> index [pointIndex, 0]
                self.baseOffset = 0
                self.pointStride = reader.strides[0]
            }
        }
    }

    func alpha(pointIndex: Int) -> Float {
        reader.float(linearIndex: baseOffset + pointIndex * pointStride)
    }
}

private func linearRGBToSRGB(_ linear: Float) -> Float {
    if linear <= 0.0031308 {
        return linear * 12.92
    }
    return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
}

private extension CGImage {
    static func fromImageData(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func resized(to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]

        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

private extension SharpLocalSplatGenerator {
    func logMemory(_ label: StaticString) {
#if canImport(Mach)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return }
        Self.log.info("Memory \(label, privacy: .public): resident=\(UInt64(info.resident_size), privacy: .public) bytes, virtual=\(UInt64(info.virtual_size), privacy: .public) bytes")
#else
        _ = label
#endif
    }
}

private extension MLMultiArray {
    func copyRGBFloat32CHW(from pixelBuffer: CVPixelBuffer) throws {
        guard dataType == .float32 else {
            throw SharpLocalSplatGenerator.Error.unsupportedMultiArrayDataType(dataType)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw SharpLocalSplatGenerator.Error.unsupportedImage
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let shapeInts = shape.map { Int(truncating: $0) }
        guard shapeInts.count >= 4 else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelInputs(["image"])
        }

        let n = shapeInts[0]
        let c = shapeInts[1]
        let h = shapeInts[2]
        let w = shapeInts[3]
        guard n == 1, c == 3, h == height, w == width else {
            throw SharpLocalSplatGenerator.Error.unsupportedModelInputs(["image"])
        }

        let dst = dataPointer.assumingMemoryBound(to: Float32.self)
        let strideN = strides[0].intValue
        let strideC = strides[1].intValue
        let strideH = strides[2].intValue
        let strideW = strides[3].intValue

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                let b = pixel[0]
                let g = pixel[1]
                let r = pixel[2]

                let baseIndex = 0 * strideN + y * strideH + x * strideW
                dst[baseIndex + 0 * strideC] = Float32(r) / 255.0
                dst[baseIndex + 1 * strideC] = Float32(g) / 255.0
                dst[baseIndex + 2 * strideC] = Float32(b) / 255.0
            }
        }
    }
}

private extension SIMD3 where Scalar == Float {
    func clamped(min: Float) -> SIMD3<Float> {
        SIMD3(Swift.max(x, min), Swift.max(y, min), Swift.max(z, min))
    }

    func clamped(to range: ClosedRange<Float>) -> SIMD3<Float> {
        SIMD3(x.clamped(to: range), y.clamped(to: range), z.clamped(to: range))
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
