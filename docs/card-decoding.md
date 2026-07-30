# CardBal Card Decoding Reference

This document summarizes how CardBal reads and decodes each supported card
family. It reflects the current iOS implementation and the Android native port.
It is an implementation reference, not an official specification for any card
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
| EZL / Cashbee | ISO 7816 | ISO 7816 | KS X 6924 transaction records. |
| NAMANE | ISO 7816 | ISO 7816 | NAMANE-specific records on iOS; Android captures ISO records under the same AID. |
| China T-Union | ISO 7816 | ISO 7816 | PBOC transaction records plus travel records on both platforms. |
| Calypso / Lignes d'Azur | ISO 7816 | ISO 7816 partial | iOS reads Calypso sections; Android currently selects known AIDs and captures records where exposed. |
| Additional FeliCa transit variants | FeliCa | Not fully ported | iOS has profile data for IruCa, PASPY, SAPICA, and related balance-oriented profiles. |

The iOS reader tries decoders in this order: T-Union, Calypso, KS X 6924, Edy,
WAON, nanaco, then generic Japanese/FeliCa transit profiles. Android currently
tries ISO 7816 first, then FeliCa.

## FeliCa Selection

FeliCa cards are read by polling known system codes and services.

| Family | System code | Balance service | History service | Extra services |
| --- | --- | --- | --- | --- |
| Japanese Transit IC | `0003` | `8B00` | `0F09` | Transit activity services `8F10`, `CB10`. |
| Octopus | `8008` | `1701` | `1701` | History starts from block 1. |
| IruCa | `80DE` | `8B00` | `0F09` | iOS profile; Suica-style balance and history path. |
| PASPY | `8592` | `8B00` | `0F09` | iOS profile; Suica-style balance and history path. |
| SAPICA | `865E` | `8B00` | `0F09` | iOS profile; Suica-style balance and history path. |
| Edy | `FE00` | `1713` | `0F17` | Card number service on iOS. |
| WAON | `FE00` | `1768` | `0B68` | WAON number `4F68`, points `4B68`; history is read as paired blocks. |
| nanaco | `FE00` | `9755` | `4F56` | Number, points, and metadata services on iOS. |

FeliCa reads stop when a block is empty or clearly zero-filled. Raw blocks are
stored with the service code so the transaction decoder can choose the correct
record layout later.

## Japanese Transit IC

Supported cards include Suica, PASMO, ICOCA, TOICA, manaca, Kitaca, SUGOCA,
nimoca, Hayakaken, and related compatible cards.

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
`StationAssets/jp_stations.sqlite`. Bus records use the bus code table and may
borrow context from related rail records when the card only stores partial
location data.

## IruCa, PASPY, and SAPICA

iOS carries explicit FeliCa profiles for these Japanese transit variants:

| Card | System code | Balance service | Balance bytes |
| --- | --- | --- | --- |
| IruCa | `80DE` | `008B` sent as `8B00` | Block bytes `11..12`, little-endian JPY. |
| PASPY | `8592` | `008B` sent as `8B00` | Block bytes `11..12`, little-endian JPY. |
| SAPICA | `865E` | `008B` sent as `8B00` | Block bytes `11..12`, little-endian JPY. |

These profiles use the same Suica-style raw history path as Japanese Transit IC:
standard history service `0F09` plus gate activity services `8F10` and `CB10`
when available. Android does not yet expose these as first-class profiles, so
the portable backup should keep raw FeliCa records intact when they are scanned
on iOS.

## Octopus

Read process:

- Poll FeliCa system `8008`.
- Read service `1701`.
- Treat block 0 as the balance source and subsequent blocks as history.

Balance is decoded from a big-endian value, divided by 10. On iOS, the Octopus
profile applies the historical offset rule: cards after 2010-12-01 use an
offset of 350, older cards use 35. Transaction amounts are inferred from
successive balance deltas when the card does not expose an explicit signed
amount.

## Rakuten Edy

Read process:

- Poll FeliCa system `FE00`.
- Read balance from service `1713`.
- Read card number from the Edy number service on iOS.
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
- Read number, points, and metadata services on iOS.
- Read history from service `4F56`.

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
- Read balance with `90DA000004`; fall back to `805C000204` when needed.
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

Station names come from `StationAssets/tunion_stations.sqlite`. Lookup combines
city ID and station ID and supports prefix matching because some cards store
more detailed station identifiers than the public station tables.

## Calypso and Lignes d'Azur

Calypso cards are ISO 7816 cards. iOS matches common Calypso AID prefixes such
as `A000000291` and `A000000404`, plus the known Lignes d'Azur application
identifier `315449432E494341`.

Read process:

- Select the Calypso application.
- Probe GET DATA tags `004F`, `006F`, `0062`, `C030`, and `D020`.
- Read common data sections from SFI `07` records 1 and 2, plus SFI `01`,
  `02`, and `08` record 1.
- Store raw sections and extract card identifiers, public data, contracts, and
  events when the section parser recognizes them.

Android currently recognizes the Lignes d'Azur AID in the ISO reader and can
capture exposed records, but the full Calypso section parser remains iOS-led.

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
python3 scripts/build_cross_platform_station_assets.py --target all --skip-tunion-osm --offline-tunion-source
```

The source-of-truth output is `StationAssets/`. The build then syncs the same
portable databases and manifest into:

- `CardBal/Resources/`
- `android/app/src/main/assets/`

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
