# Store workflows

Three manually triggered store workflows run from **Actions** on `master`.
Pushing a commit does not upload or submit an app.

## TestFlight and Google Play internal

Run [TestFlight](../../.github/workflows/testflight.yml) for iOS or
[Google Play internal](../../.github/workflows/play-internal.yml) for Android.
The optional `version` input defaults to the marketing version in the app
projects. Both project versions must agree. Each workflow tests, builds, signs
and uploads only its own platform, then saves the signed package as an artifact.
Apple may still be processing a build after the TestFlight workflow finishes.

The iOS build runs on GitHub's `xcode-27` runner image with Xcode 27.2
selected. iPhone Duo's full-screen layouts need the iOS 27.1 SDK or later; an
app built with an older SDK runs in a compatibility window on the Duo, and the
Duo-specific layout code is compiled out (`#if compiler(>=6.4)`).

iOS build numbers are simple counters: the TestFlight workflow reads the builds
already in App Store Connect and uses one above the highest plain number (53,
then 54, ...). Older dotted numbers, such as the timestamp builds 2495.1.8 and
2495.3.4 uploaded for 2.5.0, are ignored. Apple only requires a higher number
within one marketing version, so 2.5.1 (54) is accepted after 2.5.0
(2495.3.4); a new dotted number is never needed. Android version codes are
assigned when the build job starts, as minutes since 1 January 2020 UTC, because
Google Play requires every code to be higher than all earlier ones. The three
workflows share the `cardbal-stores` concurrency group, so test uploads and
submissions cannot overlap, and a later run sees the earlier upload. iOS and
Android build numbers need not match.

## Submit for review

After testing the uploads, run
[Submit for review](../../.github/workflows/submit-review.yml). Choose `both`,
`ios` or `android`. It selects the latest eligible, processed iOS TestFlight
build and/or the highest completed Google Play internal version code. When
submitting both platforms, their marketing versions must match. The selected
build ID and version code are checked again before submission.

The workflow submits the existing iOS binary to App Review with automatic
release after approval, and promotes the existing Android internal bundle to
the production track for Google's review and publishing process. It does not
rebuild or upload binaries. Store changes are separate transactions: inspect
the saved result artifact and store consoles if only one submission succeeds,
then rerun for the remaining platform.

Release notes default to `docs/release-notes/<selected version>.json`, a JSON
object mapping App Store locale names to What's New text. The optional
`release_notes` workflow input overrides that file. Include each existing iOS
locale when its saved notes are empty. Play currently uses only `en-US`, mapped
from the `en-GB` text. Keep that text within Play's 500-character limit.
When no override or matching file exists, saved store notes are retained.

The helper validates review contact, sign-in, export-compliance and listing
requirements. It preserves existing metadata. If a lower editable App Store
draft exists, it updates that draft's version number to the selected build's
version, then validates it again before submission. Active review submissions
are never replaced. Missing metadata must be completed in App Store Connect.
When adding iPad support, prepare the required iPad screenshot set on the draft
before submitting; existing iPhone screenshots do not cover that device family.

All workflows restrict store jobs to `master`. An accepted upload, a review
submission, store approval and public availability are distinct states.

## GitHub configuration

The store credentials are GitHub Actions repository secrets, available only to
the manual store jobs. The public CI workflow does not reference them.

| Secret | Used for |
| --- | --- |
| `ASC_KEY_ID`, `ASC_PRIVATE_KEY` | App Store Connect authentication; private key is PEM text |
| `ASC_ISSUER_ID` | Required for a team API key; unused for an individual key |
| `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD` | Matching Apple Distribution identity |
| `IOS_PROVISION_PROFILE_BASE64` | CardBal App Store provisioning profile |
| `FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64` | Optional existing iOS Firebase configuration |
| `FIREBASE_GOOGLE_SERVICES_JSON_BASE64` | Optional Android Firebase configuration (base64 of `google-services.json`) |
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | Existing Android upload keystore |
| `CARDBAL_UPLOAD_STORE_PASSWORD`, `CARDBAL_UPLOAD_KEY_ALIAS`, `CARDBAL_UPLOAD_KEY_PASSWORD` | Android upload-key signing |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Google Play Publisher service-account JSON |

The repository variable `ASC_APP_ID` identifies the existing CardBal App Store
record. Set `ASC_KEY_TYPE` to `individual` for a user API key; its default is
`team`. Both TestFlight and Submit for review use these GitHub Actions
credentials directly. They do not use Xcode Cloud.

Apple team keys grant access to every app. For a CardBal-only key, use an
individual key generated by an App Manager user whose app access includes only
CardBal. An Account Holder's individual key does not provide that restriction.
Create the restricted user before generating its key. Store the key ID and PEM
in this repository's `ASC_KEY_ID` and `ASC_PRIVATE_KEY` secrets, then set
`ASC_KEY_TYPE=individual`. A key's display name does not limit its app access.
Before installing it, verify that the new key's app list contains only CardBal.
Move the downloaded key to `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`
with file mode `600`; keep the directory private. Apple permits only one
download, so retain that local copy outside the repository.

App and team identifiers remain those configured in the app projects.
Renew the Apple distribution certificate/profile before expiry and replace the
corresponding secrets. Private keys, passwords and service-account JSON must
remain outside Git. Temporary signing keychains, profiles and credential files
are removed after use.

## Validation

```sh
actionlint .github/workflows/testflight.yml .github/workflows/play-internal.yml .github/workflows/submit-review.yml
python3 -m unittest discover -s tests -t .
python3 -m unittest discover -s android/tools/tests -v
```

The helpers can inspect store state without committing a release:

```sh
python3 -m tools.release.review select --platforms both --output build/review/selection.json
python3 android/tools/play_release.py inspect-latest-internal
```

These commands need their documented credentials and pinned Python dependencies.
Do not invoke `submit`, `upload-internal` or `promote-latest-to-production` while
validating a workflow unless an actual store change is intended.

References: [Apple build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[Apple API key access](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/),
[Apple API tokens](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests),
[Apple version metadata inheritance](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version/),
[Google Play edits](https://developers.google.com/android-publisher/edits),
[GitHub secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).
