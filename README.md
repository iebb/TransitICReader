# CardBal / TransitICReader

Transit IC-card readers for iPhone and Android. The apps read supported on-card
balances and records through Core NFC, ISO-DEP, and FeliCa; the available fields
depend on the card family and phone. No card-writing or top-up feature is included.

## Repository layout

| Directory | Purpose |
| --- | --- |
| `ios/CardBal/` | SwiftUI app, Core NFC readers, decoders, and iOS runtime resources |
| `CardBal.xcodeproj/` | Stable Xcode and Xcode Cloud project entry point |
| `android/` | Android app, Gradle wrapper, NFC readers, and unit tests |
| `tools/stations/` | Pinned CSV compilation and unified database packaging |
| `tools/boundaries/` | Geographic catalog maintenance |
| `tools/maintenance/stations/` | Explicit upstream research/import tools |
| `tools/ios/` | Portable archive, device-run, and log helpers |
| `tests/` | Python and production-Swift regression tests |
| `data/` | Catalog pin, geographic inputs, and offline maintenance inputs |
| `services/station-reports/` | Station-report API and review interface |
| `design/cards/` | Source/reference card artwork |
| `docs/` | Decoder notes, data attribution, development guides, and research |

## Build

Compile the station data shared by both apps:

```sh
python3 -m tools.stations.build --source csv --target all
```

The source is the public [iebb/card-stations](https://github.com/iebb/card-stations)
CSV catalog, pinned by `data/stations/card-stations.lock.json`. Compiler outputs
are generated under ignored `build/stations/`; each app receives only its runtime
files. See [station data](docs/data/station-assets.md).

For iPhone, open `CardBal.xcodeproj` in a current Xcode with Core NFC support.
A simulator build does not require a Firebase configuration:

```sh
xcodebuild -project CardBal.xcodeproj -scheme CardBal \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For Android, install JDK 17 and Android SDK 36, then:

```sh
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

Android builds invoke the shared catalog compiler automatically. Release signing
uses private local settings or environment variables; no signing material is
included. See [Android setup](android/README.md).

## Development

- [Testing and build checks](docs/development/testing.md)
- [Manual TestFlight, Play internal and store release workflows](docs/development/releases.md)
- [Card decoding](docs/decoding/cards.md)
- [Additional-card feasibility and platform gaps](docs/research/card-support.md)
- [Station data and attribution](docs/data/station-assets.md)
- [Station-report service](services/station-reports/README.md)

The compatibility command `python3 scripts/build_cross_platform_station_assets.py`
continues to forward to the shared compiler.
