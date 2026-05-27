//
//  BetterUpdater.swift
//  BetterUpdater
//
//  Public entry point. Host apps call `BetterUpdater.bootstrap(configuration:)`
//  once at launch (before any updater use), then access `BetterUpdater.shared`.
//

import Foundation

public enum BetterUpdater {

    // Set once at launch, then read-only. Guarded by the bootstrap contract
    // (call on the main thread during app startup before any updater access).
    nonisolated(unsafe) private static var _configuration: BetterUpdaterConfiguration?

    /// Install the per-app configuration. Call once, early in app launch,
    /// before `shared` or any other updater type is used. Validates the pinned
    /// public key immediately so a malformed key fails fast at startup.
    public static func bootstrap(configuration: BetterUpdaterConfiguration) {
        do {
            _ = try configuration.pinnedPublicKey()
        } catch {
            preconditionFailure("BetterUpdater.bootstrap: pinned public key is invalid: \(error)")
        }
        _configuration = configuration
    }

    /// The active configuration. Traps if `bootstrap` was not called.
    public static var configuration: BetterUpdaterConfiguration {
        guard let configuration = _configuration else {
            preconditionFailure("BetterUpdater.bootstrap(configuration:) must be called before using BetterUpdater")
        }
        return configuration
    }

    /// Whether `bootstrap` has run. Useful for guarding optional integrations.
    public static var isConfigured: Bool { _configuration != nil }

    /// The shared updater instance. Drives `@Published` state for SwiftUI/AppKit.
    @MainActor
    public static var shared: GitHubUpdater { GitHubUpdater.shared }
}
