# TransitICReader for Android

The native Android app uses Kotlin, Jetpack Compose, Android NFC and SQLite.
Its application ID remains `ad.neko.cardbal.android` for existing installations.

## Build and test

Install JDK 17, Python 3, Git, Android SDK Platform 36 and Android Build Tools 36.0.0.
Accept the Android SDK licenses using the SDK tools. Set `ANDROID_HOME` to your
SDK directory, or set `sdk.dir` in the ignored `local.properties` file.

From this directory:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

On Windows, use `gradlew.bat`. Select JDK 17 through `JAVA_HOME` if another Java
version is the default. The checked-in Gradle 8.11.1 wrapper verifies its
download using the pinned distribution checksum.

The debug APK is generated at `app/build/outputs/apk/debug/app-debug.apk`.
For an optional arm64-only APK, add `-Pcardbal.abiSplit=true`. Python defaults to
`python3`; select another executable with `-Ptransitic.python=/path/to/python`.

## Shared station sources

`prepareStationAssets`, a dependency of `preBuild`, invokes the repository's
shared CSV build through `../scripts/build_cross_platform_station_assets.py`.
`../data/stations/card-stations.lock.json` pins the public CSV catalog, and
`../data/boundaries` contains shared geographic inputs. The first build resolves
that pinned catalog into the ignored `.external` cache. This builds the same
station sources used by iPhone and does not maintain a separate Android station
database or modify the iOS resource directory. Set `CARDBAL_STATIONS_SOURCE` to
an explicit local catalog checkout when testing a station contribution; the
asset task rebuilds whenever that override is set.

Generated Android assets live under `app/build/generated/stationAssets`.
Intermediate portable exports live under `app/build/generated/portableStationAssets`.
Neither directory belongs in Git. The Android package consumes exactly:

- `JPStationCodes.csv`
- `JPBusCodes.csv`
- `jp_stations.sqlite`
- `tunion_stations.sqlite`
- `manifest.json`

The build verifies that these files exist and that no unused station exports
are packaged. `src/main/assets` is not a second source of station data.
Artwork and fonts are maintained under `src/main/res`; Manrope's license is
retained under `third_party/`.

## NFC scope

The app currently implements FeliCa readers for standard Japanese transit IC,
Octopus, Rakuten Edy, WAON and nanaco, and ISO7816 readers for T-money,
EZL/Cashbee, NAMANE and T-Union. Recognition, readable balance and decoded
history are separate capabilities; a successful application selection does not
establish that every card version exposes all records.

The unit tests use synthetic NFC frames and APDUs. They cover KS X 6924 balance
commands, guarded KROCAP configuration-DF resolution, malformed responses and
FeliCa system changes, alongside iPhone-backup compatibility. Real NFC needs a
physical device and card; unit tests do not establish hardware compatibility.
The [card support research](../docs/research/card-support.md) describes the
next candidate families and platform constraints.

## Optional private signing

Debug builds use Android's standard local debug signing. No release key is
included. With no upload-key configuration, release builds remain unsigned.
Maintainers may provide all four existing signing values through environment
variables or the ignored `local.properties` file:

- `CARDBAL_UPLOAD_STORE_FILE`
- `CARDBAL_UPLOAD_STORE_PASSWORD`
- `CARDBAL_UPLOAD_KEY_ALIAS`
- `CARDBAL_UPLOAD_KEY_PASSWORD`

Keep keystores outside the checkout. Do not commit `local.properties`, `local/`,
SDK paths, passwords, keystores, caches, APKs, bundles or build output.
