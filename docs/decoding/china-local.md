# Local Shenzhen, Wuhan, Lingnan Pass and Beijing purses

Implemented 2026-11-01 in both platform codebases; Lingnan Pass added 2026-11-14. These are distinct local
applications, not aliases for China T-Union or City Union. Identification alone
does not qualify: each reader requires a successful, four-byte balance response.
No physical cards have been tested.

| Layout | Application name | Metadata | History |
| --- | --- | --- | --- |
| Newer Shenzhen Tong | `PAY.SZT`, `5041592E535A54` | SFI `15`; serial bytes 16-19, little endian, with digit-sum check digit; issue/expiry bytes 20-23/24-27. FCI tag `8C` is the metadata fallback. | SFI `18` |
| Wuhan Tong | `AP1.WHCTC`, `4150312E5748435443` | SFI `0A` bytes 0-4 serial; SFI `05` bytes 20-23 issue, 16-19 expiry. | SFI `18` |
| Lingnan Pass (岭南通 / 羊城通 CPU) | `PAY.TICL`, `5041592E5449434C` (purse); `PAY.APPY`, `5041592E41505059` (details) | `PAY.APPY` FCI tag `9F0C`, else its SFI `15`: bytes 11-15 card number (hex); issue/expiry bytes 20-23/24-27, shown only as a valid pair. | SFI `18` of `PAY.TICL` |
| Legacy Beijing Yikatong | `OC`, `4F43`, or `PBOC`, `50424F43` | SFI `04`, at least 32 bytes; bytes 0-7 serial, 24-27 issue, 28-31 expiry. All three are required to corroborate the otherwise generic short name. | SFI `18` |

All use GET BALANCE `80 5C 00 02 04`. The public reference interprets
bit 31 as a flag and bits 30-0 as a signed integer of CNY cents. This preserves
both flag-set positive balances and overdrafts. `FFFFFFFF`, failed statuses and
wrong-length replies remain unavailable; they never become zero. This rule is
specific to these China formats and is not applied to Macau Pass or Tianfu Tong.

The reader first tries SFI addressing, then paths `1001/00xx` and `00xx`.
Beijing and Wuhan metadata can fall back to the master file. Beijing also tries
the `1001` purse DF when balance is unavailable in the named application.
History can fall back to the `0018` file path. Response handling follows bounded
`6Cxx` length correction and `61xx` GET RESPONSE continuations. Every command
is SELECT, READ BINARY, READ RECORD, GET BALANCE or GET RESPONSE.

Each 23-byte ledger record preserves its original application, SFI and slot:

- Bytes 0-1: purchase counter.
- Bytes 5-8: unsigned amount in CNY cents.
- Byte 9: type `02` top-up, `06` purchase, `09` compound purchase.
- Bytes 10-15: terminal identifier.
- Bytes 16-22: BCD `yyyyMMddHHmmss`, in `Asia/Shanghai`.

Only the established types acquire signed monetary amounts. Unknown types retain
an unavailable amount. Invalid dates, BCD or record lengths are not displayed as
transactions, while original readable records remain available in diagnostics
and backups. Terminal identifiers are not passed to City Union, T-Union,
Japanese or Korean station lookup. No station endpoints or zero-fare entry/exit
events are inferred.

## Lingnan Pass

Lingnan Pass (岭南通, issued by Guangzhou's 羊城通) is a separate local purse,
not a T-Union alias. The reader:

1. Selects `PAY.APPY` and takes the card details from its FCI (`6F` › `A5` ›
   `9F0C`), or READ BINARY SFI `15` when the FCI has no `9F0C`.
2. Selects `PAY.TICL` for GET BALANCE and the 23-byte SFI `18` ledger. If
   `PAY.TICL` is absent or has no balance, `PAY.APPY` is tried as the purse.
   Without the `PAY.APPY` details, SFI `15` (or paths `1001/0015`, `0015`) of
   the purse application is the fallback. The master file is never selected.

The `PAY.TICL` FCI's own `9F0C` is not the details file: a real reply,
`6F34 8408 5041592E5449434C A528 9F08 01 02 9F0C 21 FF×8 00×16 20190824
00000186A0`, has no card number at bytes 11-15. It is kept in diagnostics
only. The `PAY.APPY` selection is kept beside it.

Balance and ledger use the shared PBOC rules above. Records keep `PAY.TICL`
as their application and SFI `18`.

Lingnan Pass is ordered after Shenzhen and Wuhan and before Beijing's generic
names, and like them after City Union / T-Union. On a card that also has
City Union / T-Union, those stay primary and Lingnan Pass is added as another
application. On 岭南通·八达通 cards Lingnan Pass pairs with Octopus the way
T-Union does: either side may be read first and the other interface is then
checked; the result is one card, "Octopus + Lingnan Pass", with two
applications. The Octopus HKD balance stays the card balance. The
`DualCurrencyBalance` CN¥ row (Octopus – T-Union cards share one purse) is
not filled from Lingnan Pass, whose RMB purse is separate. As before, an
Octopus card read first without an Octopus-service exchange rate finishes
without checking for a second interface.

Unconfirmed on real cards: the card-number offset (taken from NFSee), the
issue/expiry offsets (standard PBOC `0015` layout; shown only when both are
valid dates in order), the `PAY.APPY` FCI contents, and Lingnan-specific
ledger types beyond `02`/`06`/`09`. Built-in iPhone reads write the AIDs tried
and their status words to Settings › Troubleshooting.

## Platform boundary

Shenzhen and Wuhan application names are declared in the iOS discovery list.
Legacy Beijing's 2- and 4-byte names are shorter than Core NFC's minimum
5-byte ISO 7816 discovery identifier. The decoder therefore works through the
iOS/macOS external ISO 7816 / CCID reader path and Android ISO-DEP, but is not
advertised as built-in iPhone NFC support. Beijing T-Union products continue
through the existing T-Union application. Adding a made-up padded Beijing AID
would not resolve discovery.

Built-in iPhone reads therefore try only `PAY.SZT`, `AP1.WHCTC`, `PAY.APPY`
and `PAY.TICL` (`ISO7816Card.selectsUnlistedApplications` is false); external
readers also try Beijing's names. `PAY.APPY` and `PAY.TICL` are listed last in
Info.plist so no other card's initial AID changes; before 2026-11-14 they were
not listed, so Core NFC never reported a Lingnan-only card's ISO 7816
interface. On every platform the local reader runs after the City Union / T-Union
reader (2.6.0 ran it first, and City Union-only cards stopped reading). When a
card has both, the local application is read after City Union / T-Union
succeeded and added as another application; City Union / T-Union stays primary.

Trip Reader database import remains limited to its existing City Union/T-Union
backup layouts. Adding a live NFC reader does not establish a backup schema.
The legacy FeliCa Shenzhen generation is also outside this addition.

## Evidence and validation

The implementation is independently written from public protocol facts. No
reference-project code, keys, card captures, artwork or station tables were
imported.

- Metrodroid at `b910c1806fd86aa545223baf1d21fc5afe68eee2`:
  [shared balance and file facts](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/china/ChinaTransitData.kt),
  [Shenzhen](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/china/NewShenzhenTransitData.kt),
  [Wuhan](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/china/WuhanTongTransitData.kt),
  [Beijing and its explicit iOS restriction](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/china/BeijingTransitData.kt),
  [ledger layout](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/china/ChinaTrip.kt).
- NFSee at `7f4db99b8c5a9a0eeb46856844eacd48d7b28528`:
  [Beijing purse DF, metadata and standard ledger](https://github.com/nfcim/nfsee/blob/7f4db99b8c5a9a0eeb46856844eacd48d7b28528/assets/read.js);
  Lingnan Pass (`ReadLingnanTong`, `BasicInfoFile`): `PAY.APPY` first, details
  from FCI `9F0C` or `00B095001E`, card number at hex digits 22-31, then
  `PAY.TICL` for balance and SFI `18` records; its
  [Info.plist](https://github.com/nfcim/nfsee/blob/7f4db99b8c5a9a0eeb46856844eacd48d7b28528/ios/Runner/Info.plist)
  lists both names.
- [wiki.nfc.im](https://wiki.nfc.im) AID index: `PAY.APPY` / `PAY.TICL` for
  羊城通 / 岭南通.
- [flutter_nfc_kit issue #32](https://github.com/nfcim/flutter_nfc_kit/issues/32):
  a real 羊城通 `PAY.TICL` SELECT reply followed by a working `805C000204`.
- Lakr233/CoreExtendedNFC at `f62736587c4d918799835236aaa4d70a00a8adeb` has no
  Lingnan Pass reader; nothing was used from it.
- Apple:
  [ISO 7816 discovery identifiers](https://developer.apple.com/documentation/bundleresources/information-property-list/com.apple.developer.nfc.readersession.iso7816.select-identifiers).

`tests/runtime/fixtures/china_local_synthetic.json` contains invented shared
inputs; the Lingnan tests also use the public `PAY.TICL` reply above. Swift runtime tests exercise the production protocol, decoder, history
registry and application persistence. Android JUnit checks the corresponding
readers and persistence, invalid identities, status words, continuation bounds,
overdrafts, top-ups and unknown transaction types.
