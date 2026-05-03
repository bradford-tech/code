# BradfordCode

A telemetry-free, MIT-licensed build of [Microsoft Visual Studio Code](https://github.com/microsoft/vscode) for macOS arm64.

BradfordCode is built from upstream Visual Studio Code OSS source, with branding and build configuration applied locally. It does not include Microsoft's binary additions or telemetry.

## Status

This repository produces a notarized `.dmg` from a local build environment, and a daily GitHub Actions cron auto-builds + auto-publishes new releases when Microsoft VS Code releases a new stable tag. See [Continuous releases](#continuous-releases) below for details.

## What's different from upstream VS Code

- BradfordCode branding (name, icon, bundle identifier `tech.bradford.code`).
- Telemetry endpoints disabled at build time.
- The bundled GitHub Copilot extension is removed (you can install it from the marketplace if you have a subscription).
- GitHub sign-in uses a Personal Access Token instead of OAuth.
- Extension marketplace points at [Open VSX](https://open-vsx.org).
- Auto-update channel reads `versions/stable/darwin-arm64/latest.json` from this repo's `main` branch.

## Building locally

### Prerequisites

- macOS arm64 (Apple Silicon).
- Xcode Command Line Tools — `xcode-select --install`.
- Node 22.22.1 — install via `nvm install` from this directory (uses `.nvmrc`).
- Homebrew packages: `jq`, `librsvg` (only for icon regeneration), `imagemagick` (only for icon regeneration).
- An Apple Developer Program membership.
- A Developer ID Application certificate exported from Keychain Access as a `.p12` file.
- An app-specific password for `notarytool` (generate at <https://appleid.apple.com/account/manage>).
- Your Apple team ID (find at <https://developer.apple.com/account#MembershipDetailsCard>).

### Setup

```bash
cp .env.local.template .env.local
# Edit .env.local and fill in the certificate path, passwords, Apple ID, and team ID.
```

`.env.local` is gitignored. Never commit it.

### Build & package

Two wrappers in `dev/` orchestrate the build:

```bash
# Clean build → BradfordCode.app (~25-45 min)
./dev/local-build.sh > build.log 2>&1

# Sign + notarize + create DMG (~5-15 min, dominated by Apple's notarization queue)
./dev/local-package.sh > package.log 2>&1
```

The output `BradfordCode.arm64.<version>.dmg` lands in `assets/`.

### First-launch sanity check

```bash
open "assets/BradfordCode.arm64.$(plutil -extract CFBundleShortVersionString raw -o - VSCode-darwin-arm64/BradfordCode.app/Contents/Info.plist).dmg"
# Drag BradfordCode.app to /Applications.
spctl --assess --verbose /Applications/BradfordCode.app
# Expected: "accepted, source=Notarized Developer ID"
```

## Repository layout

| Path | Purpose |
|---|---|
| `dev/local-build.sh`, `dev/local-package.sh` | Local build/package orchestrators (source `.env.local`, run upstream fetch + build / signing) |
| `build.sh`, `prepare_vscode.sh`, `prepare_assets.sh` | Build pipeline scripts (downloaded VS Code → patched → built → signed → DMG) |
| `build/osx/prepare_assets.sh` | macOS signing + notarization + DMG creation |
| `patches/` | Patches applied to upstream VS Code source (~35 files) |
| `patches/osx/` | macOS-specific patches |
| `src/stable/` | File overlays copied into the VS Code source tree (icons, branded SVGs) |
| `icons/` | BradfordCode app icon and the script that builds it |
| `product.json` | Overlay merged on top of upstream VS Code's product.json |
| `upstream/stable.json` | Pinned VS Code commit/tag |
| `utils.sh` | Token substitution map (`!!APP_NAME!!`, `!!GH_REPO_PATH!!`, etc.) |

## Updating the upstream VS Code pin

Edit `upstream/stable.json` to point at a different VS Code tag/commit:

```json
{
  "tag": "1.116.0",
  "commit": "560a9dba96f961efea7b1612916f89e5d5d4d679"
}
```

Then run `./dev/local-build.sh` to fetch and build that version. Some patches (especially `00-ext-github-authentication-use-pat.patch` and `00-ext-github-remove-vscodedev.patch`) may need re-rolling against newer upstream code.

## Continuous releases

A daily GitHub Actions cron tracks new Microsoft VS Code stable releases. When upstream releases a new tag, the workflow builds + signs + notarizes + publishes BradfordCode automatically. Installed BradfordCode apps poll for updates every few hours and self-update when a new version lands.

The workflow is `.github/workflows/cron-build-and-release.yml`. The cron runs once daily at 06:00 UTC; an upstream patch release cut after that time isn't picked up until the next morning. Use `Run workflow → force_build: true` if you need an off-schedule build.

### Triggering manually

Go to `Actions → cron-build-and-release → Run workflow`. Set `force_build: true` to build even if VS Code's version hasn't changed (useful for testing build changes against the current pin).

### Required repository secrets

Set these at `Settings → Secrets and variables → Actions`. The workflow can't run without them.

| Secret | Value |
|---|---|
| `CERTIFICATE_OSX_P12_DATA` | base64 of your Developer ID Application `.p12` (single-line, no newlines: `base64 -i cert.p12 \| tr -d '\n' \| pbcopy`) |
| `CERTIFICATE_OSX_P12_PASSWORD` | the password you set when exporting the `.p12` |
| `CERTIFICATE_OSX_ID` | your Apple ID email |
| `CERTIFICATE_OSX_APP_PASSWORD` | app-specific password from <https://appleid.apple.com/account/manage> |
| `CERTIFICATE_OSX_TEAM_ID` | your Apple team ID (find at <https://developer.apple.com/account#MembershipDetailsCard>) |

### How auto-update works

The build embeds an `updateUrl` of `https://raw.githubusercontent.com/bradford-tech/code/main/versions`. Installed apps poll this base + `stable/darwin-arm64/latest.json` and download the DMG referenced by `url` if its `version` (commit sha) differs from the running app's commit. The release workflow rewrites that JSON every release.

### What to do when a build fails

The workflow opens (or comments on) a GitHub issue labeled `build-failure`. Click the run link in the issue, scroll to the failed step, and look at the logs. Common cases:

- **Patch failed to apply** — upstream VS Code source moved. Re-roll the listed patch against current upstream, push the fix, manually re-run the workflow.
- **Notarization rejected** — Apple's notary log explains which embedded binary lacked an entitlement. Usually a fresh upstream change. Patch and re-run.
- **`gh release create` failed** — re-run only the `release` job from the Actions UI; the DMG is still in the workflow's artifacts.

### Where releases land

`https://github.com/bradford-tech/code/releases`. Each release contains:
- `BradfordCode.arm64.<version>.dmg` — the notarized installer.
- `BradfordCode.arm64.<version>.dmg.sha256` — checksum sidecar.

## License

MIT. See [LICENSE](LICENSE).

This repository ships build scripts and configuration. The actual editor source is downloaded from `microsoft/vscode` at build time and is licensed under MIT.

## Acknowledgements

The build recipe and patch curation are adapted from [VSCodium](https://github.com/VSCodium/vscodium), the canonical OSS VS Code distribution. BradfordCode is a single-platform, single-channel narrowing of that work for an internal use case.
