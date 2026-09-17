# Direct-download releases

The public artifact is a universal macOS 26 DMG containing the Developer ID-signed app, an Applications
shortcut, installation instructions, and the MIT license. The app and DMG each receive a notarization
ticket. App Store Connect app records and Mac App Store submission are not part of this workflow.

## Prerequisites

- Full Xcode, XcodeGen, Python 3, `asc`, and `gh`.
- A Developer ID Application certificate and matching private key in Keychain. Use
  `security find-identity -v -p codesigning` to find its SHA-1 fingerprint. Apple Development identities
  are for source builds, not distribution.
- An authenticated `asc` profile; check it with `asc auth doctor`. Credentials stay in Keychain.
- A clean checkout of the commit to release, including the intended `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `project.yml`.

Only the Account Holder can issue Developer ID certificates. If Apple's API refuses creation, use
[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list)
with an Account Holder login. Upload a CSR, download the Developer ID Application certificate, and
import it beside the matching private key. Keep key material outside this repository.

## Verify the optimized code

The test targets use `@testable import`, so Release tests need `ENABLE_TESTABILITY=YES`. That flag is
for testing only; the release archive uses normal Release settings. On an Apple silicon Mac with
Rosetta installed, both architectures can run the same suite:

```sh
xcodegen generate
xcodebuild -project BarKeepersFriend.xcodeproj -scheme BarKeepersFriend \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -destination 'platform=macOS,arch=x86_64' \
  -parallel-testing-enabled NO \
  -derivedDataPath "$PWD/artifacts/release-tests/DerivedData" \
  -resultBundlePath "$PWD/artifacts/release-tests/Release-universal.xcresult" \
  -collect-test-diagnostics on-failure \
  COMPILER_INDEX_STORE_ENABLE=NO ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY="$BKF_SIGNING_IDENTITY" -quiet test
```

Use a fresh result-bundle path each time. Rosetta tests exercise the x86_64 code but do not replace
native testing on an Intel Mac. The native verification limits in `PARITY.md` remain.

## Build and notarize

Set `BKF_RELEASE_SIGNING_IDENTITY` to the Developer ID Application fingerprint, and optionally set
`BKF_ASC_PROFILE` to a named `asc` profile. Without a profile override, `asc` uses its configured default.
Run the following commands from the repository root, using a fresh output directory:

```sh
export BKF_RELEASE_SIGNING_IDENTITY='YOUR_DEVELOPER_ID_APPLICATION_SHA1'
python3 Scripts/release.py build --output artifacts/v0.1.0
python3 Scripts/release.py notarize-app --output artifacts/v0.1.0
python3 Scripts/release.py package --output artifacts/v0.1.0
python3 Scripts/release.py notarize-dmg --output artifacts/v0.1.0
python3 Scripts/release.py verify --output artifacts/v0.1.0
```

The builder archives and exports through Xcode with Hardened Runtime, secure timestamps, both
architectures, and debugger attachment disabled. It validates the bundle identity and version and
records the source revision in `build-info.json`. A build from a dirty checkout can be inspected,
but cannot pass public-release verification.

Notarization steps save submission IDs before polling. If Apple is still processing after ten minutes,
rerun the same step to resume that submission rather than uploading again. Accepted submissions have
their developer logs downloaded beside the receipts. Review warnings as well as errors. A rejected
submission, failed staple, or failed Gatekeeper assessment stops the workflow.

The final verifier mounts the DMG read-only, verifies the contained app and its ticket, checks
Gatekeeper acceptance for both artifacts, and detaches the image. It then writes `SHA256SUMS` and
`verified.json`. The notarization ZIP is an intermediate artifact; distribute the verified DMG.

## Publish

Test the exact signed/notarized app standalone before publishing. In particular, check the permission-free
baseline, Settings, icon capture, and a reversible native move while the desktop is unlocked. Upgrading
from an Apple Development-signed source build may require renewed Accessibility/Screen Recording grants.

Use the source revision from `build-info.json` for the release tag. Publish only the DMG and checksum
file; archives, build caches, and notarization receipts are not release assets. For version 0.1.0:

```sh
gh release create v0.1.0 \
  artifacts/v0.1.0/BarKeepersFriend-0.1.0-universal.dmg \
  artifacts/v0.1.0/SHA256SUMS \
  --repo aagrawal207/bar-keepers-friend \
  --target RELEASE_SOURCE_COMMIT --draft \
  --title "Bar Keeper's Friend 0.1.0" --notes-file RELEASE_NOTES_FILE
```

Confirm the draft's tag, notes, asset names, and checksums before publishing it with `gh release edit`.
After publication, download the public DMG and compare its checksum, verify the public latest-release
API used by the app's manual update check, and update README/AGENTS/PARITY with the actual results.

Keep the final DMG and its receipt/checksum records. Build intermediates can be cleaned after the
verification record is saved. Do not delete the currently running app or the signing identity.
