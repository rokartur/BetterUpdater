import Foundation
import AppKit
import Security

/// Out-of-process installer helper, equivalent to Sparkle's `Autoupdate`.
///
/// A running `.app` cannot reliably overwrite itself: copying over a mapped
/// bundle, or `mv`'ing the executable while it is in use, fails on macOS.
/// `handoffSwap` writes a small shell script to a private temp directory,
/// spawns it detached, and returns. The script waits for the parent process
/// to exit, swaps the bundle into place, strips the quarantine xattr, and
/// relaunches via `open -n`.
///
/// If the target's parent directory is not writable by the current user,
/// `handoffSwap` first asks for admin authorization via
/// `AuthorizationExecuteWithPrivileges` and runs the same helper as root.
/// (Yes, that API is deprecated; Sparkle still uses it for the same fallback.
/// SMJobBless/SMAppService is a future migration.)
enum UpdateInstallerHelper {

    enum HandoffError: LocalizedError {
        case stageFailed(String)
        case helperWriteFailed(String)
        case spawnFailed(String)
        case authorizationDenied
        case authorizationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .stageFailed(let msg):
                return String(localized: "Could not stage update: \(msg)", table: "Updater", bundle: .module)
            case .helperWriteFailed(let msg):
                return String(localized: "Could not prepare installer helper: \(msg)", table: "Updater", bundle: .module)
            case .spawnFailed(let msg):
                return String(localized: "Could not start installer helper: \(msg)", table: "Updater", bundle: .module)
            case .authorizationDenied:
                return String(localized: "Authorization was cancelled.", table: "Updater", bundle: .module)
            case .authorizationFailed(let status):
                return String(localized: "Authorization failed (\(status)).", table: "Updater", bundle: .module)
            }
        }
    }

    /// Hands off bundle replacement to an external script and returns.
    /// Caller MUST terminate this process shortly after; the helper polls
    /// for parent exit before touching the target.
    ///
    /// - Parameters:
    ///   - stagedAppURL: source bundle (already extracted/validated)
    ///   - targetAppURL: where the bundle should live (e.g. `/Applications/BetterAudio.app`)
    ///   - removeSource: whether to delete the source after swap (true for downloads in temp dirs).
    static func handoffSwap(
        stagedAppURL: URL,
        targetAppURL: URL,
        removeSource: Bool
    ) async throws {
        let parentPID = ProcessInfo.processInfo.processIdentifier
        let helperURL = try writeHelperScript()
        let chownUser = currentUserAndGroup()

        let writable = isWritable(targetAppURL.deletingLastPathComponent())

        let args = helperArguments(
            parentPID: parentPID,
            source: stagedAppURL,
            target: targetAppURL,
            removeSource: removeSource,
            chownUser: writable ? nil : chownUser
        )

        if writable {
            // Fast path — no admin prompt, runs entirely on the calling
            // (main) actor since spawnDetached is non-blocking.
            try spawnDetached(helper: helperURL, arguments: args)
        } else {
            // Slow path — Authorization prompts present a SecurityAgent
            // dialog that blocks the calling thread. Run on a background
            // task so the main actor stays responsive.
            try await Task.detached(priority: .userInitiated) {
                try runWithPrivileges(helper: helperURL, arguments: args)
            }.value
        }
    }

    /// Returns true if the target's parent directory is writable by the
    /// current effective user. POSIX `access(W_OK)` alone misses SIP-protected
    /// paths, MDM-managed ACLs, FileVault-mounted volumes, and a few other
    /// edge cases where the mode bits look writable but a real write call
    /// fails. We therefore short-circuit on `access()` first (cheap deny) and
    /// only fall through to a true probe-write when the cheap check passes.
    static func isWritable(_ directory: URL) -> Bool {
        guard access(directory.path, W_OK) == 0 else { return false }
        let probe = directory.appendingPathComponent(".\(BetterUpdater.configuration.displayName)WriteProbe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helper script

    /// Filename (under TMPDIR) of the install-helper log. Single source of
    /// truth: the script below (writer) and the diagnostics reader in
    /// `GitHubUpdater` must agree, so both derive it from the app display name.
    static var installHelperLogName: String {
        "\(BetterUpdater.configuration.displayName)InstallHelper.log"
    }

    private static var helperScript: String { #"""
    #!/bin/bash
    # \#(BetterUpdater.configuration.displayName) update installer helper.
    # Args: <parentPID> <source> <target> <removeSource:0|1> [chownUser]
    set -u
    set -o pipefail
    PARENT_PID="${1:?missing parentPID}"
    SOURCE="${2:?missing source}"
    TARGET="${3:?missing target}"
    REMOVE_SOURCE="${4:-0}"
    CHOWN_USER="${5:-}"
    LOG="${TMPDIR:-/tmp}/\#(installHelperLogName)"

    # Log rotation: keep the live log under ~512 KB so a "Copy Diagnostics"
    # tail read stays fast and the log doesn't grow unbounded across installs.
    if [[ -f "$LOG" && $(stat -f%z "$LOG" 2>/dev/null || echo 0) -gt 524288 ]]; then
        /bin/mv -f "$LOG" "$LOG.1" 2>/dev/null || true
    fi
    {
        echo "[$(date '+%H:%M:%S')] start pid=$$ uid=$(id -u) parent=$PARENT_PID source=$SOURCE target=$TARGET remove=$REMOVE_SOURCE chown=$CHOWN_USER"

        # Wait for parent (the running BetterAudio process) to exit.
        for _ in $(seq 1 600); do
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then break; fi
            sleep 0.2
        done

        if kill -0 "$PARENT_PID" 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] parent did not exit within 120s, aborting"
            exit 10
        fi

        # Sanity: source must exist before we touch the target. Without this,
        # a race that deletes the staging dir would lead us to backup the live
        # target and then fail to install anything, leaving the user without
        # an app at the target path.
        if [[ ! -d "$SOURCE" ]]; then
            echo "[$(date '+%H:%M:%S')] source bundle missing, aborting before touching target"
            exit 9
        fi

        # Strip quarantine on the staged bundle so the installed copy doesn't
        # re-translocate on next launch. Failures here are non-fatal but we
        # log them so the breadcrumb shows why a Gatekeeper prompt happened.
        if ! /usr/bin/xattr -dr com.apple.quarantine "$SOURCE" 2>>"$LOG"; then
            echo "[$(date '+%H:%M:%S')] xattr clear on SOURCE failed (non-fatal)"
        fi

        # Backup current target if present, so we can roll back on failure.
        # Timestamp the backup name to avoid silent overwrite of a previous
        # failed install's backup (which would also fail the mv below).
        BACKUP=""
        if [[ -d "$TARGET" ]]; then
            BACKUP="${TARGET%.*}.previous.$(date +%s).app"
            if ! /bin/mv -f "$TARGET" "$BACKUP"; then
                echo "[$(date '+%H:%M:%S')] failed to move existing target out of the way"
                exit 11
            fi
        fi

        # Place new bundle. Prefer mv when source is removable; otherwise copy.
        if [[ "$REMOVE_SOURCE" == "1" ]]; then
            if ! /bin/mv -f "$SOURCE" "$TARGET"; then
                echo "[$(date '+%H:%M:%S')] mv failed; attempting copy fallback"
                /usr/bin/ditto "$SOURCE" "$TARGET" || {
                    echo "[$(date '+%H:%M:%S')] ditto failed; restoring backup"
                    [[ -n "$BACKUP" ]] && /bin/mv -f "$BACKUP" "$TARGET"
                    exit 12
                }
                /bin/rm -rf "$SOURCE" 2>/dev/null || true
            fi
        else
            if ! /usr/bin/ditto "$SOURCE" "$TARGET"; then
                echo "[$(date '+%H:%M:%S')] ditto failed; restoring backup"
                [[ -n "$BACKUP" ]] && /bin/mv -f "$BACKUP" "$TARGET"
                exit 13
            fi
        fi

        # Strip quarantine on the installed copy too (belt-and-suspenders).
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

        # If we're running as root (privileged install), restore ownership to
        # the invoking GUI user so the next non-privileged update can also
        # write the bundle without an admin prompt.
        if [[ "$(id -u)" == "0" && -n "$CHOWN_USER" ]]; then
            /usr/sbin/chown -R "$CHOWN_USER" "$TARGET" 2>/dev/null || true
        fi

        # Remove backup once we're confident the new bundle is in place.
        if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
            /bin/rm -rf "$BACKUP" 2>/dev/null || true
        fi

        # Relaunch the new app. If running as root, drop privileges so the
        # GUI process belongs to the user — otherwise the relaunched app
        # would be owned by root and behave incorrectly under WindowServer.
        if [[ "$(id -u)" == "0" && -n "$CHOWN_USER" ]]; then
            /usr/bin/sudo -u "${CHOWN_USER%%:*}" /usr/bin/open -n "$TARGET" || {
                echo "[$(date '+%H:%M:%S')] open (as user) failed"
                exit 14
            }
        else
            /usr/bin/open -n "$TARGET" || {
                echo "[$(date '+%H:%M:%S')] open failed"
                exit 14
            }
        fi

        echo "[$(date '+%H:%M:%S')] done [exit-code=0]"
        exit 0
    } >> "$LOG" 2>&1
    """# }

    private static func writeHelperScript() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(BetterUpdater.configuration.displayName)-Installer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw HandoffError.helperWriteFailed(error.localizedDescription)
        }
        let url = dir.appendingPathComponent("install_helper.sh")
        do {
            try helperScript.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw HandoffError.helperWriteFailed(error.localizedDescription)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw HandoffError.helperWriteFailed("chmod failed: \(error.localizedDescription)")
        }
        return url
    }

    private static func helperArguments(
        parentPID: pid_t,
        source: URL,
        target: URL,
        removeSource: Bool,
        chownUser: String?
    ) -> [String] {
        var args = [
            String(parentPID),
            source.path,
            target.path,
            removeSource ? "1" : "0"
        ]
        if let chownUser, !chownUser.isEmpty {
            args.append(chownUser)
        }
        return args
    }

    /// Returns "user:group" for the current effective UID/GID, used as the
    /// chown target when the helper runs as root.
    private static func currentUserAndGroup() -> String {
        let uid = getuid()
        let gid = getgid()
        let user: String
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            user = String(cString: name)
        } else {
            user = String(uid)
        }
        let group: String
        if let gr = getgrgid(gid), let name = gr.pointee.gr_name {
            group = String(cString: name)
        } else {
            group = String(gid)
        }
        return "\(user):\(group)"
    }

    // MARK: - Spawn paths

    private static func spawnDetached(helper: URL, arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [helper.path] + arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.qualityOfService = .userInitiated
        do {
            try task.run()
        } catch {
            throw HandoffError.spawnFailed(error.localizedDescription)
        }
        UpdaterLog.updater.notice("Spawned installer helper pid=\(task.processIdentifier)")
    }

    /// Runs the helper with admin privileges via `AuthorizationExecuteWithPrivileges`.
    /// Deprecated API but still functional on macOS 15. Falls back from spawnDetached
    /// when the target parent directory is not writable.
    ///
    /// TODO(updater): migrate to SMAppService — Apple will eventually remove
    /// the dlsym'd symbol. SMAppService requires a signed bundled helper
    /// tool target and notarization changes, so it's a separate PR.
    private static func runWithPrivileges(helper: URL, arguments: [String]) throws {
        UpdaterLog.updater.notice("Using AuthorizationExecuteWithPrivileges (deprecated API). SMAppService migration tracked separately.")
        var authRef: AuthorizationRef?
        let authStatus = AuthorizationCreate(nil, nil, [.interactionAllowed], &authRef)
        guard authStatus == errAuthorizationSuccess, let authRef else {
            throw HandoffError.authorizationFailed(authStatus)
        }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        // Request the right to run a tool as root.
        let rightName = kAuthorizationRightExecute
        let result: OSStatus = rightName.withCString { rightCString in
            var item = AuthorizationItem(name: rightCString, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
                return AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
            }
        }

        switch result {
        case errAuthorizationSuccess:
            break
        case errAuthorizationCanceled:
            throw HandoffError.authorizationDenied
        default:
            throw HandoffError.authorizationFailed(result)
        }

        // AuthorizationExecuteWithPrivileges is deprecated but the only API
        // available without bundling a privileged SMJobBless helper. Resolve
        // it dynamically to avoid the deprecation warning at compile time.
        typealias ExecFn = @convention(c) (
            AuthorizationRef,
            UnsafePointer<CChar>,
            AuthorizationFlags,
            UnsafePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus

        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(handle, "AuthorizationExecuteWithPrivileges") else {
            throw HandoffError.spawnFailed("AuthorizationExecuteWithPrivileges unavailable")
        }
        let exec = unsafeBitCast(sym, to: ExecFn.self)

        // Build argv as null-terminated C-string array.
        let cStrings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer {
            for p in cStrings where p != nil { free(p) }
        }

        let status = helper.path.withCString { pathPtr -> OSStatus in
            cStrings.withUnsafeBufferPointer { argvPtr in
                exec(authRef, pathPtr, [], argvPtr.baseAddress!, nil)
            }
        }

        switch status {
        case errAuthorizationSuccess:
            UpdaterLog.updater.notice("Privileged installer helper launched")
        case errAuthorizationCanceled:
            throw HandoffError.authorizationDenied
        default:
            throw HandoffError.spawnFailed("AuthorizationExecuteWithPrivileges status=\(status)")
        }
    }
}
