# BetterUpdater

Sparkle-free auto-updater for macOS apps that ship through GitHub Releases.
Checks the Releases API, downloads the `.dmg`/`.zip`, verifies it, swaps the
bundle in place and relaunches. On top of Apple code-signing it verifies a
**signed repo-identity manifest**, so an update is installed only when it
provably came from the repository the app was built for.

Used by [BetterAudio](https://github.com/rokartur/BetterAudio),
[BetterCmdTab](https://github.com/rokartur/BetterCmdTab) and the other
`Better*` apps.

- macOS 13+, Swift 6 language mode, AppKit + SwiftUI update window
- Stable and beta (pre-release) channels, with a way back to stable
- Check cadence: manual, daily, weekly, monthly; optional auto-download and auto-install
- Skip version, remind later, GitHub rate-limit back-off
- App Translocation guard (offers to move the app to `/Applications`)
- Out-of-process installer helper, admin fallback when `/Applications` is not writable
- `betterupdater` CLI to generate keys and sign/verify releases
- Localized UI (`Sources/BetterUpdater/Resources/Updater.xcstrings`)

## Install

Swift Package Manager. In Xcode: **File ▸ Add Package Dependencies…** and
enter the repo URL, or in `Package.swift`:

```swift
.package(url: "https://github.com/rokartur/BetterUpdater.git", from: "0.2.8")
```

Link the `BetterUpdater` product into your app target.

## Integrate in an app

```swift
import BetterUpdater

// Once, early in applicationDidFinishLaunching, before any other BetterUpdater use.
BetterUpdater.bootstrap(configuration: .init(
    owner: "rokartur",
    repo: "BetterAudio",
    displayName: "BetterAudio",
    bundleIdentifier: "pro.betteraudio.BetterAudio",
    pinnedPublicKeyBase64: "duIBPTDie9dBTKqijWVxsVHZ89AMuorAz04gF6K+TUQ=",
    expectedTeamIdentifier: "YOURTEAMID",
    userAgentProduct: "BetterAudio-Updater",
    manifestRequired: true
))

guard AppTranslocation.guardLaunchLocation() else { return }
await BetterUpdater.shared.checkForUpdates(force: false)
```

`BetterUpdater.shared` is a `GitHubUpdater` `ObservableObject`. Bind it from
SwiftUI or AppKit:

| Member | Purpose |
| --- | --- |
| `state: UpdateState` | `.idle`, `.checking`, `.available`, `.downloading(progress:)`, `.readyToInstall`, `.installing`, `.upToDate`, `.error` |
| `latestRelease`, `latestVersion`, `currentVersion`, `updateAvailable` | What was found |
| `checkInterval` / `setCheckInterval(_:)` | `.manual`, `.automatic` (daily), `.weekly`, `.monthly` |
| `automaticDownloadEnabled`, `automaticInstallEnabled` | Hands-off updates |
| `includePreReleases` | Beta channel; forces an hourly check cadence |
| `checkForUpdates(force:)`, `downloadUpdate()`, `installUpdate()`, `downloadAndInstall()` | Drive the flow yourself |
| `skipCurrentUpdate()`, `remindLater()`, `cancelDownload()`, `reset()` | User choices |
| `lastInstallAttempt` | Stage and helper log of the last install, for a diagnostics view |

The bundled update window: `UpdateWindowPresenter.shared.show()`. It shows on
its own when an automatic check finds an update.

## Sign releases

Each release carries `betterupdater-manifest.json` and
`betterupdater-manifest.json.sig` next to the app asset. The app refuses an
update without a valid manifest (`manifestRequired`, default `true`).

```bash
swift build -c release --product betterupdater
BU=.build/release/betterupdater

# One time: generate a key pair.
$BU keygen
#   PRIVATE_KEY -> CI secret BETTERUPDATER_PRIVATE_KEY
#   PUBLIC_KEY  -> pinnedPublicKeyBase64 in the app

# After building the .dmg/.zip:
$BU sign \
  --owner rokartur --repo BetterAudio \
  --bundle-id pro.betteraudio.BetterAudio --team-id YOURTEAMID \
  --version 26.6.3 \
  --asset dist/BetterAudio-26.6.3-20260503141522.dmg \
  --out dist/betterupdater-manifest.json \
  --private-key-file private.key        # or BETTERUPDATER_PRIVATE_KEY env

# Fail the release if the pinned key cannot verify it.
$BU verify \
  --public-key duIBPTDie9dBTKqijWVxsVHZ89AMuorAz04gF6K+TUQ= \
  --manifest dist/betterupdater-manifest.json \
  --asset dist/BetterAudio-26.6.3-20260503141522.dmg

# Upload the asset, the manifest and the .sig to the GitHub release.
```

The per-asset build number is parsed from the trailing `-<digits>` in the
filename, or passed with `--build`.

`ci/sign-release.yml` is a ready GitHub Actions workflow: copy it to
`.github/workflows/` in the app repo, set the `env` block and the
`BETTERUPDATER_PRIVATE_KEY` secret. It runs when a release is published,
signs the attached assets and uploads the manifest.

## How verification works

Most trusted first:

1. **Pinned Ed25519 public key** in `BetterUpdaterConfiguration`, covered by the app's own code signature.
2. **Signed manifest**: Ed25519 signature over the raw manifest bytes (never re-encoded JSON).
3. **Repo identity**: manifest `owner` / `repo` / `bundleIdentifier` must equal the pinned values.
4. **Anti-replay**: the manifest entry's `version` / `build` must match the asset being installed.
5. **Asset integrity**: SHA-256 and size of the download must match the manifest.
6. **Apple code signature**: `SecStaticCode` with anchor apple generic, bundle id and team id.

Fail-closed: an attacker who controls the GitHub API or CDN response cannot
strip the manifest to fall back to the Apple-only check.

## Package layout

| Target | Role |
| --- | --- |
| `BetterUpdaterManifest` | Dependency-free manifest model, Ed25519 and SHA-256 helpers, verifier. Shared by library and CLI. |
| `BetterUpdater` | Updater engine, update window, translocation guard, installer helper. |
| `betterupdater-cli` | `betterupdater keygen | sign | verify` (swift-argument-parser). |
| `BetterUpdaterTests` | Version comparison, schedule, snooze, manifest signatures, string catalog. |

## Development

```bash
swift build
swift test
swift test --filter ManifestSignatureTests
```

Releases are tagged with the bare version (`0.2.8`) and published as GitHub
Releases whose body is the changelog. See [AGENTS.md](AGENTS.md).

## License

MIT, see [LICENSE](LICENSE).
