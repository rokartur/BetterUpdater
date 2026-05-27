//
//  UpdaterLog.swift
//  BetterUpdater
//
//  Package-internal unified logging. Subsystem resolves to the host app's
//  bundle id so updater logs file under the consuming app in Console.app.
//

import Foundation
import os.log
import Security

@inline(__always)
private nonisolated func resolveSubsystem() -> String {
    let bundle = CFBundleGetMainBundle()
    if let cfID = CFBundleGetIdentifier(bundle) {
        return cfID as String
    }
    return "BetterUpdater"
}

struct UpdaterLogCategory: Sendable {
    private let logger: Logger
    private let categoryName: String

    init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.categoryName = category
    }

    @inlinable nonisolated func debug(_ message: String) {
        #if DEBUG
        logger.debug("[\(self.categoryName, privacy: .public)] \(message, privacy: .public)")
        #endif
    }

    @inlinable nonisolated func info(_ message: String) {
        logger.info("[\(self.categoryName, privacy: .public)] \(message, privacy: .public)")
    }

    @inlinable nonisolated func notice(_ message: String) {
        logger.notice("[\(self.categoryName, privacy: .public)] \(message, privacy: .public)")
    }

    @inlinable nonisolated func warn(_ message: String) {
        logger.warning("[\(self.categoryName, privacy: .public)] \(message, privacy: .public)")
    }

    @inlinable nonisolated func error(_ message: String) {
        logger.error("[\(self.categoryName, privacy: .public)] \(message, privacy: .public)")
    }

    @inlinable nonisolated func fault(_ message: String) {
        logger.fault("[\(self.categoryName, privacy: .public)] \(message, privacy: .public)")
    }

    @inlinable nonisolated func error(_ prefix: String, status: OSStatus) {
        logger.error("[\(self.categoryName, privacy: .public)] \(prefix, privacy: .public) status=\(status, privacy: .public)")
    }
}

enum UpdaterLog {
    private static let subsystem: String = resolveSubsystem()
    static let updater = UpdaterLogCategory(subsystem: subsystem, category: "updater")
}
