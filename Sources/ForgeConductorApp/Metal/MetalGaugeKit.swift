// MetalGaugeKit.swift
// What: Supplies the reusable Metal-backed gauges used throughout the rig.
// How: Shared palettes and pipelines feed dedicated renderers, while small
// NSViewRepresentable adapters expose bars, rings, tiles, and status pills to SwiftUI.
// Why: Centralizing gauge primitives keeps visual behavior consistent and modular.

import SwiftUI
import MetalKit
import simd
import ForgeConductorCore

extension TelemetryStatusTone {
    var color: Color {
        switch self {
        case .healthy: .green
        case .caution: .yellow
        case .failure: .red
        case .informational: .cyan
        case .unavailable: .secondary
        }
    }
}

// MARK: - Shared shader + types

enum MetalGaugePalette {
    static let cyan = SIMD4<Float>(0.09, 0.94, 1.0, 1)
    static let orange = SIMD4<Float>(1.0, 0.42, 0.12, 1)
    static let green = SIMD4<Float>(0.18, 1.0, 0.55, 1)
    static let purple = SIMD4<Float>(0.75, 0.45, 1.0, 1)
    static let red = SIMD4<Float>(1.0, 0.25, 0.35, 1)
    static let track = SIMD4<Float>(0.05, 0.12, 0.18, 1)

    static func from(swiftUI color: Color) -> SIMD4<Float> {
        let n = NSColor(color)
        guard let rgb = n.usingColorSpace(.deviceRGB) else { return cyan }
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
    }

    static func health(_ h: String) -> SIMD4<Float> {
        switch TelemetryHealth.tone(for: h) {
        case .healthy: return green
        case .caution: return SIMD4(1, 0.8, 0.2, 1)
        case .failure: return red
        case .informational: return cyan
        case .unavailable: return SIMD4(0.48, 0.54, 0.62, 1)
        }
    }
}

private struct GaugeVertex {
    var pos: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Shared pipeline builder for 2D colored primitives.
enum MetalGaugePipeline {
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { float2 p; float4 c; };
    struct O { float4 position [[position]]; float4 c; };
    vertex O g_vert(uint i [[vertex_id]], const device P *v [[buffer(0)]]) {
        O o; o.position = float4(v[i].p, 0, 1); o.c = v[i].c; return o;
    }
    fragment float4 g_frag(O in [[stage_in]]) { return in.c; }
    """

    static func make(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let lib = try? device.makeLibrary(source: shader, options: nil),
              let v = lib.makeFunction(name: "g_vert"),
              let f = lib.makeFunction(name: "g_frag") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }
}

// MARK: - Horizontal meter

@MainActor
final class MetalBarRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var buffer: MTLBuffer?
    private var fraction: Float = 0
    private var color = MetalGaugePalette.cyan
    private let lock = NSLock()

    func attach(_ view: MTKView) {
        let mtl = view.device ?? MTLCreateSystemDefaultDevice()
        guard let device = mtl else { return }
        self.device = device
        view.device = device
        view.delegate = self
        view.clearColor = MTLClearColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 24
        queue = device.makeCommandQueue()
        pipeline = MetalGaugePipeline.make(device: device, pixelFormat: view.colorPixelFormat)
        rebuild()
    }

    func set(fraction: Float, color: SIMD4<Float>) {
        lock.lock(); self.fraction = min(max(fraction, 0), 1); self.color = color; lock.unlock()
        rebuild()
    }

    private func rebuild() {
        guard let device else { return }
        lock.lock(); let f = fraction; let c = color; lock.unlock()
        let x = -1 + 2 * f
        var v: [GaugeVertex] = [
            .init(pos: SIMD2(-1, -0.55), color: MetalGaugePalette.track),
            .init(pos: SIMD2(1, -0.55), color: MetalGaugePalette.track),
            .init(pos: SIMD2(-1, 0.55), color: MetalGaugePalette.track),
            .init(pos: SIMD2(1, 0.55), color: MetalGaugePalette.track),
            .init(pos: SIMD2(-1, -0.55), color: c),
            .init(pos: SIMD2(x, -0.55), color: c),
            .init(pos: SIMD2(-1, 0.55), color: c),
            .init(pos: SIMD2(x, 0.55), color: c),
        ]
        buffer = device.makeBuffer(bytes: &v, length: v.count * MemoryLayout<GaugeVertex>.stride, options: .storageModeShared)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 4, vertexCount: 4)
        enc.endEncoding(); cmd.present(d); cmd.commit()
    }
}

struct MetalBarGauge: NSViewRepresentable {
    var fraction: Double
    var tint: Color

    func makeCoordinator() -> MetalBarRenderer { MetalBarRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: NSRect(x: 0, y: 0, width: 48, height: 8))
        // MTKView has no sensible intrinsic size; without bounds it reports huge
        // preferred sizes and blows out SwiftUI headers/rows.
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoResizeDrawable = true
        v.framebufferOnly = true
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        context.coordinator.attach(v)
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
    }

    /// Honor the SwiftUI proposed size so Metal bars never invent their own scale.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        let width = proposal.width ?? 48
        let height = proposal.height ?? 8
        return CGSize(width: max(width, 1), height: max(height, 1))
    }
}

// MARK: - Activity ring (MCP cards)

@MainActor
final class MetalRingRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var buffer: MTLBuffer?
    private var count = 0
    private var fraction: Float = 0
    private var color = MetalGaugePalette.cyan
    private let lock = NSLock()

    func attach(_ view: MTKView) {
        let mtl = view.device ?? MTLCreateSystemDefaultDevice()
        guard let device = mtl else { return }
        self.device = device
        view.device = device
        view.delegate = self
        view.clearColor = MTLClearColor(red: 0.015, green: 0.03, blue: 0.06, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 24
        queue = device.makeCommandQueue()
        pipeline = MetalGaugePipeline.make(device: device, pixelFormat: view.colorPixelFormat)
        rebuild()
    }

    func set(fraction: Float, color: SIMD4<Float>) {
        lock.lock(); self.fraction = min(max(fraction, 0), 1); self.color = color; lock.unlock()
        rebuild()
    }

    private func rebuild() {
        guard let device else { return }
        lock.lock(); let f = fraction; let c = color; lock.unlock()
        var verts: [GaugeVertex] = []
        let segments = 64
        let outer: Float = 0.88
        let inner: Float = 0.62
        // Background ring full 360
        appendRing(into: &verts, from: 0, to: 1, outer: outer, inner: inner, color: MetalGaugePalette.track, segments: segments)
        // Progress arc (start at top, clockwise)
        if f > 0.001 {
            appendRing(into: &verts, from: 0, to: f, outer: outer, inner: inner, color: c, segments: max(4, Int(Float(segments) * f)))
        }
        count = verts.count
        buffer = device.makeBuffer(bytes: verts, length: max(verts.count, 1) * MemoryLayout<GaugeVertex>.stride, options: .storageModeShared)
    }

    private func appendRing(
        into verts: inout [GaugeVertex],
        from: Float,
        to: Float,
        outer: Float,
        inner: Float,
        color: SIMD4<Float>,
        segments: Int
    ) {
        // Angle: 0 at top (-pi/2), increasing clockwise for "activity" feel
        let start = -Float.pi / 2 + from * Float.pi * 2
        let end = -Float.pi / 2 + to * Float.pi * 2
        let n = max(segments, 2)
        for i in 0..<n {
            let t0 = Float(i) / Float(n)
            let t1 = Float(i + 1) / Float(n)
            let a0 = start + (end - start) * t0
            let a1 = start + (end - start) * t1
            let o0 = SIMD2(cos(a0) * outer, sin(a0) * outer)
            let o1 = SIMD2(cos(a1) * outer, sin(a1) * outer)
            let i0 = SIMD2(cos(a0) * inner, sin(a0) * inner)
            let i1 = SIMD2(cos(a1) * inner, sin(a1) * inner)
            // two triangles
            verts.append(.init(pos: o0, color: color))
            verts.append(.init(pos: i0, color: color))
            verts.append(.init(pos: o1, color: color))
            verts.append(.init(pos: o1, color: color))
            verts.append(.init(pos: i0, color: color))
            verts.append(.init(pos: i1, color: color))
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer, count >= 3,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        enc.endEncoding(); cmd.present(d); cmd.commit()
    }
}

struct MetalRingGauge: NSViewRepresentable {
    var fraction: Double
    var tint: Color
    var label: String = ""

    func makeCoordinator() -> MetalRingRenderer { MetalRingRenderer() }
    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        context.coordinator.attach(v)
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
    }
}

/// Ring with centered text overlay (SwiftUI text + Metal ring).
struct MetalRingGaugeLabeled: View {
    var fraction: Double
    var tint: Color
    var centerText: String

    var body: some View {
        ZStack {
            MetalRingGauge(fraction: fraction, tint: tint)
            Text(centerText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Core bars (all Metal)

@MainActor
final class MetalCoreBarsRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var buffer: MTLBuffer?
    private var count = 0
    private var cores: [Float] = []
    private let lock = NSLock()

    func attach(_ view: MTKView) {
        let mtl = view.device ?? MTLCreateSystemDefaultDevice()
        guard let device = mtl else { return }
        self.device = device
        view.device = device
        view.delegate = self
        view.clearColor = MTLClearColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 20
        queue = device.makeCommandQueue()
        pipeline = MetalGaugePipeline.make(device: device, pixelFormat: view.colorPixelFormat)
        rebuild()
    }

    func set(cores: [Float]) {
        lock.lock(); self.cores = cores; lock.unlock()
        rebuild()
    }

    private func rebuild() {
        guard let device else { return }
        lock.lock(); let cores = self.cores; lock.unlock()
        guard !cores.isEmpty else {
            count = 0
            buffer = nil
            return
        }
        var verts: [GaugeVertex] = []
        let n = cores.count
        let gap: Float = 0.015
        let totalGap = gap * Float(n + 1)
        let barW = (2.0 - totalGap) / Float(n)
        let bottom: Float = -0.9
        let top: Float = 0.9
        let height = top - bottom
        for (i, pct) in cores.enumerated() {
            let p = min(max(pct / 100, 0), 1)
            let x0 = -1 + gap + Float(i) * (barW + gap)
            let x1 = x0 + barW
            // track
            verts.append(contentsOf: quad(x0, bottom, x1, top, MetalGaugePalette.track))
            // fill
            let y1 = bottom + height * p
            let hot = p >= 0.75
            let c = hot ? MetalGaugePalette.orange : MetalGaugePalette.cyan
            verts.append(contentsOf: quad(x0, bottom, x1, y1, c))
        }
        count = verts.count
        buffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GaugeVertex>.stride, options: .storageModeShared)
    }

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: SIMD4<Float>) -> [GaugeVertex] {
        [
            .init(pos: SIMD2(x0, y0), color: c),
            .init(pos: SIMD2(x1, y0), color: c),
            .init(pos: SIMD2(x0, y1), color: c),
            .init(pos: SIMD2(x1, y0), color: c),
            .init(pos: SIMD2(x1, y1), color: c),
            .init(pos: SIMD2(x0, y1), color: c),
        ]
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer, count >= 3,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        enc.endEncoding(); cmd.present(d); cmd.commit()
    }
}

struct MetalCoreBarsView: NSViewRepresentable {
    var cores: [Double]
    func makeCoordinator() -> MetalCoreBarsRenderer { MetalCoreBarsRenderer() }
    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        context.coordinator.attach(v)
        context.coordinator.set(cores: cores.map { Float($0) })
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.set(cores: cores.map { Float($0) })
    }
}

// MARK: - Tool load tile gauge (0–3 tiers as metal fill)

struct MetalToolLoadTile: View {
    var shortLabel: String
    var activity: Double // 0-100
    var health: String
    var loadTier: Int = 0

    var body: some View {
        VStack(spacing: 4) {
            Text(shortLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cyan)
            MetalBarGauge(fraction: min(max(activity / 100, Double(loadTier) / 3.0), 1), tint: healthColor)
                .frame(height: 6)
                .clipShape(Capsule())
            // Load tier as 3 micro Metal bars
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    MetalBarGauge(fraction: loadTier > i ? 1 : 0, tint: healthColor)
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
    }

    private var healthColor: Color {
        TelemetryHealth.tone(for: health).color
    }
}

/// Header status pill with Metal activity bar underneath.
/// Fixed geometry so the upper-right cluster stays toolbar-scale, not MTKView-scale.
struct MetalStatusPill: View {
    var text: String
    var tone: TelemetryStatusTone
    var fraction: Double = 1

    /// Compact chip: fits four across a typical detail header without colliding with the title.
    private let width: CGFloat = 80
    private let barHeight: CGFloat = 3
    private var tint: Color { tone.color }

    var body: some View {
        VStack(spacing: 3) {
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            MetalBarGauge(fraction: max(fraction, 0.05), tint: tint)
                .frame(width: width - 16, height: barHeight)
                .clipShape(Capsule())
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: width, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .stroke(tint.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(tone.rawValue)
    }
}
