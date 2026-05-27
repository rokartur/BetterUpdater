//
//  UpdaterUIHelpers.swift
//  BetterUpdater
//
//  Small UI helpers the ported AppKit views depend on. These mirror app-level
//  utilities that lived outside the original Updater folder.
//

import Foundation

/// Programmatic AppKit views never support `init?(coder:)`. Calling this from a
/// required coder init documents intent and traps clearly if it's ever hit.
func fatalCoderNotImplemented(
    file: StaticString = #file,
    line: UInt = #line
) -> Never {
    fatalError("init(coder:) has not been implemented — this view is created programmatically", file: file, line: line)
}

/// Subset of the host app's Liquid Glass variant table. Only the values the
/// update window needs are kept; `rawValue` matches AppKit's private
/// `NSGlassEffectView` `_variant` numbering.
enum LiquidGlassVariant: Int, Sendable {
    case regular = 0
    case clear = 1

    static var bestSupportedVariant: LiquidGlassVariant {
        if #available(macOS 26.2, *) {
            return .clear
        }
        return .regular
    }
}
