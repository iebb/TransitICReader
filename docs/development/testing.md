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
Without it, the app builds with analytics unconfigured. Xcode Cloud can provide
`FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64`; the root
`ci_scripts/ci_post_clone.sh` decodes it. Do not commit that generated file.

## Local state

Keep Android SDK paths, signing configuration, caches, raw captures, and device
logs out of version control. The repository tests use invented protocol-shaped
fixtures. Real-card verification is separate from synthetic tests: a successful
build does not establish support for an untested card generation.
