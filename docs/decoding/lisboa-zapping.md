# Lisboa Viva / navegante Zapping

Implemented 2026-11-01 in the iOS and Android public Calypso readers.
The supported stored-value layout requires provider **31** and tariff
**33592**. A contract purchase price, remaining ride count or successful
application selection does not count as Zapping money. Current physical-card
validation is still needed; this does not establish every navegante generation.

The existing `1TIC.ICA` selection (`315449432E494341`) is used. Network identity
comes from country `0x131` at bits 13-24 of the 29-byte SFI `07` environment,
not from the shared application name. Serial prefix bits 30-37 and serial bits
38-61 are formatted as three digits, a space and nine digits. Cardholder name
and birth date are not decoded; holder files are not read.

SFI `09` and SFI `06` (`2000/2030`) contain contracts. Their fixed layout is:
provider 7 bits, tariff 16, reserved 2, start date 14, sale agent 5, reserved 19,
period unit 16, encoded end date 14, period 7, reserved 38. Raw records retain
the remaining bytes. The current details show the encoded validity fields;
they do not calculate a replacement validity from the period unit.

Counter association preserves original slots, including zero-filled contracts.
SFI `09` slots precede SFI `06` slots. For slots 1-4, shared counter SFI `19`
record 1 contains three bytes per slot; otherwise the corresponding SFI
`0A`-`0D` record 1 supplies its first three bytes. The Zapping counter is
unsigned EUR cents, including a legitimate zero balance. Missing counters
remain unavailable. Counters beyond slot 4 are not assigned a monetary meaning
without further protocol evidence. Multiple Zapping contracts retain their
individual balances; no ambiguous aggregate is presented.

SFI `08` contains 29-byte events with this fixed layout:
local seconds since 1997-01-01 (30), reserved (3), first stamp (30),
reserved (5), contracts-used bitmap (4), reserved (29), transition (3),
provider (5), vehicle (16), reserved (4), device (16), route (16),
location (8), reserved (63).

Transitions 1/3/4 are entry/transfer/exit. Providers 1/2/3 are Carris/Metro/CP.
Readable history shows the timestamp, event, agency and numeric route/location.
Metro location is shifted right two bits. These identifiers do not become
Japanese station coordinates. Vehicle/device and contract-bit fields remain in
the raw event. No fare is present in this layout, so `amountKnown` is false.
Local seconds are resolved in `Europe/Lisbon`; skipped and repeated daylight
saving wall times remain raw instead of acquiring a guessed instant.

The existing `CYP` version-1 envelope adds network ID **6** for Lisboa.
Existing network IDs stay unchanged. Each record preserves network, SFI, slot,
length and payload. Event deduplication ignores moving ring-buffer slots;
contract slots remain distinct. Both platforms route this family through the
same public Calypso history adapter and retain currency/timezone through backup.

## Evidence and validation

This is an independent implementation of wire-format facts, with no copied GPL
implementation or personal captures. Metrodroid
`b910c1806fd86aa545223baf1d21fc5afe68eee2` provides the public
[environment](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/lisboaviva/LisboaVivaTransitData.kt),
[contract](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/lisboaviva/LisboaVivaSubscription.kt),
[event](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/lisboaviva/LisboaVivaTransaction.kt)
and [counter association](https://github.com/metrodroid/metrodroid/blob/b910c1806fd86aa545223baf1d21fc5afe68eee2/src/commonMain/kotlin/au/id/micolous/metrodroid/transit/en1545/Calypso1545TransitData.kt).
The earlier independent
[Calypso notes](../research/calypso-public-records.md) document transport and
selection.

Shared invented fixtures extend `calypso_synthetic.json`: positive and zero
Zapping counters, missing counters, wrong provider, pass counters, SFI `06`
slot mapping, winter/summer events and both daylight saving boundaries.
Swift runtime and Android JUnit consume these same bytes.
