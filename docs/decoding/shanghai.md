# Shanghai City Union, T-Union and companion scans

CardBal reads City Union and T-Union applications on the same connected tag,
preserves each application's metadata and raw records, and reconciles only
unambiguous mirrored transactions.

## Protocol sources

- [Official download directory](https://support.domosekai.com/download/):
  the protocol reference is Trip Reader **1.7.17-cn**.
- APK SHA-256:
  `b8cc78e73c3775f602656b4cde46c6ec4994ca364cdf985c5a18c6f68fe111b1`.
- [Author's Shanghai data and format notes](https://github.com/domosekai/tripreader-data/tree/c5584d6b8d9a39d7162b7b9781134be52db66186/Shanghai).
- [Author's investigation guide](https://www.domosekai.com/reader/faq.html):
  distinguishes local terminal identifiers from T-Union travel records.

No decompiled application source is included in this repository. Protocol and
format evidence does not establish physical-card compatibility.

## Applications and balances

| Application | SELECT AID | Shanghai city code | Main history |
| --- | --- | --- | --- |
| City Union / local application | `A00000000386980701` | `2000` | SFI `18`, terminal identifiers |
| T-Union / 交通联合 | `A000000632010105` | `2900` | SFI `18` plus SFI `1E`, travel details |

Both application paths read card-info file `15`; T-Union also reads file `17`.
Shanghai auxiliary files are retained with their application, SFI and record
index. A station name alone does not establish entry or exit.

CardBal reads two four-byte T-Union balance registers and uses
`P1=00 minus P1=01`. It retains the extended `80 5C 05 02 10` response for
diagnostics. The reference APK interprets that 16-byte response's unsigned
big-endian positive balance at bytes `[1,4)`, debt at `[9,12)` and debt limit
at `[13,16)`. Those offsets exclude SW1/SW2. The two paths require comparison
with actual card replies before the CardBal formula can be changed.

Shanghai uses the latest successful reading, preferring T-Union when both
applications are read together. CU and TU balances are never added.

## Shanghai station coverage

The pinned public `Shanghai/cu.csv` contains **614 unique station-code rows**:
516 metro, 18 railway, 28 BRT, 50 tram and 2 maglev. These are mappings, not
614 new physical stations; multiple identifiers can refer to the same place.

City Union and T-Union use separate identifier namespaces. For example,
莘庄 on line 1 has:

| Source | Lookup key |
| --- | --- |
| CU terminal prefix | `2000` + `110111` = `2000110111` |
| TU city + line/station prefix | `2900` + `00010011` = `290000010011` |

These keys are not interchangeable. Some pre-2017 bus terminal identifiers
overlap metro identifiers; the decoder keeps that date-dependent ambiguity
instead of applying a universal prefix substitution.

## Reading, history and persistence

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
  enriches a purchase only for a unique match on timestamp and amount/currency.
  The records must share an application source, or have a full six-byte terminal
  with an exact zero-padded eight-byte counterpart. Both history views retain
  all correlated source-record identities. Unmatched and ambiguous records
  remain available. See the [Chongqing regression](journey-correlation.md).
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

The normal all-protocol scan can read the companion interface after
recognizing Octopus FeliCa system `8008` or a supported CU/TU/Lingnan application.
Either protocol can be discovered first. When Octopus is read first, a saved or
fresh exchange rate is required before the mainland interface is checked;
otherwise the scan finishes. There is no separate dual-card action. A tag
callback containing one FeliCa and one ISO 7816 interface starts with FeliCa and
only continues as a dual card when that interface is Octopus. Repeated interfaces
of the same protocol remain a multiple-card discovery; the reader asks for one
physical card. The user keeps that same card in place throughout the read.

On iOS **26.4+**, `NFCTagReaderSession.Configuration` and
`restartPolling(configuration:)` switch protocol polling within one session.
On older iOS versions, the first session is invalidated before opening the
companion session. Tag objects are discarded between phases. If no companion
interface is discovered within six seconds, the first reading is saved.
Cancellation or an unsupported second application also preserves the first
reading. Protocol-specific scans continue to read only the selected protocol.

The wallet coalesces every entry linked by application numbers, stable tag
identifiers, or a combined scan. This includes two entries saved before their
combined scan, transitive aliases, local reloads, file imports and iCloud restores.
The surviving wallet ID, position and appearance are retained, and removed IDs
remain persisted aliases. Deletion covers all linked identities so an older
single-application backup cannot recreate the card. Separately saved cross-
protocol entries with no shared identity are linked by their next combined read;
card type alone is never enough to merge different physical cards.

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
