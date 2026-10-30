# Macau Pass

Source review date: 2026-10-31.
Reference: [HaoTian22/TU-Reader at
`f50948a0090f0b7b07e27369c3a9a66670b092a9`][upstream].
This document records CardBal's Macau Pass implementation behavior and its
source limitations. Source inspection and synthetic tests do not establish
physical-card compatibility; no physical testing has been performed.

## Scope and access

Support is limited to the ISO-DEP application with AID
`B0C4C3C5CDA8C7AEB0FC`, described upstream as a GBK-encoded Macau wallet
name. It uses ISO 7816 APDUs with a PBOC-style electronic-purse
layout. The brand is Macau Pass, the region is Macau, and the currency is
MOP. History timestamps use `Asia/Macau`.

The reference read path requires no PIN, issuer key, authentication, secure
messaging, account login, or online service. Support requires a card that
exposes this ISO-DEP application and readable fields; it does not extend to
every Macau Pass generation. Non-ISO-DEP interfaces, account-based balances,
and mobile-wallet credentials are outside this implementation.

Sources: [profile and AID][profile], [ISO-DEP transport][channel],
[application reader][reader].

## Commands and partial results

All commands are read-only. Response offsets in this document exclude the
trailing two status bytes. Successful completed responses require `9000`.

| Purpose | APDU | Handling |
|---|---|---|
| Select Macau application | `00 A4 04 00 0A B0 C4 C3 C5 CD A8 C7 AE B0 FC 00` | Required before Macau file reads |
| Read information, SFI `15` | `00 B0 95 00 00` | Optional serial and validity metadata |
| Read balance | `80 5C 00 02 04` | Optional supported balance |
| Read history, SFI `18` | `00 B2 nn C4 17` | Optional 23-byte record; `nn` starts at `01` |

Information, balance, and history are independently optional. A missing,
locked, malformed, or unsupported field must not discard other successfully
parsed fields. Preserve available raw payloads and status/error diagnostics.
The reader makes bounded attempts for information, balance, and history
even if an earlier transport operation fails. Later failed reads preserve
completed fields. Swift task cancellation aborts the read.

A successful SELECT alone is insufficient: the result must contain some
meaningful parsed data, such as a valid application serial, a supported
balance, or a valid history transaction. Raw-only responses and an
unsupported balance alone must not manufacture a usable card result.
A supported zero balance is meaningful; an unavailable balance is not zero.

In addition, every accepted scan must have either a parsed application serial
or a nonempty reader UID. Reject the scan if both are absent, even when balance
or history data parsed successfully, to prevent an empty shared wallet
identity. A reader UID can identify a partial scan when the information file
is unavailable, but does not by itself satisfy the meaningful-data requirement.
The application serial and reader UID remain distinct identifiers.

For `6Cxx`, retry with the corrected response length within a finite retry
limit. For `61xx`, collect GET RESPONSE continuation data within a finite
continuation limit. Exhausting either bound leaves the affected read
unavailable and retains its diagnostics. Neither status may create an
unbounded loop. These bounds are CardBal transport requirements; upstream's
Macau path only accepts `9000` and does not implement these recoveries.

History reads are bounded to record numbers 1 through 30, matching the
reference's scan cap. Stop on an unsuccessful terminal record read; do not
discard already accepted records. Thirty is not a verified card capacity
or a promise of complete history. Reject malformed record payloads while
retaining their raw data. All-zero 23-byte records are empty slots.

No directory discovery, MF selection, broad SFI probing, GPO, authentication,
or write command is required for the Macau fields documented here.

Sources: [APDU construction/status handling][apdu],
[information read][information], [balance read][balance],
[history collection][history-read], [upstream optional probing][probing].

## Information and serial

Byte ranges are zero-based and end-exclusive.

| Field | Payload range | Interpretation |
|---|---|---|
| Issuer | `[0,8)` | Opaque eight-byte value rendered as uppercase hexadecimal |
| Application version | `[9,10)` | Byte 9 rendered as two uppercase hexadecimal characters |
| Application serial | `[16,20)` | Four bytes rendered as eight uppercase hexadecimal characters |
| Issue/start date | `[20,24)` | Packed BCD `YYYYMMDD` |
| Expiry date | `[24,28)` | Packed BCD `YYYYMMDD` |

The serial requires at least 20 payload bytes. Preserve its byte order and
leading zeros; do not reverse it or convert it to decimal. This is the
application serial used by upstream. Equality with the printed card number
or NFC UID has not been established.

The issuer requires at least 8 payload bytes and the version at least 10.
The issue date independently requires at least 24 payload bytes; the expiry
date requires at least 28. Validate BCD and calendar dates independently and
retain invalid fields as raw diagnostics rather than inventing dates. These
are calendar dates, not UTC timestamps. Other information bytes remain
uninterpreted unless separately documented.

Sources: [Macau serial parser][serial], [information parser][information],
[Macau field layout][info-layout], [validated metadata dates][metadata].

## Balance and money

The balance response payload must be exactly four bytes. For an ordinary
value with bit 31 clear:

```text
units = unsignedBigEndian32(payload[0..<4])
balanceMOP = Decimal(units) / 10 - 10
```

Swift uses exact `Decimal` division; Android stores integer cents with
`fractionDigits = 2`. Neither path converts money through binary floating
point. One stored unit is 0.1 MOP. The fixed
MOP 10 reserve subtraction follows upstream and is retained as an explicit
compatibility assumption. It has not been independently validated across
Macau Pass products. The reserve is not a per-transaction adjustment.
Do not clamp an otherwise supported negative result to zero.

If bit 31 is set, the balance is unsupported/unavailable and its raw bytes
must remain in diagnostics. Do not clear that bit or reinterpret the value
as signed two's-complement. Upstream's shared `parseEpBalance` heuristic
originates in its Shenzhen handling and is not evidence for Macau.

Sources: [money scale and reserve][money], [balance parser][balance],
[upstream high-bit heuristic][balance-heuristic].

## History records

`MacauPassDecoder.decodeTransaction` consumes exactly 23 payload bytes.
Truncated or oversized records are not decoded as a Macau transaction.
The original record remains available as raw data.

| Field | Payload range | CardBal interpretation |
|---|---|---|
| Sequence | `[0,2)` | Unsigned big-endian integer |
| Uninterpreted field | `[2,5)` | Upstream formatter labels this "Overdraft Limit"; no balance reconstruction |
| Amount | `[5,9)` | Full unsigned BE32, in units of 0.1 MOP; provisional width |
| Transaction type | `[9,10)` | Classification described below |
| Terminal | `[10,16)` | Opaque six-byte identifier rendered as uppercase hexadecimal |
| Date | `[16,20)` | Packed BCD `YYYYMMDD` |
| Time | `[20,23)` | Packed BCD `HHmmss` |

### Amount-width discrepancy

The Macau-specific upstream formatter declares amount bytes `[5,9)`, but
the shared transaction decoder actually reads `[6,9)` for MPASS. The five
Macau fixture records all have byte 5 equal to zero, so they cannot settle
this discrepancy.

CardBal provisionally uses the full BE32 `[5,9)` field instead of silently
discarding its high byte. The amount magnitude is `Decimal(units) / 10` MOP
on Swift and `units * 10` cents on Android. This is a deliberate interpretation of the
Macau-specific layout, not independently confirmed protocol behavior.
Retain the raw record so this decision remains revisable.

Sources: [Macau-specific record layout][history-layout],
[actual upstream amount extraction][history-parser],
[upstream Macau test][tests].

### Types, dates, and identifiers

| Type | Category | Amount treatment |
|---|---|---|
| `02` | Credit/top-up | Credit with the decoded magnitude |
| `06` | Debit | Debit with the decoded magnitude |
| `09` | Debit | Debit with the decoded magnitude |
| Other values | Unknown | Report amount zero; retain the raw type and record |

The reference's Macau tests exercise `02` and `09`. Treating `06` as a
debit is an explicit CardBal decision, not coverage supplied by those
fixtures. Do not apply upstream's broad "everything except top-up is
spending" display rule to unknown types. Zero for an unknown type is a
classification safeguard, not a claim that the original transaction was free.
Both platforms set `amountKnown = false` for unknown types. Known amounts
are signed, and every decoded transaction carries currency `MOP` and issuer
timezone `Asia/Macau`.

Validate every BCD nibble in the timestamp, the calendar date, and the time.
Reject a transaction with an invalid timestamp while retaining its raw
record. The record includes its full year and seconds; do not infer a year
from scan time or substitute zero seconds. Interpret valid local timestamps
in `Asia/Macau`; the bytes do not encode a timezone.
Android also rejects historical local times with zero or multiple valid
timezone offsets, avoiding a silent choice during a skipped or repeated hour.

The terminal is opaque hexadecimal. When every nibble is a decimal digit,
this rendering preserves the same 12 digits and leading zeros as upstream's
BCD representation. A terminal identifier is not a city, mode, line, stop,
or route endpoint. No station or mode mapping data is imported, and no
route endpoints are inferred. The reference itself warns that its Macau
support cannot reliably identify bus/light-rail modes or lines.

There is no decoded balance-after field in these records. Do not reconstruct
historical balances from the current balance and an incomplete record ring.
Record positions are scan slots, not stable transaction identities. Keep
wallet/application identity with transactions and avoid merging Macau/MOP
and T-Union/CNY transactions merely because their fields happen to match.

Sources: [date, terminal, and time extraction][history-parser],
[absence of a history balance][history-no-balance],
[upstream type display rule][type-display],
[unvalidated BCD helper][bcd], [upstream cross-wallet merge keys][merge],
[declared Macau mapping limitation][support].

## Optional T-Union wallet

Probe Macau before generic T-Union. After retaining the Macau result, the
existing T-Union electronic-purse decoder may optionally select
`A000000632010105` and retain a separate CNY wallet on a co-branded card.
Macau remains the primary application. Failure to read T-Union must not
erase readable Macau data, and a TU-only result must not manufacture
meaningful Macau data.

On Android, the companion uses the existing
`Iso7816Decoder.readApplication` routine on the same connected ISO-DEP card,
after a successful Macau read. An absent application or an I/O failure
preserves the Macau result. The companion decode has no surrounding generic
exception handler that could turn an unexpected decoder error into a
successful Macau-only result.

Do not combine the wallet balances or apply Macau's scale/reserve to TU
values. Keep each wallet's AID, currency, identifiers, and transactions
separate. Upstream's display deduplication omits currency and application
from its keys and prefers TU on a merge; that behavior is not adopted.

Upstream also knows T-Union electronic-cash AID `A000000632010106`.
That EC application is not implemented in the current CardBal app and must
not be advertised as supported or decoded using the EP offsets.

Sources: [AIDs][profile], [Macau-before-TU detection order][detection],
[upstream second-wallet reader][tu-reader],
[upstream display merging][merge].

## Evidence and license

This review pins actual source rather than a moving default branch. It
does not provide issuer documentation, validate all card generations,
establish the high-bit balance format, settle the amount-width discrepancy,
or replace physical-card testing.

The upstream Macau test contains two test methods and five captured history
fixtures. Its fake channel does not provide a successful TU SELECT response,
despite the dual-wallet description. These upstream fixtures are separate
from CardBal's tests; no captured card dump is copied into this document.

Eight synthetic tests compile the production decoder and exercise selection,
read commands, partial results and status handling, payload and history
bounds, money, timestamp validity across host timezones, persisted history,
and separate companion-wallet identity and currency. Run from the repository
root on macOS with `swiftc` available:

```sh
python3 -m unittest tests.runtime.test_macau_pass -v
```

The runtime suite also checks that the shared additional-card history router
does not claim Macau aliases, for nine Swift runtime tests in total.

The Android JVM suite exercises the production reader through synthetic
APDU exchanges, including exact commands, partial results, status handling,
bounded responses, all four amount bytes, invalid dates, serial/UID identity,
and a separate T-Union purse read on the same connection. It verifies that a
missing MOP balance never displays the CNY balance, a failed companion retains
Macau data, and unexpected companion selection errors propagate. Run with a
configured Android SDK and JDK 17:

```sh
cd android
./gradlew :app:testDebugUnitTest --tests ad.neko.cardbal.android.nfc.MacauPassDecoderTest
```

Wallet identity prefers the application serial and falls back to the reader
UID when the serial is unavailable. The UID remains a separate alias for
matching partial rescans.

No physical-card testing has been performed. Synthetic tests do not resolve
the protocol uncertainties described above.

TU-Reader code is under the MIT license, copyright 2026 HaoTian22. The exact
upstream license is retained in
[`../licenses/TU-Reader-MIT.txt`](../licenses/TU-Reader-MIT.txt); its pinned source is
[upstream LICENSE][license]. Upstream separately describes its station and
route data as CC BY 4.0 in [README.en.md][data-license]. No such mapping data
is imported for this Macau implementation.

[upstream]: https://github.com/HaoTian22/TU-Reader/tree/f50948a0090f0b7b07e27369c3a9a66670b092a9
[profile]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/CardProfile.kt#L43-L64
[detection]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/CardProfile.kt#L196-L213
[channel]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/CardChannel.kt#L15-L22
[reader]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L180-L273
[apdu]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/ApduUtil.kt#L28-L59
[information]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L803-L831
[balance]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L852-L865
[history-read]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L631-L652
[probing]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L494-L551
[serial]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L32-L33
[info-layout]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/ui/RawHexFormatter.kt#L220-L228
[metadata]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/data/CardMetadataParser.kt#L90-L95
[money]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/CardProfile.kt#L51-L64
[balance-heuristic]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/ApduUtil.kt#L82-L93
[history-layout]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/ui/RawHexFormatter.kt#L265-L274
[history-parser]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/data/RecordDecoder.kt#L508-L573
[tests]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/test/java/com/example/nfctransit/MacauPassTest.kt#L7-L67
[history-no-balance]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/data/RecordDecoder.kt#L602-L604
[type-display]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/data/TransactionMapper.kt#L55-L104
[bcd]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/ApduUtil.kt#L62-L70
[merge]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/data/RecordDecoder.kt#L319-L377
[support]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/README.md#L42
[tu-reader]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/app/src/main/java/com/example/nfctransit/TransitCardReader.kt#L317-L349
[license]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/LICENSE
[data-license]: https://github.com/HaoTian22/TU-Reader/blob/f50948a0090f0b7b07e27369c3a9a66670b092a9/README.en.md#L128-L132
