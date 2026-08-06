# CardBal

Native SwiftUI iPhone app for scanning physical transit IC cards with CoreNFC.

## What it does

- Reads FeliCa transit cards with `NFCTagReaderSession`
- Shows the card ID (`IDm`)
- Tries to decode stored balance from the common transit-card balance service

## Current support

- Implemented: Japanese transit FeliCa cards on system code `0003` such as Suica, PASMO, and ICOCA
- Implemented: Octopus on FeliCa system code `8008`
- Implemented: KS X 6924 ISO7816 cards such as T-money and EZL/Cashbee
- The app now shows structured raw payloads alongside the parsed balance

## Station data

Portable station catalogs live in `StationAssets`. The Ulaanbaatar catalog is
generated from the service used by `com.uscc.ubbus` and contains Mongolian and
English station names, coordinates, routes, and ordered route-stop relations.
See [UB Smart Bus data](docs/ub-smart-bus.md) for the protocol and refresh
process.

## Run notes

- NFC scanning requires a real iPhone. The simulator can build the app but cannot read cards.
- In Xcode, set your own signing team before running on device.
- Xcode Cloud stores the Firebase plist as the
  `FIREBASE_GOOGLE_SERVICE_INFO_PLIST_BASE64` workflow environment variable.
  `ci_scripts/ci_post_clone.sh` decodes it before the build; the generated plist
  remains ignored by Git.
