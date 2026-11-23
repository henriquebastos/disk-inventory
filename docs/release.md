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

## 1c Set up GitHub

[setup-github.sh](../scripts/setup-github.sh) does each setup step with `gh`. Each step can
run again and changes only what is missing or different. No step prints a secret.

```sh
repo=OWNER/disk-inventory keys=~/.local/share/disk-inventory-release  # outside Git
scripts/setup-github.sh repo "$repo"           # public repository and origin remote; no push
scripts/setup-github.sh protect "$repo" OWNER  # release environment and tag ruleset
scripts/setup-github.sh csr "$repo" "$keys"    # private key and signing request for Apple
NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… \
  scripts/setup-github.sh secrets "$repo" "$keys" ~/Downloads/developerID_application.cer
scripts/setup-github.sh status "$repo"
```

Steps that only the account owner can do:

1. Accept the Apple Developer Program License Agreement at developer.apple.com/account.
   Until then, notarization stops with HTTP 403, and so does the `secrets` step.
2. Upload the signing request at developer.apple.com, Certificates, +, Developer ID
   Application. If Apple asks for a Sub-CA, choose G2. Download the certificate. This
   certificate is for GitHub only, so you can revoke it without an effect on your Mac.
3. Make an App Store Connect API key with the Developer role (App Store Connect, Users and
   Access, Integrations, Team Keys). Apple lets you download the `.p8` file once only. The
   issuer ID shows above the list of keys.

The `secrets` step checks the API key with the notary service. It adds the Apple
intermediate certificate from the keychains of the Mac to a `.p12` file with a random
password, and stores five secrets in the `release` environment:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and
`NOTARY_ISSUER_ID`. The release job imports the certificate into a temporary keychain and
deletes the keychain and the key files at the end.

An environment gives its secrets to each job that names it, from any branch. The `protect`
step keeps them for releases:

- The environment deploys only from the branch `main` and from tags that match `v*`.
- The `release tags` ruleset lets only administrators create, move or delete `v*` tags.
- With the optional user, each release run waits for the approval of that user.

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
