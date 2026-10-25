# BetterUpdater, agent guide

`README.md` carries the public API, install and the verification chain. This file carries what the code does not confess.

## Security invariants

A change that weakens one is a bug even with green tests.

- Verification is fail-closed: with `manifestRequired == true` a missing, unparsable or mis-signed manifest refuses the update. The Apple-only path exists for `manifestRequired == false` builds and nowhere else.
- The Ed25519 signature is checked over the raw downloaded manifest bytes; the JSON is decoded after the check.
- The manifest entry is matched to the asset being installed by `version` and `build`, and the asset to the manifest by SHA-256 and size.
- The pinned public key is the root of trust; `bootstrap` traps on a malformed key by design.
- `SecStaticCode` (anchor apple generic, bundle id, team id) is the second layer after the manifest.
- The private key enters the CLI only via `--private-key-file` or `BETTERUPDATER_PRIVATE_KEY`; `.gitignore` already blocks the key file patterns.
- `UpdateInstallerHelper` runs after every check above passed; it is the single place that strips the quarantine xattr.

## Conventions

- `GitHubUpdater` is `@MainActor`; `@Published` state changes there, network and file work runs in `Task`s that hop back.
- User-visible text: `String(localized:table:"Updater",bundle:.module)`. `StringCatalogTests` asserts the catalog holds exactly the keys the source emits, so a key and its `Updater.xcstrings` entry change in the same edit.
- Preferences persist in `UserDefaults.standard` under `GitHubUpdater.`-prefixed keys; renaming a key ships with a migration.
- Decision rules live in pure types (`GitHubUpdateDecision`, `ParsedVersion`, the schedule helpers) with a test each; UI code reads their results.
- GitHub API calls stay anonymous; a 403/429 sets `rateLimitedUntil` and the scheduler waits it out.
- `BetterUpdaterManifest` stays dependency-free so `ci/sign-release.yml` builds the CLI in seconds; swift-argument-parser is the CLI's only dependency.

## Releases

Tag is the bare version (`0.2.8`); the GitHub Release body is the changelog.

```bash
git tag <version> && git push origin <version>
gh release create <version> -R rokartur/BetterUpdater --title "<version>" --notes-file notes.md --verify-tag
```

Body format and SemVer rules: https://github.com/rokartur/BetterSettings/blob/main/AGENTS.md#releases--changelogs
