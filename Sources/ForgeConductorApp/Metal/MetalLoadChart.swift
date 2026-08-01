// MetalLoadChart.swift
// What: Adapts the single-series load renderer to SwiftUI.
// How: NSViewRepresentable creates an MTKView, assigns its coordinator, and
// forwards new sample arrays without rebuilding the native view.
// Why: The adapter isolates AppKit/Metal lifecycle details from dashboard composition.

import SwiftUI
import MetalKit

/// SwiftUI wrapper around an MTKView that draws the load history with Metal.
struct MetalLoadChart: NSViewRepresentable {
    var samples: [Float]

    func makeCoordinator() -> LoadTraceRenderer {
        LoadTraceRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        context.coordinator.attach(to: view)
        context.coordinator.update(samples: samples)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(samples: samples)
    }
}
