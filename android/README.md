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
Neither directory belongs in Git. The Android package consumes:

- `JPStationCodes.csv`
- `JPBusCodes.csv`
- `jp_stations.sqlite`
- `tunion_stations.sqlite`
- `cardbal_transit.sqlite`
- `KOTRISTransportModes.json`
- `manifest.json`

The build verifies that these files exist and that no unused station exports
are packaged. `src/main/assets` is not a second source of station data.
Artwork and fonts are maintained under `src/main/res`; Manrope's license is
retained under `third_party/`.

## NFC scope

The app implements the same card-format decoders as iPhone, including the
additional Japanese FeliCa profiles, U-Money, City Union, CEPAS, named Calypso
networks, Opal, HSL/Waltti and older Clipper. See the
[card capability matrix](../docs/research/platform-parity.md). Recognition, readable balance and decoded
history are separate capabilities; a successful application selection does not
establish that every card version exposes all records.

Snapper+ balances and history use NZD cents and New Zealand time; paired raw
records survive rescans and iPhone/Android backup imports. KMT FeliCa balances
use whole IDR, with optional printable serial and raw history retained. KMT
history timestamps are not decoded because the epoch is unverified. See the
[card format notes](../docs/decoding/cards.md#snapper-and-kmt).

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

## Manual store workflows

Run [Google Play internal](../.github/workflows/play-internal.yml) on `master`
to test, build and upload a signed AAB to Google Play **internal testing**.
The optional marketing version defaults to the matching app project versions.
Android version codes count UTC minutes since 1 January 2020, assigned when
the build job starts. The separate [TestFlight workflow](../.github/workflows/testflight.yml)
handles iOS uploads independently.
The standalone Android helper accepts version codes from 1 through 2100000000.

The separate [Submit for review workflow](../.github/workflows/submit-review.yml) selects the
latest existing TestFlight and Play internal builds, checks their marketing
versions agree, then submits those builds for App Review/production. It does
not rebuild or upload binaries. Play selection uses the greatest numeric
version code and requires a single completed internal release with a numeric
marketing-version name. It fails on ambiguous metadata, a changed selection,
an unfinished production release, or an equal/newer production build. Play
review and managed publishing settings still determine when an accepted edit
becomes public. Both store steps use existing configured listings and their
review information; they do not create a new store listing. Choose Android
alone when iOS has already been submitted. Release notes default to the
committed JSON for the selected version; see the [release guide](../docs/development/releases.md).

Maintainers configure `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` as a GitHub secret for
the existing app's Play Developer API access, and the upload signing values
above through the workflow's secret configuration. No credentials belong in
the checkout. The service account needs permissions to inspect releases and
release to testing/production for `ad.neko.cardbal.android`. Review the
[official API setup](https://developers.google.com/android-publisher/getting_started)
when granting access.

The Gradle version overrides used by the workflow can also build a local unsigned AAB
when no upload signing values are configured:

```sh
./gradlew :app:bundleRelease -Ptransitic.versionName=1.2.3 -Ptransitic.versionCode=1234
```

The Play helper can inspect the internal selection without committing an edit:

```sh
python3 -m pip install -r tools/requirements-play.txt
python3 tools/play_release.py inspect-latest-internal --metadata-out /tmp/play-internal.json
python3 -m unittest discover -s tools/tests -v
```

It reads the secret environment variable or `--service-account-file` pointing
outside the checkout. JSON output includes only the package, track, marketing
version, numeric version code and operation result. Upload also records the
bundle's SHA-256. Promotion rechecks the workflow's expected version and code
inside its own edit, and reuses the existing bundle, release notes and update
priority. It does not change the internal track.

The helper uses the official
[bundle upload](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.bundles/upload),
[track update](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks/update)
and [edit commit](https://developers.google.com/android-publisher/api-ref/rest/v3/edits/commit)
APIs. It commits with `changesInReviewBehavior=ERROR_IF_IN_REVIEW`, so another
active review causes a failure rather than being cancelled. There is no
automatic retry that changes that review policy.
