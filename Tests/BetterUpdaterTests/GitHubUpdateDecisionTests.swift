import XCTest
@testable import BetterUpdater

final class GitHubUpdateDecisionTests: XCTestCase {

    func testSameVersionNoBuildNumberDoesNotOfferUpdate() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.5.6",
            latestVersion: "26.5.6",
            currentBuildNumber: 1,
            remoteBuildNumber: nil
        ))

        XCTAssertFalse(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    func testSameVersionNewerBuildOffersUpdate() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "1.0.0",
            latestVersion: "1.0.0",
            currentBuildNumber: 20260501000000,
            remoteBuildNumber: 20260503141522
        ))

        XCTAssertTrue(decision.isUpdateAvailable)
        XCTAssertTrue(decision.isNewerBuild)
    }

    func testSameVersionSameBuildDoesNotOfferUpdate() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "1.0.0",
            latestVersion: "1.0.0",
            currentBuildNumber: 20260503141522,
            remoteBuildNumber: 20260503141522
        ))

        XCTAssertFalse(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    func testNewerVersionAlwaysOffersUpdate() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "1.0.0",
            latestVersion: "1.1.0",
            currentBuildNumber: 20260503141522,
            remoteBuildNumber: 20260503141522
        ))

        XCTAssertTrue(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    // MARKETING_VERSION strips the -beta.N suffix, so an installed beta build
    // reports the same appVersion as a stable build of the same core. The
    // updater must use the timestamp build number to detect a newer beta of
    // the same MARKETING_VERSION.
    func testBetaToBetaOfferUpdateViaBuildNumber() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.3",
            latestVersion: "26.6.3-beta.2",
            currentBuildNumber: 20260503144228,
            remoteBuildNumber: 20260520210451
        ))

        XCTAssertTrue(decision.isUpdateAvailable)
        XCTAssertTrue(decision.isNewerBuild)
    }

    func testBetaToBetaNoUpdateWhenBuildOlder() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.3",
            latestVersion: "26.6.3-beta.1",
            currentBuildNumber: 20260520210451,
            remoteBuildNumber: 20260503144228
        ))

        XCTAssertFalse(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    func testNewerBetaNumberCompareNumerically() {
        // beta.10 must be newer than beta.9 (lexicographic compare would invert).
        XCTAssertTrue(GitHubUpdateDecision.isNewerVersion("26.6.3-beta.10", than: "26.6.3-beta.9"))
        XCTAssertFalse(GitHubUpdateDecision.isNewerVersion("26.6.3-beta.9", than: "26.6.3-beta.10"))
    }

    func testStableIsNewerThanPrereleaseOfSameCore() {
        XCTAssertTrue(GitHubUpdateDecision.isNewerVersion("26.6.3", than: "26.6.3-beta.2"))
        XCTAssertFalse(GitHubUpdateDecision.isNewerVersion("26.6.3-beta.2", than: "26.6.3"))
    }

    func testStableNewMinorIsNewerThanCurrentBeta() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.3-beta.2",
            latestVersion: "26.6.4",
            currentBuildNumber: 20260520210451,
            remoteBuildNumber: 20260601000000
        ))

        XCTAssertTrue(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    // MARK: - Stable asset re-upload detection

    /// Stable releases ship assets like `BetterAudio-26.6.2.dmg` with no
    /// embedded build timestamp, so `remoteBuildNumber` is nil. Without the
    /// asset-updated-at fallback, a re-uploaded same-version DMG would be
    /// invisible to the updater.
    func testStableReUploadOfferedViaAssetTimestamp() {
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = baseline.addingTimeInterval(60 * 60 * 24) // +1 day
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.2",
            latestVersion: "26.6.2",
            currentBuildNumber: 20,
            remoteBuildNumber: nil,
            remoteAssetUpdatedAt: newer,
            lastSeenAssetUpdatedAt: baseline
        ))

        XCTAssertTrue(decision.isUpdateAvailable)
        XCTAssertTrue(decision.isNewerBuild)
    }

    func testStableReUploadNotOfferedWhenAssetTimestampSame() {
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.2",
            latestVersion: "26.6.2",
            currentBuildNumber: 20,
            remoteBuildNumber: nil,
            remoteAssetUpdatedAt: baseline,
            lastSeenAssetUpdatedAt: baseline
        ))

        XCTAssertFalse(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    /// First time we see a stable release we record the baseline silently —
    /// we don't pop a popup just because there's no recorded baseline yet,
    /// otherwise every user upgrading to this feature would see a popup
    /// for whatever release they're already running.
    func testStableReUploadFirstSeenDoesNotAutoOffer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.2",
            latestVersion: "26.6.2",
            currentBuildNumber: 20,
            remoteBuildNumber: nil,
            remoteAssetUpdatedAt: now,
            lastSeenAssetUpdatedAt: nil
        ))

        XCTAssertFalse(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }

    /// Regression: presence of the new asset-timestamp fields must not
    /// change the beta-path decision (which still uses `remoteBuildNumber`).
    func testBetaDecisionUnchangedWhenAssetTimestampFieldsPresent() {
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.6.3",
            latestVersion: "26.6.3-beta.2",
            currentBuildNumber: 20260503144228,
            remoteBuildNumber: 20260520210451,
            remoteAssetUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAssetUpdatedAt: Date(timeIntervalSince1970: 1_699_000_000)
        ))

        XCTAssertTrue(decision.isUpdateAvailable)
        XCTAssertTrue(decision.isNewerBuild)
    }

    /// Cross-version (different core) — asset timestamp must NOT bypass
    /// the version comparison, only complement it for same-core stable.
    func testAssetTimestampDoesNotTriggerOnDifferentCore() {
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = baseline.addingTimeInterval(60)
        // Current newer than remote, but remote has a newer asset stamp.
        // Should NOT offer an update — version compare wins.
        let decision = GitHubUpdateDecision.evaluate(GitHubUpdateDecision.Input(
            currentVersion: "26.7.0",
            latestVersion: "26.6.2",
            currentBuildNumber: 21,
            remoteBuildNumber: nil,
            remoteAssetUpdatedAt: newer,
            lastSeenAssetUpdatedAt: baseline
        ))

        XCTAssertFalse(decision.isUpdateAvailable)
        XCTAssertFalse(decision.isNewerBuild)
    }
}
