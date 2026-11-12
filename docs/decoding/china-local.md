# Local Shenzhen, Wuhan and Beijing purses

Implemented 2026-11-01 in both platform codebases. These are distinct local
applications, not aliases for China T-Union or City Union. Identification alone
does not qualify: each reader requires a successful, four-byte balance response.
No physical cards have been tested.

| Layout | Application name | Metadata | History |
| --- | --- | --- | --- |
| Newer Shenzhen Tong | `PAY.SZT`, `5041592E535A54` | SFI `15`; serial bytes 16-19, little endian, with digit-sum check digit; issue/expiry bytes 20-23/24-27. FCI tag `8C` is the metadata fallback. | SFI `18` |
| Wuhan Tong | `AP1.WHCTC`, `4150312E5748435443` | SFI `0A` bytes 0-4 serial; SFI `05` bytes 20-23 issue, 16-19 expiry. | SFI `18` |
| Legacy Beijing Yikatong | `OC`, `4F43`, or `PBOC`, `50424F43` | SFI `04`, at least 32 bytes; bytes 0-7 serial, 24-27 issue, 28-31 expiry. All three are required to corroborate the otherwise generic short name. | SFI `18` |

All three use GET BALANCE `80 5C 00 02 04`. The public reference interprets
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

## Platform boundary

Shenzhen and Wuhan application names are declared in the iOS discovery list.
Legacy Beijing's 2- and 4-byte names are shorter than Core NFC's minimum
5-byte ISO 7816 discovery identifier. The decoder therefore works through the
iOS/macOS external ISO 7816 / CCID reader path and Android ISO-DEP, but is not
advertised as built-in iPhone NFC support. Beijing T-Union products continue
through the existing T-Union application. Adding a made-up padded Beijing AID
would not resolve discovery.

Built-in iPhone reads therefore try only `PAY.SZT` and `AP1.WHCTC`
(`ISO7816Card.selectsUnlistedApplications` is false); external readers try all
three. On every platform the local reader runs after the City Union / T-Union
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
  [Beijing purse DF, metadata and standard ledger](https://github.com/nfcim/nfsee/blob/7f4db99b8c5a9a0eeb46856844eacd48d7b28528/assets/read.js).
- Apple:
  [ISO 7816 discovery identifiers](https://developer.apple.com/documentation/bundleresources/information-property-list/com.apple.developer.nfc.readersession.iso7816.select-identifiers).

`tests/runtime/fixtures/china_local_synthetic.json` contains invented shared
inputs. Swift runtime tests exercise the production protocol, decoder, history
registry and application persistence. Android JUnit checks the corresponding
readers and persistence, invalid identities, status words, continuation bounds,
overdrafts, top-ups and unknown transaction types.
