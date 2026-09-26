# Shanghai City Union and T-Union review

Reviewed on 2026-09-27 against the official Android Trip Reader / 读卡识途
**1.7.17-cn** APK and the current CardBal iOS reader. This is a static protocol
and data review; no physical Shanghai card or Android/iOS UI was tested.

**Finding:** Trip Reader reads both applications into one card and reconciles
their records. Before this change, CardBal stopped after a successful City Union decode,
so a Shanghai dual-application card could lose its T-Union history. Changing
decoder priority alone would leave the opposite application's data unread.

## Sources and verification

- [Official download directory](https://support.domosekai.com/download/):
  1.7.17 remained the newest listed APK at this review.
- APK SHA-256:
  `b8cc78e73c3775f602656b4cde46c6ec4994ca364cdf985c5a18c6f68fe111b1`.
- [Author's Shanghai data and format notes](https://github.com/domosekai/tripreader-data/tree/c5584d6b8d9a39d7162b7b9781134be52db66186/Shanghai).
- [Author's investigation guide](https://www.domosekai.com/reader/faq.html):
  distinguishes local terminal identifiers from T-Union travel records.

The APK was inspected with JADX 1.5.6. Its reconstructed Java has duplicated
blocks and incorrect conditions in the large reader methods. Critical balance
and record-matching branches were checked against JADX's fallback instruction
listing, not inferred from reconstructed Java alone. The symbol references
below identify this exact APK; they are not stable public APIs. No decompiled
application source is included in this repository.

## What Trip Reader does

### Select and read both applications

| Application | SELECT AID | Shanghai city code | Main history |
| --- | --- | --- | --- |
| City Union / local application | `A00000000386980701` | `2000` | SFI `18`, terminal identifiers |
| T-Union / 交通联合 | `A000000632010105` | `2900` | SFI `18` plus SFI `1E`, travel details |

`L0.d.onTagDiscovered` (JADX alias `L0.C0017d`) reads the supported local
application first, then explicitly selects T-Union even after a successful
local read. The same card object and transaction list are passed through both
paths. Its card model retains separate `isCU`/`isTU`, raw CU/TU metadata, expiry
dates, and two card numbers. T-Union metadata becomes the primary number while
the previously decoded local number is retained separately.

Both application paths read card-info file `15`; the T-Union path additionally
reads file `17`. Shanghai receives extra handling beyond ordinary `18`/`1E`
records: SFI `06` for additional transactions, CU SFI `10` for another record
stream, and selected records in `11` and `14` for local state and monthly
discount information. A Shanghai-specific path also correlates SFI `07`
extension records with `18` records by their encoded timestamps. These fields
help distinguish transport types and entry/exit state. A station name alone
does not prove entry or exit.

### Use Shanghai's T-Union balance without adding it to City Union

The local path issues `80 5C 00 02 04`. The T-Union path instead issues
`80 5C 05 02 10`, requesting a 16-byte balance response. In `L0.d.g`, the latter
path reads the positive balance from response bytes `[1,4)` and the overdraft
amount from `[9,12)`, as unsigned big-endian values. When the positive amount
is zero, it uses the negative overdraft amount. The overdraft limit comes from
`[13,16)`. All offsets here exclude SW1/SW2 and use zero-based, end-exclusive
ranges.

For Shanghai (`2900`), the T-Union result replaces the earlier local balance.
The branch that stores separate CU and TU balances and adds them is explicitly
limited to **Nantong (`3060`)**, with a previously available local balance.
It must not be generalized to all dual-application cards. This establishes
Trip Reader's treatment; it is not physical-card proof that every Shanghai
card variant has identical purse behavior.

CardBal currently reads two separate 4-byte T-Union registers and always uses
`P1=00 minus P1=01`. That differs from Trip Reader's extended-response path.
Existing CardBal comments cite earlier Shanghai diagnostic evidence, so this
difference needs comparison with actual responses before replacing the rule.

### Reconcile records and retain their origins

Trip Reader's transaction model contains CU/TU record flags, raw `18` and `1E`
payloads, and separate record positions. It can enrich one transaction with
evidence from multiple files rather than create a second trip.

- The `18` reader (`L0.d.e`) matches existing records on bytes `[5,23)`:
  amount, transaction type, terminal and timestamp. It deliberately excludes
  sequence and reserved/overdraft bytes. Matching records gain the additional
  source flag and file position.
- The `1E` reader (`L0.d.j`) correlates eligible existing records using equal
  timestamps or a terminal-string containment check, with a guard against a
  terminal containing `00000000`. It attaches the travel payload and richer
  location/type information to the matched transaction.
- Unmatched records are inserted into the combined history in order.

The second heuristic is permissive. CardBal should preserve the original
records and use stricter, tested correlation when repeated visits, equal
timestamps, or conflicting amounts make a match ambiguous. Copying the loose
terminal match would not establish that two records describe the same trip.

## Shanghai station coverage

The pinned public `Shanghai/cu.csv` contains **614 unique station-code rows**:
516 metro, 18 railway, 28 BRT, 50 tram and 2 maglev. These are mappings, not
614 new physical stations; multiple identifiers can refer to the same place.

The pre-change catalog had 612 Shanghai T-Union identifiers in the unified
database and no City Union station identifier namespace. The earlier Trip Reader import
explicitly excluded CU formats. For example, 莘庄 on line 1 has:

| Source | Lookup key |
| --- | --- |
| CU terminal prefix | `2000` + `110111` = `2000110111` |
| TU city + line/station prefix | `2900` + `00010011` = `290000010011` |

These keys are not interchangeable. The current CU decoder also consults the
TU city registry for terminal prefixes; that registry has Shanghai `2900` but
no `2000`, so the local transaction can fall back to an unlabeled terminal.
The author's Shanghai notes warn that some pre-2017 bus terminal identifiers
overlap metro identifiers. A universal prefix substitution would ignore both
the namespace and historical ambiguity.

## Gaps identified before implementation

1. **Coordinate application reads on one connected tag.** Probe both known
   AIDs and explicitly reselect before each read. `NFCTransitReader.swift`
   previously listed CU first and breaks on its successful snapshot;
   `TUnionDecoder.canDecode` only accepted the initial OS-selected AID.
   Both AIDs are already declared in `Info.plist`.
2. **Persist application and record provenance.** `TransitCardSnapshot` and
   `SavedCardRecord` previously had one family/AID and bare arrays of raw hex.
   Add application snapshots or records tagged with AID, SFI and record index,
   with backward-compatible loading of existing saved cards. A family string
   and payload length cannot reliably distinguish both applications' 23-byte
   records. Wallet rescans must retain both histories. The current
   `storageIdentifier` also prefers the decoded serial number, so switching
   between CU and TU numbers can create separate saved cards. Use a stable
   card identity with both application numbers as aliases and migrate existing
   entries without discarding user labels or history.
3. **Reconcile the display, preserving raw evidence.** Show one physical card,
   both application numbers/details, and combined trips without counting a
   mirrored purchase twice. Keep an unmatched CU-only transaction even when
   a TU travel log exists. A failed secondary read must not erase earlier
   history or turn an unavailable balance into zero.
4. **Add Shanghai CU data in its own namespace.** Import the 614 reviewed
   prefixes with provenance and transport type; link to existing station
   identities only when city, line/mode and station identity agree. Preserve
   separate CU/TU city codes and do not invent coordinates or entry/exit events.
5. **Validate balance and extra files with card captures.** Compare the extended
   balance response and existing register reads, preserving the current rule
   until the discrepancy is resolved. Add Shanghai auxiliary-file parsing only
   for verified layouts.

Useful regression cases are: CU-only, TU-only, a dual card with either initial
AID; one unavailable application; mirrored and distinct `18` records; `1E`
enrichment; repeat visits to one terminal; CU `2000` versus TU `2900`; empty
slots; and a rescan that reads only one of the two previously saved applications.
Live confirmation requires a physical dual-mode Shanghai card. The Android
APK's behavior is a reference for the implementation, not iOS device validation.

## Implemented in CardBal

- `ChineseTransitDecoder` selects and reads both known AIDs on the same connected
  ISO 7816 tag, regardless of the initially selected application. A failed second
  application leaves the first usable. Shanghai captures SFI `18`, `06`, CU `10`,
  TU `1E`, and auxiliary `07`/`11`/`14`/`10` records with their file/index identity.
- Application snapshots retain card numbers, metadata, balances, diagnostics,
  scan dates and raw records through wallet saves, exports and same-card backup
  merges. Application-number aliases and a stable Chinese-card UID fallback
  match partial rescans to an existing wallet entry while retaining its ID and
  customization. History is merged by application/file/content, not ring position.
- Mirrored PBOC purchases match bytes `[5,23)` only across distinct sources.
  Multiple matching records within one source remain separate. A TU travel row
  enriches a purchase only for a unique match on timestamp, amount/currency and
  the full six-byte terminal with an exact zero-padded eight-byte counterpart.
  Unmatched and ambiguous records remain available.
- CU entry/exit interpretation uses the reviewed SFI `11`/`14` terminal and
  minute fields; contradictory auxiliary directions remain unknown. Other
  auxiliary bytes are retained for inspection. Metro station lookup is disabled
  for missing dates and pre-2017 records with overlapping bus terminal numbers.
- All **614** published Shanghai CU prefixes are stored in
  `cityunion_terminal_prefixes`, separate from TU station codes. **577** match
  an existing TU station uniquely by Shanghai city, station name, line and mode;
  those also have `cn.cityunion.terminal_prefix` aliases. The other **37** keep
  their station names without invented map coordinates or route identities.
- Shanghai uses the latest successful balance reading, preferring TU when both
  are read together, and never adds CU and TU balances. Missing reads remain
  unavailable; a retained balance keeps its original read date. The extended
  `805C050210` response is saved for diagnostics. The established primary-minus-
  debt formula is unchanged pending physical-card comparison.

## Octopus across FeliCa and ISO 7816

The explicit **Read Both Octopus Sides** action reads FeliCa system `8008` first,
then polls ISO 14443 for the supported mainland application on the same physical
card. It instructs the user to keep only that card present. Ordinary discovery
never combines arbitrary FeliCa and ISO tags from one callback.

On iOS **26.4+**, `NFCTagReaderSession.Configuration` and
`restartPolling(configuration:)` switch protocol polling within one session.
On older iOS versions, the first session is invalidated before opening the ISO
session. Tag objects are discarded between phases. Timeout, cancellation or an
unsupported second application saves the known Octopus reading; a partial rescan
also preserves previously saved mainland history.

Each application decodes its own history and currency. The wallet headline uses
Octopus's HKD balance; the application details retain the mainland reading
without adding the two. This matters because modern Octopus China T-Union is a
single HKD purse with currency conversion, whereas older Octopus-Lingnan products
have separate purses. A dual-protocol discovery alone does not identify that
financial arrangement. Legacy flattened Octopus + ISO records are separated
using their recorded AID and payload lengths; ambiguous old combined balance
strings are not treated as new application balances.

Primary references:

- [Apple Core NFC tag sessions](https://developer.apple.com/documentation/corenfc/nfctagreadersession)
- [Apple polling configuration](https://developer.apple.com/documentation/corenfc/nfctagreadersession/configuration)
- [Octopus China T-Union FAQ](https://www.octopus.com.hk/en/consumer/customer-service/faq/get-your-octopus/china-t-union.html)

## Validation boundary

The Swift regression harness executes the production Chinese APDU readers,
application reconciliation, saved-card matching and source-data lookup with
synthetic replies. It covers initial CU/TU selection, missing applications,
status-word handling, `6C00` retries, strict correlation, conflicting auxiliary
records, mixed currencies, persistence and legacy/partial rescans. Source tests
verify all 614 CU mappings, the 577 safe links, and identical portable/iOS assets.
The iOS release build also validates the availability-guarded Core NFC APIs.
Physical RF handover, wallet balances and timing still require Shanghai and
Octopus cards on real iPhones; no such device verification is claimed.
