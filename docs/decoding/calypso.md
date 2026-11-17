# Calypso public records

The native codecs are independently written from public wire-format facts.
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

The shared public reader requires at least one
decoded contract or travel event. Generic raw diagnostics may remain inside the
pure helper but are rejected by its native snapshot adapters. The iPhone
La Carte compatibility path described below is a separate fallback.

Unknown products remain numeric. A counter is displayed as trips/money only when
its unit semantics are supported; other values are explicitly raw counters.
Multiple stored-value contracts remain separate; a headline monetary balance is
provided only for exactly one decoded monetary contract. Validity boundaries are
displayed, without claiming a pass is currently usable or inspecting protected
files. Holder names, birth dates and government ID fields are not decoded.

## Transport and persistence

Commands are SELECT (`A4`) and READ RECORD (`B2`) only. Selecting directory `2000`
is not opening a secure session. Public SFI reads use P2 `(SFI << 3) | 4`;
when unavailable, standard public file selectors are tried. Envelope SFIs are
the logical Calypso file mapping for such selected-file fallbacks. Exact9000
is required. A `6Cxx` response permits one corrected-Le retry; Le `00` is 256.
Other status words/protected records remain unreadable; no keys or authentication
attempts are introduced. The reader is bounded and never writes a card.

`CYP1` envelope: `43595001 | profile:u8 | logicalSFI:u8 | record:u8 |
payloadLength:BE16 | payload`. Raw environment/contracts/counters/events survive
wallet merge/backup. History decoding accepts only supported event files/layouts,
and does not reinterpret contracts as travel. Event-ring deduplication ignores
the moving slot while non-event slot context and unknown envelopes are retained.
MOBIB SFI23 is preserved and treated as an event-file alias.

EN1545 date fields are days from 1997-01-01; local time fields are minutes, not
seconds. Rav-Kav event timestamps are UTC seconds from 1997-01-01. Invalid days,
minutes, unknown network/timezone contexts and ambiguous/nonexistent local DST
wall times are not fabricated into dated events; their source bytes remain raw.

## Validation

Both native codec suites use
`tests/runtime/fixtures/calypso_synthetic.json`. Coverage includes identification,
contract dates and counter units, malformed envelopes, DST cases, corrected-Le
retries, zero stored value, ring movement and ID-only gating. These checks do
not establish physical-card compatibility or universal generation coverage.

Calypso adapter identity uses the decoded public serial when available; otherwise both platforms preserve the legacy unsigned UID-as-decimal serial. This protects existing Nice-card wallet identity while new scans use the generic Calypso label.

## La Carte compatibility on iPhone

When Core NFC initially selects a supported Calypso application, the iPhone
tries `CalypsoDecoder` before readers that select other applications.
`CalypsoCardProfile.matches` accepts known AID prefixes, including DF names with
trailing padding such as `3MTR.ICA`.

`NiceCalypsoReader` first uses the selected application without reselecting it.
It selects ticketing directory `2000` and reads SFI `07`, `1E`, `08`, `09` and
`0A` using class `94`. If the class is rejected and no usable records are
returned, it retries with class `00`. Event times are minutes.

The shared public reader runs afterwards. Its decoded result takes precedence
for a positively identified non-Intercode network, or when the Nice reader has
no records. Otherwise the compatibility snapshot keeps the
"Lignes d'Azur card" label, ticket fields and Check Online. It can retain
raw replies even when no ticket was decoded; that fallback is not positive
evidence of network identity. Diagnostics include command status words.
This compatibility path is iPhone-specific and remains unverified on a
physical card.
