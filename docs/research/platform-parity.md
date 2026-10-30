# Card decoding on iPhone and Android

Reviewed 2026-10-31. Both apps now implement the following on-card decoding.
The checks use invented protocol bytes and production parsers; physical-card RF
validation and access to every card generation remain separate requirements.
An identifier, successful SELECT, logo or listed chip family does not count as
balance, ticket or travel-record support.

| Family | Balance / ticket data on both | Records on both |
| --- | --- | --- |
| Japanese transit IC | JPY purse | Usage and gate activity; Japanese station and bus lookup |
| IruCa, PASPY, SAPICA | Existing JPY profiles | Same profile-specific usage/gate services on both |
| OKICA | Latest transaction's JPY purse | Yui Rail / bus usage and top-ups; OKICA station codes |
| Ryuto | Latest transaction's JPY purse | Boarding/alighting time and numeric bus-stop codes |
| Edy | JPY purse, optional card number and issue date | Payments, top-ups and gifts |
| WAON | JPY purse, optional number/points | Paired-block payments/top-ups |
| nanaco | JPY purse, optional number/points/dates | Payments, top-ups, point redemption and transfers |
| Octopus | HKD purse | Existing balance-delta records; no guessed trip dates |
| T-money, EZL/Cashbee | KRW purse and metadata | Single transactions and Korean transit timestamps/fares; reviewed station aliases |
| U-Money | Issuer + serial-prefix identification, MNT purse | Compatible records in Ulaanbaatar time; no Korean station inference |
| NAMANE | KRW purse | SFI 14 compact transaction amounts/counters; no guessed dates |
| Snapper+ | Positively identified NZD purse | Paired SFI 3/4 records, signed fares/reversals and New Zealand dates |
| KMT FeliCa generation | IDR purse and optional card number | Raw history retained; historical epoch remains unresolved |
| T-Union / City Union | CNY purse; T-Union purse minus debt | PBOC and travel records; application/file identity retained in backups |
| NETS FlashPay / stored-value EZ-Link | Signed SGD-cent purse, CAN | CEPAS payments, MRT/bus transactions, reloads/refunds |
| Opal DESFire | Signed AUD-cent purse | Last-event summary only; no fare inferred from that summary |
| HSL V1/V2 / Waltti DESFire | EUR purse and ticket-product validity | Journey logs, last reload and embedded ticket validations |
| Older Clipper DESFire | Signed USD-cent purse | Trips and reloads; pending/completed trip halves reconciled |
| Navigo / OPUS / MOBIB / Rav-Kav | Network-specific contracts, passes and applicable trip/value counters | Public travel events; numeric operator/route/location fields |

The Calypso reader identifies the network from public environment fields and
requires decoded ticket or event data. Shared application names such as
`1TIC.ICA` are not evidence that a card belongs to Nice. See the
[Calypso implementation notes](calypso-public-records.md) for the supported
layouts and the Nice identification boundary.

## Persistence and display

New CEPAS, DESFire and Calypso records use bounded, versioned hex envelopes.
Both platforms preserve the same bytes in backups and select the corresponding
codec before any generic Japanese or Korean decoder. Moving ring-buffer slots
do not create extra visible events. Clipper completion and HSL/Waltti embedded
validation reconciliation operate on the whole history collection.

Amounts keep their original integer currency units until presentation. Issuer
time zones are explicit. An unavailable amount is shown as unavailable, not a
zero charge. KMT raw records remain available without an invented epoch.
Android also consumes the pinned unified CSV-built station catalog for Korean
aliases, Chinese terminal aliases and distance-weighted Japanese route drawing;
Japanese edge vertices use the same compressed geohash representation as iOS.
Application-specific records survive Android import, rescan and export.

## Boundaries

These additions cover readable physical-card generations. SimplyGo account
balances are not obtained from a CEPAS purse. Newer Clipper generations and
protected DESFire files are not enabled by recognizing an older application.
Myki, Nol, AT HOP and other identifier-only implementations are not counted.

MIFARE Classic examples from the GitHub survey, including Classic EasyCard and
Bip!, have not been advertised as iPhone NFC support. Core NFC does not expose
Classic sector access; Android additionally needs compatible hardware and the
appropriate keys. No keys, card-writing commands, personal captures or copied
GPL implementation code are included.

## Evidence and tests

- [CEPAS wire notes](cepas.md)
- [DESFire application layouts and transport](desfire-stored-value.md)
- [Calypso layouts and primary sources](calypso-public-records.md)
- Ryuto service `898F` / system `8B5D` and log fields: MIT
  [TRETJapanNFCReader at 03470a5](https://github.com/treastrain/TRETJapanNFCReader/blob/03470a515c0b06d762de39e6d80f9a07ed502cae/Sources/FeliCa/Ryuto/RyutoCardData.swift)
  and [service definition](https://github.com/treastrain/TRETJapanNFCReader/blob/03470a515c0b06d762de39e6d80f9a07ed502cae/Sources/FeliCa/Ryuto/RyutoCardItemType.swift).

Shared invented-byte fixtures live under `tests/runtime/fixtures`; Swift runtime
checks and Android JUnit tests consume them. Native simulator/APK builds check
that the real readers and display/backup integration compile together.
