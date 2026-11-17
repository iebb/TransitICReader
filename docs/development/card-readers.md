# Adding or changing a card reader

Start with the [coverage reference](../decoding/capabilities.md) and
[decoder pipeline](../decoding/cards.md). A brand name, chip family or successful
application selection does not prove that a balance or transaction file is
readable.

## Establish the readable format

Identify the card generation, transport, application, files and positive
identification fields. Record exact command bytes, lengths, byte order,
currency units and timestamp epoch in the relevant `docs/decoding/` page.
Pin protocol references to the revision that supplies those facts.

Keep monetary balance, ticket validity, remaining rides and purchase price
distinct. Account-based balances such as SimplyGo are not a local stored-value
purse. A generation with the same brand may use a different layout or expose
only a serial number.

For built-in iPhone NFC, declare the required ISO 7816 AIDs and FeliCa system
codes in `ios/CardBal/Info.plist`. Runtime selection does not add undeclared
discovery identifiers. Short application names may require an external
reader; [legacy Beijing](../decoding/china-local.md#platform-boundary) is one
such case. Android uses `IsoDep` or `NfcF` for the corresponding transport.

MIFARE Classic is a separate hardware and key requirement. Core NFC does not
expose Classic sector access, and Android support depends on the reader.
Recognizing DESFire or FeliCa also does not unlock protected files.
The existing reader transports and supported external hardware are described
in [external NFC readers](external-nfc-readers.md).

## Preserve meaning through the wallet

Implement bounded reads and explicit status handling. A failed or malformed
balance remains unavailable. Preserve legitimate zero balances and unknown
amounts separately. Do not invent timestamps, stations, fares or map coordinates.

Keep raw application, file and record identity through persistence, rescan
merging and backup import. Moving ring-buffer positions are not stable
transaction identities. Multiple applications on one physical card retain
separate balances and histories; do not infer that two purses can be summed.

Use portable station identifiers with provenance. A route, operator, terminal
prefix or city name is not automatically a physical station. Data contributions
belong in the [station catalog](../data/station-assets.md).

## Validate and document

Use invented protocol bytes for shared Swift and Kotlin fixtures. Cover positive
identity, wrong families, signed amounts, timezones, invalid lengths and status
words, bounded retries, optional-file failures and zero values. Exercise wallet
round trips and partial rescans as well as the pure parser.

Run the relevant checks from [the testing guide](testing.md). Compile the
native adapters when changing a transport or decoder integration. Synthetic
tests establish parser behavior; record physical reader/card verification
separately from format support, including any generation or discovery limits.

Update the coverage reference and the relevant protocol page to describe the
resulting behavior. Add user-facing release notes as described in
[the release guide](releases.md). Keep source attribution and applicable licence
notices; source-code adaptations retain the upstream licence.
