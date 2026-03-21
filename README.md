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

## Run notes

- NFC scanning requires a real iPhone. The simulator can build the app but cannot read cards.
- In Xcode, set your own signing team before running on device.
