# Chongqing payment and gate history correlation

The regression uses an entirely invented four-event scenario. Its dates, times,
terminal identifiers, fares, balances and station choices are test data, not a
user's journey or captured card payload.

Each invented payment/gate pair has an equal timestamp and fare, while its
terminal fields deliberately use unrelated namespaces:

| Invented timestamp | SFI 18 payment terminal | SFI 1E gate terminal | Event | Fare |
| --- | --- | --- | --- | --- |
| 2020-02-03 09:40:10 | `990000000001` | `8800000000000001` | Exit, 沙坪坝 | 0.00 |
| 2020-02-03 09:30:05 | `990000000001` | `8800000000000001` | Entry, 沙坪坝 | 0.00 |
| 2020-02-03 08:25:35 | `990000000002` | `8800000000000002` | Exit, 小龙坎 | -2.50 |
| 2020-02-03 08:10:20 | `990000000001` | `8800000000000003` | Entry, 沙坪坝 | 0.00 |

The public station keys exercise normal Chongqing station-name resolution.
The terminal identifiers are invented and do not assert any real gate mapping.

Static inspection of the official [Trip Reader 1.7.17-cn APK](https://support.domosekai.com/download/tripreader-1.7.17-cn.apk)
from its [download directory](https://support.domosekai.com/download/) established
that its SFI 1E reader can attach travel data to an eligible existing payment
on equal timestamps. The inspected APK has SHA-256
`b8cc78e73c3775f602656b4cde46c6ec4994ca364cdf985c5a18c6f68fe111b1`.
`L0.d.j` (JADX alias `L0.C0017d`), checked against the fallback instruction
listing, also has an alternative terminal-containment heuristic. Equal timestamps
do not require that heuristic. No decompiled source is included in this repository.

CardBal accepts equal timestamps and amounts/currencies within the same
application, without comparing payment and gate terminal identifiers. A
deduplicated CU/TU payment retains both application sources, so it can still
match TU travel data. Cross-application matches without that shared provenance
continue to require the exact zero-padded terminal relationship. Every match
must be unique in both directions; conflicting fares, missing dates, repeated
payment candidates and competing entry/exit candidates stay separate.

Both payment and ride history retain the entry/exit, station and balance data
and all source-record identities. Fares are never added. The raw application
records are unchanged. Saved application histories and older flattened wallet
records use the same decoder, so existing stored cards benefit without a rescan.

`tests/runtime/fixtures/chongqing_history.swift` constructs every record from
invented fields. The regression checks that eight input records become four
enriched events, including zero fares, saved and legacy cards, mirrored CU/TU
payments and ambiguous/conflicting records. Physical NFC verification remains
a separate device test.
