# 1 Continuous checks and releases

GitHub Actions runs the checks on each change and builds the DMG for each release. Both
workflows run on the `xcode-27` image (macOS 27, Apple silicon) with Xcode 27.1, Rust 1.96.0
and XcodeGen ([setup action](../.github/actions/setup/action.yml)). The `macos-26` image
has only Xcode 26.

## 1a Checks

[checks.yml](../.github/workflows/checks.yml) runs `scripts/check.sh model` for each push to
`main` and each pull request: Rust format, Clippy, Rust tests, swift-format, the documentation
check, the GUI build with the app icon check, the bridge smoke test and the model tests. The
UI tests do not run on GitHub, because they need the screen and the pointer of one machine.
Run `scripts/check.sh all` locally before a merge ([checks.md](checks.md)). When a check
fails, the run keeps the stage logs as the `check-logs` artifact for 14 days; a failed
release keeps them as `release-check-logs`. A newer push cancels the run of a pull request,
but each commit on `main` keeps its result.

The checks use no secrets.

## 1b Release a version

1. Make sure that the checks pass on the commit.
2. On GitHub, open Releases, then Draft a new release.
3. Type a new tag such as `v1.2.0` on that commit, a title and the notes. Click Publish.

[release.yml](../.github/workflows/release.yml) then:

1. reads the version from the tag; `v1.2.0` gives `1.2.0`, and other tag forms, such as
   `v1.2` or `1.2.0`, stop the run;
2. runs `scripts/check.sh model` on the tag;
3. builds the Release app for Apple silicon with that version
   ([build-release.sh](../scripts/build-release.sh)), before any secret is in the job;
4. signs the app with the Developer ID certificate and the hardened runtime, and puts it in a
   signed DMG with an Applications link ([package-release.sh](../scripts/package-release.sh));
5. sends the DMG to the Apple notary service, staples the ticket and checks it with
   Gatekeeper;
6. attaches `DiskInventory-1.2.0.dmg` and `DiskInventory-1.2.0.dmg.sha256` to the release.

The release shows without the DMG until the run ends, usually after 15 to 30 minutes. Draft
releases do not start the workflow. If a run fails, GitHub sends an email and the release
stays without a DMG. Fix the cause, then run the Release workflow by hand (Actions, Release,
Run workflow, branch `main`) with the same tag, or delete the release and its tag.

The app needs macOS 26 or later and Apple silicon. To scan protected folders, people add
the app in System Settings, Privacy & Security, Full Disk Access.

## 1c Signing secrets

The release job uses the GitHub environment `release`. Store these secrets in that
environment, not in the repository:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key, exported from Keychain Access as a `.p12` file, then encoded with `base64 -i developer-id.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | The password of the `.p12` file |
| `NOTARY_KEY_P8` | The full text of an App Store Connect API key file (`AuthKey_….p8`) with the Developer role |
| `NOTARY_KEY_ID` | The key ID of that API key |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the list of API keys |

Create the API key in App Store Connect, Users and Access, Integrations, App Store Connect
API, Team Keys. Apple lets you download the key file once only.

The job imports the certificate into a temporary keychain and deletes the keychain and the
key file at the end. Notarization stops with HTTP 403 when the Apple Developer Program
License Agreement is not accepted; accept it at developer.apple.com/account.

An environment gives its secrets to each job that names it, from any branch. These rules
keep the secrets for releases (Settings, Environments, release, and Settings, Rules):

- Deployment branches and tags: Selected, with the branch `main` and the tag pattern `v*`.
- A tag ruleset for `v*` that lets only administrators create, change or delete such tags.
- Optional: you as a required reviewer, so each release run waits for your approval.

Pull requests from forks never get the secrets.

## 1d Package locally

The release steps also run locally:

```sh
scripts/build-release.sh 1.2.0 /private/tmp/disk-inventory-release
scripts/package-release.sh 1.2.0 /private/tmp/disk-inventory-release
```

Without `SIGN_IDENTITY`, the app keeps its ad hoc signature, and macOS on other Macs blocks
it. With `SIGN_IDENTITY="Developer ID Application: NAME (TEAM)"`, the app and the DMG are
signed. Add `NOTARY_PROFILE`, a profile that `xcrun notarytool store-credentials` saved, or
`NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`, to notarize and staple the DMG
too. Each script replaces its work folder (`build` or `dmg` in the output folder) at the
start and removes it after a successful run. The output folder keeps the app, the DMG and
the checksum.
