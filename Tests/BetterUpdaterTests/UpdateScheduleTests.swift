import XCTest
@testable import BetterUpdater

/// Scheduler math for the automatic-check loop (`GitHubUpdater.nextCheckDate`).
///
/// Regression coverage for the zero-delay spin: with a stale `lastCheckDate`
/// (anchor + interval already in the past) every failed check must still
/// schedule the retry in the future. Returning a past date makes the scheduler
/// fire instantly, and each failed run's reschedule cancels the next in-flight
/// check — an endless "Update check failed: cancelled" loop.
final class UpdateScheduleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let interval: TimeInterval = 60 * 60 // DEBUG "daily" cadence

    func testFailureWithStaleAnchorNeverSchedulesInThePast() {
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: now.addingTimeInterval(-3 * interval),
            lastFailureDate: now,
            now: now
        )
        XCTAssertGreaterThan(next, now)
        XCTAssertEqual(next, now.addingTimeInterval(GitHubUpdaterConfig.errorRetryInterval))
    }

    func testFailureRetriesAfterErrorRetryInterval() {
        let failure = now.addingTimeInterval(-60)
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: now.addingTimeInterval(-120),
            lastFailureDate: failure,
            now: now
        )
        XCTAssertEqual(next, failure.addingTimeInterval(GitHubUpdaterConfig.errorRetryInterval))
    }

    func testSuccessAnchorsToLastCheckPlusInterval() {
        let lastCheck = now.addingTimeInterval(-600)
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: lastCheck,
            lastFailureDate: nil,
            now: now
        )
        XCTAssertEqual(next, lastCheck.addingTimeInterval(interval))
    }

    func testFirstLaunchAnchorsToNow() {
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: nil,
            lastFailureDate: nil,
            now: now
        )
        XCTAssertEqual(next, now.addingTimeInterval(interval))
    }

    func testFailureOlderThanLastSuccessIsIgnored() {
        let lastCheck = now.addingTimeInterval(-600)
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: lastCheck,
            lastFailureDate: lastCheck.addingTimeInterval(-60),
            now: now
        )
        XCTAssertEqual(next, lastCheck.addingTimeInterval(interval))
    }

    func testClockSkewFutureDatesAreClampedToNow() {
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: now.addingTimeInterval(3600),
            lastFailureDate: now.addingTimeInterval(7200),
            now: now
        )
        XCTAssertEqual(next, now.addingTimeInterval(GitHubUpdaterConfig.errorRetryInterval))
    }

    // MARK: - Rate limit backoff

    func testRateLimitResetOutranksTheShorterRetryInterval() {
        let reset = now.addingTimeInterval(45 * 60)
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: now.addingTimeInterval(-3 * interval),
            lastFailureDate: now,
            retryNotBefore: reset,
            now: now
        )
        XCTAssertEqual(next, reset)
    }

    func testElapsedRateLimitDoesNotDelayTheRetry() {
        let next = GitHubUpdater.nextCheckDate(
            interval: interval,
            lastCheckDate: nil,
            lastFailureDate: now,
            retryNotBefore: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertEqual(next, now.addingTimeInterval(GitHubUpdaterConfig.errorRetryInterval))
    }

    func testRetryAfterHeaderWins() {
        let retry = GitHubUpdater.rateLimitRetryDate(
            retryAfter: "60",
            rateLimitRemaining: "0",
            rateLimitReset: String(now.addingTimeInterval(3000).timeIntervalSince1970),
            now: now
        )
        XCTAssertEqual(retry, now.addingTimeInterval(60))
    }

    func testResetHeaderUsedWhenQuotaIsExhausted() {
        let reset = now.addingTimeInterval(1800)
        let retry = GitHubUpdater.rateLimitRetryDate(
            retryAfter: nil,
            rateLimitRemaining: "0",
            rateLimitReset: String(reset.timeIntervalSince1970),
            now: now
        )
        XCTAssertEqual(retry, reset)
    }

    /// A 403 with quota left is a different failure (blocked, bad token, abuse
    /// detection without headers) — the caller must keep its generic error path.
    func testNonRateLimitForbiddenReturnsNil() {
        XCTAssertNil(GitHubUpdater.rateLimitRetryDate(
            retryAfter: nil,
            rateLimitRemaining: "59",
            rateLimitReset: String(now.addingTimeInterval(1800).timeIntervalSince1970),
            now: now
        ))
    }

    func testAbsurdHeaderIsClampedToAnHour() {
        let retry = GitHubUpdater.rateLimitRetryDate(
            retryAfter: "999999",
            rateLimitRemaining: nil,
            rateLimitReset: nil,
            now: now
        )
        XCTAssertEqual(retry, now.addingTimeInterval(3600))
    }
}
