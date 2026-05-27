import XCTest
@testable import BetterUpdater

final class UpdaterLogicTests: XCTestCase {

    // MARK: - ParsedVersion ordering

    func testCoreVersionOrdering() {
        XCTAssertTrue(ParsedVersion("1.0.0") < ParsedVersion("1.0.1"))
        XCTAssertTrue(ParsedVersion("1.2.0") < ParsedVersion("1.10.0"))
        XCTAssertTrue(ParsedVersion("26.6.2") < ParsedVersion("26.6.3"))
        XCTAssertFalse(ParsedVersion("2.0.0") < ParsedVersion("1.9.9"))
    }

    func testPrereleaseIsLowerThanStable() {
        XCTAssertTrue(ParsedVersion("1.0.0-beta.1") < ParsedVersion("1.0.0"))
        XCTAssertTrue(ParsedVersion("1.0.0-beta.1") < ParsedVersion("1.0.0-beta.2"))
        XCTAssertFalse(ParsedVersion("1.0.0") < ParsedVersion("1.0.0-beta.9"))
    }

    func testVPrefixIsStripped() {
        XCTAssertEqual(ParsedVersion("v1.2.3"), ParsedVersion("1.2.3"))
    }

    // MARK: - Update decision

    func testNewerCoreVersionIsAvailable() {
        let d = GitHubUpdateDecision.evaluate(.init(
            currentVersion: "26.6.2", latestVersion: "26.6.3",
            currentBuildNumber: 1, remoteBuildNumber: 2
        ))
        XCTAssertTrue(d.isUpdateAvailable)
        XCTAssertFalse(d.isNewerBuild)
    }

    func testSameVersionNewerBuildIsAvailable() {
        let d = GitHubUpdateDecision.evaluate(.init(
            currentVersion: "26.6.3", latestVersion: "26.6.3",
            currentBuildNumber: 100, remoteBuildNumber: 200
        ))
        XCTAssertTrue(d.isUpdateAvailable)
        XCTAssertTrue(d.isNewerBuild)
    }

    func testSameVersionSameBuildIsNotAvailable() {
        let d = GitHubUpdateDecision.evaluate(.init(
            currentVersion: "26.6.3", latestVersion: "26.6.3",
            currentBuildNumber: 200, remoteBuildNumber: 200
        ))
        XCTAssertFalse(d.isUpdateAvailable)
    }

    func testStableReuploadDetectedViaAssetTimestamp() {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let reupload = Date(timeIntervalSince1970: 2_000)
        let d = GitHubUpdateDecision.evaluate(.init(
            currentVersion: "26.6.3", latestVersion: "26.6.3",
            currentBuildNumber: 0, remoteBuildNumber: nil,
            remoteAssetUpdatedAt: reupload, lastSeenAssetUpdatedAt: baseline
        ))
        XCTAssertTrue(d.isUpdateAvailable)
        XCTAssertTrue(d.isNewerBuild)
    }

    func testFirstSightingOfStableAssetIsSilent() {
        let d = GitHubUpdateDecision.evaluate(.init(
            currentVersion: "26.6.3", latestVersion: "26.6.3",
            currentBuildNumber: 0, remoteBuildNumber: nil,
            remoteAssetUpdatedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAssetUpdatedAt: nil
        ))
        XCTAssertFalse(d.isUpdateAvailable)
    }
}
