# Local Shenzhen, Wuhan, Lingnan Pass and Beijing purses

Both platforms read these distinct local
applications, not aliases for China T-Union or City Union. Identification alone
does not qualify: each reader requires a successful, four-byte balance response.
No physical cards have been tested.

| Layout | Application name | Metadata | History |
| --- | --- | --- | --- |
| Newer Shenzhen Tong | `PAY.SZT`, `5041592E535A54` | SFI `15`; serial bytes 16-19, little endian, with digit-sum check digit; issue/expiry bytes 20-23/24-27. FCI tag `8C` is the metadata fallback. SFI `1A` bytes 4-7, when readable, replace the expiry. | SFI `18` |
| Wuhan Tong | `AP1.WHCTC`, `4150312E5748435443` | SFI `0A` bytes 0-4 serial; SFI `05` bytes 20-23 issue, 16-19 expiry. | SFI `18` |
| Lingnan Pass (岭南通 / 羊城通 CPU) | `PAY.TICL`, `5041592E5449434C` (purse); `PAY.APPY`, `5041592E41505059` (details) | `PAY.APPY` SFI `15`, else its FCI tag `9F0C`: bytes 11-15 card number (hex), 27-30 expiry, 49 issuer. No issue date. | SFI `18` of `PAY.TICL` |
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
and backups. No station endpoints or zero-fare entry/exit events are inferred.

Shenzhen Tong and Lingnan Pass records also get a place, as Trip Reader shows it:

- Shenzhen Tong: `深圳市`. For purchases (`06`/`09`), `5180` plus the last four
  terminal bytes is looked up like a Shenzhen City Union terminal, in the same
  `cityunion_terminal_prefixes` table; a match names the station and marks the
  record as rail (or bus, by station type).
- Lingnan Pass: byte 10 `01` is `广州市` when byte 12 is `00`, otherwise `广东省`;
  byte 10 `88` names the member card's city from byte 11 (issuer codes below).

Otherwise the place is the terminal identifier. Wuhan and Beijing terminals are
not looked up, and no terminal is passed to T-Union, Japanese or Korean lookup.

## Lingnan Pass

Lingnan Pass (岭南通, issued by Guangzhou's 羊城通) is a separate local purse,
not a T-Union alias. The reader:

1. Selects `PAY.APPY` and takes the card details from its
   READ BINARY SFI `15` (Trip Reader reads 70 bytes), or the shorter FCI copy
   (`6F` › `A5` › `9F0C`, as NFSee reads) when SFI `15` is unreadable.
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

The details name the member card that issued it. Byte 49 is the issuer code;
a known code becomes the Brand, region and Issuing City, as with T-Union city
cards (the family stays "Lingnan Pass"):

| Code | Card | City | Code | Card | City |
| --- | --- | --- | --- | --- | --- |
| 1 | 羊城通 | 广州市 | 83 | 河源通 | 河源市 |
| 17 | 广佛通 | 佛山市 | 84 | 漠江通 | 阳江市 |
| 48 | 红海通 | 汕尾市 | 85 | 广达通 | 清远市 |
| 53 | 五邑通 | 江门市 | 86 | 茂名通 | 茂名市 |
| 64 | 肇庆通 | 肇庆市 | 87 | 嘉应通 | 梅州市 |
| 72 | 惠州通 | 惠州市 | 89 | 榕江通 | 揭阳市 |
| 80 | 湛江通 | 湛江市 | 96 | 云浮通 | 云浮市 |
| 82 | 韶州通 | 韶关市 | 97 | 潮州通 | 潮州市 |

An unknown code keeps "Lingnan Pass" / Guangzhou. Trip Reader also resolves
Guangzhou metro terminals to station names with its `metro-yct.csv`; that
table is not in CardBal's station data, so those records show the city and
terminal only.

Lingnan Pass is ordered after Shenzhen and Wuhan and before Beijing's generic
names, and like them after City Union / T-Union. On a card that also has
City Union / T-Union, those stay primary and Lingnan Pass is added as another
application. On 岭南通·八达通 cards Lingnan Pass pairs with Octopus the way
T-Union does: either side may be read first and the other interface is then
checked; the result is one card, "Octopus + Lingnan Pass", with two
applications. The Octopus HKD balance stays the card balance. The
`DualCurrencyBalance` CN¥ row (Octopus – T-Union cards share one purse) is
not filled from Lingnan Pass, whose RMB purse is separate. An
Octopus card read first without an Octopus-service exchange rate finishes
without checking for a second interface.

Unconfirmed on real cards: the card-number, expiry and issuer offsets (taken
from NFSee and Trip Reader), the `PAY.APPY` FCI contents, and Lingnan-specific
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
Info.plist so other cards retain their initial AID priority.
On every platform the local reader runs after the City Union / T-Union
reader. When a
card has both, the local application is read after City Union / T-Union
succeeded and added as another application; City Union / T-Union stays primary.

Trip Reader database import remains limited to its existing City Union/T-Union
backup layouts. Adding a live NFC reader does not establish a backup schema.
The legacy FeliCa Shenzhen generation is also outside this reader; Trip
Reader 1.7.17 reads only ISO-DEP cards, and its 深圳通 is this `PAY.SZT` reader.

## Evidence and validation

The implementation is independently written from public protocol facts. No
reference-project code, keys, card captures, artwork or station tables were
imported. The Shenzhen station names come from CardBal's existing City Union
station data.

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
- Trip Reader 1.7.17 (`tripreader-1.7.17-cn.apk`, SHA-256 as in
  [tripreader.md](../data/tripreader.md)): Lingnan Pass `PAY.APPY` SFI `15`
  70-byte layout (card number, expiry, issuer), issuer card names and cities,
  record cities; Shenzhen Tong SFI `1A` expiry and `5180` + last four terminal
  bytes for station lookup.
- Apple:
  [ISO 7816 discovery identifiers](https://developer.apple.com/documentation/bundleresources/information-property-list/com.apple.developer.nfc.readersession.iso7816.select-identifiers).

`tests/runtime/fixtures/china_local_synthetic.json` contains invented shared
inputs; the Lingnan tests also use the public `PAY.TICL` reply above. Swift runtime tests exercise the production protocol, decoder, history
registry and application persistence. Android JUnit checks the corresponding
readers and persistence, invalid identities, status words, continuation bounds,
overdrafts, top-ups and unknown transaction types.
