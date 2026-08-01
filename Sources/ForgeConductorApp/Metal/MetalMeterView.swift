// MetalMeterView.swift
// What: Retains the semantic meter name used by higher-level views.
// How: A type alias maps that API to the shared MetalBarGauge implementation.
// Why: Call sites express intent while rendering stays consolidated in one gauge module.

import SwiftUI

/// Back-compat alias — all meters use `MetalBarGauge` from MetalGaugeKit.
typealias MetalMeterView = MetalBarGauge
