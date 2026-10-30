# Apple Watch card-reading feasibility

Investigated 2026-10-31 against the CardBal iOS source, Apple's public
documentation, and the locally installed Xcode 27.2 (27B52) SDKs. Source
references were rechecked the same day against the 2.5.0 monorepo source under
`ios/CardBal/`.

## Decision

**Direct physical-card reading with Apple Watch's built-in NFC: not feasible
with the current public watchOS SDK.** A paired Watch companion that displays
the results of iPhone scans is feasible. Reading through a separate Bluetooth
reader is a conditional hardware integration, rather than a direct NFC port.

| Experience | Feasibility | Main constraint |
| --- | --- | --- |
| Hold a physical Suica, Octopus, T-money, or other supported card near the Watch to read it | Not supported | Core NFC and `NFCTagReaderSession` are unavailable on watchOS |
| View balances and recent trips from the last iPhone scan | Feasible | Add watchOS UI, a sync payload, and local persistence |
| Show a favorite card's last scanned balance in a complication | Feasible | Background delivery and widget refresh are system scheduled |
| Request an update from the iPhone | Feasible for saved data | A fresh physical-card scan still requires the active iPhone app and the card near the iPhone |
| Read arbitrary transit cards already in Apple Wallet | Not a general solution | PassKit access is entitlement scoped; it does not grant universal access to other issuers' passes |
| Read a card using an external Bluetooth LE reader | Technically plausible; unverified | Reader protocol, FeliCa/APDU support, and watchOS compatibility must be demonstrated |

## Why built-in NFC is blocked

Apple's [NFC Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/nfc)
explicitly identify NFC scanning as unsupported on watchOS. The
[Core NFC framework](https://developer.apple.com/documentation/corenfc)
does not list watchOS as a supported platform.

Local SDK checks independently agree:

- `WatchOS27.2.sdk/System/Library/Frameworks/CoreNFC.framework` is absent.
- The iPhone SDK's `NFCTagReaderSession.h` marks the session and its polling
  options `API_UNAVAILABLE(watchos, macos, tvos, visionos)`.
- A Swift typecheck containing only `import CoreNFC` fails for the watchOS
  device target with `no such module 'CoreNFC'`, and succeeds for iOS using
  the same Xcode installation.
- A watchOS typecheck importing Foundation, SwiftUI, WatchConnectivity,
  WidgetKit, and CoreBluetooth succeeds.

This establishes public SDK availability, not the underlying NFC hardware's
electrical capabilities. Apple Wallet's NFC functionality does not expose a
general reader session to third-party Watch apps.

Apple's newer [NFC & SE Platform](https://developer.apple.com/support/nfc-se-platform/)
documents provisioning and presenting credentials on iPhone through approved
iOS apps. It does not supply the missing watchOS physical-card reader API.

## What this means for CardBal

The existing reader in `ios/CardBal/NFC/NFCTransitReader.swift` creates
`NFCTagReaderSession` sessions and polls ISO 18092, ISO 14443, and ISO 15693.
Decoders receive the transport-neutral `CardTag` from
`ios/CardBal/NFC/CardTransport.swift`;
`ios/CardBal/NFC/CoreNFCCardTransport.swift` adapts Core NFC FeliCa,
ISO 7816, and MIFARE tags to it. Those two Core NFC files cannot be compiled
into a normal watchOS target.

There is useful persisted data to reuse:

- `SavedCardRecord` already contains card identity, display preferences,
  balance, scan timestamp, and history records.
- `CardWalletStore.upsert(snapshot:)` merges scan results and persists them.
- The store also handles imports, edits, deletions, and iCloud restores; these
  changes should refresh the Watch snapshot too.

The current project has one iOS application target and no WatchConnectivity
integration. Sharing all existing source files with a new Watch target would
not work: `CardWalletStore` uses `UIImage`, `SavedCardColor` uses `UIColor`,
and saved-record history decoding goes through `TransactionDecoderRegistry`
into the full decoder and station-catalog sources, which have not been built
for watchOS. The app entry point also imports UIKit and Firebase. A separate
small watchOS app with a Foundation-only transfer model avoids making that
whole dependency graph a prerequisite.

## Recommended companion design

Keep the iPhone as the scanning and decoding device. Build a paired Watch app
that receives presentation-ready snapshots:

```text
Physical card -> iPhone Core NFC -> decode and persist
                                         |
                                  WatchConnectivity
                                         |
                                  Watch local cache
                                         |
                              Watch UI and complication
```

1. Define a versioned, `Codable` transfer model independent of UIKit, Core NFC,
   and station databases. Include a stable card ID, title, family, formatted
   balance(s), marker/color values, last scan time, and a bounded list of
   already decoded recent trips. Preserve separate application balances for
   cards that expose multiple purses.
2. Configure and activate `WCSession` on both devices. Publish the latest
   compact wallet snapshot with `updateApplicationContext(_:)` after relevant
   changes and once the session activates. Apple documents that this replaces
   any pending context, which fits synchronization of the current wallet.
3. Persist received state on the Watch. Display saved results when the phone
   is unavailable. Distinguish each card's `scannedAt` from the snapshot's
   sync time so a newly delivered old scan never appears to be a new read.
4. Use `sendMessage` only for a reachable companion's immediate saved-data
   refresh. A fresh card read should direct the person to open CardBal on
   their iPhone and hold the card near it. Do not promise that a message can
   silently start scanning on a locked or background iPhone.
5. Add a WidgetKit complication backed by the Watch cache. Share that local
   cache with the widget through a Watch app group, and request timeline
   reloads when snapshots arrive. Display the last scan time or a stale-data
   indicator. Delivery and reload requests do not guarantee immediate updates.

Apple's [Watch Connectivity sample](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
demonstrates companion messaging, background transfers, persistent widget
data, and complication updates. The
[`updateApplicationContext(_:)` documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:))
describes opportunistic delivery, replacement of pending state, and the
requirement for an activated session.

Use compact snapshots for the first version; a complete raw-record archive,
card-face images, and the station catalogs are unnecessary for a balance and
recent-trip viewer. If images are added later, use separate file transfers
and size-limited thumbnails.

The existing iCloud Documents backup is not an implemented Watch sync path.
WatchConnectivity provides the direct paired-device path without adding a
server. Independently installed or Family Setup operation would need a
separate data-source and synchronization design.

## Other routes

### External Bluetooth reader

Apple supports Bluetooth accessory communication on watchOS; its
[Bluetooth background execution session](https://developer.apple.com/videos/play/wwdc2022/10135/)
also explains runtime limits. This makes a foreground Watch app controlling
a BLE reader plausible, but does not prove any specific reader compatible.

Before selecting hardware, demonstrate all of the following on a real Watch:

- A documented BLE transport callable through CoreBluetooth, without an
  iOS-only binary SDK dependency.
- FeliCa polling and read commands for the relevant Japanese cards and
  Octopus; ISO 7816 APDU exchange for the relevant Korean, Chinese, Macau,
  Singapore, and Clipper DESFire cards; Ultralight page reads for Clipper
  tickets. Advertising only NDEF support is insufficient for CardBal.
- Reliable reconnects, complete reads within the available runtime, and an
  acceptable battery/physical interaction.

Decoders now use the `CardTag` transport abstraction, which also backs the
[USB CCID external-reader path](../development/external-nfc-readers.md) on
iPhone, iPad, and Mac. A BLE reader would need a new CoreBluetooth-backed
adapter for that interface, plus a watchOS build of the decoders, models, and
station catalogs they use; neither has been attempted. This is materially more
work than the companion viewer. No accessory has been selected or tested.

### Apple Wallet passes

PassKit exposes stored-value and transit pass properties, but
[`PKPassLibrary.passes()`](https://developer.apple.com/documentation/passkit/pkpasslibrary/passes())
returns only passes the app can access under its entitlements. CardBal's
current entitlements do not establish access to third-party transit passes.
Issuer-approved Wallet integration would be a separate project and would
not enable physical-card scanning on the Watch.

## Scope of verification and next milestone

The investigation reviewed source dependencies, current Apple documentation,
SDK headers/framework availability, and minimal Swift compiler probes.
It did not add an app target, change scanning behavior, test a physical Watch,
validate a particular accessory, or establish App Review acceptance.

If Watch support is desired, the next useful milestone is a companion
prototype: scan on iPhone, receive a versioned snapshot on a paired Watch,
show it offline with its scan time, then validate edits/deletions, reconnection,
and a complication on physical devices. Do not schedule a built-in NFC
reader implementation unless Apple adds a public watchOS reader API.
