# FareBot publicly readable card survey

Reviewed 2026-10-31 against FareBot master at
`dc09f6f014ea3675b64bcd38335b4b78d77fa374`.
The upstream head was rechecked on that date and still matches this revision.
CardBal comparisons use monorepo `origin/master` at
`7d9f5514d7060d090232dd126195088faff0fbaa`, plus the Clipper work being integrated
for 2.5.0. The original survey's "next" list predates the monorepo parity work.
See the [current platform matrix](platform-parity.md) and
[additional-card research](card-support.md) for implementation scope.

Here, **publicly readable** means the card exposes useful data through read
commands without supplying secret keys, authenticating through an operator
service, or recovering keys. This is a source-code assessment of supported card
formats, not a claim that every current issue of each branded card is readable.
No physical cards were tested for this survey.

The largest remaining travel-history gap in this survey is **ORCA**. Other
unimplemented candidates include **Adelaide, Hafilat, Tampere**, disposable
**Compass/Ventra** tickets and **HSL Ultralight**. More named Intercode networks
and their station catalogs remain possible extensions to the existing Calypso
reader. KMT, NETS FlashPay, HSL/Waltti, Snapper+ and general Calypso are already
implemented; they are not new-reader recommendations.

## Travel-history evidence and current CardBal scope

| Card / region | Protocol | Evidence in FareBot | Value and effort for CardBal |
|---|---|---|---|
| **ORCA / Seattle** | DESFire | Application `3010F2`; file `02` travel records, `03` top-ups, `04` purse. Serial comes from `FFFFFF/0F`. Transaction decoder understands tap-in/out/cancel, fares, balances, operators, rail/ferry/BRT station mappings and bus vehicle IDs. [Factory][orca] / [transactions][orca-tx] | Best next DESFire history target. Reuses APDU transport, but needs ORCA-specific record sizes, trip merging and station catalogs. Target this exact on-card layout, not every ORCA generation. |
| **Kartu Multi Trip (KMT) / Jakarta commuter rail** | FeliCa | System `90B7`, balance service `1017`, history `200F`, identity `300B`. History carries timestamp, sequence, amount, process type and station ID. Ride records identify the **end station**; they do not provide both endpoints. [Factory][kmt] / [trips][kmt-trip] | Already implemented on both platforms: IDR purse, optional number and raw history. CardBal deliberately leaves historical dates unresolved because the epoch transition is uncertain. Validating that epoch and optional station mapping are follow-up work, not a missing reader. |
| **HSL / Helsinki; Waltti / Finland** | DESFire | HSL apps `1120EF` / `1420EF`, Waltti `0010AB`. File `04` record history, `02` balance/refill, `03` value ticket and `01` season contract. Embedded events enrich log records. [Factory][hsl] / [transactions][hsl-tx] | Already implemented on both platforms: EUR purse, journey logs, last reload, season/value products and embedded validations, with Helsinki time handling and duplicate suppression. Possible enrichment is named products/zones/routes and physical-generation validation; current support is not balance/pass only. See [DESFire scope](desfire-stored-value.md). |
| **Navigo and other Intercode cards** | Calypso / ISO 7816 | Environment, contracts and event records; Navigo lookup includes agency/transport/station mapping. Other Intercode factories cover networks such as OuRA, KorriGo and Pastel. [Factory][intercode] / [Navigo lookup][navigo] | Named Navigo, OPUS, MOBIB, Rav-Kav and generic French Intercode already have positive network dispatch, contract and event parsing. Further network-specific products, lookups and researched event/timezone contexts remain useful. Generic `1TIC.ICA` and network `0x250064` do not establish Nice identity. See [Calypso scope](calypso-public-records.md). |
| **Adelaide Metrocard** | DESFire | Application `B006F2`; event files `03`-`06`, `09`-`0B` (up to seven file-backed events), purse/contracts `10`-`13`; EN1545/Intercode-style trip parsing. [Factory][adelaide] | Not implemented in the current monorepo. Existing DESFire and Calypso field readers provide reusable transport/date primitives, but this application and event layout need a dedicated profile. Source marks the implementation as preview. |
| **Hafilat / Abu Dhabi** | DESFire | Application `0107F2`; four event files `03`-`06`, purse/contracts `10`-`13`. Events decode date/time and available route/location/vehicle fields. [Factory][hafilat] / [events][hafilat-tx] | Not implemented. Useful recent bus history; shares EN1545 work with Adelaide, with a distinct application, layout and issuer timezone. |
| **Tampere / Nysse** | DESFire | Application `0121EF`; record file `03` contains time, fare, route, top-up/first-tap/transfer and passenger count. Purse and contracts come from other files. [Factory][tampere] / [trips][tampere-trip] | Not implemented. Good route-level history candidate using existing DESFire transport; this parser does not establish station-to-station endpoints. |
| **NETS FlashPay / Singapore** | CEPAS | Same purse `3` and history `3` as EZ-Link. Issuer comes from CAN prefix: `111` for NETS, `100` for EZ-Link. [Factory][ezlink] / [issuer mapping][ezlink-data] / [read commands][cepas] | Already implemented on both platforms: issuer-specific naming, signed SGD cents, purse status and payments/transit/reload/refund history. CardBal does not read SimplyGo account balances. See [CEPAS scope](cepas.md). |
| **Snapper / Wellington** | ISO 7816 / KS X 6924 | Pairs SFI `03` trip records with SFI `04` balance records, merges tap-on/off and transfers, reads timestamps/fares. Station display is journey/sequence IDs rather than resolved stop names. [Factory][snapper] / [transactions][snapper-tx] | Snapper+ is already positively identified and decoded on both platforms: NZD purse, paired SFI 3/4 history, signed fares/reversals and New Zealand dates. Older non-plus generations remain outside that claim; numeric IDs are not mapped stops. |

## Public data with narrower history

| Card | What is actually exposed/decoded | Assessment |
|---|---|---|
| **Opal / Sydney** | Public DESFire file `07`: balance, weekly trip count, auto-top-up state and **one last transaction** with timestamp/mode/type. [Info][opal] | CardBal already implements signed AUD purse and a last-event summary. This is not a multi-trip history source; no fare is inferred from the event summary. |
| **Compass disposable tickets / Vancouver** | Ultralight ticket data plus two event slots, with station lookup in the Compass specialization. [Factory][compass] / [shared parser][nextfare-ul] | Useful recent validations, not the reusable Compass card or a long history. |
| **Ventra disposable tickets / Chicago** | Ultralight ticket data plus the same two-event-slot structure. Shared events do not supply a fare. [Factory][ventra] / [shared parser][nextfare-ul] | Ticket support only; do not conflate it with the reusable Ventra card. |
| **HSL Ultralight tickets** | Ticket/contract state and last embedded event. [Factory][hsl-ul] | Smaller extension after HSL DESFire. |
| **OPUS / Montreal** | Calypso subscriptions and validation events, but the lookup explicitly says the card does **not store stations**. [Info][opus] / [lookup][opus-lookup] | Already implemented contract/validation fields. Further presentation may help, but missing station data cannot be reconstructed into journeys. |
| **MOBIB / Brussels; Rav-Kav / Israel** | Calypso contract/event parsers exist, with much station resolution falling back to numeric IDs. [MOBIB][mobib] / [Rav-Kav][ravkav] | Already implemented supported contracts/events; scoped product/counter/lookup enrichment remains possible. Do not promise detailed station maps or every generation. |
| **MRT Jakarta** | FeliCa purse/identity implementation; `trips` is explicitly empty. [Info][mrtj] | Balance-only in this FareBot revision. |

## Do not classify these as keyless history support

- **Myki:** despite the main support table, `MykiTransitInfo` subclasses
  `SerialOnlyTransitInfo` with reason `LOCKED`. This revision does not provide
  public balance or trip history. [Source][myki]
- **Leap:** a detailed history parser exists, but it explicitly returns
  `LockedLeapTransitInfo` when file `02` is unauthorized. The shared DESFire
  reader still has TODOs for invoking unlockers. Treat it as conditional on a
  proven readable layout, not a guaranteed public-read target.
  [Factory][leap] / [reader][desfire-reader]
- **EasyCard DESFire:** the README advertises it, but the inspected
  `EasyCardTransitFactory` accepts `ClassicCard`, and the central registry
  registers it only for `CardType.MifareClassic`. No corresponding DESFire
  EasyCard decoder/registration was found in this revision.
  [Factory][easycard] / [registry][registry]
- **MIFARE Classic families** such as Oyster, CharlieCard, TAP, reusable
  OV-chipkaart, EasyCard Classic, Rejsekort, Smartrider and Bip require
  authenticated sector reads. Publicly known/default keys still require
  authentication and a compatible reader. They are a separate external-reader
  workstream; built-in iPhone NFC does not add Classic support. FareBot itself
  distinguishes this in its platform/key requirements. [README][readme]
- **AT HOP, Presto, Nol, Istanbulkart, Nortic, TPF and Nextfare DESFire** have
  locked/identification-only implementations; **Holo and TriMet Hop** are
  identification-only because the useful account data is not stored on-card.
  [Serial-only implementations][serialonly]

## Suggested implementation order

1. **ORCA**, for the strongest missing trip-history functionality. Reuse the
   general [DESFire transport](../../android/app/src/main/java/ad/neko/cardbal/android/nfc/StoredValueProtocol.kt);
   add its own sizes, record/trip reconciliation and reviewed station catalogs.
   The integrated generic transport already supports variable record widths.
2. **Adelaide and Hafilat**, for dedicated DESFire/EN1545 application profiles
   with public recent events and contracts. Reuse existing primitives without
   treating an existing Calypso network profile as equivalent.
3. **Tampere**, for route/fare/transfer history and products, preserving the
   upstream limit that both station endpoints are not established.
4. **Remaining Intercode networks**, such as OuRA, KorriGo and Pastel, where
   FareBot supplies more specific factory/lookup knowledge than CardBal's generic
   French parsing. Research positive identity, products, dates and station data
   per network rather than adding a shared AID.
5. **Compass/Ventra and HSL Ultralight** tickets, as bounded ticket-validation
   additions. Clipper Ultralight transport is being integrated, but sharing a
   chip does not establish a shared ticket layout.

Separately improve already implemented readers where evidence supports it:
KMT's historical epoch, named HSL/Waltti products/zones/routes, and station
lookups for named Calypso profiles. HSL/Waltti journey, reload and embedded-event
decoding already exists. These are enrichment and validation tasks, not missing
reader implementations.

For each candidate, verify a public or synthetic fixture through the parser and a real card
through both intended reader paths. A parser accepting imported dumps proves
less than successfully reading the same data from a live card without keys.

[orca]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/orca/src/commonMain/kotlin/com/codebutler/farebot/transit/orca/OrcaTransitFactory.kt
[orca-tx]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/orca/src/commonMain/kotlin/com/codebutler/farebot/transit/orca/OrcaTransaction.kt
[kmt]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/kmt/src/commonMain/kotlin/com/codebutler/farebot/transit/kmt/KMTTransitFactory.kt
[kmt-trip]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/kmt/src/commonMain/kotlin/com/codebutler/farebot/transit/kmt/KMTTrip.kt
[hsl]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/hsl/src/commonMain/kotlin/com/codebutler/farebot/transit/hsl/HSLTransitFactory.kt
[hsl-tx]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/hsl/src/commonMain/kotlin/com/codebutler/farebot/transit/hsl/HSLTransaction.kt
[intercode]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/intercode/IntercodeTransitFactory.kt
[navigo]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/intercode/IntercodeLookupNavigo.kt
[adelaide]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/adelaide/src/commonMain/kotlin/com/codebutler/farebot/transit/adelaide/AdelaideTransitFactory.kt
[hafilat]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/hafilat/src/commonMain/kotlin/com/codebutler/farebot/transit/hafilat/HafilatTransitFactory.kt
[hafilat-tx]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/hafilat/src/commonMain/kotlin/com/codebutler/farebot/transit/hafilat/HafilatTransaction.kt
[tampere]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/tampere/src/commonMain/kotlin/com/codebutler/farebot/transit/tampere/TampereTransitFactory.kt
[tampere-trip]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/tampere/src/commonMain/kotlin/com/codebutler/farebot/transit/tampere/TampereTrip.kt
[ezlink]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/ezlink/src/commonMain/kotlin/com/codebutler/farebot/transit/ezlink/EZLinkTransitFactory.kt
[ezlink-data]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/ezlink/src/commonMain/kotlin/com/codebutler/farebot/transit/ezlink/EZLinkData.kt
[cepas]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/cepas/src/commonMain/kotlin/com/codebutler/farebot/card/cepas/CEPASProtocol.kt
[snapper]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/snapper/src/commonMain/kotlin/com/codebutler/farebot/transit/snapper/SnapperTransitFactory.kt
[snapper-tx]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/snapper/src/commonMain/kotlin/com/codebutler/farebot/transit/snapper/SnapperTransaction.kt
[opal]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/opal/src/commonMain/kotlin/com/codebutler/farebot/transit/opal/OpalTransitInfo.kt
[compass]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/yvr-compass/src/commonMain/kotlin/com/codebutler/farebot/transit/yvrcompass/CompassUltralightTransitInfo.kt
[ventra]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/ventra/src/commonMain/kotlin/com/codebutler/farebot/transit/ventra/VentraUltralightTransitInfo.kt
[nextfare-ul]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/nextfareul/src/commonMain/kotlin/com/codebutler/farebot/transit/nextfareul/NextfareUltralightTransitData.kt
[hsl-ul]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/hsl/src/commonMain/kotlin/com/codebutler/farebot/transit/hsl/HSLUltralightTransitFactory.kt
[opus]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/opus/OpusTransitInfo.kt
[opus-lookup]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/opus/OpusLookup.kt
[mobib]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/mobib/MobibTransitInfo.kt
[ravkav]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/ravkav/RavKavTransitInfo.kt
[mrtj]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/mrtj/src/commonMain/kotlin/com/codebutler/farebot/transit/mrtj/MRTJTransitInfo.kt
[myki]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/myki/src/commonMain/kotlin/com/codebutler/farebot/transit/myki/MykiTransitInfo.kt
[leap]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/tfi-leap/src/commonMain/kotlin/com/codebutler/farebot/transit/tfileap/LeapTransitFactory.kt
[desfire-reader]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/desfire/src/commonMain/kotlin/com/codebutler/farebot/card/desfire/DesfireCardReader.kt
[easycard]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/easycard/src/commonMain/kotlin/com/codebutler/farebot/transit/easycard/EasyCardTransitFactory.kt
[registry]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/app/src/commonMain/kotlin/com/codebutler/farebot/shared/transit/TransitFactoryRegistryBuilder.kt
[readme]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/README.md
[serialonly]: https://github.com/codebutler/farebot/tree/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/serialonly
