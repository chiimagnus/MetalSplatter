import Foundation
import PLYIO
import simd

struct SplatPLYMetadata: Sendable {
    struct Camera: Sendable {
        var extrinsic: simd_float4x4?
        var intrinsic: simd_float3x3?
        var imageSize: SIMD2<UInt32>?
    }

    enum ForwardAxis: Sendable {
        case positiveZ
        case negativeZ
        case unknown
    }

    var camera: Camera
    var sampledMeanZ: Float?
    var forwardAxisHint: ForwardAxis
}

extension SplatPLYMetadata {
    enum ReadError: LocalizedError {
        case notAFileURL
        case headerNotFound
        case unsupportedHeader(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .notAFileURL:
                "URL 不是文件路径"
            case .headerNotFound:
                "无法在 PLY 文件中找到 end_header"
            case .unsupportedHeader(let reason):
                "不支持的 PLY header：\(reason)"
            case .ioFailure(let message):
                "读取 PLY 失败：\(message)"
            }
        }
    }

    static func read(from url: URL, sampleVertexCount: Int = 4096) throws -> SplatPLYMetadata {
        guard url.isFileURL else { throw ReadError.notAFileURL }

        let (header, bodyOffset) = try readHeader(url: url)
        guard header.format == .binaryLittleEndian else {
            throw ReadError.unsupportedHeader("仅支持 binary_little_endian（当前：\(header.format.rawValue)）")
        }

        let camera = try readCameraBlocksIfPresent(url: url, header: header, bodyOffset: bodyOffset)
        let sampledMeanZ = try sampleMeanZ(url: url, header: header, bodyOffset: bodyOffset, sampleVertexCount: sampleVertexCount)

        let forwardAxisHint: ForwardAxis
        if let sampledMeanZ {
            forwardAxisHint = sampledMeanZ >= 0 ? .positiveZ : .negativeZ
        } else {
            forwardAxisHint = .unknown
        }

        return SplatPLYMetadata(camera: camera,
                                sampledMeanZ: sampledMeanZ,
                                forwardAxisHint: forwardAxisHint)
    }

    private static func readHeader(url: URL) throws -> (PLYHeader, Int) {
        let endHeaderNeedle = Data("end_header\n".utf8)
        let endHeaderNeedleCRLF = Data("end_header\r\n".utf8)

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var headerData = Data()
        while headerData.count < 256 * 1024 {
            let chunk = try file.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            headerData.append(chunk)

            if let range = headerData.range(of: endHeaderNeedle) {
                let bodyOffset = range.upperBound
                let header = try PLYHeader.decodeASCII(from: headerData.prefix(bodyOffset))
                return (header, bodyOffset)
            }
            if let range = headerData.range(of: endHeaderNeedleCRLF) {
                let bodyOffset = range.upperBound
                let header = try PLYHeader.decodeASCII(from: headerData.prefix(bodyOffset))
                return (header, bodyOffset)
            }
        }

        throw ReadError.headerNotFound
    }

    private static func sampleMeanZ(url: URL,
                                    header: PLYHeader,
                                    bodyOffset: Int,
                                    sampleVertexCount: Int) throws -> Float? {
        guard let vertexIndex = header.index(forElementNamed: "vertex") else {
            return nil
        }
        let vertexElement = header.elements[vertexIndex]
        guard vertexElement.count > 0 else { return nil }

        guard let zPropertyIndex = vertexElement.index(forPropertyNamed: "z") else {
            return nil
        }

        let vertexStride = try byteWidth(of: vertexElement)
        let zOffset = try byteOffset(ofPropertyIndex: zPropertyIndex, in: vertexElement)

        let toSample = min(Int(vertexElement.count), max(sampleVertexCount, 0))
        guard toSample > 0 else { return nil }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(bodyOffset))

        var sumZ: Float = 0
        var sampled = 0

        let maxBatchVertices = 4096
        while sampled < toSample {
            let batch = min(maxBatchVertices, toSample - sampled)
            let byteCount = batch * vertexStride
            guard let data = try file.read(upToCount: byteCount), data.count == byteCount else {
                throw ReadError.ioFailure("vertex 数据读取不足（expected \(byteCount)）")
            }

            data.withUnsafeBytes { raw in
                for i in 0..<batch {
                    let base = i * vertexStride + zOffset
                    let bits = raw.load(fromByteOffset: base, as: UInt32.self).littleEndian
                    let z = Float(bitPattern: bits)
                    sumZ += z
                }
            }

            sampled += batch
        }

        return sumZ / Float(toSample)
    }

    private static func readCameraBlocksIfPresent(url: URL,
                                                  header: PLYHeader,
                                                  bodyOffset: Int) throws -> Camera {
        guard let vertexIndex = header.index(forElementNamed: "vertex") else {
            return Camera(extrinsic: nil, intrinsic: nil, imageSize: nil)
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var offset = bodyOffset
        for (index, element) in header.elements.enumerated() {
            if index == vertexIndex {
                let stride = try byteWidth(of: element)
                offset += Int(element.count) * stride
                continue
            }

            if index < vertexIndex {
                offset += Int(element.count) * (try byteWidth(of: element))
                continue
            }

            switch element.name {
            case "extrinsic":
                if element.count == 16, element.properties.count == 1,
                   element.properties[0].type == .primitive(.float32) {
                    try file.seek(toOffset: UInt64(offset))
                    let data = try file.read(upToCount: 16 * 4) ?? Data()
                    if data.count == 16 * 4 {
                        let values = data.withUnsafeBytes { raw -> [Float] in
                            (0..<16).map { i in
                                let bits = raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                                return Float(bitPattern: bits)
                            }
                        }
                        let m = simd_float4x4(columns: (
                            SIMD4(values[0], values[1], values[2], values[3]),
                            SIMD4(values[4], values[5], values[6], values[7]),
                            SIMD4(values[8], values[9], values[10], values[11]),
                            SIMD4(values[12], values[13], values[14], values[15])
                        ))
                        var camera = Camera(extrinsic: m, intrinsic: nil, imageSize: nil)
                        offset += Int(element.count) * (try byteWidth(of: element))
                        // Continue scanning for intrinsic/image_size
                        for laterElement in header.elements[(index + 1)...] {
                            if laterElement.name == "intrinsic",
                               laterElement.count == 9,
                               laterElement.properties.count == 1,
                               laterElement.properties[0].type == .primitive(.float32) {
                                try file.seek(toOffset: UInt64(offset))
                                let d = try file.read(upToCount: 9 * 4) ?? Data()
                                if d.count == 9 * 4 {
                                    let v = d.withUnsafeBytes { raw -> [Float] in
                                        (0..<9).map { i in
                                            let bits = raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                                            return Float(bitPattern: bits)
                                        }
                                    }
                                    camera.intrinsic = simd_float3x3(rows: [
                                        SIMD3(v[0], v[1], v[2]),
                                        SIMD3(v[3], v[4], v[5]),
                                        SIMD3(v[6], v[7], v[8]),
                                    ])
                                }
                            } else if laterElement.name == "image_size",
                                      laterElement.count == 2,
                                      laterElement.properties.count == 1,
                                      laterElement.properties[0].type == .primitive(.uint32) {
                                try file.seek(toOffset: UInt64(offset))
                                let d = try file.read(upToCount: 2 * 4) ?? Data()
                                if d.count == 2 * 4 {
                                    let size = d.withUnsafeBytes { raw -> SIMD2<UInt32> in
                                        let a = raw.load(fromByteOffset: 0, as: UInt32.self).littleEndian
                                        let b = raw.load(fromByteOffset: 4, as: UInt32.self).littleEndian
                                        return SIMD2(a, b)
                                    }
                                    camera.imageSize = size
                                }
                            }

                            offset += Int(laterElement.count) * (try byteWidth(of: laterElement))
                            if laterElement.name == "version" { break }
                        }
                        return camera
                    }
                }
            default:
                break
            }

            offset += Int(element.count) * (try byteWidth(of: element))
        }

        return Camera(extrinsic: nil, intrinsic: nil, imageSize: nil)
    }

    private static func byteWidth(of element: PLYHeader.Element) throws -> Int {
        var total = 0
        for property in element.properties {
            switch property.type {
            case .primitive(let primitive):
                total += primitive.byteWidth
            case .list:
                throw ReadError.unsupportedHeader("element \(element.name) 含 list property，无法静态计算 byteWidth")
            }
        }
        return total
    }

    private static func byteOffset(ofPropertyIndex index: Int, in element: PLYHeader.Element) throws -> Int {
        var offset = 0
        for i in 0..<index {
            switch element.properties[i].type {
            case .primitive(let primitive):
                offset += primitive.byteWidth
            case .list:
                throw ReadError.unsupportedHeader("element \(element.name) 含 list property，无法静态计算 byteOffset")
            }
        }
        return offset
    }
}
