// ResourceBundle.swift
// What: Resolves packaged resources under both SwiftPM and Xcode framework layouts.
// How: Conditional bundle lookup prefers SwiftPM's generated bundle and otherwise uses
// a private token class to locate the containing Xcode framework.
// Why: Callers should not contain build-system-specific resource path logic.

import Foundation

/// Resource bundle that works for both SwiftPM (`Bundle.module`) and the Xcode framework target.
enum ResourceBundle {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
