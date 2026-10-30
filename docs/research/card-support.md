# Additional card support research

Reviewed 2026-10-28 against the Android and iPhone readers and current primary
platform documentation. These are implementation candidates, not claims that
additional cards have been tested on hardware. Recognition, balance and history
decoding are separate capabilities.

Implemented on 2026-10-30: Snapper+ balance and paired history, and KMT FeliCa
balance with optional card number and raw history, on both iPhone and Android.
The [implementation notes](../decoding/cards.md#snapper-and-kmt) describe
identification, currency handling, history limits and synthetic tests. Physical
card validation remains outstanding; the candidate analysis below records the
initial research priorities.

## Existing coverage and confirmed compatibility fixes

Android currently has five FeliCa profiles: standard Japanese transit IC,
Octopus, Rakuten Edy, WAON and nanaco. Its ISO7816 reader handles T-money,
EZL/Cashbee, NAMANE and T-Union. The iPhone implementation additionally has
IruCa, SAPICA, OKICA, a legacy PASPY profile, CityUnion, U-money handling and
network-specific Nice Calypso decoding. Entries in a brand-name dictionary do
not by themselves provide balance or transaction support.

The Android import includes three bounded corrections with synthetic tests:

- KS X 6924 balance reads use `90 4C 00 00 04`, independently of T-Union's PBOC
  command. Responses must have the successful status and exactly four balance
  bytes. See [protocol](../../android/app/src/main/java/ad/neko/cardbal/android/nfc/Iso7816Protocol.kt)
  and [tests](../../android/app/src/test/java/ad/neko/cardbal/android/nfc/Iso7816ProtocolTest.kt).
- `A0000004520001` is treated as the KROCAP configuration DF, rather than being
  labeled Lignes d'Azur. Only an unambiguous supported Korean main AID is
  followed, and that main application's selection must succeed. Unknown,
  conflicting and malformed FCI remains unsupported. The
  [primary KSX implementation](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/card/ksx6924/KROCAPConfigDFApplication.kt)
  identifies the same configuration DF.
- FeliCa polling must succeed before decoding a profile. The selected system's
  returned IDm replaces the discovery IDm; subsequent responses must match that
  address and valid framing. See [protocol](../../android/app/src/main/java/ad/neko/cardbal/android/nfc/FeliCaProtocol.kt)
  and [tests](../../android/app/src/test/java/ad/neko/cardbal/android/nfc/FeliCaProtocolTest.kt).

No additional card profiles are enabled by these corrections.

## Ranked next candidates

| Priority | Candidate | Platforms and minimum implementation |
| --- | --- | --- |
| 1 | Android parity: IruCa, SAPICA, OKICA and CityUnion | Reuse the existing [iPhone FeliCa profiles](../../ios/CardBal/NFC/Profiles/FeliCaProfiles.swift) and [Chinese readers](../../ios/CardBal/NFC/Decoders/TUnionDecoder.swift). Add typed balance/history parsing and synthetic vectors, then physical-card tests. Full Korean/U-money parity also needs purse metadata and currency handling. |
| 2 | Snapper+ in Wellington | Both platforms can reuse KS X 6924 transport. Add positive Snapper identification, NZD cent handling and its distinct SFI 3/4 record layout. Issuer ID alone is insufficient; older non-plus cards differ. [Issuer's current iPhone compatibility](https://www.snapper.co.nz/snapper-ios-app/), [primary decoder](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/snapper/SnapperTransitData.kt). |
| 3 | Kartu Multi Trip, FeliCa generation, Indonesia | Both platforms can use the existing unencrypted FeliCa reader. A balance-first profile needs system `90B7`, service `1017`, little-endian stored value and IDR. Add the iPhone system-code declaration. The reference history decoder has an uncertain historical epoch transition, so validate timestamps separately. [Primary implementation](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/kmt/KMTTransitData.kt). |
| 4 | Older Shenzhen Tong variants | Both platforms: separate ISO7816 `PAY.SZT` and legacy FeliCa `8005`/`0118` profiles, with CNY parsing. Modern T-Union cards already have a reader. Reuse transport rather than assuming all generations have the same history or balance layout. [PBOC reference](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/china/NewShenzhenTransitData.kt), [FeliCa reference](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/octopus/OctopusTransitData.kt). |
| 5 | Named Calypso networks such as Navigo, MOBIB and OPUS | Both platforms can reuse ISO7816 commands, but require per-network AIDs and record layouts. The current iPhone Calypso reader uses Nice-specific contract parsing and branding; adding AIDs alone would mislabel other networks. Readable public files and authenticated files must remain distinct. [Calypso application guidance](https://keyple.org/learn/user-guide/calypso-application/). |
| 6 | Verified DESFire layouts, starting with Opal | Both platforms need a DESFire transport, native command/status/chaining handling and a card-specific parser. The known Opal layout exposes balance and a last-event summary; that is not full trip history or access to protected files. [Primary decoder](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/opal/OpalTransitData.kt). |
| 7 | CEPAS / NETS FlashPay / card-based EZ-Link | Android has a public purse/history protocol. First verify each card generation's iPhone discovery path: older blanket claims of iPhone incompatibility are outdated. NETS confirms iPhone NFC reading, while current FareBot has a CEPAS fallback for some MIFARE-tag discoveries. This needs a device/card feasibility test before a support claim. Account-based SimplyGo balances are a separate backend concern. [Issuer](https://www.nets.com.sg/nets/for-you/nets-flashpay), [current iPhone reference](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/app/src/iosMain/kotlin/com/codebutler/farebot/shared/nfc/IosNfcScanner.kt). |

## Platform and access boundaries

For ordinary physical-card reading, iPhone uses the existing TAG capability and
usage description. Applicable ISO7816 AIDs and FeliCa system codes must also be
declared in `Info.plist`; runtime reader configuration cannot introduce
undeclared identifiers. [Apple tag reader](https://developer.apple.com/documentation/corenfc/nfctagreadersession),
[configuration](https://developer.apple.com/documentation/corenfc/nfctagreadersession/configuration/iso7816selectidentifiers).

Android exposes `IsoDep` and `NfcF`; applications implement the card protocol
above their raw I/O. Reader availability and a recognized technology are not
proof that a purse or history file can be read.
[Android NFC technologies](https://developer.android.com/develop/connectivity/nfc/advanced-nfc),
[NFC-F I/O](https://developer.android.com/reference/android/nfc/tech/NfcF).

MIFARE Classic requires a separate Android path, hardware support and appropriate
keys for protected sectors. Android makes that technology optional, and Core
NFC does not expose Classic access. Protected DESFire/FeliCa files similarly
need the issuer's access material; matching a logo or chip family cannot supply
it. Bank-card account balances and arbitrary Wallet credentials are not stored
value accessible through these transit readers.
[Android Classic requirements](https://developer.android.com/reference/android/nfc/tech/MifareClassic),
[Apple's supported MIFARE families](https://developer.apple.com/videos/play/wwdc2019/715/),
[NXP access conditions](https://www.nxp.com/docs/en/application-note/AN12343.pdf).

Metrodroid and FareBot are GPL-3.0 reference projects. The links establish
protocol and layout evidence; the Android corrections and their test inputs
here were written independently and contain no personal captures or keys.
