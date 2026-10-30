# Development wallets

These JSON files use the normal cross-platform CardBal backup format. They are
repository development inputs, not app-bundle resources.

- `owner-wallet.json`: all 48 entries from the owner's local wallet export,
  containing 513 raw transaction/transit records. This collection mixes real
  captures and existing owner mock entries; the original export has no reliable
  per-entry provenance flag. Do not describe every entry as a verified physical
  scan. Older decoded-only entries were recovered from their `rawData` fields.
- `mock-wallet.json`: three explicitly synthetic Ryuto, Edy and nanaco examples,
  generated from the existing invented protocol vectors in
  `tests/runtime/fixtures/card-parity.json`. These are not physical captures.

Both sets omit custom artwork, artwork references, original card identifiers,
custom names and device metadata. Balances, fares, public station/operator codes
and ticket state are retained. Dates are shifted; these are not untouched dumps.
The project license applies to these contributed samples. Station names and maps
are resolved from the separately licensed bundled station catalog.

See [the simulator guide](../../docs/development/sample-data.md) for launch
commands, transformations, limitations and the contribution procedure.
