# CardBal

Native SwiftUI iPhone app for scanning physical transit IC cards with CoreNFC.

## What it does

- Reads FeliCa transit cards with `NFCTagReaderSession`
- Shows the card ID (`IDm`)
- Tries to decode stored balance from the common transit-card balance service

## Current support

- Implemented: Japanese transit FeliCa cards on system code `0003` such as Suica, PASMO, and ICOCA
- Implemented: Octopus on FeliCa system code `8008`
- Implemented: KS X 6924 ISO7816 cards such as T-money, U-Money, and EZL/Cashbee. U-Money is distinguished from the shared T-money-compatible application by purse issuer `0x01` together with a normalized card number beginning with `16`.
- The app now shows structured raw payloads alongside the parsed balance
- An opt-in Developer Mode probes SFIs 1-30 with read-only APDUs and keeps every readable record and short-EF binary block in Raw Data.

## Station data

Station lookup sources are contribution-friendly CSVs in
[iebb/card-stations](https://github.com/iebb/card-stations). Japanese IC uses one
shared station file; T-Union is grouped by city, Korean cards by known company
or mode, and U-money by city. Xcode builds compile the pinned CSV revision into
the app's SQLite database before copying resources. The pin lives in
`StationAssets/card-stations.lock.json`; update it after merging a data PR.

```sh
python3 scripts/build_cross_platform_station_assets.py --target all
# Test an unmerged CSV contribution:
python3 scripts/build_cross_platform_station_assets.py --target all --csv-source ../card-stations
```

Set `CARDBAL_STATIONS_SOURCE=/path/to/card-stations` to test a local data checkout
in Xcode. Builds use the pinned commit by default and never refresh upstream
station services. The first build fetches that commit; later builds reuse it.

Generated portable station catalogs live in `StationAssets`. The Ulaanbaatar catalog is
generated from the service used by `com.uscc.ubbus` and contains Mongolian and
English station names, coordinates, routes, and ordered route-stop relations.
See [UB Smart Bus data](docs/ub-smart-bus.md) for the protocol and refresh
process.

Chinese station and terminal lookups also incorporate
[Trip Reader / 读卡识途 data](docs/tripreader-data.md), with pinned sources and
separate station-code and terminal-ID matching.

## Run notes

- NFC scanning requires a real iPhone. The simulator can build the app but cannot read cards.
- In Xcode, set your own signing team before running on device.
- Xcode Cloud stores the Firebase plist as the
  `FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64` workflow environment variable.
  `ci_scripts/ci_post_clone.sh` decodes it before the build; the generated plist
  remains ignored by Git.
