# FareBot card assessment: balance required

Reviewed 2026-11-01 against FareBot master at
`dc09f6f014ea3675b64bcd38335b4b78d77fa374`.
The upstream head was rechecked on that date and still matches this revision.
CardBal comparisons use monorepo `origin/master` at
`79eaf0b` plus the China/Lisbon implementation in this worktree.
The original survey's "next" list predates the monorepo parity work.
See the [current platform matrix](platform-parity.md) and
[additional-card research](card-support.md) for implementation scope.

Here, **publicly readable** means the card exposes useful data through read
commands without supplying secret keys, authenticating through an operator
service, or recovering keys. This is a source-code assessment of supported card
formats, not a claim that every current issue of each branded card is readable.
No physical cards were tested for this survey.

The inclusion rule is **a readable monetary balance**. A serial, successful
application selection, trip history, pass validity, remaining rides or a
contract's purchase price does not establish a stored-value balance. Balance
readability and current usefulness are assessed separately: a legacy parser can
meet the first requirement without providing a current card's balance.

The earlier history-led priority list is superseded below. In particular,
Adelaide and Hafilat expose no decoded money balance, and FareBot's ORCA parser
does not establish support for the next-generation cards.

## Implemented after this assessment

The newer Shenzhen Tong, Wuhan Tong, legacy Beijing Yikatong and Lisboa Viva
Zapping layouts now have balance and readable-history implementations in both
platform codebases. Beijing uses an external ISO 7816 reader on iOS: its short
`OC` / `PBOC` names cannot be declared for built-in Core NFC discovery. See
[China wire notes](../decoding/china-local.md) and
[Lisbon wire notes](../decoding/lisboa-zapping.md). Synthetic tests establish
parser behavior; physical-card validation remains outstanding.

## Balance readers assessed

These are source-level candidates, not physical-card validation. The current
CardBal platform matrix and reader sources were checked for overlap; an existing
T-Union reader does not establish support for a city's separate legacy purse.

| Card / format | Balance evidence | Assessment |
|---|---|---|
| **Shenzhen Tong, newer ISO 7816 format** | `PAY.SZT` (`5041592E535A54`); CNY purse plus trips. [Decoder][shenzhen-new] | Implemented on both platforms using the PBOC transport. Keep separate from legacy FeliCa Shenzhen Tong and the T-Union companion purse. |
| **Wuhan Tong** | `AP1.WHCTC`; CNY purse plus trips. [Decoder][wuhan] | Implemented on both platforms with positive application selection. |
| **Beijing Yikatong, legacy PBOC format** | Applications named `OC` or `PBOC`; CNY purse, validity and trips. [Decoder][beijing] | Implemented on Android and iOS external readers. Requires the short name, a readable purse, nonempty serial and valid metadata dates. Built-in iPhone discovery is unavailable for these short names. T-Union variants retain their separate reader. |
| **Lisboa Viva / navegante Zapping** | Calypso counter converted to EUR when the contract tariff is `33592` and the provider is interagency 31. [Subscription][lisboa-sub] / [lookup][lisboa-lookup] | Implemented in both Calypso readers, including SFI 06 contracts, original counter slots and local-second travel events. Only provider 31 / tariff 33592 becomes money; a current card still needs validation. |
| **MagnaCarta** | DESFire application `F080F3`, file `02`, bytes 6-7; EUR purse, no trips. [Factory][magnacarta-factory] / [info][magnacarta-info] | Balance criterion met. Cashless-card scope rather than a new transit network; optional if those cards belong in CardBal. |

The China trio should reuse the shared balance/record transport while retaining
application-specific identity, serial and file layouts. This assessment does
not establish that Trip Reader imports for every one of these formats become
supported automatically.

## Balance formats with material limits

| Card / format | Balance evidence | Limit and recommendation |
|---|---|---|
| **Tampere / Nysse** | DESFire `0121EF`; contract type 7 holds EUR cents in bytes 7-8, with a file `01` fallback; file `03` has trips. [Factory][tampere] | Meets the source-level balance rule for this layout. Nysse says its new system moves travel-card information from the physical card into an account-based background system. Treat FareBot's parser as a legacy-layout candidate until a current card proves otherwise. [Operator][nysse-renewal] |
| **MRT Jakarta Kartu Jelajah Berganda** | FeliCa system `9373`, service `10D7`; IDR purse and last amount, no trip list. [Info][mrtj] / [factory][mrtj-factory] | Technically a simple balance reader, similar to KMT. The operator deactivated KJB on **31 October 2024**, so this is a retired-card addition rather than a useful current priority. [Operator][mrtj-retirement] |
| **ORCA, original layout** | DESFire `3010F2`, file `04`; USD purse plus history. [Factory][orca] | Legacy layout has a balance parser. Next-generation ORCA remains unsupported in upstream issue 818; issue 814 also reports first-generation card values not updating after the 2022 migration. Do not advertise a current ORCA balance or prioritize it without a fresh live-card reading. [Issue 818][orca-nextgen] / [issue 814][orca-stale] |
| **Legacy FeliCa Shenzhen Tong** | System `8005`, service `0118`; CNY conversion uses a fixed offset. [Source][octopus-info] | Raw data exists, but the conversion needs card-generation/calibration evidence. Do not treat this as a trustworthy current balance merely because FareBot formats a number. Prefer `PAY.SZT`. |
| **Troika Ultralight purse layout** | Shared Troika parser has RUB purse layouts E3/E5; other Ultralight layouts are ride tickets. [Source][troika-ul] | Only a card actually exposing the purse layout meets the money-balance requirement. Do not generalize to ordinary single/multiple-ride tickets or the key-dependent Classic purse. |
| **Ventra / Compass disposable tickets** | Shared Nextfare Ultralight parser exposes an 11-bit currency field from the latest transaction as `balance`. [Source][nextfare-ul] | Narrow disposable-ticket candidate. Validate that the field is spendable remaining money for the intended product. It does not establish balance support for the reusable Ventra/Compass cards. |
| **Intercard** | DESFire `5F8415`, file `01`; intended balance units are tenths of a cent. [Factory][intercard-factory] / [info][intercard-info] | Hold for verification/fixes. The factory casts file `01` to `StandardDesfireFile`, while the shared reader constructs `ValueDesfireFile` for value files. Such a file yields no balance through that cast. Currency also has a FIXME: CHF is hardcoded despite some issuers using EUR. [File parser][desfire-file-parser] |

## Excluded by the money-balance rule

- **Adelaide and Hafilat:** trips, contracts and purse metadata, but no decoded
  monetary balance in their transit-info or subscription implementations.
  File names containing "purse" do not establish balance decoding.
  [Adelaide][adelaide-info] / [Hafilat][hafilat-info]
- **Venezia, Pisa and additional French Intercode network names:** ticket,
  event and/or ride-counter support is insufficient. The shared EN1545 path
  can present a contract's `cost` as a balance, while the ordinary subscription
  `cost` is its purchase price. Count only a proven stored-value counter, such
  as Lisboa Zapping, rather than every non-null balance object.
  [Shared data][calypso1545] / [subscription][en1545-sub]
- **Kiev/Kyiv Digital, Warsaw, YarGor, Tartu, RicaricaMi and Cifial:** no
  decoded monetary balance found in the registered implementations.
- **Myki; locked Leap; AT HOP, Presto, Nol, Istanbulkart, Nortic, TPF,
  Nextfare DESFire, Strelka, SunCard and KROCAP:** identification-only or
  unavailable balance in the inspected path.
- **Holo and TriMet Hop:** identification-only, with useful account information
  held off-card. **HSL/OV-chipkaart Ultralight and other ride/pass-only tickets**
  do not qualify merely by reporting remaining rides or validity.
- **EMV, Amiibo, generic NDEF and generic Vicinity identities:** no supported
  stored-value transit purse established by these readers.

See the [central factory registry][registry] for the protocol-specific scope.
A branded card being listed in FareBot's README is not enough evidence.

## Balance-capable cards requiring Classic keys

These **meet the balance-data criterion conditionally on readable sectors**.
They are not excluded merely because they require keys. Deployment is a separate
constraint: authenticated Classic reads need compatible Android hardware or an
external reader, appropriate keys and a deliberate key-handling design.
Built-in iPhone NFC does not expose Classic sector access.

The registered balance-capable families include Bilhete Unico, Bip!, Bonobus,
CharlieCard, EasyCard Classic, ERG (Manly Fast Ferry and Christchurch Metrocard),
Gautrain, Kazan, KomuterLink, MetroMoney, Metro Q, Nextfare Classic (including
LAX TAP and MSP GoTo), Otago GoCard, OV-chipkaart Classic, Oyster, Podorozhnik,
RKF (Rejsekort, SLaccess and Vasttrafik), Selecta, SEQ Go, SmartRider,
Touch 'n Go, Troika Classic/hybrid, Umarsh, Zolotaya Korona and Waikato
BUSIT/SmartRide Rotorua.
This is not a claim about every current generation issued under those brands.
[Registry][registry] / [platform and key requirements][readme]

## Travel-history evidence and current CardBal scope

This older matrix retains implementation evidence; the balance assessment above
controls eligibility and priority.

| Card / region | Protocol | Evidence in FareBot | Value and effort for CardBal |
|---|---|---|---|
| **ORCA / Seattle** | DESFire | Application `3010F2`; file `02` travel records, `03` top-ups, `04` purse. Serial comes from `FFFFFF/0F`. Transaction decoder understands tap-in/out/cancel, fares, balances, operators, rail/ferry/BRT station mappings and bus vehicle IDs. [Factory][orca] / [transactions][orca-tx] | Legacy layout only. Next-generation support is not established, and old card values may be stale after migration. Requires a current live-card balance check before implementation priority is justified. |
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

## Follow-up order

1. Validate the implemented **China PBOC trio** and **Lisboa Zapping** with
   current physical cards. Beijing's built-in iPhone limitation is explicit.
2. Assess **Lingnan Pass / Yang Cheng Tong**, **Suzhou Citizen Card** and
   **Tsinghua campus cards** found in other projects; see the
   [cross-platform follow-up](other-balance-readers.md).
3. **MagnaCarta**, if campus/cashless cards are in product scope. Resolve
   **Intercard** only after the file-type and currency issues are demonstrated
   and fixed.
4. **Tampere and the narrow ticket/purse layouts** only after present-day
   on-card balance validation. Keep retired MRT Jakarta and stale/unsupported
   ORCA layouts out of the current-support promise.
5. Treat **Classic balance readers** as a separate platform/key workstream,
   rather than adding identifiers and claiming balance support.

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
[beijing]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/china/src/commonMain/kotlin/com/codebutler/farebot/transit/china/BeijingTransitInfo.kt
[shenzhen-new]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/china/src/commonMain/kotlin/com/codebutler/farebot/transit/china/NewShenzhenTransitInfo.kt
[wuhan]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/china/src/commonMain/kotlin/com/codebutler/farebot/transit/china/WuhanTongTransitInfo.kt
[lisboa-sub]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/lisboaviva/LisboaVivaSubscription.kt
[lisboa-lookup]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/calypso/src/commonMain/kotlin/com/codebutler/farebot/transit/calypso/lisboaviva/LisboaVivaLookup.kt
[magnacarta-factory]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/magnacarta/src/commonMain/kotlin/com/codebutler/farebot/transit/magnacarta/MagnaCartaTransitFactory.kt
[magnacarta-info]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/magnacarta/src/commonMain/kotlin/com/codebutler/farebot/transit/magnacarta/MagnaCartaTransitInfo.kt
[nysse-renewal]: https://www.nysse.fi/en/tickets-and-fares/travel-card/account-based-payment-system.html
[mrtj-factory]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/mrtj/src/commonMain/kotlin/com/codebutler/farebot/transit/mrtj/MRTJTransitFactory.kt
[mrtj-retirement]: https://landingpage-dev.jakartamrt.co.id/id/siaran-pers/dorong-sistem-pembayaran-berbasis-aplikasi-kartu-jelajah-berganda-dinonaktifkan
[orca-nextgen]: https://github.com/metrodroid/metrodroid/issues/818
[orca-stale]: https://github.com/metrodroid/metrodroid/issues/814
[octopus-info]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/octopus/src/commonMain/kotlin/com/codebutler/farebot/transit/octopus/OctopusTransitFactory.kt
[troika-ul]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/troika/src/commonMain/kotlin/com/codebutler/farebot/transit/troika/TroikaUltralightTransitFactory.kt
[intercard-factory]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/intercard/src/commonMain/kotlin/com/codebutler/farebot/transit/intercard/IntercardTransitFactory.kt
[intercard-info]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/intercard/src/commonMain/kotlin/com/codebutler/farebot/transit/intercard/IntercardTransitInfo.kt
[desfire-file-parser]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/card/desfire/src/commonMain/kotlin/com/codebutler/farebot/card/desfire/raw/RawDesfireFile.kt
[adelaide-info]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/adelaide/src/commonMain/kotlin/com/codebutler/farebot/transit/adelaide/AdelaideTransitInfo.kt
[hafilat-info]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/hafilat/src/commonMain/kotlin/com/codebutler/farebot/transit/hafilat/HafilatTransitInfo.kt
[calypso1545]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/en1545/src/commonMain/kotlin/com/codebutler/farebot/transit/en1545/Calypso1545TransitData.kt
[en1545-sub]: https://github.com/codebutler/farebot/blob/dc09f6f014ea3675b64bcd38335b4b78d77fa374/transit/en1545/src/commonMain/kotlin/com/codebutler/farebot/transit/en1545/En1545Subscription.kt
