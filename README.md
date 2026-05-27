# BetterUpdater

A self-contained, Sparkle-free macOS auto-updater built on the GitHub Releases
API — with a **signed repo-identity manifest** that cryptographically proves an
update really came from the repository it claims to, on top of Apple
code-signing.

Used by [BetterCmdTab](https://github.com/rokartur/BetterCmdTab) and
[BetterAudio](https://github.com/rokartur/BetterAudio).

## Why not Sparkle?

Sparkle's EdDSA signs the appcast. BetterUpdater does the same idea but the
signed document binds the **repository identity** (owner / repo / bundle id /
team id) and **per-asset checksums**, so verification answers one blunt
question: *"is this really an official build of this repo?"* The trust anchor is
an Ed25519 public key **pinned in the app binary** (and therefore protected by
the app's own Apple code signature).

### Verification chain (most-trusted first)

1. **Pinned Ed25519 public key** — baked into the app via
   `BetterUpdaterConfiguration`, covered by the app's code signature.
2. **Signed manifest** (`betterupdater-manifest.json` + `.sig`, shipped as
   release assets) — Ed25519 signature checked against the pinned key, over the
   **raw manifest bytes** (never re-encoded JSON).
3. **Repo identity** — manifest must declare the pinned `owner` / `repo` /
   `bundleIdentifier`.
4. **Anti-replay** — the manifest entry's `version` / `build` must match the
   asset about to be installed (a valid old manifest can't be served for a new
   asset).
5. **Asset integrity** — SHA-256 + size of the downloaded file must match the
   manifest.
6. **Apple code signature** — `SecStaticCode`: anchor apple generic + bundle id
   + team id (the existing layer, now the second line of defense).

`manifestRequired` (default `true`) makes verification **fail-closed**: a
missing/invalid manifest refuses the update, so an attacker controlling the
GitHub API/CDN response cannot strip the manifest to fall back to the
Apple-only path.

## Integrating in an app

```swift
import BetterUpdater

// Once, early in app launch (e.g. applicationDidFinishLaunching),
// BEFORE AppTranslocation.guardLaunchLocation() or any BetterUpdater.shared use:
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

// Then use it like the old GitHubUpdater singleton:
guard AppTranslocation.guardLaunchLocation() else { return }
await BetterUpdater.shared.checkForUpdates(force: false)
```

`BetterUpdater.shared` is the `GitHubUpdater` `ObservableObject` (publishes
`state`, `latestRelease`, etc.) — bind it in SwiftUI/AppKit exactly as before.

## Signing releases (the `betterupdater` CLI)

```bash
# One time: generate a key pair.
betterupdater keygen
#   PRIVATE_KEY  -> store as a CI secret (BETTERUPDATER_PRIVATE_KEY)
#   PUBLIC_KEY   -> paste into the app's BetterUpdaterConfiguration

# In release CI, after building the .dmg/.zip:
betterupdater sign \
  --owner rokartur --repo BetterAudio \
  --bundle-id pro.betteraudio.BetterAudio --team-id YOURTEAMID \
  --version 26.6.3 \
  --asset dist/BetterAudio-26.6.3-20260503141522.dmg \
  --out dist/betterupdater-manifest.json \
  --private-key-file private.key       # or BETTERUPDATER_PRIVATE_KEY env

# Guard before publishing: fail the release if the pinned key can't verify it.
betterupdater verify \
  --public-key duIBPTDie9dBTKqijWVxsVHZ89AMuorAz04gF6K+TUQ= \
  --manifest dist/betterupdater-manifest.json \
  --asset dist/BetterAudio-26.6.3-20260503141522.dmg

# Upload the dmg/zip + manifest + .sig to the GitHub release.
```

The build number per asset is parsed from the trailing `-<digits>` in the
filename, or pass `--build`.

## Package layout

- `BetterUpdaterManifest` — dependency-free manifest model + Ed25519/SHA-256
  helpers + the full verifier. Shared by the library and the CLI.
- `BetterUpdater` — the updater engine, AppKit/SwiftUI update window, translocation
  guard, and signed-manifest gate. macOS 13+.
- `betterupdater` — the signing/verification CLI.

## License

See the consuming apps.
