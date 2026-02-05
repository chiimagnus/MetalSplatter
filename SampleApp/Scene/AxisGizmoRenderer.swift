#if os(visionOS)

import Metal
import simd

final class AxisGizmoRenderer {
    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    private struct Uniforms {
        var projectionMatrix: simd_float4x4
        var viewMatrix: simd_float4x4
    }

    private struct UniformsArray {
        var uniforms0: Uniforms
        var uniforms1: Uniforms
    }

    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState?
    private let vertexBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer
    private let maxViewCount: Int

    init(device: MTLDevice,
         colorFormat: MTLPixelFormat,
         depthFormat: MTLPixelFormat,
         sampleCount: Int,
         maxViewCount: Int,
         axisLength: Float = 0.5) throws {
        self.device = device
        self.maxViewCount = max(1, min(maxViewCount, 2))

        let vertices: [Vertex] = [
            // X axis (red)
            .init(position: .zero, color: SIMD3(1, 0, 0)),
            .init(position: SIMD3(axisLength, 0, 0), color: SIMD3(1, 0, 0)),
            // Y axis (green)
            .init(position: .zero, color: SIMD3(0, 1, 0)),
            .init(position: SIMD3(0, axisLength, 0), color: SIMD3(0, 1, 0)),
            // Z axis (blue)
            .init(position: .zero, color: SIMD3(0, 0, 1)),
            .init(position: SIMD3(0, 0, axisLength), color: SIMD3(0, 0, 1)),
        ]

        guard let vb = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<Vertex>.stride * vertices.count,
                                         options: [.storageModeShared]) else {
            throw NSError(domain: "AxisGizmoRenderer", code: -1)
        }
        vb.label = "AxisGizmoVertices"
        vertexBuffer = vb

        guard let ub = device.makeBuffer(length: MemoryLayout<UniformsArray>.stride,
                                         options: [.storageModeShared]) else {
            throw NSError(domain: "AxisGizmoRenderer", code: -2)
        }
        ub.label = "AxisGizmoUniforms"
        uniformBuffer = ub

        let library = try device.makeDefaultLibrary(bundle: .main)

        let vertexFunction = library.makeFunction(name: "axisVertex")
        let fragmentFunction = library.makeFunction(name: "axisFragment")
        if vertexFunction == nil || fragmentFunction == nil {
            throw NSError(domain: "AxisGizmoRenderer", code: -3)
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "AxisGizmoPipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.maxVertexAmplificationCount = self.maxViewCount

        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        if depthFormat != .invalid {
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = false
            depthDescriptor.depthCompareFunction = .lessEqual
            depthState = device.makeDepthStencilState(descriptor: depthDescriptor)
        } else {
            depthState = nil
        }
    }

    func encode(viewports: [ModelRendererViewportDescriptor],
                colorTexture: MTLTexture,
                depthTexture: MTLTexture?,
                rasterizationRateMap: MTLRasterizationRateMap?,
                renderTargetArrayLength: Int,
                to commandBuffer: MTLCommandBuffer) {
        guard let firstViewport = viewports.first else { return }

        let passDescriptor = MTLRenderPassDescriptor()

        guard let colorAttachment = passDescriptor.colorAttachments[0] else { return }
        colorAttachment.texture = colorTexture
        colorAttachment.loadAction = .load
        colorAttachment.storeAction = .store

        if let depthTexture {
            passDescriptor.depthAttachment.texture = depthTexture
            passDescriptor.depthAttachment.loadAction = .load
            passDescriptor.depthAttachment.storeAction = .dontCare
        }

        if let rasterizationRateMap {
            passDescriptor.rasterizationRateMap = rasterizationRateMap
        }

        passDescriptor.renderTargetArrayLength = renderTargetArrayLength

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.label = "AxisGizmoEncoder"

        encoder.setViewport(firstViewport.viewport)

        let p = uniformBuffer.contents().bindMemory(to: UniformsArray.self, capacity: 1)
        let u0 = Uniforms(projectionMatrix: firstViewport.projectionMatrix,
                          viewMatrix: firstViewport.viewMatrix)
        let u1: Uniforms
        if viewports.count > 1 {
            u1 = Uniforms(projectionMatrix: viewports[1].projectionMatrix,
                          viewMatrix: viewports[1].viewMatrix)
        } else {
            u1 = u0
        }
        p.pointee = UniformsArray(uniforms0: u0, uniforms1: u1)

        encoder.setRenderPipelineState(pipelineState)
        if let depthState {
            encoder.setDepthStencilState(depthState)
        }

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}

#endif // os(visionOS)
