# Local 天府通 CPU cards

Implemented for the iOS/Core NFC and Mac Catalyst/CryptoTokenKit transports.
The ACR122U path was tested with a physical local CPU card on 2026-10-31.
iPad and macOS require an external reader. Built-in iPhone NFC discovery is
configured with the public application AID but has not been physically tested
with this card. Android's local Tianfu Tong decoder is not implemented.

## 读卡识途 comparison

Reviewed the author's [Trip Reader site](https://www.domosekai.com/reader/index.html),
[FAQ](https://www.domosekai.com/reader/faq.html), the official 1.7.17 Android APK
already used by this repository's station-data review, and the author's public
[card emulator](https://github.com/domosekai/cardemulator/blob/master/app/src/main/java/com/domosekai/cardemulator/HCEService.kt).
The APK's SHA-256 is
`b8cc78e73c3775f602656b4cde46c6ec4994ca364cdf985c5a18c6f68fe111b1`.
No APK, decompiled code, or personal capture is committed. This decoder is an
independent implementation of the observed read protocol.

Trip Reader selects the public application by AID, identifies issuer `54466100`,
and reads PBOC purchases and top-ups separately. It also selects local DF `1002`
for the monthly ride application, its monthly credit table and ride history.
The public emulator confirms these application/file distinctions. CardBal reads
dated monthly allocations but does not yet display the separate ride-purse
transaction history. Ride counts are never converted to CNY.

The public [Trip Reader station repository](https://github.com/domosekai/tripreader-data)
has no Chengdu directory at its pinned revision. The author's
[Chengdu BRT issue](https://support.domosekai.com/bugs/view.php?id=358) documents
full terminal-to-stop mappings shared by local and T-Union cards. Those are
specific terminal identities, not a rule for decoding every Chengdu terminal.
The tested card's terminal IDs did not match the reviewed APK's exact BRT table.
CardBal therefore retains terminal IDs without inventing stations or map visits.
The local issuer enables China in the country filters; ownership alone is not
evidence of visiting Chengdu.

## Read protocol

This card does not expose the standard City Union or T-Union AIDs. It accepts
selection by name and by local directory ID:

| Application | AID | Local DF |
| --- | --- | --- |
| Root 天府通卡 | `D156000015CCECB8AECDA8BFA8` | `3F00` |
| Public 公共应用 | `D156000015B9ABB9B2D3A6D3C3` | `1001` |
| Monthly 月票应用 | `D156000015D4C2C6B1D3A6D3C3` | `1002` |

The cash reader requires successful public selection and a 33-byte SFI `15`
file beginning `54 46 61 00`. Offsets below are zero-based:

| File / command | Interpretation |
| --- | --- |
| SFI `15`, bytes `10..<20` | 20 BCD digits of card number, preserving leading zeros |
| SFI `15`, bytes `20..<24`, `24..<28` | BCD issue/expiry dates |
| `80 5C 00 02 04` | Four-byte big-endian cash purse, minor CNY units |
| SFI `18` | 23-byte PBOC cash purchases |
| SFI `09` | 23-byte PBOC cash top-ups |
| Monthly SFI `1A` | Twelve four-byte allocations: two-byte BCD year and two-byte big-endian ride count, slot 1 = January |

Cash records contain sequence `0..<2`, reserved/overdraft `2..<5`, amount
`5..<9`, type `9`, full terminal `10..<16`, and BCD timestamp `16..<23`.
Type `02` credits the cash purse; `06` and `09` debit it. Other types retain
their raw record with amount marked unknown. Zero-value purchases remain
visible without inferring entry/exit. Timestamps use Asia/Shanghai.

Both cash SFIs retain application, file and record provenance through wallet
serialization and rescan merging. A failed balance read stays unavailable;
it does not become zero. Monthly allocation tables are accepted only when
the second application's card number matches the cash application's number.

All commands are SELECT, READ BINARY, READ RECORD or GET BALANCE. The external
transport also reads the card UID. No PIN verification, authentication,
value initialization, debit, credit or write commands are used.

## Verification

The physical Mac Catalyst scan returned the cash balance and nine cash records,
including a correctly credited top-up. An exhaustive read of accessible root,
public and monthly short-file identifiers and circular records was then saved
outside the repository; the reader session was closed for offline development.
Protected or otherwise undiscoverable data is not claimed to be dumped.

Synthetic Swift tests exercise identification, BCD serial/date validation,
cash units/signs, zero and truncated records, unknown types, monthly ride units,
missing balances, rescan merging, persistence, file provenance and the read-only
command set. No physical card number or personal trip data is in the fixtures.
