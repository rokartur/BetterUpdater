import AppKit
import Foundation
import Security

/// Detects and resolves Gatekeeper Path Randomization (App Translocation).
///
/// When the app is launched from a quarantined location (e.g. `~/Downloads`),
/// macOS runs it from a read-only mount under `/private/var/folders/.../AppTranslocation/<UUID>/d/<App>.app`.
/// Bundle paths inside the running process point at the translocated location, which
/// breaks the in-place self-updater because:
///   - The bundle URL is not under `/Applications`, so the updater targets `/Applications/<App>.app`.
///   - The translocated mount is read-only.
///   - After a manual install, Dock entries and recent items can re-launch the
///     translocated path, so the new build never becomes the running build.
///
/// `guardLaunchLocation()` must run before any update check. If the launch is
/// translocated, the user is asked to move the app to `/Applications`; the
/// updater is suppressed until that is resolved.
public enum AppTranslocation {

    // MARK: - Detection

    /// Returns true if the running bundle is translocated.
    /// Uses the private but stable `SecTranslocateIsTranslocatedURL` API
    /// (present since macOS 10.12; Sparkle uses the same symbol). Falls back
    /// to a path-based heuristic if the symbol cannot be resolved.
    public static func isTranslocated() -> Bool {
        let bundleURL = Bundle.main.bundleURL

        if let result = secTranslocateIsTranslocated(bundleURL) {
            return result
        }

        // Fallback heuristic — the AppTranslocation mount is always under this path.
        return bundleURL.path.contains("/AppTranslocation/")
    }

    /// Returns the user-visible original location (e.g. `~/Downloads/\(BetterUpdater.configuration.displayName).app`)
    /// for a translocated bundle, or nil if not available.
    public static func originalLocation() -> URL? {
        secTranslocateOriginalURL(Bundle.main.bundleURL)
    }

    // MARK: - Launch-time gate

    /// Call once at app launch, before any updater work.
    ///
    /// If the running bundle is translocated, surfaces a blocking alert:
    ///   - "Move to Applications" — copies the bundle to `/Applications`,
    ///     strips the quarantine xattr, relaunches from there, and terminates.
    ///   - "Quit" — exits.
    ///
    /// Returns `true` if the launch is OK and the caller may proceed.
    /// Returns `false` if the app is in the process of relaunching/quitting;
    /// the caller should abort further setup. The actual user prompt + move
    /// runs asynchronously after this returns.
    @MainActor
    @discardableResult
    public static func guardLaunchLocation() -> Bool {
        guard isTranslocated() else { return true }

        UpdaterLog.updater.notice("App launched from translocated path: \(Bundle.main.bundleURL.path)")

        // Don't block applicationDidFinishLaunching — kick off the alert +
        // async move on the next runloop tick. Caller aborts the rest of
        // bootstrap; the user only ever interacts with the alert.
        Task { @MainActor in
            await presentTranslocationAlertAndResolve()
        }
        return false
    }

    @MainActor
    private static func presentTranslocationAlertAndResolve() async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Move \(BetterUpdater.configuration.displayName) to Applications", table: "Updater", bundle: .module)
        alert.informativeText = String(localized: "\(BetterUpdater.configuration.displayName) is running from a temporary location and cannot install updates from here. Move it to your Applications folder to continue.", table: "Updater", bundle: .module)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Move to Applications", table: "Updater", bundle: .module))
        alert.addButton(withTitle: String(localized: "Quit", table: "Updater", bundle: .module))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            UpdaterLog.updater.notice("User declined to move translocated app — quitting")
            NSApplication.shared.terminate(nil)
            return
        }

        do {
            try await moveToApplicationsAndRelaunch()
        } catch {
            UpdaterLog.updater.error("Failed to move translocated app: \(error.localizedDescription)")
            let failure = NSAlert()
            failure.messageText = String(localized: "Could Not Move \(BetterUpdater.configuration.displayName)", table: "Updater", bundle: .module)
            failure.informativeText = String(localized: "Please drag \(BetterUpdater.configuration.displayName) to your Applications folder manually, then relaunch.\n\n\(error.localizedDescription)", table: "Updater", bundle: .module)
            failure.alertStyle = .critical
            failure.addButton(withTitle: String(localized: "Quit", table: "Updater", bundle: .module))
            failure.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Move + relaunch

    /// Resolves the translocated launch.
    ///
    /// If `/Applications/<Bundle>.app` already exists (e.g. the user has
    /// installed it before and is now running a stale Downloads copy), we
    /// just relaunch the existing copy — never overwrite it with a possibly
    /// older bundle. Otherwise we hand off to the installer helper to copy
    /// the un-translocated source into `/Applications`.
    ///
    /// In both cases this process is terminated so macOS can launch the
    /// /Applications binary fresh (no translocation).
    @MainActor
    public static func moveToApplicationsAndRelaunch() async throws {
        let sourceURL = originalLocation() ?? Bundle.main.bundleURL
        let bundleName = Bundle.main.bundleURL.lastPathComponent
        let targetURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleName)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            UpdaterLog.updater.notice("Found existing \(targetURL.path) — relaunching from there instead of copying \(sourceURL.path)")
            try relaunchExisting(at: targetURL)
            return
        }

        UpdaterLog.updater.notice("Moving \(sourceURL.path) → \(targetURL.path)")

        try await UpdateInstallerHelper.handoffSwap(
            stagedAppURL: sourceURL,
            targetAppURL: targetURL,
            removeSource: false
        )

        // Helper takes over once this process exits. Give the spawn a moment
        // to detach, then terminate so the helper can complete the swap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Launches the bundle at `targetURL` and terminates this process.
    /// Used when /Applications already contains the app and we don't want
    /// to risk overwriting it with a possibly older copy.
    @MainActor
    private static func relaunchExisting(at targetURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", targetURL.path]
        try task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - SecTranslocate dynamic linkage

    private typealias IsTranslocatedFn = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
    private typealias CreateOriginalPathFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    nonisolated(unsafe) private static let securityHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
    }()

    private static func secTranslocateIsTranslocated(_ url: URL) -> Bool? {
        guard let handle = securityHandle,
              let sym = dlsym(handle, "SecTranslocateIsTranslocatedURL") else {
            return nil
        }
        let fn = unsafeBitCast(sym, to: IsTranslocatedFn.self)
        var result: DarwinBoolean = false
        var errPtr: Unmanaged<CFError>? = nil
        let ok = fn(url as CFURL, &result, &errPtr)
        if let err = errPtr {
            err.release()
        }
        guard ok.boolValue else { return nil }
        return result.boolValue
    }

    private static func secTranslocateOriginalURL(_ url: URL) -> URL? {
        guard let handle = securityHandle,
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }
        let fn = unsafeBitCast(sym, to: CreateOriginalPathFn.self)
        var errPtr: Unmanaged<CFError>? = nil
        guard let cfURLUnmanaged = fn(url as CFURL, &errPtr) else {
            if let err = errPtr {
                err.release()
            }
            return nil
        }
        let cfURL = cfURLUnmanaged.takeRetainedValue()
        return cfURL as URL
    }
}
