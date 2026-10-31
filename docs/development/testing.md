# Development checks

Run commands from the repository root unless stated otherwise. Python 3.9+
compiles the pinned station catalog using the standard library. The first build
fetches its public Git revision; the cached exact checkout supports later offline
builds. Boundary-source maintenance has separate optional dependencies.

```sh
python3 -m tools.stations.build --source csv --target all --no-sync-android
python3 -m unittest discover -s tests -t . -v
```

The runtime tests compile production Swift readers against the generated data.
Those tests require the Swift toolchain and SQLite headers, supplied by Xcode on
macOS. The shared-data build must run before tests that inspect the real catalog.

```sh
xcodebuild -project CardBal.xcodeproj -scheme CardBal \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
(cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug)
(cd services/station-reports && npm ci && npm run typecheck && npm test && npm run build)
```

## Localization

English, Simplified Chinese, Japanese and Korean share the catalogs in
`ios/CardBal/Resources/*.lproj/Localizable.strings`. After editing them, regenerate
the Android resources and check coverage:

```sh
python3 tools/localization.py
python3 tools/localization.py --check
```

The Python suite checks matching keys and placeholders, untranslated English,
UI literals and Swift runtime translations. Android unit tests cover formatted
messages and language changes. After an iOS build, add `--swift-strings` pointing
to its `Objects-normal/arm64` directory to check compiler-extracted UI keys.
Keep user-entered titles and raw identifiers verbatim.

## iPhone device helpers

```sh
tools/ios/archive.sh
tools/ios/build-and-run.sh <DEVICE_UDID>
tools/ios/scan-logs.sh <DEVICE_UDID> [SECONDS]
```

`DEVICE_ID` can supply the device instead. Signing and bundle identifiers use the
project settings unless explicitly overridden. Build products and local log files
stay in ignored `build/ios/`. These commands act on the selected device and app.

## Optional Firebase configuration

A local `ios/CardBal/Resources/GoogleService-Info.plist` enables the existing
Firebase integration. It is ignored and copied into the app only when present.
Without it, the app builds with analytics unconfigured. The GitHub Actions
TestFlight workflow can provide `FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64`;
the root `ci_scripts/ci_post_clone.sh` decodes it. Do not commit that generated file.

Android works the same way with an ignored `android/app/google-services.json`
from the Firebase Android app registered for `ad.neko.cardbal.android`. The
Google Services Gradle plugin is applied only when that file exists. Without it,
Firebase stays unconfigured and analytics is disabled. The Google Play internal
workflow writes the file from `FIREBASE_GOOGLE_SERVICES_JSON_BASE64` (the base64
of the file) and skips this step when the secret is empty. Neither app has an
analytics setting or custom events. Android does not collect the advertising ID.

## Local state

Set `OCTOPUS_ENQUIRY_BASE_URL` in the build environment, or copy `.env.example`
to the ignored `.env` and supply the HTTPS enquiry base URL. iOS bundles a
generated configuration plist; Android generates its BuildConfig value.
The store upload workflows read the GitHub Actions secret of the same name.
For Xcode Cloud, supply that secret in its workflow environment.
The value is absent from tracked source but can be extracted from the built app.

Without configuration, public Octopus reads and existing IDm calibrations still
work, and Settings hides both Octopus switches. The Octopus Online toggle
controls whether new calibrations may contact the service; Allow Card Updates
(off by default) controls whether the service's card updates reach the card. `python3 -m unittest tests.runtime.test_octopus_online -v` exercises the
production Swift OCAP/HTTP path against a local synthetic server; Android's
`OctopusOnlineTest` exercises the same invented fixture and failure cases.

Keep Android SDK paths, signing configuration, caches, raw captures, and device
logs out of version control. The reviewed, anonymized owner collection and
explicitly synthetic wallets in `data/development/` are the documented exception;
see [simulator sample data](sample-data.md) for setup and provenance. Protocol
tests also use invented fixtures. Real-card verification is separate from tests: a successful
build does not establish support for an untested card generation.
