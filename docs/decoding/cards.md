# CardBal Card Decoding Reference

This document summarizes how CardBal reads and decodes each supported card
family. It reflects the current iOS implementation and the Android native port.
The [platform matrix](../research/platform-parity.md) records the current
cross-platform scope. It is an implementation reference, not an official specification for any card
network.

## Decode Pipeline

CardBal separates NFC reading from transaction interpretation:

1. Detect the card technology and select a decoder.
2. Read card metadata, balance fields, and raw transaction records.
3. Persist raw records in the wallet model and backup format.
4. Decode raw records into display transactions.
5. Resolve stations from portable station assets when a record contains station
   codes.

The cross-platform backup format keeps decoded wallet data plus raw records, so
iOS and Android can re-import the same card history and re-run platform-native
presentation logic.

## Platform Decoder Coverage

| Card family | iOS reader | Android reader | Notes |
| --- | --- | --- | --- |
| Japanese Transit IC | FeliCa | FeliCa | Full raw history and station lookup on both platforms. |
| Octopus | FeliCa | FeliCa | Android decodes history and balance with the same service family. |
| Rakuten Edy | FeliCa | FeliCa | Balance, card number where available, and history. |
| WAON | FeliCa | FeliCa | Balance, WAON number, points, and paired-block history. |
| nanaco | FeliCa | FeliCa | Balance, points where available, metadata, and history. |
| T-money | ISO 7816 | ISO 7816 | KS X 6924 transaction records. |
| U-Money | ISO 7816 | ISO 7816 | Issuer `01` plus a `16` serial prefix selects MNT and Ulaanbaatar time on both. |
| EZL / Cashbee | ISO 7816 | ISO 7816 | KS X 6924 transaction records. |
| NAMANE | ISO 7816 | ISO 7816 | SFI 14 compact amounts and counters on both; dates remain unknown. |
| Snapper+ (New Zealand) | ISO 7816 | ISO 7816 | Positively identified KS X 6924 variant; NZD balance and paired transaction/history records. |
| Kartu Multi Trip / KMT (Indonesia, FeliCa generation) | FeliCa | FeliCa | Whole-IDR balance, optional printable card number, and raw history; history timestamps remain unresolved. |
| China T-Union | ISO 7816 | ISO 7816 | PBOC transaction records plus travel records on both platforms. |
| Local 天府通 CPU | ISO 7816 / CCID | Not implemented | CNY cash purse, purchase/top-up history and dated monthly ride allocations; [format review](tianfutong.md). |
| Named Calypso networks | ISO 7816 | ISO 7816 | Network-specific public contracts, counters and travel events. |
| IruCa / PASPY / SAPICA / OKICA / Ryuto | FeliCa | FeliCa | Balance and their configured record services on both. |
| CEPAS / NETS FlashPay / stored-value EZ-Link | ISO/MIFARE | ISO-DEP | SGD balance and records; no SimplyGo backend balance. |
| Opal / HSL / Waltti | DESFire | DESFire | Public purse, journey or ticket files according to the generation. |
| Clipper | DESFire / Ultralight | DESFire / Ultralight | USD purse, trip/top-up history and mapped stations for the public DESFire format; disposable ticket state and validations. [Format](clipper.md). |
| Macau Pass / 澳门通 | ISO 7816 / CCID | ISO-DEP | MOP purse, serial, validity and recent transaction records; optional T-Union companion. [Format](macau-pass.md). |

Both platforms try CEPAS before readers that change the implicit application,
then Macau Pass, Clipper and the remaining DESFire, Chinese, Calypso, Korean and FeliCa readers.

## Snapper+ and KMT

Both implementations were added on 2026-10-30 using independently written
parsers and synthetic protocol tests. Physical-card validation is still needed.

Snapper+ shares AID `D4100000030001` with Korean cards. Identification requires
an unambiguous complete purse TLV with issuer `02` and nonempty SFI 4 records
matching Snapper's 46-byte signature; the AID or issuer alone is insufficient.
GET BALANCE `904C000004` stores signed NZD cents. SFI 4 supplies signed amounts,
balance and counter; optional 52-byte SFI 3 companions supply dates and tap state.
Dates use `Pacific/Auckland`; invalid and ambiguous dates remain unknown.
An unused card without identifying records cannot be positively labeled Snapper+.

The original ISO record number pairs SFI 3 and SFI 4 during a scan. A versioned
hex envelope (`53502B01`, record number, companion length, SFI 4, optional SFI 3)
keeps that pair together through rescans and backup imports. Merge identity uses
the full SFI 4 payload, ignoring its moving circular-file slot and preferring a
more complete companion. Operator and journey IDs are not mapped to Korean or
Japanese station codes. No NZ station database or inferred routes are added.

KMT requires successful polling of FeliCa system `90B7`. Balance service `1017`
(wire order `17 10`) exposes whole-IDR unsigned little-endian 32-bit values.
Optional identifier service `300B` (`0B 30`) is shown only for printable ASCII;
IDm remains the wallet identity. Up to 20 readable history blocks from `200F`
(`0F 20`) are retained as raw data. The available reference explicitly guesses
the historical epoch transition, so the app does not fabricate dates, fares or
Japanese-style station events from these records.

Protocol evidence: [Snapper format](https://github.com/metrodroid/metrodroid/wiki/Snapper),
[pinned Snapper reference](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/snapper/SnapperTransitData.kt),
[pinned KMT reference](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/kmt/KMTTransitData.kt),
[KMT epoch discussion](https://github.com/metrodroid/metrodroid/pull/522),
[Snapper issuer compatibility](https://www.snapper.co.nz/snapper-ios-app/).
These establish wire-format facts; GPL reference implementation, artwork and
personal card captures are not included in this BSD-licensed implementation.

## FeliCa Selection

FeliCa cards are read by polling known system codes and services.

| Family | System code | Balance service | History service | Extra services |
| --- | --- | --- | --- | --- |
| Japanese Transit IC | `0003` | `8B00` | `0F09` | Transit activity services `8F10`, `CB10`. |
| Octopus | `8008` | `1701` | `1701` | History starts from block 1. |
| IruCa | `80DE` | `8B00` | `0F09` | Both platforms; configured balance and history path. |
| PASPY | `8592` | `8B00` | `0F09` | Both platforms; configured balance and history path. |
| SAPICA | `865E` | `8B00` | `0F09` | Both platforms; configured balance and history path. |
| OKICA | `8FC1` | `8F02` | `8F02` | Gate activity `0F05`; SF entry `0B06`. |
| Edy | `FE00` | `1713` | `0F17` | Optional card number service on both. |
| WAON | `FE00` | `1768` | `0B68` | WAON number `4F68`, points `4B68`; history is read as paired blocks. |
| nanaco | `FE00` | `9755` | `4F56` | Optional number, points, and metadata on both. |

FeliCa reads stop when a block is empty or clearly zero-filled. Raw blocks are
stored with the service code so the transaction decoder can choose the correct
record layout later.

## Japanese Transit IC

Supported cards include Suica, PASMO, ICOCA, TOICA, manaca, Kitaca, SUGOCA,
nimoca, Hayakaken, and related compatible cards.

OKICA is polled separately on system `8FC1`. Its newest `8F02` transaction
record supplies the balance, and its transaction layout resolves Yui Rail
stations and Okinawa bus operators independently of the `0003` layout.

Read process:

- Poll FeliCa system `0003`.
- Read balance from service `8B00`.
- Read usage history from service `0F09`.
- Read additional transit activity from services `8F10` and `CB10` when
  available.
- Detect the card brand from the real serial prefix and known system overrides.

`0F09` usage records are 16 bytes:

| Field | Bytes | Decode |
| --- | --- | --- |
| Process and device | `0..3` | Use kind, product, and device context. |
| Date | `4..5` | Packed year, month, and day. |
| Entry station | `6..7` | Area plus line and station code. |
| Exit station | `8..9` | Area plus line and station code. |
| Balance | `10..11` | Little-endian yen balance. |
| Sequence and region hints | `12..15` | Sequence, region, and bus/station context. |

Transit activity records are 16 bytes:

| Field | Bytes | Decode |
| --- | --- | --- |
| Activity type | `0..1` | Activity and subtype. |
| Station | `2..3` | Station code. |
| Device | `4..5` | Terminal or device identifier. |
| Date | `6..7` | Packed date. |
| Time | `8..9` | BCD time. |
| Amount | `10..11` | Little-endian amount. |

Station lookup uses the portable Japanese station database generated from
`build/stations/jp_stations.sqlite`. Bus records use the bus code table and may
borrow context from related rail records when the card only stores partial
location data.

## IruCa, PASPY, and SAPICA

Both platforms carry explicit FeliCa profiles for these Japanese transit variants:

| Card | System code | Balance service | Balance bytes |
| --- | --- | --- | --- |
| IruCa | `80DE` | `008B` sent as `8B00` | Block bytes `11..12`, little-endian JPY. |
| PASPY | `8592` | `008B` sent as `8B00` | Block bytes `11..12`, little-endian JPY. |
| SAPICA | `865E` | `008B` sent as `8B00` | Block bytes `11..12`, little-endian JPY. |

These profiles use the same Suica-style raw history path as Japanese Transit IC:
standard history service `0F09` plus gate activity services `8F10` and `CB10`
when available. Portable backups keep their raw FeliCa records intact.

## Octopus

Read process:

- Poll FeliCa system `8008`.
- Read service `1701`.
- Treat block 0 as the balance source and subsequent blocks as history.

Balance is decoded from a big-endian value, divided by 10. On both platforms, the Octopus
profile applies the historical offset rule: the public scan-date compatibility rule uses an
offset of 500 from 2017-10-01 in Hong Kong time, and 350 before that scan-date transition. Transaction amounts are inferred from
successive balance deltas when the card does not expose an explicit signed
amount.

## Rakuten Edy

Read process:

- Poll FeliCa system `FE00`.
- Read balance from service `1713`.
- Read card number from the optional Edy number service.
- Read history from service `0F17`.

Edy history records are 16 bytes:

| Field | Bytes | Decode |
| --- | --- | --- |
| Type | `0` | Transaction kind. |
| Sequence | `2..3` | Big-endian sequence. |
| Date/time | `4..7` | Packed elapsed date/time. |
| Amount | `8..11` | Big-endian yen amount. |
| Balance | `12..15` | Big-endian yen balance. |

## WAON

Read process:

- Poll FeliCa system `FE00`.
- Read balance from service `1768`.
- Read WAON number from service `4F68`.
- Read points from service `4B68`.
- Read transaction history from service `0B68`.

The point count is a big-endian 24-bit value at bytes `0..2` of points
block 0. History also names returns, point downloads, refunds, automatic
charges, moves to a new card, and point exchanges. These less common operations
retain an unknown transaction category because their balance effect is not
inferred from the label.

WAON history is decoded as a 32-byte paired-block record:

| Field | Bytes | Decode |
| --- | --- | --- |
| Terminal data | `0..12` | Merchant or terminal context. |
| Sequence | `13..14` | Transaction sequence. |
| Type | `17` | Transaction kind. |
| Packed payload | `18..28` | Date/time, amount, balance, and points fields. |

## nanaco

Read process:

- Poll FeliCa system `FE00`.
- Read balance from service `9755`.
- Read optional number, points, and metadata services.
- Read history from service `4F56`.

Points service `0B56` (service ID `560B` before little-endian encoding for
card I/O) stores two big-endian 24-bit counters in block 1, at bytes `0..2`
and `5..7`; the displayed point total is their sum. Transaction types `5C`,
`6F`, and `70` represent top-ups.

These retail point layouts and transaction names follow the
[nanaco](https://github.com/treastrain/TRETJapanNFCReader/blob/03470a515c0b06d762de39e6d80f9a07ed502cae/Sources/FeliCa/Nanaco/NanacoCardData.swift)
and
[WAON](https://github.com/treastrain/TRETJapanNFCReader/blob/03470a515c0b06d762de39e6d80f9a07ed502cae/Sources/FeliCa/Waon/WaonCardData.swift)
formats in TRETJapanNFCReader. Optional point reads may be unavailable on
individual cards; failure does not prevent a balance or history read.

nanaco history records are 16 bytes:

| Field | Bytes | Decode |
| --- | --- | --- |
| Type | `0` | Transaction kind. |
| Amount | `1..4` | Big-endian amount. |
| Balance | `5..8` | Big-endian balance. |
| Date/time | `9..12` | Packed date/time. |
| Sequence | `13..14` | Big-endian sequence. |

## Korean KS X 6924 Cards

Supported AIDs:

| Card | AID prefix | Records |
| --- | --- | --- |
| T-money | `D410000003` | SFI `3` transit history, SFI `4` single transactions. |
| EZL / Cashbee | `D410000014` | SFI `3` transit history, SFI `4` single transactions. |
| NAMANE | `D410000029` | NAMANE-specific SFI `14` records. |

Read process:

- Select the matching ISO 7816 AID.
- Read the KS X 6924 balance with `904C000004` and require exact success/length.
- Read the configured SFI records with `READ RECORD`.
- Skip all-zero records.

Transaction dispatch:

- 52-byte records are parsed as KS X 6924 transit history.
- 14-byte NAMANE records are parsed by the NAMANE-specific parser.
- Other KS X 6924 records are parsed as single stored-value transactions.

Transit-history time decoding is profile-scoped by the inferred KOTRIS code in
bytes `09..10`. Standard rows use the observed 33-bit packed clock and regional
rows may use strict seven-byte BCD. The corpus-validated Mybi Busan and Busan
subway profiles use a 24-bit big-endian value with `day = value >> 11`,
`hour = (value >> 6) & 31`, and `minute = value & 63`, relative to
2011-11-12 in `Asia/Seoul`. Boarding records select clock A (`11..13`) and
alighting records select clock B (`14..16`); `FBF000` and invalid clock fields
are rejected. Non-BCD integrated-Mybi and Gwangju clock blocks remain
undecoded until their own records validate the same dialect. KORAIL's official mode table supplies
the code names, while the byte-field application and Mybi clock are explicitly
CardBal corpus inferences documented by the Korean Trip Atlas.

## China T-Union

Supported AID: `A000000632010105`.

Read process:

- Select the T-Union PBOC application.
- Extract FCI metadata when present, including tags such as `9F0C`, `9F00`,
  and `9F08`.
- Read balance with `805C000204`.
- Read PBOC stored-value transactions from SFI `0x18`, records 1 through 10.
- Read travel records from SFI `0x1E`, records 1 through 30.
- Retry ISO commands with corrected Le when the card returns `6Cxx`.
- Skip all-zero records.

PBOC transaction records are 23 bytes:

| Field | Bytes | Decode |
| --- | --- | --- |
| Counter and overdraft | `0..4` | Sequence and card state. |
| Amount | `5..8` | Big-endian cents. |
| Type | `9` | Transaction kind. |
| Terminal | `10..15` | Terminal identifier. |
| Date | `16..19` | BCD date. |
| Time | `20..22` | BCD time. |

Travel records are 48 bytes or longer:

| Field | Bytes | Decode |
| --- | --- | --- |
| Type | `0` | Travel record type. |
| Terminal | `1..8` | Terminal identifier. |
| Subtype | `9` | Ride subtype. |
| Station ID | `10..16` | Operator station code. |
| Amount | `17..20` | Big-endian cents. |
| Balance | `21..24` | Big-endian cents. |
| Date/time | `25..31` | BCD date and time. |
| City ID | `32..33` | T-Union city code. |

Station source data lives in `build/stations/tunion_stations.sqlite`; iOS uses
the synchronized `TUnionLineStations.json` prefix registry and the unified
`cardbal_transit.sqlite`. Station lookup combines city ID and station ID and
uses the longest matching prefix because cards can store more detailed codes.
When no station prefix matches, reviewed exact terminal IDs can resolve the
station. SFI `18` purchase records only use globally unambiguous full terminal
IDs; SFI `1E` lookups also require the transaction city. Terminal-only stops
without a reviewed station-code match have names but no invented map position.
See [Trip Reader data](../data/tripreader.md) for sources and refresh instructions.

## Calypso public records

Both apps read network-specific public ticket and travel files. Generic RIDs or
`1TIC.ICA` alone do not identify a city. The codecs use versioned envelopes,
strict network/layout identification, checked status words and corrected-Le
retries. See [Calypso sources and supported layouts](../research/calypso-public-records.md).

## CEPAS and DESFire

See the [CEPAS purse/history protocol](../research/cepas.md) and
[Opal, HSL/Waltti and Clipper layout notes](../research/desfire-stored-value.md).
These include exact commands, units, timestamps, source revisions and bounds.

## Generic ISO 7816 Handling

Unknown or partially supported ISO 7816 cards are handled conservatively:

- Select known AIDs first.
- Try the card-family balance commands.
- Read configured SFI records.
- Store raw records even when the transaction parser cannot fully classify
  them.
- Avoid persisting empty all-zero records.

This keeps exports portable and lets a later decoder improvement re-interpret
older scans without needing to re-scan the physical card.

## Portable Station Assets

Japanese and Chinese station data are built into portable assets before being
copied into each platform:

```sh
python3 -m tools.stations.build --source csv --target all
```

The source is the public CSV catalog pinned by `data/stations/card-stations.lock.json`.
Derived portable exports live under `build/stations/`. App builds package the
consumed databases and manifests into:

- `ios/CardBal/Resources/`
- `android/app/build/generated/stationAssets/`

Important generated files:

| File | Purpose |
| --- | --- |
| `jp_stations.sqlite` | Japanese rail and bus station lookup. |
| `jp_stations_coverage.json` | Coverage metadata for Japanese station assets. |
| `tunion_stations.sqlite` | China T-Union city, line, and station lookup. |
| `manifest.json` | Cross-platform asset manifest and counts. |

Both platforms should use the portable SQLite databases instead of platform-only
station builders. The Android station database refreshes its copied asset cache
when assets change so regenerated station data is picked up after rebuilds.

## Shanghai applications and Octopus companion protocols

Both Chinese readers probe CU and TU AIDs on the connected card and
stores their metadata and raw records separately. Shanghai CU terminal prefixes
use their own catalog namespace. Combined history retains source application,
SFI and index; only unambiguous mirrored transactions are reconciled. Partial
rescans retain the other application's saved history. Balance readings are never
summed across applications.

On iPhone, normal all-protocol scans automatically read a recognized Octopus/CU/TU card's
companion protocol, in either order. iOS 26.4+ changes polling configuration
within one session; older iOS releases open the second session only after the
first has ended. The first result survives a missing, failed or cancelled second
read. Linked entries are merged into one saved card on scan, reload and restore,
including entries saved separately before a combined read. HKD and CNY histories
remain independently decoded. See [the protocol review and validation boundaries](shanghai.md).

Android preserves the same application records and probes both interfaces when
the Android tag exposes ISO-DEP and NFC-F together. Hardware that discovers one
interface at a time still needs a separate scan; cross-card links are not guessed.
