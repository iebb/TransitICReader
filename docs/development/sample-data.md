# Simulator and emulator sample data

Use the checked-in [development wallets](../../data/development/README.md) to
exercise the wallet, detail, raw-record and map views without NFC. The owner set
contains 48 cards and 513 raw records from Japan, Korea, China, Hong Kong and the
legacy Lignes d'Azur ticket display. The separate three-card mock set covers
Ryuto, Edy and nanaco with invented bytes and known test expectations.

The owner collection includes real captures and owner mock entries. Its source
export does not record which entries are mocks. Provenance is therefore recorded
for the collection, rather than guessed per card. The samples are useful for
decoder/UI development, not evidence of RF compatibility for every card.

## iOS Simulator

Build and install a **Debug simulator** app. For example:

```sh
xcodebuild -project CardBal.xcodeproj -scheme CardBal -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios-simulator CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot <SIMULATOR_UDID>
xcrun simctl install <SIMULATOR_UDID> \
  build/ios-simulator/Build/Products/Debug-iphonesimulator/CardBal.app
python3 -m tools.samples.launch ios --device <SIMULATOR_UDID>
```

Run commands from the repository root. If the simulator is already running,
omit `simctl boot`. Use `--set owner` or `--set mock` to load just one collection;
the default is `--set all` (51 cards). `--device booted` also works when exactly
one simulator is booted and has the app installed.

The launcher copies an artwork-free backup into the app's data container and
sets `CARDBAL_SAMPLE_BACKUP` for that process. Only Debug builds running in iOS
Simulator honor this variable. Xcode Scheme → Run → Arguments → Environment
Variables can supply the absolute copied JSON path instead.

The sample mode uses `Library/Application Support/CardBal/samples.sqlite`.
Every sample launch reloads the selected set; edits in this development wallet
are temporary. The normal `cards.sqlite`, migration data and iCloud metadata are
left alone. Both automatic and manual iCloud operations are disabled in sample
mode. Launch the normal wallet with:

```sh
python3 -m tools.samples.launch ios --device <SIMULATOR_UDID> --normal
```

## Android emulator

Install the Debug APK on a running Android emulator:

```sh
(cd android && ./gradlew :app:assembleDebug)
adb -s emulator-5554 install -r android/app/build/outputs/apk/debug/app-debug.apk
python3 -m tools.samples.launch android --device emulator-5554 --set all
```

The launcher verifies that the target is an emulator, copies the JSON through
`run-as` (which requires a debuggable app), and starts the activity with the
`cardbal.developmentSamples` intent extra. The app also requires a Debug build
and an emulator's `goldfish`/`ranchu` hardware before honoring that extra.
Samples use the separate `samples.sqlite` database, reloaded at each requested
sample launch. No root access, database replacement or custom images are needed.

```sh
python3 -m tools.samples.launch android --device emulator-5554 --normal
```

`--app-id` overrides the default iOS bundle ID or Android application ID for a
locally renamed build. Installing or updating the app is a separate step; the
launcher does not build, install or publish anything.

## Anonymization and correctness

The private export and its 16 custom image assets are **not** included. The
checked-in owner collection was prepared with `tools/samples/prepare.py`:

- Card IDs use a `sample:owner:` namespace. Card numbers/IDm, serial fields and
  identifier result fields receive consistent synthetic replacements. Japanese
  printed-number brand prefixes remain recognizable. Custom titles, photo-face
  settings, image filenames, image bytes and deletion markers are omitted.
  Simple color/marker choices remain for a varied development wallet.
- Scan dates, display dates and recognized encoded history calendars move by
  one privately chosen offset together. The offset is not published with the
  samples. Clock time, ordering and intervals remain meaningful. The
  script handles FeliCa dates, Edy's day counter, WAON/nanaco packed bits, Chinese
  BCD calendars, and Korean BCD, packed33 and Mybi calendars. Empty/invalid date
  sentinels stay empty/invalid; unknown dates are never invented.
- Balances, fares, event types, ticket counts/status, currency-related metadata,
  public station codes, city codes and Korean modes remain available. Station
  and terminal location codes are retained so existing resolution still works;
  the data is not intended to hide which public transit systems are represented.
- History counters are replaced consistently while retaining their sort order,
  gate/SAM device identifiers are
  cleared, and undecoded/reserved tails are zeroed. Octopus keeps the decoded
  balance field plus a synthetic marker to retain distinct records with equal
  balances; its unverified history clock is not copied or interpreted.
- The old export's decoded `transactions` objects are migrated back to raw
  hex records using `rawData`. Current apps decode those records normally.
  There is no second, hand-maintained list of displayed transactions.

This preserves the fields decoded by the current apps, with the documented
identity/date changes. It does not preserve cryptographic validity, unknown
vendor fields or an original RF/APDU session. The legacy Lignes entries retain
their ticket display fields; their missing raw contracts are not invented.

## Updating the samples

Keep a new private export outside tracked paths. Prepare a candidate in the
ignored build directory, then review the JSON and diff before copying it into
`data/development/`:

```sh
python3 -m tools.samples.prepare /absolute/private/wallet-export.json \
  --shift-days-file /absolute/private/date-offset.txt
python3 -m unittest tests.samples.test_development_samples -v
```

The offset file contains a nonzero integer number of calendar days. Keep it and
the source export private; choose an offset within the calendars' supported
year ranges. The repository's transformation tests use a separate known offset
on invented records, not the offset applied to the owner's collection.

The preparer only supports the documented families, record sizes and display
fields. Unknown layouts fail so they can be reviewed explicitly. Extending a
layout requires reviewing every identifier/calendar field and adding a focused
regression case. A valid JSON file alone is not proof of anonymization.

Do not copy the private source, SQLite wallet, images, screenshots or device
logs into this directory. Keep mock data explicitly labeled and document its
origin. Regenerate `mock-wallet.json` from the shared invented vectors with
`python3 -m tools.samples.prepare` (output defaults to `build/samples`).

The Python checks cover sample structure, representative transformations,
artwork rejection and launch isolation. Android tests import/round-trip both
wallets through the production backup models and decode the Edy/nanaco histories.
Production Swift checks verify backup decoding and the retail record dates,
fares and balances. Physical-card testing remains a separate task.
