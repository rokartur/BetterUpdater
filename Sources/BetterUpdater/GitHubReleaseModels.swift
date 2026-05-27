//
//  GitHubReleaseModels.swift
//  \(BetterUpdater.configuration.displayName)
//
//  Models for GitHub Releases API responses
//

import Foundation

// MARK: - Update Check Interval

public enum UpdateCheckInterval: String, CaseIterable, Identifiable, Codable, Sendable {
    case manual = "manual"
    case automatic = "automatic"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual:
            return String(localized: "Manual", table: "Updater", bundle: .module)
        case .automatic:
            return String(localized: "Automatic", table: "Updater", bundle: .module)
        }
    }

    public var description: String {
        switch self {
        case .manual:
            return String(localized: "Only check when you click the button", table: "Updater", bundle: .module)
        case .automatic:
            return String(localized: "Automatically check and install updates", table: "Updater", bundle: .module)
        }
    }

    /// Interval in seconds (nil for manual).
    /// DEBUG builds poll hourly so update plumbing changes surface fast;
    /// release builds stay on the 24h cadence users expect.
    public var interval: TimeInterval? {
        switch self {
        case .manual:
            return nil
        case .automatic:
            #if DEBUG
            return 60 * 60 // 1 hour
            #else
            return 24 * 60 * 60 // 24 hours
            #endif
        }
    }
}

// MARK: - GitHub Release Response

public struct GitHubRelease: Codable, Sendable {
    public let id: Int
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let createdAt: Date
    public let publishedAt: Date?
    public let htmlUrl: String
    public let assets: [GitHubAsset]
    
    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case htmlUrl = "html_url"
        case assets
    }
    
    /// Extract semantic version from tag (removes 'v' prefix if present)
    public var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
    
    /// Find the macOS app asset. Prefers .dmg over .zip; within each, prefers
    /// names that explicitly mention "macos".
    public var macOSAsset: GitHubAsset? {
        let extensions = ["dmg", "zip"]
        for ext in extensions {
            let suffix = "." + ext
            if let preferred = assets.first(where: {
                $0.name.lowercased().hasSuffix(suffix) && $0.name.lowercased().contains("macos")
            }) {
                return preferred
            }
            if let any = assets.first(where: { $0.name.lowercased().hasSuffix(suffix) }) {
                return any
            }
        }
        return nil
    }
}

// MARK: - GitHub Asset

public struct GitHubAsset: Codable, Sendable {
    public let id: Int
    public let name: String
    public let label: String?
    public let state: String
    public let contentType: String
    public let size: Int
    public let downloadCount: Int
    public let browserDownloadUrl: String
    public let createdAt: Date
    public let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case label
        case state
        case contentType = "content_type"
        case size
        case downloadCount = "download_count"
        case browserDownloadUrl = "browser_download_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    /// Human-readable file size
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Build number embedded in asset filename (e.g. \(BetterUpdater.configuration.displayName)-1.0.0-20260503141522.dmg → 20260503141522)
    public var buildNumber: Int? {
        let baseName = name.components(separatedBy: ".").dropLast().joined(separator: ".")
        return baseName.components(separatedBy: "-").last.flatMap { Int($0) }
    }
}

// MARK: - Update Check Result

enum UpdateCheckResult: Sendable {
    case upToDate
    case updateAvailable(release: GitHubRelease)
    case error(UpdateError)
}

// MARK: - Update Error

enum UpdateError: Error, LocalizedError, Sendable {
    case networkError(String)
    case invalidResponse
    case noReleasesFound
    case parsingError(String)
    case downloadFailed(String)
    case installationFailed(String)
    case verificationFailed(String)
    case userCancelled

    public var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid response from GitHub"
        case .noReleasesFound:
            return "No releases found"
        case .parsingError(let message):
            return "Failed to parse release info: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .installationFailed(let message):
            return "Installation failed: \(message)"
        case .verificationFailed(let message):
            return message
        case .userCancelled:
            return "Update cancelled"
        }
    }
}

// MARK: - Update State

public enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case available(version: String, releaseNotes: String?)
    case downloading(progress: Double)
    case readyToInstall(localURL: URL)
    case installing(progress: Double, step: String)
    case error(String)
    case upToDate
    
    public static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.checking, .checking),
             (.upToDate, .upToDate):
            return true
        case (.available(let v1, let n1), .available(let v2, let n2)):
            return v1 == v2 && n1 == n2
        case (.downloading(let p1), .downloading(let p2)):
            return p1 == p2
        case (.readyToInstall(let u1), .readyToInstall(let u2)):
            return u1 == u2
        case (.installing(let p1, let s1), .installing(let p2, let s2)):
            return p1 == p2 && s1 == s2
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        default:
            return false
        }
    }
}
