# Store workflows

The repository has two manually triggered store workflows. Run them from
**Actions** on the `master` branch. Pushing a commit does not upload or release
an app.

## Upload

Run [Upload](../../.github/workflows/upload.yml), enter a three-part version
such as `2.5.0`, and leave the build counter blank for normal releases.
The workflow tests and builds both apps, signs them with the configured upload
credentials, then uploads the IPA to TestFlight and the AAB to Google Play's
internal testing track. It saves the signed packages as workflow artifacts.
Apple may still be processing the build after the workflow finishes.

Both apps receive the supplied marketing version. The default build counter is
`1000 + workflow run number`. iOS uses `counter.attempt`; Android uses
`counter * 100 + attempt`, so retrying a workflow produces a new build number.
An optional counter override from 1 to 9999 is available when an existing store
build has a higher number. Subsequent uploads must continue using a high enough
counter; never reuse a number already uploaded to that store.

## Release

After testing both uploads, run [Release](../../.github/workflows/release.yml).
It selects the latest eligible, processed iOS TestFlight build and the highest
completed Google Play internal version code. Their marketing versions and
Upload build counters must match; this prevents an older ready TestFlight build
being paired with a newer Android upload while Apple is processing. Existing
builds from before this paired Upload workflow need a paired Upload first.
The selected IDs are checked again before submitting, so another upload
cannot silently replace the selection.

Release submits the existing iOS binary to App Review with automatic release
after approval, and promotes the existing internal Android bundle to the
production track. It does not invoke Xcode, Gradle, signing or a binary upload.
Apple and Google still apply their normal review and publishing requirements.
Store changes are separate transactions: if one store rejects a request, inspect
the workflow results and store consoles before retrying.

Existing listing metadata and saved release notes are retained. The optional
`release_notes` input supplies actual iOS What's New text as locale-to-text JSON,
for example `{"en-US":"Improved station names and route drawing."}`. Supply
every localization that needs new notes, or prepare the matching version's
notes in App Store Connect first. The helper stops if required review contact,
sign-in, export-compliance or listing information is missing; it does not invent
answers. A new Apple version inherits the current listing, then receives the
selected build only after these checks.

Both workflows share a concurrency group so uploads and promotions do not run
at the same time. Neither workflow can run its store jobs from another branch.

## GitHub configuration

The store credentials are GitHub Actions repository secrets, available only to
the manual store jobs. The public CI workflow does not reference them.

| Secret | Used for |
| --- | --- |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | App Store Connect authentication; private key is PEM text |
| `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD` | Matching Apple Distribution identity |
| `IOS_PROVISION_PROFILE_BASE64` | CardBal App Store provisioning profile |
| `FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64` | Optional existing iOS Firebase configuration |
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | Existing Android upload keystore |
| `CARDBAL_UPLOAD_STORE_PASSWORD`, `CARDBAL_UPLOAD_KEY_ALIAS`, `CARDBAL_UPLOAD_KEY_PASSWORD` | Android upload-key signing |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Google Play Publisher service-account JSON |

The repository variable `ASC_APP_ID` identifies the existing CardBal App Store
record. App and team identifiers remain those configured in the app projects.
Renew the Apple distribution certificate/profile before expiry and replace the
corresponding secrets. Private keys, passwords and service-account JSON must
remain outside Git. Temporary signing keychains, profiles and credential files
are removed after use.

## Validation

```sh
actionlint .github/workflows/upload.yml .github/workflows/release.yml
python3 -m unittest discover -s tests -t .
python3 -m unittest discover -s android/tools/tests -v
```

The helpers can inspect store state without committing a release:

```sh
python3 -m tools.release.app_store select --app-id "$ASC_APP_ID"
python3 android/tools/play_release.py inspect-latest-internal
```

These commands need their documented credentials and pinned Python dependencies.
Do not invoke `submit`, `upload-internal` or `promote-latest-to-production` while
validating a workflow unless an actual store change is intended.

References: [Apple build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[Apple version metadata inheritance](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version/),
[Google Play edits](https://developers.google.com/android-publisher/edits),
[GitHub secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).
