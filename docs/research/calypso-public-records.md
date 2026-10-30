# Calypso implementation evidence and limits — 2026-10-31

The new native codecs were independently written from public wire-format facts.
No GPL implementation, card image, keys, personal captures, station tables or
reference-project fixtures were copied into the BSD repository. The synthetic
fixture consists of invented bits, counters, products and timestamps.

## Primary source pins

- Metrodroid `b910c1806fd86aa545223baf1d21fc5afe68eee2`, [Calypso application/file selectors](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/card/calypso/CalypsoApplication.kt).
- [Intercode environment/contract-list identifiers](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/intercode/IntercodeTransitData.kt), [contracts](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/intercode/IntercodeSubscription.kt), [events](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/intercode/IntercodeTransaction.kt).
- [OPUS](https://github.com/metrodroid/metrodroid/tree/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/opus), [MOBIB](https://github.com/metrodroid/metrodroid/tree/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/mobib), [Rav-Kav](https://github.com/metrodroid/metrodroid/tree/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/ravkav).
- Cardpeek `de8cee209b870f3d7aa1c6bd55e84738765dc1e6`, [French Intercode fields](https://github.com/L1L1/cardpeek/blob/de8cee209b870f3d7aa1c6bd55e84738765dc1e6/dot_cardpeek_dir/scripts/calypso/c250.lua), [MOBIB](https://github.com/L1L1/cardpeek/blob/de8cee209b870f3d7aa1c6bd55e84738765dc1e6/dot_cardpeek_dir/scripts/calypso/c56n1.lua).
- **Nice correction:** Cardpeek's [commit adding c250n64](https://github.com/L1L1/cardpeek/commit/7cb22c8f9bd2b74f22778d5f137c70ff284d16e3) explicitly identifies Montpellier. `0x250064` cannot establish Nice identity. `1TIC.ICA` is a generic application name. No trustworthy positive Nice-specific identifier was found in these primary sources.

## Implemented public data

| Profile | Positive identity | Parsed records |
| --- | --- | --- |
| Named Navigo | Environment network `0x250901`, with presence bitmap | Contract-list types `20`, `46`, `FF`; common contract fields; dates; supported counters/journeys; Intercode events |
| OPUS | Environment network `0x124001` | Per-network optional contracts, pass dates, supported trip counters, public validation date/operator/route |
| MOBIB | Environment network `0x056001`, supported environment version <=4 | Old/new contract and event layouts through version4; numeric products, dates, counters and event operator/route/location codes |
| Rav-Kav | Environment network `0x37602` or `0x37603` | Contract validity, counter semantics: tariff-use2 trips, tariff-use3 ILS cents; UTC-second events and explicit monetary fields |
| Generic French Intercode | Complete environment with MCC `0x250`; no city claim | Common contract/pass fields and raw counters. Product191 + best-contract type46 + bounded counter preserves the legacy ticket-count profile, labeled numerically. Events require a researched metropolitan event-network identifier to establish timezone. |

No ID-only scan is presented as supported: native adapters require at least one
decoded contract or travel event. Generic raw diagnostics may remain inside the
pure helper but are rejected by the native snapshot adapters.

Unknown products remain numeric. A counter is displayed as trips/money only when
its unit semantics are supported; other values are explicitly raw counters.
Multiple stored-value contracts remain separate; a headline monetary balance is
provided only for exactly one decoded monetary contract. Validity boundaries are
displayed, without claiming a pass is currently usable or inspecting protected
files. Holder names, birth dates and government ID fields are not decoded.

## Transport and persistence

Commands are SELECT (`A4`) and READ RECORD (`B2`) only. Selecting directory2000
is not opening a secure session. Public SFI reads use P2 `(SFI << 3) | 4`;
when unavailable, standard public file selectors are tried. Envelope SFIs are
the logical Calypso file mapping for such selected-file fallbacks. Exact9000
is required. A6Cxx response permits one corrected-Le retry; Le00 is256.
Other status words/protected records remain unreadable; no keys or authentication
attempts are introduced. The reader is bounded and never writes a card.

`CYP1` envelope: `43595001 | profile:u8 | logicalSFI:u8 | record:u8 |
payloadLength:BE16 | payload`. Raw environment/contracts/counters/events survive
wallet merge/backup. History decoding accepts only supported event files/layouts,
and does not reinterpret contracts as travel. Event-ring deduplication ignores
the moving slot while non-event slot context and unknown envelopes are retained.
MOBIB SFI23 is preserved and treated as an event-file alias.

EN1545 date fields are days from1997-01-01; local time fields are minutes, not
seconds. Rav-Kav event timestamps are UTC seconds from1997-01-01. Invalid days,
minutes, unknown network/timezone contexts and ambiguous/nonexistent local DST
wall times are not fabricated into dated events; their source bytes remain raw.

## Validation

Shared `tests/runtime/fixtures/calypso_synthetic.json` contains five
identification profiles, eleven contract variants and nine event cases; it is
used by both native codec test suites. Fixture SHA256:
`4eb55d0ed174842c1e11fe3069a62332453fefd0b4f99e9ca9ebc2bd39de04f0`.

The Swift production helper test passes with direct expected amounts, timestamps,
contract dates and counter units, plus malformed envelopes, DST cases,6C00,
zero stored value, ring movement and ID-only gating. The native Swift adapter,
profile and helper also typecheck against the installed iPhoneOS SDK using model
stubs; root performs the full app build. Android compilation passed before the
last integration changes; root owns the final serialized Android test/build.
No physical-card/RF verification has been performed, and no universal generation
coverage is claimed. Nice city branding remains explicitly unresolved.

Calypso adapter identity uses the decoded public serial when available; otherwise both platforms preserve the legacy unsigned UID-as-decimal serial. This protects existing Nice-card wallet identity while new scans use the generic Calypso label.
