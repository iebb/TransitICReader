# DESFire stored-value readers

The iPhone and Android implementations independently read the public DESFire
layouts below. They issue no authentication, modification, debit, credit or key
commands. Recognizing a chip or selecting an application without usable purse,
journey or ticket-product data does not produce a supported-card snapshot.

The implementations were written from the protocol facts described below.
No GPL implementation, station lookup, artwork or capture fixture is included.
The checked-in shared vectors are wholly invented byte arrays, identifiers,
amounts and dates. Physical cards were unavailable for validation.

## Applications and transport

Metrodroid stores its AID integers in **wire order**, explicitly unlike NXP's
numeric notation. This implementation uses NXP numeric notation and serializes
three little-endian bytes. These are consequently the actual select payloads:

| Layout tag | Family | NXP numeric AID | Three wire bytes |
| --- | --- | --- | --- |
| 1 | Opal | `534531` | `31 45 53` |
| 2 | HSL V1 | `EF2011` | `11 20 EF` |
| 3 | HSL V2 | `EF2014` | `14 20 EF` |
| 4 | Waltti | `AB1000` | `00 10 AB` |
| 5 | Older Clipper DESFire | `F21190` | `90 11 F2` |

The transport supports explicitly selected native responses (leading status)
or ISO-wrapped responses (trailing `91` and status). It never guesses framing.
Allowed commands are select application `5A`, file settings `F5`, plain data
`BD`, records `BB`, application list `6A`, version `60` and continuation `AF`.
Only `00` finishes a response; `AF` requests a new empty continuation command.
Chains are limited to 64 frames and 65,536 bytes. Refusal statuses never become
partial successful data. Standard/backup and linear/cyclic record settings,
record counts, plain communication mode and complete returned lengths are checked.
Encrypted/MACed and unsupported file types remain unavailable.

Both native adapters use wrapped `90` commands. iPhone sends them through
`NFCMiFareTag.sendMiFareCommand`, or through `NFCISO7816Tag.sendCommand` while
restoring SW1/SW2 for the pure transport. Android uses `IsoDep.transceive`.
These are DESFire application selects using `5A`, not ISO `A4` selects; the
three-byte numbers must not be added as ISO7816 AIDs in Info.plist.

Evidence: [Metrodroid transport at b910c180](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/card/desfire/DesfireProtocol.kt),
[FareBot transport at dc09f6f0](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/desfire/src/commonMain/kotlin/com/codebutler/farebot/card/desfire/DesfireProtocol.kt),
[FareBot iPhone adapter](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/src/iosMain/kotlin/com/codebutler/farebot/card/nfc/IosCardTransceiver.kt).

## Parsed scope

Opal reads file `07`'s first 16 bytes, reversing byte order before MSB-first bit
extraction. The stored balance is signed 21-bit AUD cents at bit 54; the event
counter starts at bit 75 and spans 16 bits. Last-event action, mode, day and
minute occupy bits 21/4, 25/3, 39/15 and 28/11. Days are local calendar days
since 1980-01-01 in Australia/Sydney. Serial fields are unsigned 32-bit at bit
96 plus a decimal digit at bit 92, added to the documented card-number prefix.
No fee is present in this summary: the event's amount stays **unknown**, not
zero or an inferred fare. This is balance plus last event, not full Opal history.
The stored checksum field is not treated as a verified integrity algorithm.

Evidence: [Metrodroid Opal layout](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/opal/OpalTransitData.kt),
[FareBot's independently checked field positions](https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/opal/src/commonMain/kotlin/com/codebutler/farebot/transit/opal/OpalTransitFactory.kt).

HSL V1/V2 and Waltti use MSB-first fields. File `02` begins with a 20-bit EUR
cent purse, followed by the last reload's 14-bit date, 11-bit local minute and
20-bit amount. File `04` is read as records using its actual settings: journey
date/minute start at bit 1/14 and 15/11, fare at 51/14, and remaining value at
70/20 for V1/Waltti or 71/20 for V2. File `08` optionally supplies identifier
bytes 1 through 9, retained as hex rather than guessed decimal digits.

File `01` supplies up to two season products: six-byte V1, seven-byte V2 or
ten-byte Waltti entries, with product/area and validity-date fields. File `03`
supplies value-ticket product and validity fields. V1 value-ticket validity
starts at bit 88, V2 at 205, and Waltti at 112. Their embedded validations are
also parsed without inventing a fare. Dates count local days since 1997-01-01
in Europe/Helsinki. Season end values are displayed as dates, without claiming
an otherwise unverified inclusive end-of-day timestamp. Zero/unloaded validity
fields remain unavailable, and unknown product/zone codes remain numeric.

Evidence: [purse/application layout](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/hsl/HSLTransitData.kt),
[journey and embedded-validation fields](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/hsl/HSLTransaction.kt),
[season products](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/hsl/HSLKausi.kt),
[value tickets](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/hsl/HSLArvo.kt),
[reload fields](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/hsl/HSLRefill.kt),
[date encoding](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/en1545/En1545FixedInteger.kt).

Older Clipper DESFire file `02` has a signed big-endian 16-bit USD-cent purse at
byte 18. File `08` has an unsigned four-byte number at byte 1. File `0E` contains
32-byte journey entries; file `04` contains 32-byte reload entries despite both
being standard files. Journey agency/fare/start/end/from/to/route fields start
at bytes 2/6/12/16/20/22/28. Reload time and amount start at bytes 4 and 14.
Times are unsigned big-endian seconds since 1900-01-01 UTC, displayed in
America/Los_Angeles. Fare costs become negative amounts and reloads positive.
Temporary journey records sharing entry time, agency, origin and route prefer
a completed record; conflicting complete records are preserved. No agency or
station names are synthesized. Newer Clipper generations are outside this path.

Evidence: [purse, standard-file records and epoch](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/clipper/ClipperTransitData.kt),
[journey fields](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/clipper/ClipperTrip.kt),
[reload direction](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/clipper/ClipperRefill.kt).

Nonexistent or ambiguous local times at daylight-saving changes return an
unknown timestamp. Malformed or unavailable fields never use the scan date,
current date, zero balance or a guessed epoch as a substitute.

## Persistence and integration

Raw records use a hex-only envelope with an 11-byte header:
`44 46 53 56`, version `01`, layout tag, kind, two-byte BE record index,
two-byte BE payload length, then the exact payload. Kinds are last event `1`,
reload/purse `2`, journey `3`, season file `4` and value-ticket file `5`.
The parser rejects unknown versions, mismatched families, malformed hex,
incorrect lengths and payloads above 4,096 bytes.

The HSL/Waltti purse file contains a last-reload summary and the **current**
purse. The parser does not label that current value as the older reload's
balance-after. Repeated summaries differing only in those 20 current-purse bits
remain raw evidence but become one visible reload summary. The format cannot
establish a complete count of otherwise indistinguishable reloads.

Pass files remain in these envelopes so products can be reconstructed after
wallet persistence. `parseHistories` is the visible batch-history API, including
pending/completed Clipper handling and HSL/Waltti embedded-validation duplicate
suppression. A record index is a file position, not a stable transaction counter.
Raw semantic merging may ignore only that index when format, kind and complete
payload are identical; it must preserve changed balances or journeys.

The pure helpers contain no platform NFC or app model dependencies. The native
`StoredValueDecoder` adapters map their snapshots to existing app records.
The root registry owns transaction model/category/currency mapping; unknown
amounts remain unknown. Shared synthetic vectors verify all five layouts on
Swift and Kotlin, alongside status, chaining, length, AID order, signed purse,
unsigned serial, pass and timezone guards. These tests establish implementation
behavior, not physical-card compatibility or access to authenticated files.
