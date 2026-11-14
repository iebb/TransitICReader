# Other balance readers on iOS and Android

Reviewed 2026-11-01. Inclusion requires code that decodes a monetary balance;
identity, pass validity, purchase price and rides alone are insufficient.
This is a targeted source review, not a complete inventory of every reader
app, and it does not claim current physical-card validation.

FareBot and Metrodroid master were rechecked at `dc09f6f` and `b910c18`
respectively. NFSee master was `7f4db99`; TU-Reader was inspected at `f50948a`.
Both platform source trees and each actual balance path were considered:
an upstream README listing a card is insufficient.

## Best additional gaps

| Card / layout | Existing reader evidence | Platform assessment | CardBal gap |
| --- | --- | --- | --- |
| Lingnan Pass / Yang Cheng Tong local purse | NFSee's shared iOS/Android script selects `PAY.APPY` for information, then `PAY.TICL` for the balance and PBOC ledger. TU-Reader has both profiles and flags some station interpretation as partial. | Both platform sources exist in NFSee; application names fit Core NFC discovery. | Implemented on both platforms (2026-11-14); see [china-local.md](../decoding/china-local.md#lingnan-pass). |
| Suzhou Citizen Card `SUXIN.DDF01` | NFSee reads `80 5C 00 01 04` and explicitly omits transaction history for this layout. TU-Reader also lists `SUXIN.DDF01` and a separate `535A504B5F5A5959` application but marks Suzhou unverified. | Both platform sources exist in NFSee. Its balance command differs from the ordinary `P2=02` China purse command. | Missing on both. Balance-only satisfies the user's rule; no history should be promised from this source. The second TU-Reader profile is a separate unverified candidate. |
| Tsinghua campus CPU card | NFSee's ISO 14443-4 Type B branch selects `A00000000386980701`; `ReadTHU` obtains a balance using `P2=01` and the PBOC transaction path. | Shared iOS/Android source implementation. Sharing City Union's AID requires positive metadata identification rather than relabeling every City Union card. | Missing dedicated campus layout. Campus/cashless product scope should be deliberate; any future reader can omit name/student-number decoding. |
| MagnaCarta | FareBot DESFire factory selects `F080F3`, file `02`, bytes 6-7 as EUR stored value. | An unprotected DESFire balance candidate for both platforms; not independently physical-tested here. | Missing on both; no history in the inspected decoder. Cashless rather than transit scope. |
| Local Tianfu Tong CPU | CardBal iOS already reads its CNY purse, purchases/top-ups and monthly ride allocations. | This checkout has no matching Android decoder or AID registration. | **Existing iOS-to-Android parity gap**, separate from the four cards implemented in this change. |

NFSee's repository contains both iOS and Android clients using the shared
reader assets. That establishes a cross-platform source implementation, not
that a current App Store binary, phone and newly issued card have been tested.
In particular its Octopus implementation uses an old fixed balance offset; it
does not supersede CardBal's card-specific calibration work.

## Candidates with substantial limits

- **Intercard:** FareBot has a balance parser, but its factory expects a standard
  file where the reader may construct a value-file object. Currency is also
  hardcoded despite issuer differences. Resolve those facts before a support
  claim.
- **Tampere/Nysse, original ORCA and MRT Jakarta KJB:** balance implementations
  exist, but operator migration, stale card values or retirement can make the
  value unusable as a current balance. See the
  [FareBot assessment](farebot-public-card-survey.md) for primary evidence.
- **Legacy FeliCa Shenzhen Tong:** fixed-offset balance conversion still needs
  generation/calibration evidence. The new `PAY.SZT` reader does not implement it.
- **Classic balances** such as EasyCard Classic, Bip!, Oyster and Touch 'n Go:
  appropriate keys and compatible Android or external-reader hardware are
  separate requirements. Built-in iPhone NFC does not expose Classic sectors.
- **Ride-only Calypso/Ultralight profiles, bank cards, Myki/Nol and other
  identifier-only paths** do not pass the monetary-balance rule.

## Result of this change

The China trio and Lisbon Zapping now have production parsers in both CardBal
codebases. Newer Shenzhen, Wuhan and Lisbon have built-in iPhone discovery
paths. Legacy Beijing remains Android plus iOS/macOS external reader because
its short `OC` / `PBOC` names cannot be declared for Core NFC discovery.
See [platform parity](platform-parity.md) and
[card decoder details](../decoding/cards.md).

Trip Reader backup imports for Beijing, Shenzhen, Lingnan, Suzhou and Tianfu
remain skipped. Their database formats need their own import work; live-card
decoder availability is a separate capability.

## Primary sources

- [NFSee README and two platform clients](https://github.com/nfcim/nfsee/tree/7f4db99b8c5a9a0eeb46856844eacd48d7b28528).
- [NFSee shared balance/history functions and dispatch](https://github.com/nfcim/nfsee/blob/7f4db99b8c5a9a0eeb46856844eacd48d7b28528/assets/read.js):
  `ReadPBOCBalanceATCAndTrans`, `ReadLingnanTong`, `ReadSuzhouCitizenCard`,
  `ReadTHU` and the Type A/Type B dispatch.
- [TU-Reader profiles](https://github.com/HaoTian22/TU-Reader/blob/f50948a/app/src/main/java/com/example/nfctransit/CardProfile.kt)
  and [its stated validation limits](https://github.com/HaoTian22/TU-Reader/blob/f50948a/README.en.md).
- [FareBot MagnaCarta factory](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/magnacarta/src/commonMain/kotlin/com/codebutler/farebot/transit/magnacarta/MagnaCartaTransitFactory.kt)
  and [balance interpretation](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/magnacarta/src/commonMain/kotlin/com/codebutler/farebot/transit/magnacarta/MagnaCartaTransitInfo.kt).
- [Metrodroid master and platform/generation notes](https://github.com/metrodroid/metrodroid/tree/b910c1806fd86aa545223baf1d21fc5afe68eee2).
