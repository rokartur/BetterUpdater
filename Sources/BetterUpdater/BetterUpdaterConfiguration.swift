//
//  BetterUpdaterConfiguration.swift
//  BetterUpdater
//
//  Per-app configuration injected once at launch via `BetterUpdater.bootstrap`.
//  Everything that differs between host apps (repo identity, display name,
//  pinned signing key) lives here so the updater engine itself is generic.
//

import Foundation
import CryptoKit
import BetterUpdaterManifest

public struct BetterUpdaterConfiguration: Sendable {
    /// GitHub repository owner (e.g. `rokartur`).
    public let owner: String
    /// GitHub repository name (e.g. `BetterAudio`).
    public let repo: String
    /// User-visible app name used in update UI and helper paths (e.g. `BetterAudio`).
    public let displayName: String
    /// Expected app bundle identifier; asserted against the signed manifest.
    public let bundleIdentifier: String
    /// Ed25519 public key (base64 raw representation) pinned in the app binary.
    /// This is the root of trust for the signed repo-identity manifest.
    public let pinnedPublicKeyBase64: String
    /// Expected Apple Developer Team identifier (cert OU). Optional; when set
    /// it is asserted by the manifest verifier and the Apple code-sign check.
    public let expectedTeamIdentifier: String?
    /// Product token used in the GitHub API `User-Agent` (e.g. `BetterAudio-Updater`).
    public let userAgentProduct: String
    /// When true (default), a missing/invalid signed manifest fails the update
    /// (fail-closed). Set false only for transitional/dev builds.
    public let manifestRequired: Bool

    public init(
        owner: String,
        repo: String,
        displayName: String,
        bundleIdentifier: String,
        pinnedPublicKeyBase64: String,
        expectedTeamIdentifier: String? = nil,
        userAgentProduct: String,
        manifestRequired: Bool = true
    ) {
        self.owner = owner
        self.repo = repo
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.pinnedPublicKeyBase64 = pinnedPublicKeyBase64
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.userAgentProduct = userAgentProduct
        self.manifestRequired = manifestRequired
    }

    /// Pinned identity the signed manifest must declare.
    public var expectedIdentity: ExpectedIdentity {
        ExpectedIdentity(owner: owner, repo: repo, bundleIdentifier: bundleIdentifier)
    }

    /// Decode the pinned public key. Throws if the base64 / key is malformed.
    public func pinnedPublicKey() throws -> Curve25519.Signing.PublicKey {
        try BetterUpdaterCrypto.publicKey(fromBase64: pinnedPublicKeyBase64)
    }
}
