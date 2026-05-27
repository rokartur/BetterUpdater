//
//  Ed25519.swift
//  BetterUpdaterManifest
//
//  Thin CryptoKit wrappers for the signing scheme + a full verifier that ties
//  a signed manifest to a pinned public key, a pinned repo identity, and a
//  downloaded asset's bytes. Shared by the CLI (sign) and the app (verify).
//

import Foundation
import CryptoKit

public enum BetterUpdaterCrypto {

    // MARK: - Key handling

    /// Generate a fresh Ed25519 key pair, returned base64-encoded.
    /// The private key is the 32-byte raw seed; keep it secret (CI secret).
    public static func generateKeyPair() -> (privateKeyBase64: String, publicKeyBase64: String) {
        let priv = Curve25519.Signing.PrivateKey()
        return (
            priv.rawRepresentation.base64EncodedString(),
            priv.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    public static func privateKey(fromBase64 base64: String) throws -> Curve25519.Signing.PrivateKey {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CryptoError.invalidBase64("private key")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    public static func publicKey(fromBase64 base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CryptoError.invalidBase64("public key")
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    // MARK: - Sign / verify raw bytes

    /// Sign arbitrary bytes, returning the detached signature base64-encoded.
    public static func sign(_ data: Data, with privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let signature = try privateKey.signature(for: data)
        return signature.base64EncodedString()
    }

    /// Verify a base64 detached signature over `data` against `publicKey`.
    /// Returns false on a bad signature; never throws for the bad-sig case.
    public static func isValidSignature(_ signatureBase64: String, for data: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - Hashing

    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stream a file from disk and return its lowercase hex SHA-256 without
    /// loading the whole file into memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public enum CryptoError: Error, LocalizedError, Equatable {
        case invalidBase64(String)

        public var errorDescription: String? {
            switch self {
            case .invalidBase64(let what): return "Invalid base64 for \(what)."
            }
        }
    }
}

// MARK: - Full verification flow

public enum BetterUpdaterVerifier {

    /// Verify a signed manifest end-to-end.
    ///
    /// - Parameters:
    ///   - manifestData: the RAW bytes of the downloaded manifest file. The
    ///     signature is checked against exactly these bytes (never re-encoded).
    ///   - signatureBase64: detached Ed25519 signature, base64.
    ///   - pinnedPublicKey: the public key baked into (and code-signed with) the app.
    ///   - expectedIdentity: pinned owner/repo/bundleId the manifest must declare.
    ///   - assetName: the asset the client is about to install.
    ///   - assetSize: size of the downloaded asset in bytes.
    ///   - assetSHA256Hex: SHA-256 of the downloaded asset.
    ///   - expectedVersion / expectedBuild: anti-replay — the version/build the
    ///     client believes it is installing (from the release/asset name). When
    ///     supplied, the manifest entry must match, so a valid-but-old signed
    ///     manifest cannot be served for a newer asset.
    /// - Returns: the validated manifest on success.
    public static func verify(
        manifestData: Data,
        signatureBase64: String,
        pinnedPublicKey: Curve25519.Signing.PublicKey,
        expectedIdentity: ExpectedIdentity,
        assetName: String,
        assetSize: Int,
        assetSHA256Hex: String,
        expectedVersion: String? = nil,
        expectedBuild: Int? = nil
    ) throws -> BetterUpdaterManifest {
        // 1) Signature over raw bytes against the pinned key.
        guard BetterUpdaterCrypto.isValidSignature(signatureBase64, for: manifestData, publicKey: pinnedPublicKey) else {
            throw ManifestVerificationError.signatureInvalid
        }

        // 2) Decode only after the signature passes.
        let manifest: BetterUpdaterManifest
        do {
            manifest = try JSONDecoder().decode(BetterUpdaterManifest.self, from: manifestData)
        } catch {
            throw ManifestVerificationError.malformedManifest(error.localizedDescription)
        }

        // 3) Identity: "this repo is really this repo".
        if manifest.owner != expectedIdentity.owner {
            throw ManifestVerificationError.identityMismatch(field: "owner", expected: expectedIdentity.owner, found: manifest.owner)
        }
        if manifest.repo != expectedIdentity.repo {
            throw ManifestVerificationError.identityMismatch(field: "repo", expected: expectedIdentity.repo, found: manifest.repo)
        }
        if manifest.bundleIdentifier != expectedIdentity.bundleIdentifier {
            throw ManifestVerificationError.identityMismatch(field: "bundleIdentifier", expected: expectedIdentity.bundleIdentifier, found: manifest.bundleIdentifier)
        }

        // 4) Asset must be listed.
        guard let entry = manifest.asset(named: assetName) else {
            throw ManifestVerificationError.assetNotListed(name: assetName)
        }

        // 5) Anti-replay: version/build must match what we're installing.
        if let expectedVersion, entry.version != expectedVersion {
            throw ManifestVerificationError.versionMismatch(field: "version", expected: expectedVersion, found: entry.version)
        }
        if let expectedBuild, entry.build != expectedBuild {
            throw ManifestVerificationError.versionMismatch(field: "build", expected: String(expectedBuild), found: String(entry.build))
        }

        // 6) Integrity: size + checksum of the actual downloaded bytes.
        if entry.size != assetSize {
            throw ManifestVerificationError.sizeMismatch(expected: entry.size, found: assetSize)
        }
        let expectedHash = entry.sha256.lowercased()
        let foundHash = assetSHA256Hex.lowercased()
        if expectedHash != foundHash {
            throw ManifestVerificationError.checksumMismatch(expected: expectedHash, found: foundHash)
        }

        return manifest
    }
}
