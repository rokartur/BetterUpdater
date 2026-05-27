//
//  betterupdater CLI
//
//  Release-time signing tool for the BetterUpdater signed repo-identity
//  manifest. Used in CI: keygen once, then sign each release's assets, then
//  verify before upload so a key mismatch fails the release instead of
//  shipping an un-verifiable (permanently fail-closed) update.
//

import Foundation
import CryptoKit
import ArgumentParser
import BetterUpdaterManifest

typealias Curve25519Private = Curve25519.Signing.PrivateKey

@main
struct BetterUpdaterTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "betterupdater",
        abstract: "Sign and verify BetterUpdater release manifests (Ed25519).",
        subcommands: [Keygen.self, Sign.self, Verify.self]
    )
}

// MARK: - keygen

struct Keygen: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate an Ed25519 key pair. Keep the private key secret (CI secret); pin the public key in each app."
    )

    @Flag(name: .long, help: "Print only the public key.")
    var publicOnly = false

    func run() throws {
        let pair = BetterUpdaterCrypto.generateKeyPair()
        if publicOnly {
            print(pair.publicKeyBase64)
            return
        }
        print("PRIVATE_KEY (base64, keep secret):")
        print(pair.privateKeyBase64)
        print("")
        print("PUBLIC_KEY (base64, pin in app configuration):")
        print(pair.publicKeyBase64)
    }
}

// MARK: - shared key loading

private enum KeyLoading {
    static func privateKey(inline: String?, file: String?) throws -> Curve25519Private {
        let base64: String
        if let inline, !inline.isEmpty {
            base64 = inline
        } else if let file {
            base64 = try String(contentsOfFile: file, encoding: .utf8)
        } else if let env = ProcessInfo.processInfo.environment["BETTERUPDATER_PRIVATE_KEY"] {
            base64 = env
        } else {
            throw ValidationError("Provide --private-key, --private-key-file, or BETTERUPDATER_PRIVATE_KEY.")
        }
        return try BetterUpdaterCrypto.privateKey(fromBase64: base64)
    }
}

// MARK: - sign

struct Sign: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build + sign a manifest for one release's assets."
    )

    @Option(name: .long, help: "GitHub repository owner (e.g. rokartur).")
    var owner: String

    @Option(name: .long, help: "GitHub repository name (e.g. BetterAudio).")
    var repo: String

    @Option(name: .long, help: "App bundle identifier (e.g. pro.betteraudio.BetterAudio).")
    var bundleId: String

    @Option(name: .long, help: "Apple Developer Team identifier (cert OU). Optional.")
    var teamId: String?

    @Option(name: .long, help: "Marketing version for this release (e.g. 26.6.3).")
    var version: String

    @Option(name: .long, help: "Override build number for all assets (default: parsed from asset filename, else 0).")
    var build: Int?

    @Option(name: .long, parsing: .upToNextOption, help: "Asset file path(s) to include (repeatable).")
    var asset: [String] = []

    @Option(name: .long, help: "Output manifest path (default: ./betterupdater-manifest.json).")
    var out: String = "betterupdater-manifest.json"

    @Option(name: .long, help: "Ed25519 private key (base64).")
    var privateKey: String?

    @Option(name: .long, help: "File containing the Ed25519 private key (base64).")
    var privateKeyFile: String?

    func run() throws {
        guard !asset.isEmpty else { throw ValidationError("At least one --asset is required.") }
        let key = try KeyLoading.privateKey(inline: privateKey, file: privateKeyFile)

        var entries: [BetterUpdaterManifest.Asset] = []
        for path in asset {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
            let sha = try BetterUpdaterCrypto.sha256Hex(ofFileAt: url)
            let resolvedBuild = build ?? Self.parseBuild(fromFileName: name) ?? 0
            entries.append(.init(name: name, version: version, build: resolvedBuild, sha256: sha, size: size))
            FileHandle.standardError.write(Data("signed \(name): sha256=\(sha) size=\(size) build=\(resolvedBuild)\n".utf8))
        }

        let manifest = BetterUpdaterManifest(
            owner: owner, repo: repo, bundleIdentifier: bundleId,
            teamIdentifier: teamId, assets: entries
        )

        // Encode deterministically and sign EXACTLY the bytes we write to disk.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: URL(fileURLWithPath: out))

        let signature = try BetterUpdaterCrypto.sign(manifestData, with: key)
        let sigPath = out + ".sig"
        try Data(signature.utf8).write(to: URL(fileURLWithPath: sigPath))

        print("Wrote \(out) and \(sigPath)")
    }

    /// Parse the trailing -<digits> timestamp build from an asset filename,
    /// e.g. "BetterAudio-26.6.3-20260503141522.dmg" -> 20260503141522.
    static func parseBuild(fromFileName name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        guard let dash = stem.range(of: "-", options: .backwards) else { return nil }
        let tail = String(stem[dash.upperBound...])
        guard tail.count >= 6, tail.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(tail)
    }
}

// MARK: - verify

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verify a manifest + signature against a pinned public key (and optionally asset files)."
    )

    @Option(name: .long, help: "Ed25519 public key (base64).")
    var publicKey: String

    @Option(name: .long, help: "Manifest path.")
    var manifest: String = "betterupdater-manifest.json"

    @Option(name: .long, help: "Signature path (default: <manifest>.sig).")
    var sig: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Asset file path(s) to check against manifest checksums (repeatable).")
    var asset: [String] = []

    func run() throws {
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let sigPath = sig ?? (manifest + ".sig")
        let signature = try String(contentsOfFile: sigPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pub = try BetterUpdaterCrypto.publicKey(fromBase64: publicKey)

        guard BetterUpdaterCrypto.isValidSignature(signature, for: manifestData, publicKey: pub) else {
            FileHandle.standardError.write(Data("FAIL: signature invalid\n".utf8))
            throw ExitCode(2)
        }
        let decoded = try JSONDecoder().decode(BetterUpdaterManifest.self, from: manifestData)
        print("OK: signature valid for \(decoded.owner)/\(decoded.repo) (\(decoded.assets.count) asset(s))")

        for path in asset {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard let entry = decoded.asset(named: name) else {
                FileHandle.standardError.write(Data("FAIL: asset \(name) not in manifest\n".utf8))
                throw ExitCode(3)
            }
            let sha = try BetterUpdaterCrypto.sha256Hex(ofFileAt: url)
            guard sha.lowercased() == entry.sha256.lowercased() else {
                FileHandle.standardError.write(Data("FAIL: \(name) checksum mismatch\n".utf8))
                throw ExitCode(4)
            }
            print("OK: \(name) checksum matches")
        }
    }
}
