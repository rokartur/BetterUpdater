# BetterUpdater, agent guide

Swift package: a GitHub-Releases auto-updater for macOS apps with a signed
repo-identity manifest. Read `README.md` first for the public API and the
verification chain. This file covers what an agent needs to change the code
safely.

## Commands

```bash
swift build                                      # library + CLI
swift test                                       # 54 XCTest cases
swift test --filter ManifestSignatureTests       # one suite
swift build -c release --product betterupdater   # the CLI binary
```

macOS 13+, Swift 6 language mode with strict concurrency on the library
target. No Xcode project; everything is SwiftPM. There is no UI test harness:
the update window is verified by running a host app (BetterAudio,
BetterCmdTab) against a real release.

## Layout

```
Sources/BetterUpdaterManifest/   Manifest.swift (model + verifier), Ed25519.swift (CryptoKit helpers)
Sources/BetterUpdater/
  BetterUpdater.swift            bootstrap(configuration:), shared
  BetterUpdaterConfiguration.swift
  GitHubUpdater.swift            the engine: check, schedule, download, verify, install, channels
  GitHubReleaseModels.swift      GitHubRelease, GitHubAsset, UpdateState, UpdateCheckInterval, UpdateError
  UpdateInstallerHelper.swift    detached shell helper that swaps the bundle after the app exits
  AppTranslocation.swift         translocation detection, move to /Applications
  UpdateWindowPresenter.swift    NSPanel host for the SwiftUI UpdateWindowView
  UpdateWindowView.swift, MarkdownView.swift, MarkdownNSView.swift   release-notes UI
  Resources/Updater.xcstrings    every user-facing string
Sources/betterupdater-cli/       keygen | sign | verify
Tests/BetterUpdaterTests/
ci/sign-release.yml              workflow template consumers copy into their repo
```

## Security invariants

Keep these. A change that weakens one is a bug even when tests pass.

- Verification is fail-closed. With `manifestRequired == true` a missing,
  unparsable or mis-signed manifest refuses the update. Never add a fallback
  to the Apple-only path.
- The Ed25519 signature is checked over the raw downloaded manifest bytes.
  Do not decode and re-encode before verifying.
- The manifest entry must match the asset about to be installed by `version`
  and `build`, and the asset by SHA-256 and size. Both checks stay.
- The pinned public key is the root of trust. `bootstrap` traps on a malformed
  key on purpose.
- `SecStaticCode` validation (anchor apple generic, bundle id, team id) stays as
  the second layer after the manifest.
- The private key never enters the repo. `.gitignore` blocks `*.privatekey`
  and `betterupdater-private*.txt`; the CLI reads it from
  `--private-key-file` or `BETTERUPDATER_PRIVATE_KEY`.
- The installer helper runs only after every check above passed; it is the
  step that strips the quarantine xattr, so nothing may call it earlier.

## Conventions

- `GitHubUpdater` is `@MainActor`; all `@Published` state changes happen there.
  Network and file work runs in `Task`s that hop back to the main actor.
- User-visible text goes through `String(localized:table:bundle:)` against
  `Updater.xcstrings`. `StringCatalogTests` asserts the catalog holds exactly
  the keys the source emits, so add or remove the key and its catalog entry
  together.
- Persisted preferences use `UserDefaults.standard` with `GitHubUpdater.`
  prefixed keys. Renaming a key needs a migration for existing users.
- Decision logic lives in pure, testable types (`GitHubUpdateDecision`,
  `ParsedVersion`, schedule helpers). Put new rules there, not in the UI.
- GitHub API calls are unauthenticated. A 403/429 sets `rateLimitedUntil` and
  the scheduler waits it out; never add a token to work around it.
- No new dependencies beyond swift-argument-parser (CLI only).
  `BetterUpdaterManifest` stays dependency-free so the CLI builds fast in CI.

## Releases

Tags are the bare SemVer version (`0.2.8`), no `v` prefix. Cut manually:

```bash
git tag <version> && git push origin <version>
gh release create <version> -R rokartur/BetterUpdater --title "<version>" --notes-file notes.md --verify-tag
```

The release body is the changelog: a `## <headline>` line, then only the
sections that apply (`### Added`, `### Changed`, `### Fixed`,
`### Performance`, `### Removed`) with bullets naming the real symbols that
changed, and a `**Full changelog:**` compare link to the previous tag.
`MAJOR` for source-breaking API changes, `MINOR` for new API, `PATCH` for
fixes.

Consumers pin `from: "<version>"` in their `Package.swift`; a `MAJOR` bump
requires updating them.
