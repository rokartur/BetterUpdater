import XCTest
import Foundation
import CryptoKit
@testable import BetterUpdaterManifest

final class ManifestSignatureTests: XCTestCase {

    private func makeKeys() throws -> (priv: Curve25519.Signing.PrivateKey, pub: Curve25519.Signing.PublicKey) {
        let pair = BetterUpdaterCrypto.generateKeyPair()
        let priv = try BetterUpdaterCrypto.privateKey(fromBase64: pair.privateKeyBase64)
        let pub = try BetterUpdaterCrypto.publicKey(fromBase64: pair.publicKeyBase64)
        return (priv, pub)
    }

    // MARK: - Raw sign / verify

    func testSignVerifyRoundTrip() throws {
        let (priv, pub) = try makeKeys()
        let data = Data("hello manifest".utf8)
        let sig = try BetterUpdaterCrypto.sign(data, with: priv)
        XCTAssertTrue(BetterUpdaterCrypto.isValidSignature(sig, for: data, publicKey: pub))
    }

    func testTamperedDataFailsVerification() throws {
        let (priv, pub) = try makeKeys()
        var data = Data("hello manifest".utf8)
        let sig = try BetterUpdaterCrypto.sign(data, with: priv)
        data[0] ^= 0xFF // flip a byte
        XCTAssertFalse(BetterUpdaterCrypto.isValidSignature(sig, for: data, publicKey: pub))
    }

    func testTamperedSignatureFailsVerification() throws {
        let (priv, pub) = try makeKeys()
        let data = Data("hello manifest".utf8)
        let sig = try BetterUpdaterCrypto.sign(data, with: priv)
        // Corrupt the signature: decode, flip a byte, re-encode.
        var sigBytes = Data(base64Encoded: sig)!
        sigBytes[0] ^= 0xFF
        let badSig = sigBytes.base64EncodedString()
        XCTAssertFalse(BetterUpdaterCrypto.isValidSignature(badSig, for: data, publicKey: pub))
    }

    func testWrongKeyFailsVerification() throws {
        let (priv, _) = try makeKeys()
        let (_, otherPub) = try makeKeys()
        let data = Data("hello manifest".utf8)
        let sig = try BetterUpdaterCrypto.sign(data, with: priv)
        XCTAssertFalse(BetterUpdaterCrypto.isValidSignature(sig, for: data, publicKey: otherPub))
    }

    // MARK: - Why we verify raw bytes, never re-encoded JSON

    func testReEncodingChangesBytesAndBreaksSignature() throws {
        let (priv, pub) = try makeKeys()
        // Deliberately non-canonical JSON: keys out of order + extra whitespace.
        // This is the shape a hand-written / differently-serialized manifest can
        // take. We sign the RAW bytes.
        let rawJSON = """
        {
            "repo": "BetterAudio",
            "owner": "rokartur",
            "formatVersion": 1,
            "bundleIdentifier": "pro.betteraudio.BetterAudio",
            "teamIdentifier": "ABCDE12345",
            "assets": []
        }
        """
        let rawData = Data(rawJSON.utf8)
        let sig = try BetterUpdaterCrypto.sign(rawData, with: priv)

        // Verifying the raw bytes succeeds.
        XCTAssertTrue(BetterUpdaterCrypto.isValidSignature(sig, for: rawData, publicKey: pub))

        // Decoding then re-encoding produces different bytes (sorted keys, no
        // pretty whitespace) — so the signature must NOT validate against them.
        let decoded = try JSONDecoder().decode(BetterUpdaterManifest.self, from: rawData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reEncoded = try encoder.encode(decoded)
        XCTAssertNotEqual(rawData, reEncoded, "Re-encoded JSON should differ from the raw bytes")
        XCTAssertFalse(
            BetterUpdaterCrypto.isValidSignature(sig, for: reEncoded, publicKey: pub),
            "Signature must only validate against the exact signed bytes"
        )
    }

    // MARK: - Full verifier flow

    /// Build a signed manifest for a single asset and return everything the
    /// verifier needs. The signature is over the EXACT bytes we hand back.
    private func makeSignedManifest(
        owner: String = "rokartur",
        repo: String = "BetterAudio",
        bundleId: String = "pro.betteraudio.BetterAudio",
        assetName: String = "BetterAudio-26.6.3-20260503141522.dmg",
        version: String = "26.6.3",
        build: Int = 20260503141522,
        assetBytes: Data
    ) throws -> (manifestData: Data, sig: String, pub: Curve25519.Signing.PublicKey, sha: String, size: Int) {
        let (priv, pub) = try makeKeys()
        let sha = BetterUpdaterCrypto.sha256Hex(of: assetBytes)
        let manifest = BetterUpdaterManifest(
            owner: owner, repo: repo, bundleIdentifier: bundleId,
            teamIdentifier: "ABCDE12345",
            assets: [.init(name: assetName, version: version, build: build, sha256: sha, size: assetBytes.count)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(manifest)
        let sig = try BetterUpdaterCrypto.sign(data, with: priv)
        return (data, sig, pub, sha, assetBytes.count)
    }

    func testVerifierHappyPath() throws {
        let assetBytes = Data((0..<2048).map { UInt8($0 & 0xFF) })
        let m = try makeSignedManifest(assetBytes: assetBytes)
        let result = try BetterUpdaterVerifier.verify(
            manifestData: m.manifestData,
            signatureBase64: m.sig,
            pinnedPublicKey: m.pub,
            expectedIdentity: ExpectedIdentity(owner: "rokartur", repo: "BetterAudio", bundleIdentifier: "pro.betteraudio.BetterAudio"),
            assetName: "BetterAudio-26.6.3-20260503141522.dmg",
            assetSize: m.size,
            assetSHA256Hex: m.sha,
            expectedVersion: "26.6.3",
            expectedBuild: 20260503141522
        )
        XCTAssertEqual(result.owner, "rokartur")
        XCTAssertEqual(result.assets.count, 1)
    }

    func testVerifierRejectsWrongIdentity() throws {
        let assetBytes = Data("app".utf8)
        let m = try makeSignedManifest(assetBytes: assetBytes)
        XCTAssertThrowsError(try BetterUpdaterVerifier.verify(
            manifestData: m.manifestData, signatureBase64: m.sig, pinnedPublicKey: m.pub,
            expectedIdentity: ExpectedIdentity(owner: "attacker", repo: "BetterAudio", bundleIdentifier: "pro.betteraudio.BetterAudio"),
            assetName: "BetterAudio-26.6.3-20260503141522.dmg", assetSize: m.size, assetSHA256Hex: m.sha
        )) { error in
            guard case ManifestVerificationError.identityMismatch(let field, _, _) = error else {
                return XCTFail("expected identityMismatch, got \(error)")
            }
            XCTAssertEqual(field, "owner")
        }
    }

    func testVerifierRejectsChecksumMismatch() throws {
        let assetBytes = Data("app".utf8)
        let m = try makeSignedManifest(assetBytes: assetBytes)
        XCTAssertThrowsError(try BetterUpdaterVerifier.verify(
            manifestData: m.manifestData, signatureBase64: m.sig, pinnedPublicKey: m.pub,
            expectedIdentity: ExpectedIdentity(owner: "rokartur", repo: "BetterAudio", bundleIdentifier: "pro.betteraudio.BetterAudio"),
            assetName: "BetterAudio-26.6.3-20260503141522.dmg", assetSize: m.size,
            assetSHA256Hex: BetterUpdaterCrypto.sha256Hex(of: Data("different".utf8))
        )) { error in
            guard case ManifestVerificationError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testVerifierRejectsReplayedVersion() throws {
        let assetBytes = Data("app".utf8)
        let m = try makeSignedManifest(assetBytes: assetBytes) // manifest says 26.6.3
        XCTAssertThrowsError(try BetterUpdaterVerifier.verify(
            manifestData: m.manifestData, signatureBase64: m.sig, pinnedPublicKey: m.pub,
            expectedIdentity: ExpectedIdentity(owner: "rokartur", repo: "BetterAudio", bundleIdentifier: "pro.betteraudio.BetterAudio"),
            assetName: "BetterAudio-26.6.3-20260503141522.dmg", assetSize: m.size, assetSHA256Hex: m.sha,
            expectedVersion: "27.0.0" // client expects a newer version than the (old, valid) manifest
        )) { error in
            guard case ManifestVerificationError.versionMismatch = error else {
                return XCTFail("expected versionMismatch, got \(error)")
            }
        }
    }

    func testVerifierRejectsUnlistedAsset() throws {
        let assetBytes = Data("app".utf8)
        let m = try makeSignedManifest(assetBytes: assetBytes)
        XCTAssertThrowsError(try BetterUpdaterVerifier.verify(
            manifestData: m.manifestData, signatureBase64: m.sig, pinnedPublicKey: m.pub,
            expectedIdentity: ExpectedIdentity(owner: "rokartur", repo: "BetterAudio", bundleIdentifier: "pro.betteraudio.BetterAudio"),
            assetName: "not-in-manifest.dmg", assetSize: m.size, assetSHA256Hex: m.sha
        )) { error in
            guard case ManifestVerificationError.assetNotListed = error else {
                return XCTFail("expected assetNotListed, got \(error)")
            }
        }
    }
}
