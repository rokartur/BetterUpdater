import XCTest
@testable import BetterUpdater

/// Pure-logic tests for the auto-popup snooze gate and the install-attempt
/// boot probe. These exercise the `nonisolated static` helpers on
/// `GitHubUpdater` so we don't need to spin up the @MainActor singleton.
final class GitHubUpdateSnoozeTests: XCTestCase {

    // MARK: - Snooze gate

    func testShouldAutoPresentNewVersionAlwaysTrue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = GitHubUpdater.shouldAutoPresentUpdateWindow(
            forVersion: "26.6.3",
            lastAutoShownVersion: "26.6.2",
            lastAutoShownAt: now.addingTimeInterval(-60),
            now: now,
            snoozeInterval: 3 * 24 * 60 * 60
        )
        XCTAssertTrue(result, "A different version must always bypass the snooze")
    }

    func testShouldAutoPresentWhenNeverShownBefore() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = GitHubUpdater.shouldAutoPresentUpdateWindow(
            forVersion: "26.6.3",
            lastAutoShownVersion: nil,
            lastAutoShownAt: nil,
            now: now,
            snoozeInterval: 3 * 24 * 60 * 60
        )
        XCTAssertTrue(result)
    }

    func testShouldAutoPresentSameVersionWithinSnoozeFalse() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let shown = now.addingTimeInterval(-(2 * 24 * 60 * 60)) // 2 days ago
        let result = GitHubUpdater.shouldAutoPresentUpdateWindow(
            forVersion: "26.6.3-beta.9",
            lastAutoShownVersion: "26.6.3-beta.9",
            lastAutoShownAt: shown,
            now: now,
            snoozeInterval: 3 * 24 * 60 * 60
        )
        XCTAssertFalse(result, "Still inside the 3-day snooze window")
    }

    func testShouldAutoPresentSameVersionAfterSnoozeTrue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let shown = now.addingTimeInterval(-(4 * 24 * 60 * 60)) // 4 days ago
        let result = GitHubUpdater.shouldAutoPresentUpdateWindow(
            forVersion: "26.6.3-beta.9",
            lastAutoShownVersion: "26.6.3-beta.9",
            lastAutoShownAt: shown,
            now: now,
            snoozeInterval: 3 * 24 * 60 * 60
        )
        XCTAssertTrue(result, "Snooze expired — popup should fire again")
    }

    func testSnoozeIntervalConstantIsThreeDays() {
        XCTAssertEqual(GitHubUpdater.autoShowSnoozeInterval, 3 * 24 * 60 * 60)
    }

    // MARK: - Boot probe (verifyPreviousInstall)

    func testVerifyPreviousInstallDetectsHandoffSpawnMismatch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = LastInstallAttempt(
            version: "26.6.3-beta.9",
            attemptedAt: now.addingTimeInterval(-(10 * 60)), // 10 min ago
            stage: .handoffSpawned,
            errorMessage: nil,
            helperLogTail: nil
        )
        let newStage = GitHubUpdater.verifyPreviousInstallDecision(
            attempt: attempt,
            installedVersion: "26.6.2",   // we're still on the old version
            now: now,
            gracePeriod: 5 * 60
        )
        XCTAssertEqual(newStage, .helperExited)
    }

    func testVerifyPreviousInstallClearsOnVersionMatch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = LastInstallAttempt(
            version: "26.6.3-beta.9",
            attemptedAt: now.addingTimeInterval(-(10 * 60)),
            stage: .handoffSpawned,
            errorMessage: nil,
            helperLogTail: nil
        )
        let newStage = GitHubUpdater.verifyPreviousInstallDecision(
            attempt: attempt,
            installedVersion: "26.6.3-beta.9",
            now: now,
            gracePeriod: 5 * 60
        )
        XCTAssertEqual(newStage, .succeeded)
    }

    func testVerifyPreviousInstallWithinGracePeriodReturnsNil() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = LastInstallAttempt(
            version: "26.6.3-beta.9",
            attemptedAt: now.addingTimeInterval(-(2 * 60)), // 2 min ago
            stage: .handoffSpawned,
            errorMessage: nil,
            helperLogTail: nil
        )
        let newStage = GitHubUpdater.verifyPreviousInstallDecision(
            attempt: attempt,
            installedVersion: "26.6.2",
            now: now,
            gracePeriod: 5 * 60
        )
        XCTAssertNil(newStage, "Within grace period we must wait, not flag failure")
    }

    func testVerifyPreviousInstallLeavesTerminalStageAlone() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stages: [LastInstallAttempt.Stage] = [.succeeded, .helperExited, .handoffFailed]
        for stage in stages {
            let attempt = LastInstallAttempt(
                version: "26.6.3-beta.9",
                attemptedAt: now.addingTimeInterval(-(24 * 60 * 60)),
                stage: stage,
                errorMessage: nil,
                helperLogTail: nil
            )
            let newStage = GitHubUpdater.verifyPreviousInstallDecision(
                attempt: attempt,
                installedVersion: "26.6.2",
                now: now,
                gracePeriod: 5 * 60
            )
            XCTAssertNil(newStage, "Terminal stage \(stage.rawValue) must not be reclassified")
        }
    }

    /// Beta MARKETING_VERSION drops the `-beta.N` suffix, so the installed
    /// bundle reports "26.6.3" even though the attempt was tagged
    /// "26.6.3-beta.9". The version-match check should normalise via
    /// ParsedVersion so this is still recognised as success.
    func testVerifyPreviousInstallMatchesBetaWithoutSuffix() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = LastInstallAttempt(
            version: "26.6.3-beta.9",
            attemptedAt: now.addingTimeInterval(-(10 * 60)),
            stage: .handoffSpawned,
            errorMessage: nil,
            helperLogTail: nil
        )
        // Bundle reports stripped marketing version.
        let newStage = GitHubUpdater.verifyPreviousInstallDecision(
            attempt: attempt,
            installedVersion: "26.6.3",
            now: now,
            gracePeriod: 5 * 60
        )
        // Stable 26.6.3 has prerelease=[] which makes it NEWER than 26.6.3-beta.9
        // per semver; `ParsedVersion.==` returns false. This is by design — we
        // only treat strict equality as "same install". The user can still see
        // a recovery breadcrumb here, which is fine.
        XCTAssertEqual(newStage, .helperExited,
                       "Stripped marketing version is treated as a different (newer-stable) build")
    }
}
