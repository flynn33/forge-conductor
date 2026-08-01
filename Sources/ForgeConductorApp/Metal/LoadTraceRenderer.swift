// LoadTraceRenderer.swift
// What: Draws the historical load trace into an MTKView.
// How: The delegate converts normalized samples into GPU vertex buffers and
// encodes Metal draw calls whenever SwiftUI supplies updated history.
// Why: GPU rendering keeps a rapidly refreshing chart off the main UI drawing path.

import Foundation
import MetalKit
import simd

/// Metal renderer for CPU load history (glowing cyan line + fill).
@MainActor
final class LoadTraceRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var sampleCount = 0
    private let lock = NSLock()
    private var samples: [Float] = []

    func attach(to view: MTKView) {
        let mtl = view.device ?? MTLCreateSystemDefaultDevice()
        guard let device = mtl else { return }
        self.device = device
        view.device = device
        view.delegate = self
        queue = device.makeCommandQueue()
        buildPipeline(device: device, pixelFormat: view.colorPixelFormat)
    }

    func update(samples: [Float]) {
        lock.lock()
        self.samples = samples
        lock.unlock()
        rebuildVertices()
    }

    private func buildPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            return
        }
        guard let vert = library.makeFunction(name: "load_vertex"),
              let frag = library.makeFunction(name: "load_fragment") else { return }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func rebuildVertices() {
        guard let device else { return }
        lock.lock()
        let src = samples
        lock.unlock()
        let n = max(src.count, 2)
        // Triangle strip fill under the curve + line on top: store fill verts then line verts.
        // Layout: for each sample i, position xy in NDC-ish [-1,1], color as attribute.
        struct V { var pos: SIMD2<Float>; var color: SIMD4<Float> }
        var verts: [V] = []
        verts.reserveCapacity(n * 2 + n)

        let cyan = SIMD4<Float>(0.09, 0.94, 1.0, 0.55)
        let cyanLine = SIMD4<Float>(0.2, 0.96, 1.0, 1.0)
        let base = SIMD4<Float>(0.05, 0.2, 0.3, 0.0)

        func x(_ i: Int) -> Float {
            guard n > 1 else { return 0 }
            return -1 + 2 * Float(i) / Float(n - 1)
        }
        func y(_ v: Float) -> Float {
            let t = min(max(v / 100.0, 0), 1)
            return -0.85 + 1.7 * t
        }

        // Fill strip
        for i in 0..<n {
            let val = i < src.count ? src[i] : 0
            verts.append(V(pos: SIMD2(x(i), -0.85), color: base))
            verts.append(V(pos: SIMD2(x(i), y(val)), color: cyan))
        }
        let fillCount = verts.count

        // Line
        for i in 0..<n {
            let val = i < src.count ? src[i] : 0
            verts.append(V(pos: SIMD2(x(i), y(val)), color: cyanLine))
        }

        let bytes = verts.count * MemoryLayout<V>.stride
        vertexBuffer = device.makeBuffer(bytes: verts, length: bytes, options: .storageModeShared)
        sampleCount = fillCount // first draw fill; line uses rest
        // Store line offset in high bits via sampleCount encoding: fillCount | (lineCount << 16) — simpler: store both
        lock.lock()
        self.fillVertexCount = fillCount
        self.lineVertexCount = n
        lock.unlock()
    }

    private var fillVertexCount = 0
    private var lineVertexCount = 0

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let pipeline,
              let queue,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: rpd),
              let vertexBuffer else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        lock.lock()
        let fill = fillVertexCount
        let line = lineVertexCount
        lock.unlock()

        if fill >= 2 {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: fill)
        }
        if line >= 2 {
            encoder.drawPrimitives(type: .lineStrip, vertexStart: fill, vertexCount: line)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float4 color    [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };

    // We pass tightly packed float2 + float4 without MTLVertexDescriptor by
    // reinterpreting buffer as float array in shader.
    struct Packed {
        float2 position;
        float4 color;
    };

    vertex VertexOut load_vertex(uint vid [[vertex_id]],
                                 const device Packed *vertices [[buffer(0)]]) {
        Packed v = vertices[vid];
        VertexOut out;
        out.position = float4(v.position, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 load_fragment(VertexOut in [[stage_in]]) {
        return in.color;
    }
    """
}
