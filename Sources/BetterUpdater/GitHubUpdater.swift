//
//  GitHubUpdater.swift
//  BetterUpdater
//
//  Custom updater using GitHub Releases API + signed repo-identity manifest.
//  No external dependencies beyond Apple frameworks + BetterUpdaterManifest.
//

import Foundation
import AppKit
import Combine
import Security
import CryptoKit
import BetterUpdaterManifest

// MARK: - GitHub Updater Configuration

/// Static + per-app configuration. The per-app values (owner/repo/userAgent)
/// are routed through `BetterUpdater.configuration`, set at launch via
/// `BetterUpdater.bootstrap(configuration:)`.
enum GitHubUpdaterConfig {
    /// GitHub repository owner
    static var owner: String { BetterUpdater.configuration.owner }

    /// GitHub repository name
    static var repo: String { BetterUpdater.configuration.repo }

    /// GitHub API base URL
    static let apiBaseURL = "https://api.github.com"

    /// GitHub API version header
    static let apiVersion = "2022-11-28"

    /// User agent for API requests. Includes app version so GitHub-side
    /// telemetry can attribute requests to a specific build.
    static var userAgent: String {
        "\(BetterUpdater.configuration.userAgentProduct)/\(HostAppInfo.appVersion) (\(HostAppInfo.appBuildNumber))"
    }

    /// Minimum interval between manual checks (in seconds) - 60 seconds
    static let minManualCheckInterval: TimeInterval = 60

    /// Retry delay after a failed silent check. Short enough that transient
    /// network blips recover quickly; long enough to not hammer GitHub.
    static let errorRetryInterval: TimeInterval = 15 * 60

    /// Cadence forced while the beta channel is enabled, so testers pick up
    /// new pre-release builds quickly regardless of the chosen cadence.
    static let betaCheckInterval: TimeInterval = 60 * 60 // 1 hour

    /// Default check interval
    static let defaultCheckInterval: UpdateCheckInterval = .automatic
}

struct ParsedVersion: Equatable, Comparable {
    public let core: [Int]
    public let prerelease: [String]

    init(_ raw: String) {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreStr = String(parts.first ?? "")
        self.core = coreStr.split(separator: ".").compactMap { Int($0) }
        if parts.count > 1 {
            self.prerelease = parts[1].split(separator: ".").map(String.init)
        } else {
            self.prerelease = []
        }
    }

    public static func < (lhs: ParsedVersion, rhs: ParsedVersion) -> Bool {
        let maxCount = max(lhs.core.count, rhs.core.count)
        let l = lhs.core + Array(repeating: 0, count: maxCount - lhs.core.count)
        let r = rhs.core + Array(repeating: 0, count: maxCount - rhs.core.count)
        for componentIndex in 0..<maxCount {
            if l[componentIndex] != r[componentIndex] {
                return l[componentIndex] < r[componentIndex]
            }
        }
        // Cores equal — per semver, a prerelease has lower precedence than the corresponding stable.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false):
            let minCount = min(lhs.prerelease.count, rhs.prerelease.count)
            for prereleaseIndex in 0..<minCount {
                let a = lhs.prerelease[prereleaseIndex]
                let b = rhs.prerelease[prereleaseIndex]
                if a == b { continue }
                if let ai = Int(a), let bi = Int(b) {
                    return ai < bi
                }
                return a < b
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }
}

struct GitHubUpdateDecision: Equatable {
    public let isUpdateAvailable: Bool
    public let isNewerBuild: Bool

    struct Input {
        let currentVersion: String
        let latestVersion: String
        let currentBuildNumber: Int
        let remoteBuildNumber: Int?
        /// `updated_at` from the GitHub asset metadata. Used to detect stable
        /// re-uploads where the version + asset filename are unchanged but
        /// the bits behind the URL differ (`buildNumber` parser returns nil
        /// for "\(BetterUpdater.configuration.displayName)-26.6.2.dmg" since there's no embedded timestamp).
        var remoteAssetUpdatedAt: Date? = nil
        /// Previously-seen `updated_at` for this exact version, persisted per
        /// version in UserDefaults. nil means we've never recorded a baseline
        /// — first detection is silent so we don't pop a popup for an asset
        /// that was already on disk before this feature shipped.
        var lastSeenAssetUpdatedAt: Date? = nil
    }

    public static func evaluate(_ input: Input) -> GitHubUpdateDecision {
        let current = ParsedVersion(input.currentVersion)
        let latest = ParsedVersion(input.latestVersion)

        // Build-number fallback fires when both releases share the same semantic
        // core (e.g. 26.6.3 vs 26.6.3-beta.2). MARKETING_VERSION drops the
        // -beta.N suffix, so betas of the same core can only be told apart by
        // the timestamp-based CURRENT_PROJECT_VERSION.
        let coresMatch = current.core == latest.core
        let newerBuild: Bool = {
            guard coresMatch else { return false }
            if let remoteBuild = input.remoteBuildNumber {
                return remoteBuild > input.currentBuildNumber
            }
            // Stable assets have no embedded build timestamp in the filename.
            // Use the asset's `updated_at` against the per-version baseline
            // so a re-uploaded same-version DMG is still offered as an update.
            // First sighting (no baseline) doesn't trigger — we just record
            // the baseline below in `checkForUpdates` so future re-uploads do.
            if current == latest,
               let remoteUpdatedAt = input.remoteAssetUpdatedAt,
               let baseline = input.lastSeenAssetUpdatedAt,
               remoteUpdatedAt > baseline {
                return true
            }
            return false
        }()

        let updateAvailable = current < latest || newerBuild

        return GitHubUpdateDecision(
            isUpdateAvailable: updateAvailable,
            isNewerBuild: newerBuild
        )
    }

    /// Compare two semantic versions, including prerelease tags.
    /// Returns true if version1 is newer than version2.
    public static func isNewerVersion(_ version1: String, than version2: String) -> Bool {
        ParsedVersion(version2) < ParsedVersion(version1)
    }
}

// MARK: - LastInstallAttempt breadcrumb

/// Diagnostic record of the most recent install handoff. Persisted to
/// UserDefaults so that on the next launch we can detect silent failures
/// (helper script exits non-zero after the parent process already quit)
/// and surface them to the user instead of repeating the popup forever.
public struct LastInstallAttempt: Codable, Equatable {
    public enum Stage: String, Codable {
        /// Handoff to the installer helper succeeded; awaiting verification on next boot.
        case handoffSpawned
        /// Handoff itself threw — manual install dialog already shown.
        case handoffFailed
        /// On boot we observed the installed version didn't match the staged version
        /// and enough time elapsed that the helper should have finished.
        case helperExited
        /// On boot we observed the installed version matches — install succeeded.
        case succeeded
    }

    public let version: String
    public let attemptedAt: Date
    public var stage: Stage
    public var errorMessage: String?
    public var helperLogTail: String?
}

// MARK: - GitHub Updater

@MainActor
public final class GitHubUpdater: ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = GitHubUpdater()
    
    // MARK: - Published Properties
    
    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var latestRelease: GitHubRelease?
    @Published public private(set) var lastCheckDate: Date?
    @Published public private(set) var checkInterval: UpdateCheckInterval = GitHubUpdaterConfig.defaultCheckInterval
    /// True when same version but the remote has a newer build number
    @Published public private(set) var isNewerBuild: Bool = false
    @Published public var automaticDownloadEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticDownloadEnabled, forKey: "GitHubUpdater.automaticDownloadEnabled")
        }
    }
    @Published public var automaticInstallEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticInstallEnabled, forKey: "GitHubUpdater.automaticInstallEnabled")
        }
    }
    @Published public var includePreReleases: Bool {
        didSet {
            UserDefaults.standard.set(includePreReleases, forKey: "GitHubUpdater.includePreReleases")
            // Beta channel forces an hourly cadence — re-arm the scheduler so
            // toggling beta takes effect immediately.
            if includePreReleases != oldValue { rescheduleAutomaticCheck() }
        }
    }
    @Published public var skippedVersion: String? {
        didSet {
            if let v = skippedVersion {
                UserDefaults.standard.set(v, forKey: "GitHubUpdater.skippedVersion")
            } else {
                UserDefaults.standard.removeObject(forKey: "GitHubUpdater.skippedVersion")
            }
        }
    }
    /// Latest version the auto-popup was last shown for. Combined with
    /// `lastAutoShownAt` to suppress repeat auto-popups within the snooze
    /// window — without this, every auto-check (boot, 24h cadence) would
    /// re-pop the same version the user already dismissed.
    @Published public private(set) var lastAutoShownVersion: String? {
        didSet {
            if let v = lastAutoShownVersion {
                UserDefaults.standard.set(v, forKey: "GitHubUpdater.lastAutoShownVersion")
            } else {
                UserDefaults.standard.removeObject(forKey: "GitHubUpdater.lastAutoShownVersion")
            }
        }
    }
    @Published public private(set) var lastAutoShownAt: Date? {
        didSet {
            if let d = lastAutoShownAt {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "GitHubUpdater.lastAutoShownAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "GitHubUpdater.lastAutoShownAt")
            }
        }
    }
    /// Most recent install handoff, used to detect silent helper failures
    /// across launches. `nil` means no install has been attempted (clean state).
    @Published public private(set) var lastInstallAttempt: LastInstallAttempt? {
        didSet {
            if let attempt = lastInstallAttempt,
               let data = try? JSONEncoder().encode(attempt) {
                UserDefaults.standard.set(data, forKey: "GitHubUpdater.lastInstallAttempt")
            } else {
                UserDefaults.standard.removeObject(forKey: "GitHubUpdater.lastInstallAttempt")
            }
        }
    }

    /// Set check interval - call this from UI instead of direct binding
    public func setCheckInterval(_ interval: UpdateCheckInterval) {
        guard interval != checkInterval else { return }
        checkInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "GitHubUpdater.checkInterval")
        rescheduleAutomaticCheck()
    }
    
    // MARK: - Private Properties
    
    private var downloadTask: URLSessionDownloadTask?
    private var downloadProgressObservation: NSKeyValueObservation?
    private var automaticCheckTask: Task<Void, Never>?
    private let urlSession: URLSession
    private var downloadedFileURL: URL?
    /// Timestamp of the last failed silent check. Used by the scheduler to
    /// retry sooner than the next full interval after a network blip.
    private var lastFailureDate: Date?
    
    // MARK: - Computed Properties
    
    /// Whether automatic checks are enabled (not manual)
    public var automaticChecksEnabled: Bool {
        checkInterval != .manual
    }

    /// Interval the scheduler actually uses. Beta channel forces the hourly
    /// cadence; Manual disables automatic checks entirely.
    public var effectiveCheckInterval: TimeInterval? {
        guard checkInterval != .manual else { return nil }
        if includePreReleases { return GitHubUpdaterConfig.betaCheckInterval }
        return checkInterval.interval
    }

    // MARK: - Initialization
    
    private init() {
        // Restore the user's chosen cadence (default: daily/24h). Persisted by
        // setCheckInterval(_:). Unknown/legacy values fall back to the default.
        let storedInterval = UserDefaults.standard.string(forKey: "GitHubUpdater.checkInterval")
        self.checkInterval = storedInterval.flatMap(UpdateCheckInterval.init(rawValue:)) ?? GitHubUpdaterConfig.defaultCheckInterval
        self.automaticDownloadEnabled = UserDefaults.standard.object(forKey: "GitHubUpdater.automaticDownloadEnabled") as? Bool ?? false
        self.automaticInstallEnabled = UserDefaults.standard.object(forKey: "GitHubUpdater.automaticInstallEnabled") as? Bool ?? true
        self.includePreReleases = UserDefaults.standard.object(forKey: "GitHubUpdater.includePreReleases") as? Bool ?? false
        // "Skip This Version" tooltip promises "don't remind me about this version"
        // — honour that across launches. Auto-popup snooze (lastAutoShownAt)
        // still re-prompts when a NEW version ships even if user skipped older.
        self.skippedVersion = UserDefaults.standard.string(forKey: "GitHubUpdater.skippedVersion")
        self.lastAutoShownVersion = UserDefaults.standard.string(forKey: "GitHubUpdater.lastAutoShownVersion")
        let lastShownTS = UserDefaults.standard.double(forKey: "GitHubUpdater.lastAutoShownAt")
        self.lastAutoShownAt = lastShownTS > 0 ? Date(timeIntervalSince1970: lastShownTS) : nil
        if let data = UserDefaults.standard.data(forKey: "GitHubUpdater.lastInstallAttempt") {
            self.lastInstallAttempt = try? JSONDecoder().decode(LastInstallAttempt.self, from: data)
        } else {
            self.lastInstallAttempt = nil
        }

        // Restore lastCheckDate so the auto-check cadence is wall-clock based:
        // if the previous check ran at 13:00, the next one fires at 13:00 the
        // following day (or +1h in DEBUG) regardless of relaunches/sleep.
        let storedTimestamp = UserDefaults.standard.double(forKey: "GitHubUpdater.lastCheckDate")
        self.lastCheckDate = storedTimestamp > 0 ? Date(timeIntervalSince1970: storedTimestamp) : nil
        
        // Configure URL session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": GitHubUpdaterConfig.apiVersion,
            "User-Agent": GitHubUpdaterConfig.userAgent
        ]
        self.urlSession = URLSession(configuration: config)
        
        UpdaterLog.updater.info("GitHubUpdater initialized with check interval: \(checkInterval.rawValue)")

        // Detect whether the previous in-app install actually landed so the
        // UI can surface silent helper failures instead of repeating the loop.
        verifyPreviousInstall()

        // Sweep archives left from prior sessions (downloads that were never
        // installed, or installs that bypassed per-archive cleanup). Detached
        // so file IO never blocks app launch.
        Task.detached { GitHubUpdater.purgeStaleDownloads() }

        // Schedule automatic check if not manual
        rescheduleAutomaticCheck()
    }
    
    deinit {
        downloadProgressObservation?.invalidate()
        downloadTask?.cancel()
    }
    
    // MARK: - Public Methods
    
    /// Check for updates
    /// - Parameter force: If true, bypasses the minimum check interval
    public func checkForUpdates(force: Bool = false) async {
        // Don't trample an in-flight install. A scheduled auto-check that
        // fires while a download/install is mid-handoff would flip `state`
        // back to `.checking`, dropping the progress UI on the floor.
        switch state {
        case .downloading, .installing, .readyToInstall:
            UpdaterLog.updater.debug("Skipping scheduled check — install in progress (state=\(String(describing: state)))")
            return
        default:
            break
        }

        // Check if we should skip based on recent check
        if !force, let lastCheck = lastCheckDate {
            let elapsed = Date().timeIntervalSince(lastCheck)
            if elapsed < GitHubUpdaterConfig.minManualCheckInterval {
                UpdaterLog.updater.debug("Skipping update check - last check was \(Int(elapsed))s ago")
                return
            }
        }

        // Manual checks (force=true) always surface errors. Silent autoruns
        // bottle them up into `.idle` so we don't drum up an .error popup on
        // every transient network blip.
        let isSilent = !force

        state = .checking
        UpdaterLog.updater.info("Checking for updates... (silent: \(isSilent))")

        do {
            let release = try await fetchLatestRelease()
            latestRelease = release
            lastCheckDate = Date()
            lastFailureDate = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "GitHubUpdater.lastCheckDate")

            let currentVersion = HostAppInfo.appVersion
            let latestVersion = release.version
            let remoteAssetUpdatedAt = release.macOSAsset?.updatedAt
            let lastSeenAssetUpdatedAtKey = "GitHubUpdater.lastSeenAssetUpdatedAt.\(latestVersion)"
            let lastSeenTS = UserDefaults.standard.double(forKey: lastSeenAssetUpdatedAtKey)
            let lastSeenAssetUpdatedAt: Date? = lastSeenTS > 0 ? Date(timeIntervalSince1970: lastSeenTS) : nil

            UpdaterLog.updater.info("Current version: \(currentVersion) (\(HostAppInfo.appBuildNumber)), Latest version: \(latestVersion) (\(release.macOSAsset?.buildNumber.map(String.init) ?? "?"))")

            let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                currentBuildNumber: Int(HostAppInfo.appBuildNumber) ?? 0,
                remoteBuildNumber: release.macOSAsset?.buildNumber,
                remoteAssetUpdatedAt: remoteAssetUpdatedAt,
                lastSeenAssetUpdatedAt: lastSeenAssetUpdatedAt
            ))

            // Persist the baseline so a future re-upload of this same version
            // is detected as a newer build. We record after evaluating so the
            // first sighting is silent (no popup for "the asset already on
            // disk before this feature shipped").
            if let remoteAssetUpdatedAt {
                UserDefaults.standard.set(remoteAssetUpdatedAt.timeIntervalSince1970, forKey: lastSeenAssetUpdatedAtKey)
            }

            if decision.isUpdateAvailable {
                // Skip if user chose to skip this version (unless force/manual check)
                // Don't skip beta→stable or asset-updated transitions
                if !force, !decision.isNewerBuild, let skipped = skippedVersion, skipped == latestVersion {
                    UpdaterLog.updater.info("Skipping version \(latestVersion) (user skipped)")
                    state = .idle
                    return
                }

                isNewerBuild = decision.isNewerBuild

                if decision.isNewerBuild {
                    UpdaterLog.updater.notice("Newer build available for version \(latestVersion) (same version, newer build number)")
                } else {
                    UpdaterLog.updater.notice("Update available: \(latestVersion)")
                }
                state = .available(version: latestVersion, releaseNotes: release.body)

                // Auto-popup gate: suppress repeat pops within the snooze window
                // for the same version. Menu badge still reflects .available so
                // the user can re-open via the menubar. Forced (manual) checks
                // and version-change events always pop fresh.
                if force || shouldAutoPresentUpdateWindow(forVersion: latestVersion) {
                    lastAutoShownVersion = latestVersion
                    lastAutoShownAt = Date()
                    UpdateWindowPresenter.shared.show()
                } else {
                    UpdaterLog.updater.info("Suppressing auto-popup for \(latestVersion) (snoozed by user — menu badge still active)")
                }
            } else {
                isNewerBuild = false
                UpdaterLog.updater.info("App is up to date")
                state = .upToDate
            }
        } catch {
            let errorMessage = (error as? UpdateError)?.localizedDescription ?? error.localizedDescription
            UpdaterLog.updater.error("Update check failed: \(errorMessage)")
            lastFailureDate = Date()
            if !isSilent {
                state = .error(errorMessage)
            } else {
                // Silent failure - reset to idle
                state = .idle
            }
        }

        // Re-anchor the automatic loop. Success paths align the next fire
        // to lastCheckDate + interval; failure paths trigger a shorter retry
        // via lastFailureDate + errorRetryInterval.
        rescheduleAutomaticCheck()
    }

    /// Download the latest update
    public func downloadUpdate() async {
        guard let release = latestRelease,
              let asset = release.macOSAsset else {
            state = .error(String(localized: "No downloadable asset found", table: "Updater", bundle: .module))
            UpdaterLog.updater.error("No macOS asset found in release")
            return
        }
        
        guard let url = URL(string: asset.browserDownloadUrl) else {
            state = .error(String(localized: "Invalid download URL", table: "Updater", bundle: .module))
            return
        }
        
        state = .downloading(progress: 0)
        UpdaterLog.updater.info("Downloading update from: \(url.absoluteString)")
        
        do {
            let localURL = try await downloadFile(from: url, fileName: asset.name)
            // Gate: the downloaded asset must match a signed repo-identity
            // manifest before we ever offer to install. Fail-closed when
            // `manifestRequired` (the default).
            try await verifyReleaseManifest(release: release, asset: asset, downloadedAsset: localURL)
            downloadedFileURL = localURL
            // Drop any older archives now that the new one is verified, so a
            // download the user never installs can't leave the prior build behind.
            GitHubUpdater.purgeStaleDownloads(keeping: localURL)
            state = .readyToInstall(localURL: localURL)
            UpdaterLog.updater.notice("Download complete and verified: \(localURL.path)")
        } catch {
            let errorMessage = (error as? UpdateError)?.localizedDescription ?? error.localizedDescription
            UpdaterLog.updater.error("Download failed: \(errorMessage)")
            state = .error(errorMessage)
        }
    }

    // MARK: - Signed repo-identity manifest verification

    /// Verify the downloaded asset against the release's signed manifest.
    /// This is the "this repo is really this repo" gate: an Ed25519 signature
    /// over a manifest that binds repo identity + per-asset checksums, checked
    /// against the public key pinned in the app via `BetterUpdaterConfiguration`.
    ///
    /// When `manifestRequired` is true (default), any missing/invalid manifest
    /// fails the update (fail-closed) so an attacker controlling the API/CDN
    /// cannot strip the manifest to downgrade to the Apple-codesign-only path.
    private func verifyReleaseManifest(release: GitHubRelease, asset: GitHubAsset, downloadedAsset: URL) async throws {
        let config = BetterUpdater.configuration

        // Manifest + signature must live in the SAME release's asset list.
        let manifestAsset = release.assets.first { $0.name == BetterUpdaterManifest.assetFileName }
        let signatureAsset = release.assets.first { $0.name == BetterUpdaterManifest.signatureAssetFileName }

        guard let manifestAsset, let signatureAsset else {
            if config.manifestRequired {
                UpdaterLog.updater.error("Manifest/signature asset missing and manifestRequired=true — refusing update.")
                throw UpdateError.verificationFailed(String(localized: "This release is not signed with a verification manifest.", table: "Updater", bundle: .module))
            }
            UpdaterLog.updater.warn("Manifest/signature asset missing; manifestRequired=false — skipping verification.")
            return
        }

        let pinnedKey: Curve25519.Signing.PublicKey
        do {
            pinnedKey = try config.pinnedPublicKey()
        } catch {
            throw UpdateError.verificationFailed(String(localized: "Update verification key is invalid.", table: "Updater", bundle: .module))
        }

        do {
            // Manifest + signature are tiny; fetch into memory. Verification is
            // performed over the RAW manifest bytes (never re-encoded JSON).
            let manifestData = try await fetchData(from: manifestAsset.browserDownloadUrl)
            let signatureString = try await fetchString(from: signatureAsset.browserDownloadUrl)

            let assetSize = ((try? FileManager.default.attributesOfItem(atPath: downloadedAsset.path))?[.size] as? Int) ?? asset.size
            let assetHash = try BetterUpdaterCrypto.sha256Hex(ofFileAt: downloadedAsset)

            _ = try BetterUpdaterVerifier.verify(
                manifestData: manifestData,
                signatureBase64: signatureString,
                pinnedPublicKey: pinnedKey,
                expectedIdentity: config.expectedIdentity,
                assetName: asset.name,
                assetSize: assetSize,
                assetSHA256Hex: assetHash,
                expectedVersion: release.version,
                expectedBuild: asset.buildNumber
            )
            UpdaterLog.updater.notice("Signed manifest verified for \(asset.name) (\(release.version)).")
        } catch let error as ManifestVerificationError {
            UpdaterLog.updater.error("Manifest verification failed: \(error.localizedDescription)")
            throw UpdateError.verificationFailed(error.errorDescription ?? String(localized: "Update verification failed.", table: "Updater", bundle: .module))
        } catch let error as UpdateError {
            throw error
        } catch {
            if config.manifestRequired {
                UpdaterLog.updater.error("Could not fetch manifest assets: \(error.localizedDescription)")
                throw UpdateError.verificationFailed(String(localized: "Could not verify the update’s signature.", table: "Updater", bundle: .module))
            }
            UpdaterLog.updater.warn("Manifest fetch failed; manifestRequired=false — skipping. \(error.localizedDescription)")
        }
    }

    private func fetchData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw UpdateError.invalidResponse }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.networkError("HTTP error fetching \(url.lastPathComponent)")
        }
        return data
    }

    private func fetchString(from urlString: String) async throws -> String {
        let data = try await fetchData(from: urlString)
        guard let string = String(data: data, encoding: .utf8) else { throw UpdateError.invalidResponse }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Download and install update in one step (one-click update)
    public func downloadAndInstall() async {
        await downloadUpdate()
        
        // If download was successful, proceed to install
        if case .readyToInstall = state {
            await installUpdate()
        }
    }
    
    /// Install the downloaded update
    public func installUpdate() async {
        guard case .readyToInstall(let localURL) = state else {
            UpdaterLog.updater.warn("No update ready to install")
            return
        }

        state = .installing(progress: 0.0, step: String(localized: "Starting installation…", table: "Updater", bundle: .module))
        UpdaterLog.updater.info("Installing update from: \(localURL.path)")

        do {
            try await performInstallation(from: localURL)
        } catch {
            let errorMessage = (error as? UpdateError)?.localizedDescription ?? error.localizedDescription
            UpdaterLog.updater.error("Installation failed: \(errorMessage)")
            state = .error(errorMessage)
        }
    }
    
    /// Open the GitHub releases page
    public func openReleasesPage() {
        let url = URL(string: "https://github.com/\(GitHubUpdaterConfig.owner)/\(GitHubUpdaterConfig.repo)/releases")!
        NSWorkspace.shared.open(url)
    }
    
    /// Open the latest release page
    public func openLatestReleasePage() {
        if let release = latestRelease, let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        } else {
            openReleasesPage()
        }
    }
    
    /// Cancel any ongoing download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgressObservation?.invalidate()
        downloadProgressObservation = nil
        
        if case .available(let version, let notes) = state {
            // Stay on available state
            state = .available(version: version, releaseNotes: notes)
        } else {
            state = .idle
        }
        
        UpdaterLog.updater.info("Download cancelled")
    }
    
    /// Reset state to idle without side effects (e.g. after "up to date" auto-dismiss)
    public func resetToIdle() {
        state = .idle
    }

    /// Reset state to idle
    public func reset() {
        cancelDownload()
        state = .idle
        isNewerBuild = false
        
        // Clean up any downloaded files
        if let url = downloadedFileURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                UpdaterLog.updater.warn("Failed to remove downloaded update file at \(url.path): \(error.localizedDescription)")
            }
            downloadedFileURL = nil
        }
    }

    /// Skip the currently offered update version
    public func skipCurrentUpdate() {
        if let version = latestRelease?.version {
            skippedVersion = version
            UpdaterLog.updater.info("User skipped version \(version)")
        }
        state = .idle
    }

    /// Close update window without skipping — popup re-appears only after the
    /// auto-show snooze window expires (`autoShowSnoozeInterval`) or when a
    /// newer version ships. The menu bar update button stays in `.available`
    /// so the user can re-open the window on demand.
    public func remindLater() {
        if let version = latestRelease?.version {
            lastAutoShownVersion = version
            lastAutoShownAt = Date()
            UpdaterLog.updater.info("User chose 'Remind Me Later' for \(version); auto-popup snoozed for \(Int(Self.autoShowSnoozeInterval / 86400))d")
        } else {
            UpdaterLog.updater.info("User chose 'Remind Me Later'")
        }
        UpdateWindowPresenter.shared.hide()
    }

    /// How long an auto-popup stays snoozed for the same version after the
    /// user dismisses it. Forced checks (menu "Check for Updates") and a
    /// genuinely newer version always bypass the snooze. Matches the
    /// "Remind me in 3 days" button label in `UpdateWindowView`.
    nonisolated static let autoShowSnoozeInterval: TimeInterval = 3 * 24 * 60 * 60

    /// Whether the auto-popup should fire for `version` right now. False when
    /// the user already saw (and dismissed) the same version within the
    /// snooze window. Always true when the version changed since the last
    /// auto-show, or the snooze has expired.
    private func shouldAutoPresentUpdateWindow(forVersion version: String) -> Bool {
        Self.shouldAutoPresentUpdateWindow(
            forVersion: version,
            lastAutoShownVersion: lastAutoShownVersion,
            lastAutoShownAt: lastAutoShownAt,
            now: Date(),
            snoozeInterval: Self.autoShowSnoozeInterval
        )
    }

    /// Pure form of the snooze gate, suitable for unit testing without an
    /// `@MainActor` instance or live `Date()` calls.
    nonisolated static func shouldAutoPresentUpdateWindow(
        forVersion version: String,
        lastAutoShownVersion: String?,
        lastAutoShownAt: Date?,
        now: Date,
        snoozeInterval: TimeInterval
    ) -> Bool {
        guard let lastShownVersion = lastAutoShownVersion,
              lastShownVersion == version,
              let lastShownAt = lastAutoShownAt else {
            return true
        }
        return now.timeIntervalSince(lastShownAt) >= snoozeInterval
    }
    
    // MARK: - Private Methods
    
    private func fetchLatestRelease() async throws -> GitHubRelease {
        let endpoint: String
        
        if includePreReleases {
            // Fetch all releases and get the first one
            endpoint = "\(GitHubUpdaterConfig.apiBaseURL)/repos/\(GitHubUpdaterConfig.owner)/\(GitHubUpdaterConfig.repo)/releases?per_page=1"
        } else {
            // Use the latest release endpoint (excludes prereleases)
            endpoint = "\(GitHubUpdaterConfig.apiBaseURL)/repos/\(GitHubUpdaterConfig.owner)/\(GitHubUpdaterConfig.repo)/releases/latest"
        }
        
        guard let url = URL(string: endpoint) else {
            throw UpdateError.networkError("Invalid URL")
        }
        
        let (data, response) = try await urlSession.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw UpdateError.noReleasesFound
            }
            throw UpdateError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if includePreReleases {
            // Response is an array
            let releases = try decoder.decode([GitHubRelease].self, from: data)
            guard let firstRelease = releases.first else {
                throw UpdateError.noReleasesFound
            }
            return firstRelease
        } else {
            // Response is a single release
            return try decoder.decode(GitHubRelease.self, from: data)
        }
    }
    
    private func downloadFile(from url: URL, fileName: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: UpdateError.downloadFailed("Updater deallocated"))
                return
            }
            
            let task = self.urlSession.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        continuation.resume(throwing: UpdateError.userCancelled)
                    } else {
                        continuation.resume(throwing: UpdateError.downloadFailed(error.localizedDescription))
                    }
                    return
                }
                
                guard let tempURL = tempURL else {
                    continuation.resume(throwing: UpdateError.downloadFailed("No file downloaded"))
                    return
                }
                
                // Move to a permanent location
                let destinationDir: URL

                do {
                    destinationDir = try GitHubUpdater.updaterDownloadDirectoryURL()
                } catch {
                    continuation.resume(throwing: UpdateError.downloadFailed("Failed to prepare updater directory: \(error.localizedDescription)"))
                    return
                }

                // Keep original filename for easier debugging/manual support.
                let destinationURL = destinationDir.appendingPathComponent(fileName)

                let fileManager = FileManager.default
                
                do {
                    // Remove existing file if present
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: UpdateError.downloadFailed("Failed to save file: \(error.localizedDescription)"))
                }
            }
            
            // Observe download progress BEFORE `task.resume()` — a short
            // download can complete before a deferred observer install fires,
            // leaving the UI stuck at 0%. `downloadFile` only runs from
            // `downloadUpdate` which is `@MainActor`, so we're guaranteed to
            // be on main here.
            let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in
                    self?.state = .downloading(progress: value)
                }
            }

            MainActor.assumeIsolated {
                self.downloadProgressObservation = observation
                self.downloadTask = task
            }
            task.resume()
        }
    }
    
    private func performInstallation(from url: URL) async throws {
        switch url.pathExtension.lowercased() {
        case "zip":
            try await installFromZip(at: url)
        case "dmg":
            try await installFromDmg(at: url)
        default:
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            await showInstallationInstructions(manual: true)
        }
    }

    
    private func updateInstallProgress(_ progress: Double, step: String) async {
        state = .installing(progress: progress, step: step)
        // Small delay to make progress visible
        try? await Task.sleep(for: .milliseconds(300))
    }
    
    private func installFromZip(at url: URL) async throws {
        let fileManager = FileManager.default

        // Cleanup the original archive only on error paths — the success path
        // explicitly removes it before `installApp` because `installApp` calls
        // `NSApplication.terminate(nil)`, which short-circuits any `defer`.
        // Without the explicit pre-handoff cleanup the .zip would leak to
        // `~/Library/Application Support/\(BetterUpdater.configuration.displayName)/UpdaterDownloads/` on
        // every install (silent disk bloat).
        var handedOff = false
        defer {
            if !handedOff {
                removeDownloadedArchiveIfNeeded(at: url)
            }
        }

        // Step 1: Prepare installation
        await updateInstallProgress(0.05, step: String(localized: "Preparing installation…", table: "Updater", bundle: .module))

        // Unzip to temp directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("\(BetterUpdater.configuration.displayName)_Update_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Step 2: Extracting archive
        await updateInstallProgress(0.15, step: String(localized: "Extracting archive…", table: "Updater", bundle: .module))

        let unzipStatus = try await runProcessAndWait(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", url.path, "-d", tempDir.path]
        )

        guard unzipStatus == 0 else {
            throw UpdateError.installationFailed("Failed to unzip update")
        }

        // Step 3: Verifying contents
        await updateInstallProgress(0.35, step: String(localized: "Verifying contents…", table: "Updater", bundle: .module))

        // Find the .app bundle in extracted files
        let appBundle = try await findFirstAppBundle(in: tempDir)

        // Cleanup the original archive now (before handoff) because
        // `installApp` calls `NSApplication.terminate(nil)` and any `defer`
        // we leave for cleanup would never fire.
        removeDownloadedArchiveIfNeeded(at: url)
        handedOff = true

        // Hand off to the installer helper. installApp terminates this process,
        // and the helper consumes `appBundle` via `mv` after we exit. Do NOT
        // remove `tempDir` here — that would race the helper and leave the user
        // with the old build still in /Applications.
        try await installApp(from: appBundle)
    }

    private func installFromDmg(at url: URL) async throws {
        let fileManager = FileManager.default

        // See `installFromZip` — defer fires only on error paths because
        // success path terminates the process before any defer would run.
        var handedOff = false
        defer {
            if !handedOff {
                removeDownloadedArchiveIfNeeded(at: url)
            }
        }

        await updateInstallProgress(0.05, step: String(localized: "Preparing installation…", table: "Updater", bundle: .module))

        // Mount with a private random mountpoint so we never collide with an
        // existing mount of the same volume name.
        let mountpoint = fileManager.temporaryDirectory
            .appendingPathComponent("\(BetterUpdater.configuration.displayName)_DMG_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountpoint, withIntermediateDirectories: true)

        await updateInstallProgress(0.15, step: String(localized: "Mounting disk image…", table: "Updater", bundle: .module))

        let attachStatus = try await runProcessAndWait(
            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: [
                "attach",
                "-nobrowse",
                "-quiet",
                "-noverify",
                "-readonly",
                "-mountpoint", mountpoint.path,
                url.path
            ]
        )

        guard attachStatus == 0 else {
            try? await removeItemIfExists(at: mountpoint)
            throw UpdateError.installationFailed("Failed to mount disk image")
        }

        // Always detach, even on failure. Force-detach on the second attempt
        // in case a child process briefly held the mount open.
        @Sendable func detach() async {
            let status = (try? await self.runProcessAndWait(
                executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", "-quiet", mountpoint.path]
            )) ?? -1
            if status != 0 {
                _ = try? await self.runProcessAndWait(
                    executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["detach", "-quiet", "-force", mountpoint.path]
                )
            }
        }

        let stagingDir = fileManager.temporaryDirectory
            .appendingPathComponent("\(BetterUpdater.configuration.displayName)_DmgStage_\(UUID().uuidString)", isDirectory: true)

        do {
            await updateInstallProgress(0.30, step: String(localized: "Verifying contents…", table: "Updater", bundle: .module))

            let mountedApp = try await findFirstAppBundle(in: mountpoint)

            // Copy out of the read-only mount into a writable staging dir so the
            // installer helper can `mv` the bundle into /Applications.
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let stagedApp = stagingDir.appendingPathComponent(mountedApp.lastPathComponent)

            await updateInstallProgress(0.45, step: String(localized: "Extracting archive…", table: "Updater", bundle: .module))

            let dittoStatus = try await runProcessAndWait(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [mountedApp.path, stagedApp.path]
            )
            guard dittoStatus == 0 else {
                throw UpdateError.installationFailed("Failed to extract app from disk image")
            }

            // Unmount before handing off — the helper script doesn't need the DMG anymore.
            await detach()

            // Cleanup the original .dmg now (before handoff) since
            // `installApp` calls `NSApplication.terminate(nil)` and the
            // outer `defer` would never fire.
            removeDownloadedArchiveIfNeeded(at: url)
            handedOff = true

            // installApp terminates this process; the helper consumes
            // `stagedApp` after we exit. Do NOT clean `stagingDir` here —
            // that would race the helper and leave the user with the old
            // build still in /Applications.
            try await installApp(from: stagedApp)
        } catch {
            await detach()
            try? await removeItemIfExists(at: stagingDir)
            try? await removeItemIfExists(at: mountpoint)
            throw error
        }
    }


    private func removeDownloadedArchiveIfNeeded(at url: URL) {
        let fileManager = FileManager.default
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" || ext == "dmg" else { return }

        // Safety: remove only the exact archive that this updater downloaded.
        guard let trackedDownloadedURL = downloadedFileURL,
              trackedDownloadedURL.standardizedFileURL == url.standardizedFileURL else {
            UpdaterLog.updater.debug("Skipping archive cleanup for untracked zip: \(url.path)")
            return
        }

        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                UpdaterLog.updater.debug("Removed downloaded archive: \(url.path)")
            } catch {
                UpdaterLog.updater.warn("Failed to remove downloaded archive at \(url.path): \(error.localizedDescription)")
            }
        }

        if downloadedFileURL == url {
            downloadedFileURL = nil
        }
    }

    nonisolated private static func updaterDownloadDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupportDir = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let updaterDir = appSupportDir
            .appendingPathComponent("\(BetterUpdater.configuration.displayName)", isDirectory: true)
            .appendingPathComponent("UpdaterDownloads", isDirectory: true)

        if !fileManager.fileExists(atPath: updaterDir.path) {
            try fileManager.createDirectory(at: updaterDir, withIntermediateDirectories: true)
        }

        return updaterDir
    }

    /// Remove leftover archives in `UpdaterDownloads`, optionally keeping one.
    ///
    /// `removeDownloadedArchiveIfNeeded` only cleans the single archive this
    /// process downloaded, so stale `.dmg`/`.zip` pile up when a download is
    /// never installed (user quits at `readyToInstall`) or when an earlier
    /// version was installed via a path that bypassed that cleanup. Without
    /// this sweep the directory grows unbounded across releases.
    ///
    /// Staged bundles handed to the installer live in `temporaryDirectory`,
    /// not here — so a full sweep on launch never races an in-flight install.
    nonisolated static func purgeStaleDownloads(keeping keepURL: URL? = nil) {
        let fileManager = FileManager.default
        guard let dir = try? updaterDownloadDirectoryURL(),
              let entries = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }

        let keepStandardized = keepURL?.standardizedFileURL
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            guard ext == "zip" || ext == "dmg" else { continue }
            if let keepStandardized, entry.standardizedFileURL == keepStandardized { continue }
            do {
                try fileManager.removeItem(at: entry)
                UpdaterLog.updater.debug("Purged stale download: \(entry.path)")
            } catch {
                UpdaterLog.updater.warn("Failed to purge stale download at \(entry.path): \(error.localizedDescription)")
            }
        }
    }

    private func installApp(from sourceApp: URL) async throws {
        // Determine target. Prefer the running bundle's location when it's
        // already in /Applications; otherwise install into /Applications.
        // The translocation gate at app launch (AppTranslocation.guardLaunchLocation)
        // ensures we are NOT running translocated by this point.
        let currentAppURL = Bundle.main.bundleURL
        let applicationsDir = URL(fileURLWithPath: "/Applications")

        let targetAppURL: URL
        if currentAppURL.path.hasPrefix("/Applications/") {
            targetAppURL = applicationsDir.appendingPathComponent(currentAppURL.lastPathComponent)
        } else if automaticInstallEnabled {
            targetAppURL = applicationsDir.appendingPathComponent(sourceApp.lastPathComponent)
        } else {
            targetAppURL = currentAppURL.deletingLastPathComponent()
                .appendingPathComponent(sourceApp.lastPathComponent)
        }

        UpdaterLog.updater.info("Installing app from \(sourceApp.path) to \(targetAppURL.path)")

        // Verify Developer ID + bundle ID match the running build before swap.
        try await validateDownloadedAppBundle(at: sourceApp)

        await updateInstallProgress(0.55, step: String(localized: "Preparing installer…", table: "Updater", bundle: .module))

        // Record the attempt BEFORE handoff so that if anything past this
        // point silently kills us, the next launch's boot probe sees the
        // breadcrumb and can flip stage→.helperExited.
        let stagedVersion = latestRelease?.version ?? HostAppInfo.appVersion
        lastInstallAttempt = LastInstallAttempt(
            version: stagedVersion,
            attemptedAt: Date(),
            stage: .handoffSpawned,
            errorMessage: nil,
            helperLogTail: nil
        )

        // Hand off to the external installer. It waits for this process to
        // exit, swaps the bundle, strips quarantine, and relaunches.
        do {
            try await UpdateInstallerHelper.handoffSwap(
                stagedAppURL: sourceApp,
                targetAppURL: targetAppURL,
                removeSource: true
            )
        } catch UpdateInstallerHelper.HandoffError.authorizationDenied {
            UpdaterLog.updater.notice("User cancelled installer authorization — falling back to manual install")
            recordInstallHandoffFailure(version: stagedVersion, message: "Authorization cancelled")
            NSWorkspace.shared.selectFile(sourceApp.path, inFileViewerRootedAtPath: sourceApp.deletingLastPathComponent().path)
            await showInstallationInstructions(manual: true)
            return
        } catch {
            UpdaterLog.updater.error("Installer handoff failed: \(error.localizedDescription) — falling back to manual install")
            recordInstallHandoffFailure(version: stagedVersion, message: error.localizedDescription)
            NSWorkspace.shared.selectFile(sourceApp.path, inFileViewerRootedAtPath: sourceApp.deletingLastPathComponent().path)
            await showInstallationInstructions(manual: true)
            return
        }

        await updateInstallProgress(0.95, step: String(localized: "Restarting \(BetterUpdater.configuration.displayName)…", table: "Updater", bundle: .module))
        try? await Task.sleep(for: .milliseconds(200))

        // Helper takes over once we exit; terminate so it can complete the swap.
        UpdaterLog.updater.notice("Quitting to allow installer helper to finish")
        await MainActor.run {
            NSApplication.shared.terminate(nil)
        }
    }
    
    @MainActor
    private func showInstallationInstructions(manual: Bool) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Update Downloaded", table: "Updater", bundle: .module)
        alert.informativeText = String(localized: "The update has been downloaded. Please drag the new \(BetterUpdater.configuration.displayName) app to your Applications folder to complete the installation.\n\nAfter installation, restart \(BetterUpdater.configuration.displayName).", table: "Updater", bundle: .module)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK", table: "Updater", bundle: .module))
        alert.addButton(withTitle: String(localized: "Open Applications Folder", table: "Updater", bundle: .module))
        
        let response = alert.runModal()
        
        if response == .alertSecondButtonReturn {
            // Open Applications folder
            if let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first {
                NSWorkspace.shared.open(applicationsURL)
            }
        }
        
        state = .idle
    }

    private func runProcessAndWait(executableURL: URL, arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    private func findFirstAppBundle(in directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.installationFailed("No app bundle found in archive")
            }
            return appBundle
        }.value
    }

    private func removeItemIfExists(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }.value
    }

    private func validateDownloadedAppBundle(at appURL: URL) async throws {
        let expectedBundleIdentifier = Bundle.main.bundleIdentifier
        let expectedTeamIdentifier = Self.currentTeamIdentifier()

        try await Task.detached(priority: .userInitiated) {
            try Self.validateAppBundleSignature(
                at: appURL,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier
            )
        }.value
    }

    nonisolated private static func validateAppBundleSignature(
        at appURL: URL,
        expectedBundleIdentifier: String?,
        expectedTeamIdentifier: String?
    ) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            throw UpdateError.installationFailed("Invalid app bundle signature")
        }

        var requirementParts: [String] = ["anchor apple generic"]
        if let expectedBundleIdentifier, !expectedBundleIdentifier.isEmpty {
            requirementParts.append("identifier \"\(escapedRequirementValue(expectedBundleIdentifier))\"")
        }
        if let expectedTeamIdentifier, !expectedTeamIdentifier.isEmpty {
            requirementParts.append("certificate leaf[subject.OU] = \"\(escapedRequirementValue(expectedTeamIdentifier))\"")
        }

        var requirement: SecRequirement?
        let requirementString = requirementParts.joined(separator: " and ")
        guard SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.installationFailed("Invalid update signing requirement")
        }

        let status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement
        )
        guard status == errSecSuccess else {
            // Pull the downloaded bundle's actual identifier + team so the
            // breadcrumb can show "expected X.beta vs got X" — without this,
            // a bundle-id channel mismatch (stable ↔ beta) reads as a generic
            // signature failure and the support team has no signal.
            let actualBundleId = readBundleIdentifier(at: appURL)
            let actualTeamId = readTeamIdentifier(at: appURL)
            let expected = "\(expectedBundleIdentifier ?? "<nil>")/\(expectedTeamIdentifier ?? "<nil>")"
            let actual = "\(actualBundleId ?? "<nil>")/\(actualTeamId ?? "<nil>")"
            throw UpdateError.installationFailed("Update signature verification failed (OSStatus \(status)). Expected \(expected); got \(actual). Did the release ship from a different signing channel?")
        }
    }

    nonisolated private static func readBundleIdentifier(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    nonisolated private static func readTeamIdentifier(at appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func currentTeamIdentifier() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            return nil
        }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func escapedRequirementValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func rescheduleAutomaticCheck() {
        cancelAutomaticCheck()

        // Only schedule if not manual. Beta channel forces the hourly cadence.
        guard let interval = effectiveCheckInterval else {
            UpdaterLog.updater.debug("Automatic update checks disabled (manual mode)")
            return
        }

        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                let nextDate = await self.computeNextCheckDate(interval: interval)
                let delay = nextDate.timeIntervalSinceNow

                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }

                guard !Task.isCancelled else { break }

                await self.checkForUpdates(force: false)

                // checkForUpdates calls rescheduleAutomaticCheck which cancels
                // this task and spawns a fresh one. Exit cleanly.
                break
            }
        }

        UpdaterLog.updater.debug("Automatic update checks scheduled: \(checkInterval.title)")
    }

    /// Compute the next wall-clock moment the auto-check should fire.
    /// - Anchors to `lastCheckDate + interval` so a check at 13:00 today
    ///   reliably fires at 13:00 tomorrow regardless of relaunches/sleep.
    /// - Clamps an anchor that lives in the future (clock skew / user moved
    ///   the system clock backwards) so we don't stall for years.
    /// - Honours `lastFailureDate + errorRetryInterval` to retry sooner after
    ///   a network blip, never later than the regular cadence.
    private func computeNextCheckDate(interval: TimeInterval) -> Date {
        let now = Date()
        let rawAnchor = lastCheckDate ?? now
        let safeAnchor = rawAnchor > now ? now : rawAnchor
        let successNext = safeAnchor.addingTimeInterval(interval)

        guard let failure = lastFailureDate,
              failure > (lastCheckDate ?? .distantPast) else {
            return successNext
        }

        let safeFailure = failure > now ? now : failure
        let retryNext = safeFailure.addingTimeInterval(GitHubUpdaterConfig.errorRetryInterval)
        return min(successNext, retryNext)
    }
    
    private func cancelAutomaticCheck() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    // MARK: - Install attempt breadcrumb

    /// Path to the bash helper's log. Persists across launches; tailed by
    /// `verifyPreviousInstall()` so the support team can ask the user to
    /// hit "Copy Diagnostics" instead of hunting for a path inside `TMPDIR`.
    nonisolated public static var helperLogURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(BetterUpdater.configuration.displayName)InstallHelper.log")
    }

    /// Window in which a recent handoff is "still booting up" — used so the
    /// boot probe doesn't immediately flag a helperExited state right after
    /// a successful install that's still propagating through LaunchServices.
    nonisolated static let postHandoffGracePeriod: TimeInterval = 5 * 60

    /// Pure form of the boot-probe verdict. Returns the new stage given
    /// the recorded attempt, the installed version, and the current time.
    /// `nil` means "leave the existing stage alone" (within grace period).
    nonisolated static func verifyPreviousInstallDecision(
        attempt: LastInstallAttempt,
        installedVersion: String,
        now: Date,
        gracePeriod: TimeInterval
    ) -> LastInstallAttempt.Stage? {
        let attemptedVersionParsed = ParsedVersion(attempt.version)
        let installedParsed = ParsedVersion(installedVersion)
        let versionsMatch = (installedParsed == attemptedVersionParsed) || installedVersion == attempt.version

        switch attempt.stage {
        case .succeeded, .helperExited, .handoffFailed:
            return nil
        case .handoffSpawned:
            if versionsMatch { return .succeeded }
            let elapsed = now.timeIntervalSince(attempt.attemptedAt)
            if elapsed >= gracePeriod { return .helperExited }
            return nil
        }
    }

    /// Maximum lines of the helper log to embed in the breadcrumb (kept small
    /// so a `Copy Diagnostics` paste stays comfortably under the typical 4 KB
    /// Slack/Discord paste cutoff).
    nonisolated public static let helperLogTailLineCap = 20

    /// Maximum bytes we read from the helper log when computing the tail.
    nonisolated static let helperLogReadByteCap = 1 * 1024 * 1024

    private func recordInstallHandoffFailure(version: String, message: String) {
        lastInstallAttempt = LastInstallAttempt(
            version: version,
            attemptedAt: Date(),
            stage: .handoffFailed,
            errorMessage: message,
            helperLogTail: Self.tailHelperLogIfRecent()
        )
    }

    /// Called from `init()` after defaults are restored. Decides whether the
    /// previous `handoffSpawned` attempt actually delivered a new bundle:
    /// - version matches → mark `.succeeded` so the menu retry UI clears.
    /// - version mismatch + recent (< 5 min) → leave alone; we may still be
    ///   inside the launch-services propagation window after a fast install.
    /// - version mismatch + stale → mark `.helperExited` so the UI surfaces
    ///   the silent failure and the user gets a retry path.
    private func verifyPreviousInstall() {
        guard var attempt = lastInstallAttempt else { return }

        let installedVersion = HostAppInfo.appVersion
        let now = Date()

        // Re-attach log tail on terminal stages (cheap idempotent enrichment).
        if attempt.stage != .handoffSpawned, attempt.helperLogTail == nil {
            attempt.helperLogTail = Self.tailHelperLogIfRecent()
            lastInstallAttempt = attempt
            return
        }

        guard let newStage = Self.verifyPreviousInstallDecision(
            attempt: attempt,
            installedVersion: installedVersion,
            now: now,
            gracePeriod: Self.postHandoffGracePeriod
        ) else {
            UpdaterLog.updater.debug("Previous install attempt still within grace window")
            return
        }

        attempt.stage = newStage
        attempt.helperLogTail = Self.tailHelperLogIfRecent()
        switch newStage {
        case .succeeded:
            lastInstallAttempt = attempt
            UpdaterLog.updater.notice("Previous install of \(attempt.version) verified — running build matches")
            // If the user landed on a stable build but the beta channel is
            // still on, they're about to be re-offered the same beta again
            // on the next check. Surface a one-time reminder so they can opt
            // out cleanly instead of fighting the loop.
            maybePresentBetaChannelReminderIfNeeded(installedVersion: installedVersion)
        case .helperExited:
            attempt.errorMessage = attempt.errorMessage ?? "Helper completed but installed version is still \(installedVersion); expected \(attempt.version)"
            lastInstallAttempt = attempt
            UpdaterLog.updater.error("Previous install of \(attempt.version) appears to have failed silently — running build is \(installedVersion)")
        case .handoffSpawned, .handoffFailed:
            lastInstallAttempt = attempt
        }
    }

    /// Shows a one-time alert when a fresh stable install lands while the
    /// beta channel is still enabled — the most common shape of the
    /// "endless update popup" complaint. Per-version flag so users who
    /// stay opted in stop seeing it after the first reminder per version.
    private func maybePresentBetaChannelReminderIfNeeded(installedVersion: String) {
        guard includePreReleases else { return }
        let installed = ParsedVersion(installedVersion)
        guard installed.prerelease.isEmpty else { return }
        let key = "GitHubUpdater.didShowBetaChannelReminder.\(installedVersion)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        // Defer to next runloop tick so the alert isn't presented during
        // `init` (NSApp.mainWindow may not exist yet).
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "You're still on the beta channel", table: "Updater", bundle: .module)
            alert.informativeText = String(localized: "You installed \(BetterUpdater.configuration.displayName) v\(installedVersion). Pre-releases are still enabled, so newer betas will continue to be offered automatically. You can change this in Settings → General.", table: "Updater", bundle: .module)
            alert.addButton(withTitle: String(localized: "Keep Betas Enabled", table: "Updater", bundle: .module))
            alert.addButton(withTitle: String(localized: "Disable Betas", table: "Updater", bundle: .module))
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                GitHubUpdater.shared.includePreReleases = false
            }
        }
    }

    nonisolated private static func tailHelperLogIfRecent() -> String? {
        let url = helperLogURL
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }

        if let size = attrs[.size] as? Int, size > helperLogReadByteCap {
            // Read only the last byte-cap window of a giant log. Cheap seek
            // beats slurping a multi-megabyte file just to throw most away.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let offset = UInt64(size - helperLogReadByteCap)
            try? handle.seek(toOffset: offset)
            let data = (try? handle.read(upToCount: helperLogReadByteCap)) ?? Data()
            return formatTail(from: data)
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return formatTail(from: data)
    }

    nonisolated private static func formatTail(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(helperLogTailLineCap).joined(separator: "\n")
        return tail.isEmpty ? nil : tail
    }
}

// MARK: - Convenience Extensions

extension GitHubUpdater {
    
    /// Human-readable description of last check
    public var lastCheckDescription: String {
        guard let date = lastCheckDate else {
            return String(localized: "Never", table: "Updater", bundle: .module)
        }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    /// Whether an update is available
    public var updateAvailable: Bool {
        if case .available = state {
            return true
        }
        return false
    }
    
    /// Current version string
    public var currentVersion: String {
        HostAppInfo.appVersion
    }
    
    /// Latest available version (if any)
    public var latestVersion: String? {
        latestRelease?.version
    }
}
