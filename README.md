# CardBal / TransitICReader

English | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

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
- [Card capabilities on both platforms](docs/research/platform-parity.md)
- [Card decoding](docs/decoding/cards.md)
- [Additional-card feasibility and platform gaps](docs/research/card-support.md)
- [Station data and attribution](docs/data/station-assets.md)
- [Station-report service](services/station-reports/README.md)

The compatibility command `python3 scripts/build_cross_platform_station_assets.py`
continues to forward to the shared compiler.

## Station sources

Both apps compile station, line, and route data from the public
[iebb/card-stations](https://github.com/iebb/card-stations) CSV catalog, at the
revision pinned in `data/stations/card-stations.lock.json`. Send corrections there
as pull requests with a source. The catalog combines:

| Data | Source | License |
| --- | --- | --- |
| Japanese stations, lines, and rail geometry | [station_database](https://github.com/Seo-4d696b75/station_database) by Seo-4d696b75 | CC BY-SA 4.0 |
| Japanese FeliCa station and bus codes | CardBal code registries | No upstream grant recorded |
| T-Union and Shanghai City Union stations, lines, and gates | [Trip Reader / 读卡识途 data](https://github.com/domosekai/tripreader-data), Domosekai Limited and contributors | CC BY 4.0 |
| China and Korea coordinates, names, and map references | [OpenStreetMap contributors](https://www.openstreetmap.org/copyright) | ODbL 1.0 |
| Korean station codes and names | KORAIL KOTRIS, MOLIT, Seoul Metropolitan Government, Busan BIMS, KRIC, and Daegu Transportation Corporation | Publisher terms; Seoul data is KOGL Type 1 |
| Supplementary Korean names | [Wikidata](https://www.wikidata.org/wiki/Wikidata:Licensing) | CC0 1.0 |
| Ulaanbaatar stops and routes | UB Smart Bus, Ulaanbaatar Smart Card LLC | No license recorded |

City and province outlines in `data/boundaries/` come from
[geoBoundaries](https://www.geoboundaries.org) (CC BY 4.0; Runfola et al. 2020),
OpenStreetMap (ODbL 1.0), and [Natural Earth](https://www.naturalearthdata.com)
(public domain). Each JSON catalog records the underlying license of every
country layer. The reviewed inputs in `data/maintenance/` come from OpenStreetMap
and Trip Reader.

Per-path licenses and full license texts are in
[card-stations/licenses](https://github.com/iebb/card-stations/blob/master/licenses/README.md).
See also [Trip Reader provenance](docs/data/tripreader.md) and
[UB Smart Bus data](docs/data/ub-smart-bus.md).

## License

The source code is available under the [BSD 3-Clause License](LICENSE).

Station, map, and boundary data keep the upstream licenses listed above; the BSD
license does not apply to them. The bundled `cardbal_transit.sqlite` and the
Android station assets are adapted from those sources and keep their attribution
and share-alike terms. The Manrope font in the Android app is licensed under the
[SIL Open Font License 1.1](android/third_party/Manrope-OFL.txt). Card artwork,
card names, and logos belong to their issuers and are not covered by the BSD
license.
