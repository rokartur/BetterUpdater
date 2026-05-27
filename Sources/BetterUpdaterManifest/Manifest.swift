//
//  Manifest.swift
//  BetterUpdaterManifest
//
//  The signed repo-identity manifest. This is the document an Ed25519
//  signature is computed over. It binds a GitHub release's downloadable
//  assets to a specific repository identity and per-asset checksums, so a
//  client that pins the matching public key can prove "this asset really
//  came from this repo" — beyond what Apple code-signing alone tells you.
//
//  IMPORTANT: verification is always performed over the RAW on-disk bytes of
//  the manifest file, never over a re-encoded copy. `JSONEncoder` output is
//  not byte-stable (key ordering / whitespace / number formatting), so
//  decoding and re-encoding would change the bytes and break the signature.
//  Decode only AFTER the signature check passes, purely to read fields.
//

import Foundation

/// The signed manifest shipped as a release asset (`betterupdater-manifest.json`).
public struct BetterUpdaterManifest: Codable, Equatable, Sendable {
    /// Schema version so future changes can be detected/migrated.
    public let formatVersion: Int
    /// GitHub repository owner this release belongs to (e.g. `rokartur`).
    public let owner: String
    /// GitHub repository name (e.g. `BetterAudio`).
    public let repo: String
    /// Expected app bundle identifier (e.g. `pro.betteraudio.BetterAudio`).
    public let bundleIdentifier: String
    /// Expected Apple Developer Team identifier (cert OU). Optional but
    /// recommended; lets the client cross-check the manifest against the
    /// downloaded bundle's code signature.
    public let teamIdentifier: String?
    /// One entry per downloadable macOS asset in the release.
    public let assets: [Asset]

    public struct Asset: Codable, Equatable, Sendable {
        /// Exact asset file name as uploaded to the release
        /// (e.g. `BetterAudio-26.6.3-20260503141522.dmg`).
        public let name: String
        /// Marketing version (e.g. `26.6.3`).
        public let version: String
        /// Timestamp-style build number embedded in the asset name.
        public let build: Int
        /// Lowercase hex SHA-256 of the asset bytes.
        public let sha256: String
        /// Asset size in bytes (defense-in-depth sanity check).
        public let size: Int

        public init(name: String, version: String, build: Int, sha256: String, size: Int) {
            self.name = name
            self.version = version
            self.build = build
            self.sha256 = sha256
            self.size = size
        }
    }

    public init(
        formatVersion: Int = BetterUpdaterManifest.currentFormatVersion,
        owner: String,
        repo: String,
        bundleIdentifier: String,
        teamIdentifier: String?,
        assets: [Asset]
    ) {
        self.formatVersion = formatVersion
        self.owner = owner
        self.repo = repo
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.assets = assets
    }

    public static let currentFormatVersion = 1

    /// Standard asset name for the manifest itself when uploaded to a release.
    public static let assetFileName = "betterupdater-manifest.json"
    /// Standard asset name for the detached signature.
    public static let signatureAssetFileName = "betterupdater-manifest.json.sig"

    /// Find the manifest entry for a given asset file name.
    public func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }
}

/// The set of identity claims a client pins and checks the manifest against.
public struct ExpectedIdentity: Equatable, Sendable {
    public let owner: String
    public let repo: String
    public let bundleIdentifier: String

    public init(owner: String, repo: String, bundleIdentifier: String) {
        self.owner = owner
        self.repo = repo
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Result of validating a manifest against pinned identity + a downloaded asset.
public enum ManifestVerificationError: Error, Equatable, Sendable {
    case signatureInvalid
    case malformedManifest(String)
    case identityMismatch(field: String, expected: String, found: String)
    case assetNotListed(name: String)
    case checksumMismatch(expected: String, found: String)
    case sizeMismatch(expected: Int, found: Int)
    case versionMismatch(field: String, expected: String, found: String)
    case publicKeyInvalid
}

extension ManifestVerificationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .signatureInvalid:
            return "Update manifest signature is invalid."
        case .malformedManifest(let detail):
            return "Update manifest is malformed: \(detail)"
        case .identityMismatch(let field, let expected, let found):
            return "Update manifest \(field) mismatch (expected \(expected), found \(found))."
        case .assetNotListed(let name):
            return "Downloaded asset \(name) is not listed in the signed manifest."
        case .checksumMismatch(let expected, let found):
            return "Downloaded asset checksum mismatch (expected \(expected), found \(found))."
        case .sizeMismatch(let expected, let found):
            return "Downloaded asset size mismatch (expected \(expected) bytes, found \(found))."
        case .versionMismatch(let field, let expected, let found):
            return "Manifest \(field) mismatch (expected \(expected), found \(found))."
        case .publicKeyInvalid:
            return "Pinned public key is invalid."
        }
    }
}
