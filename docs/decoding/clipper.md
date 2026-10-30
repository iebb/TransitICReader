# Clipper

This upgrades the existing older-generation Clipper DESFire support with
named agencies and stations, route and vehicle labels, optional expiry, and
MIFARE Ultralight ticket decoding. The existing `StoredValueProtocol` reader
and its saved `DFSV` history envelopes remain supported. New DESFire scans
prefer `ClipperDecoder`; the history registry dispatches the new record
formats before falling back to the existing envelope decoder.

The implementation is adapted from FareBot commit
[`dc09f6f014ea3675b64bcd38335b4b78d77fa374`](https://github.com/codebutler/farebot/tree/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper).
Source review date: 2026-10-31. No physical Clipper card or reader testing has
been performed. Account balances, mobile-wallet credentials, and newer or
otherwise different card generations are outside the supported layouts.

## Transport and required files

DESFire selects native application **wire bytes `90 11 F2`**. FareBot names
this `0x9011f2`; the existing reader's NXP-style numeric notation is
`0xF21190`, serialized least-significant byte first. Both select the same
application. This is native `5A`, not an ISO `A4` application-name selection,
and no three-byte ISO AID entitlement is required.

`ClipperDecoder` accepts `.miFare` only for family `.desfire`, and also
accepts `.iso7816` for APDU-capable readers. `DESFireReader` sends the same
wrapped native APDU on both paths. The MiFare transport returns payload
followed by `91 xx`; the ISO7816 adapter restores those trailing status
bytes from its separate response fields. There is no new tag case or
Ultralight transport protocol.

| Operation | Example command |
| --- | --- |
| Select Clipper application | `90 5A 00 00 03 90 11 F2 00` |
| Get settings for file `08` | `90 F5 00 00 01 08 00` |
| Read all data from file `08` | `90 BD 00 00 07 08 00 00 00 00 00 00 00` |
| Read all records from file `04` | `90 BB 00 00 07 04 00 00 00 00 00 00 00` |
| Continue a response | `90 AF 00 00 00` |

Only `9100` completes successfully; `91AF` requests continuation. Other
statuses fail that file. The reader requires progress on continuation,
limits a command to 256 frames and 8,192 payload bytes, and checks returned
length against file settings. Standard/backup data settings must contain
seven bytes; linear/cyclic record settings must contain 13 bytes, specify
32-byte records, and have current count no greater than capacity. Zero
size returns an empty file without issuing a data read. Settings lengths,
record counts and sizes are little-endian; the Clipper data fields below
are big-endian.

Only select, settings, data reads, record reads and generated continuation
commands are sent. There is no authentication, key handling, secure-message
implementation, balance modification or write operation. File access must
permit the unauthenticated reads represented by these layouts.

| File | Requirement | Parsed data |
| --- | --- | --- |
| `08` | Required, at least 5 bytes | Unsigned 32-bit decimal serial at `[1,5)` |
| `02` | Required, at least 20 bytes | Signed 16-bit USD cents at `[18,20)` |
| `01` | Optional | Expiry at `[8,10)`, unsigned days since 1900-01-01 |
| `04` | Optional | 32-byte refill records |
| `0E` | Optional | 32-byte journey records |

File `08` is read first, then `02`, then optional files `01`, `04`, `0E`.
A missing, denied, truncated or otherwise failed required read rejects
the new decoder's snapshot. Optional failures preserve the readable purse
and record the unavailable file numbers in Raw Data. Completed optional
files are retained if later optional reads fail. Cancellation aborts the
read rather than becoming an unavailable optional file. A successful but
short optional expiry file remains raw and contributes no expiry value.

The snapshot keeps technology `ISO7816` on either DESFire transport and uses
the decimal serial as its displayed identity. Reader UID is retained as the
raw identifier when available; an absent UID stays empty rather than being
replaced by the serial. Shared wallet integration keeps storage identity
`DESFire|<UID>` for these snapshots when UID is available, matching the
previous generic reader. Without UID, storage falls back to the ISO7816
serial identity; it cannot establish a match to an earlier UID-only save.

Sources: [serial, balance and expiry](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperTransitFactory.kt#L67-L114),
[wrapped DESFire transport](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/desfire/src/commonMain/kotlin/com/codebutler/farebot/card/desfire/DesfireProtocol.kt).

## Journey and refill records

All offsets in this section refer to the original 32-byte record, before
the local storage prefix. A file whose length is not a multiple of 32
contributes no decoded records. Records are visited from the end of the
file toward the beginning.

| Journey field, file `0E` | Byte range | Meaning |
| --- | --- | --- |
| Agency | `[2,4)` | Unsigned agency identifier; zero rejects the record |
| Fare | `[6,8)` | Unsigned cents, exposed as a negative USD amount |
| Vehicle | `[10,12)` | Unsigned vehicle identifier |
| Entry timestamp | `[12,16)` | Unsigned seconds since 1900-01-01 UTC; zero rejects the record |
| Exit timestamp | `[16,20)` | Nonzero marks a completed journey for deduplication |
| Origin | `[20,22)` | Agency-specific station or zone identifier |
| Destination | `[22,24)` | Agency-specific station or zone identifier |
| Route | `[28,30)` | Agency-specific route identifier |
| Mode | `[30,32)` | Transport code |

| Refill field, file `04` | Byte range | Meaning |
| --- | --- | --- |
| Agency | `[2,4)` | Unsigned agency identifier |
| Timestamp | `[4,8)` | Unsigned seconds since 1900-01-01 UTC; zero rejects the record |
| Machine | `[8,12)` | Unsigned decimal terminal identifier |
| Amount | `[14,16)` | Unsigned cents, exposed as a positive USD top-up |

Money uses exact `Decimal` division by 100, with no binary floating-point
money conversion. Journey/refill transactions carry `currencyCode = USD`,
`issuerTimeZone = America/Los_Angeles`, and signed-amount metadata. Unix
seconds are Clipper seconds minus `2,208,988,800`. Date/time displays use Los
Angeles daylight-saving rules. Day-only expiry values use UTC calendar
formatting to avoid shifting the date into the preceding day. Zero expiry
is unavailable. The decoder does not reconstruct historical balances from
the current purse and incomplete event history.

Mode codes `61`, `75`, `77` map to bus; `6F` to metro; `78` to train; `73`
to ferry. Code `62` uses the agency to distinguish ferry (`19`, `1B`),
train (`06`, `0C`) and tram. Unknown codes remain unknown. Vehicle `0` and
`FFFF` are unavailable; values below 10,000 display as decimal. Larger
values retain FareBot's LRV display formula: decimal quotient by 10,
followed by uppercase hexadecimal of remainder plus 9.

New persisted DESFire records are **33 bytes: file number + original
32-byte record**. File prefix `0E` distinguishes journeys from `04`
refills. `rawTransactions` holds both; `rawTransitHistory` holds journeys.
Full files, including ignored bytes and padding, remain in scan Raw Data.

Before a Clipper rescan merges history, `canonicalHistoryRecord` converts
only exact old `DFSV` version 1 envelopes with layout tag `05`, kind `02`
(refill) or `03` (journey), and declared/actual payload length 32 into the
corresponding 33-byte record. The old two-byte record index does not affect
canonical identity. Strict ASCII hex and an exact 43-byte envelope are
required. Other versions, tags, kinds, malformed lengths and unrecognized
raw strings are returned unchanged. This removes old/new duplicates while
preserving older events that are absent from the current on-card ring.
Old envelopes still decode through the legacy registry path before rescan.

For valid journey records sharing the same nonzero entry timestamp, the
decoder prefers the first completed record in the supplied context, or
the first provisional record if none is completed. This also works across
merged scans. A malformed record cannot suppress a valid candidate.
The identity is timestamp-only: agency, origin and route are not additional
identity fields, and same-second records can therefore coalesce. Exit time
is used for completion preference and remains raw; it is not exposed as
a separate transaction timestamp. Wallet deletion of every backing
provisional/completed record is shared integration behavior, separate from
these stateless decoders.

Sources: [record extraction and fields](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperTransitFactory.kt#L172-L273),
[vehicle display](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperTrip.kt#L80-L100),
[epoch](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperUtil.kt).

## Ultralight tickets

`ClipperUltralightDecoder` accepts only `.miFare` with family `.ultralight`.
It sends `30 04` first, verifies the first returned byte is `13`, then sends
`30 00`, `30 08`, `30 0C`. Each response must be exactly 16 bytes, covering
pages 0 through 15 when assembled. Any failed or short read rejects the
ticket; cancellation aborts. The external ACR122 adapter supplies the same
MiFare interface. Generic CCID ISO7816 support alone does not provide
Ultralight page reads.

| Assembled ticket bytes | Meaning |
| --- | --- |
| `[12,16)` | Unsigned big-endian decimal serial |
| `16` | Required marker `13` |
| `17` | Passenger code: `04` adult, `44` senior, `84` RTC, `C4` youth |
| `[20,22)` | Unsigned big-endian product |
| `[22,24)` | Unsigned big-endian base/expiry day count |
| `[24,44)`, `[44,64)` | Two 20-byte event slots |

Event fields are MSB-first bit fields relative to their 20-byte slot:

| Bit offset / width | Meaning |
| --- | --- |
| `0 / 7` | Sequence counter |
| `7 / 17` | Event type; `1` updates ticket state but is hidden from travel history |
| `24 / 17` | Minutes subtracted from base days times 1,440 |
| `41 / 17` | Station identifier |
| `68 / 5` | Agency |
| `80 / 4` | Balance sequence counter |
| `84 / 6` | Remaining trips |
| `100 / 10` | Transfer duration in minutes; zero is unavailable |

The latest state uses wrapping balance-counter comparison first
(`(new - old) & 8 == 0`), then sequence comparison
(`(new - old) & 64 == 0`). Empty slots are ignored. Hidden events still
participate in state selection. Product low-nibble values `3` through `A`
identify adult/senior/RTC/youth single/return products; unknown products and
passenger codes remain hexadecimal. Product agency is the upper bits, with
`21` mapped to Muni (`12`). Expiry comes from the base day count. The issue
date is the upstream derived value, base days minus 89, rather than an
independently stored purchase timestamp.

Persisted ticket history is **22 bytes: two base-date bytes + original
20-byte event**. This preserves relative time decoding after reload.
Tickets provide remaining rides and validations, not a cash balance or
recorded fare; visible events set `amountKnown = false`. The base date and
event fields are layout values, not cryptographically verified ticket state.

Sources: [ticket detection and pages](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperUltralightTransitFactory.kt),
[event bits and counters](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperUltralightTrip.kt),
[products and derived dates](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/clipper/src/commonMain/kotlin/com/codebutler/farebot/transit/clipper/ClipperUltralightSubscription.kt).

## Catalog and licenses

`data/stations/ClipperTransit.json` contains 129 stations, 25 operators and
four named lines. It is an offline conversion of the pinned
[`clipper.mdst`](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/base/src/commonMain/composeResources/files/clipper.mdst),
whose SHA-256 is
`e3b402e0c3bd2abc02dcd5959a309692f8b7e45d6d079701f5e8771608215f40`.
The JSON retains source URL, commit, source hash and the full notice.
Keys combine agency and station/route as `(agency << 16) | identifier`.
Station lookup codes are `CLIPPER:<decimal combined identifier>`.

Missing catalog entries retain numeric agency, route and station codes,
with the upstream zone/end-of-line conventions where applicable. A missing
or unsupported catalog does not prevent purse/history decoding. Valid
catalog coordinates are available to map integration; no Clipper track
graph or path between endpoints is included.

The new adapted Swift decoders and public mocked fixture carry
GPL-3.0-or-later notices. The corresponding license is
[`FareBot-GPL-3.0.txt`](../licenses/FareBot-GPL-3.0.txt), matching upstream
[`COPYING`](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/COPYING).
Credits include Eric Butler, Bao-Long Nguyen-Trong, Michael Farrell, Google,
and the anonymous Clipper contributor. The catalog notice includes BART,
SFMTA, VTA, the 511 data agreement, and mapping contributors; it states
that mapping data is subject to Metrodroid's license terms.
These additions retain those terms alongside the repository's BSD license.
The existing independent `StoredValueProtocol` implementation and its
invented shared vectors are a separate source/license boundary.

To reproduce the JSON from the pinned FareBot checkout, run at repository
root:

```sh
python3 tools/stations/import_clipper_catalog.py /path/to/farebot
```

The importer verifies both checkout HEAD and MdST SHA-256 before writing
`data/stations/ClipperTransit.json`. App builds do not fetch or refresh it.

## Validation

```sh
python3 -m unittest tests.runtime.test_clipper -v
```

The ten tests compile the production Swift Clipper readers, catalog,
transport protocols, value models, registry and byte helpers. They replay FareBot's
public [mocked BART/refill test data](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/app/src/commonTest/kotlin/com/codebutler/farebot/test/ClipperTransitTest.kt)
and invented transport/ticket responses. Coverage includes signed purse
values, unsigned serials, exact Decimal amounts, timestamps/DST, station
resolution, JSON history reload and completed-trip preference, identical
DESFire APDUs through ISO7816 and MiFare, continuation/status/size limits,
record reads, optional failures, cancellation, Ultralight counter wrap and
hidden events, and importer paths/metadata/truncated inputs. The pinned
MdST conversion was also checked to reproduce the JSON byte-for-byte.

The harness compiles the actual `CardWalletStore.mergeRawRecords` and
`deleteLocalRecord` methods, `TransitApplicationRecord`,
`TransitApplicationHistory`, legacy `StoredValueProtocol`/`AdditionalCardHistory`,
the production history registry, `storageIdentifier`, and the external
ACR122 adapter. It verifies old/new envelope normalization and merge,
retention of unscanned older events, stable UID identity with a serial
fallback when UID is absent, deferred grouped deletion and JSON reload for
both flattened histories and application-backed imported backups.
Deletion is checked for both `ISO7816` and legacy `DESFire` labels,
preserving other cards, applications, record kinds, refills and unrelated
records. The displayed application's single source-record ID must remove
its hidden provisional event without broadening that scope.

USB tests check PN532 page-read framing, one `61xx` GET RESPONSE,
malformed/truncated/error replies and rejection of non-read commands.
Unrelated decoders, storage/UI and application containers use small test
adapters. The tests do not access the real wallet database or iCloud and do
not exercise UI, live USB hardware, or platform builds. No private card
captures, customer fixtures, credentials or device keys are included.
Passing these tests does not establish physical RF compatibility.
