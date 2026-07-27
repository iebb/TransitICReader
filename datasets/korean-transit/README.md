# CardBal Korean transit research dataset

This directory is the canonical local, reproducible snapshot behind the
Cloudflare Pages Korean Trip Atlas.

- `cardbal-korean-transit.sqlite` contains the original D1-compatible rows,
  every attributed row, all 319 official KOTRIS modes plus separately sourced
  Seoul/institutional supplements, station
  aliases, aggregates, journey candidates, field statistics, and citations.
- `korean-trips.json` is the complete browser-ready representation.
- `manifest.json` records hashes, coverage, source provenance, and the observed
  mode-by-mode attribution state.

The local canonical records and public Pages build retain every full 52-byte
card-history payload. Card identifiers are SHA-256 hashes; neither artifact
contains a plaintext full card ID, and every `last4` / `cardLast4` field is
discarded. Only the full hashes are exposed as card identifiers.

## Generate

From the repository root, refresh from the production D1 database and sync the
Pages snapshot:

```sh
python3 scripts/generate_korean_transit_dataset.py
```

Rebuild fully offline from the local SQLite snapshot:

```sh
python3 scripts/generate_korean_transit_dataset.py \
  --source-sqlite datasets/korean-transit/cardbal-korean-transit.sqlite
```

For a byte-for-byte reproducible JSON metadata timestamp, also pass
`--generated-at` with the value recorded in `manifest.json`. The output uses
atomic replacement and validates the SQLite integrity and table counts before
finishing.

Station names are evidence-qualified. `official_dataset_exact_match` is the
strict settlement-ID join. `official_dataset_transformed_exact_match` means an
exact official station row reached through a documented, system-scoped legacy
transform (capital rail, Busan BIMS/Metro, Daegu, or Jeju); the transform is not
misrepresented as an official card-format specification. The dated code-190
Seoul match attributes only two places and deliberately leaves the system and
operator unresolved. `user_confirmed` means a supplied labelled trip sample;
all such samples now also have official-row attribution. Review candidates and
unresolved tokens remain raw.

Regenerate the two-district Jeju crosswalk from the vendored official selector
responses with `python3 scripts/generate_molit_jeju_mappings.py`, then rebuild
`CardBal/Resources/KoreanStationAliases.json` before running the canonical
dataset generator. High-only capital-rail artifacts retain rejected hypotheses
separately, and the build rechecks every cited official CSV row and source hash.

Timestamp parsing is also profile-scoped: standard records use a 33-bit packed
clock, regional rows may use seven-byte BCD, and Mybi-family bytes 11–17 are
retained as two opaque counters plus a flag until an epoch is evidenced.

The Pages enrichment layer adds exact coordinates to 355 of the 820 aliases
(2,316 rows) and official station translations to 186 English, 158 Hanja, 177
Chinese, and 177 Japanese aliases. Identity, coordinates, and translated names
carry separate source IDs and matching methods. Missing coordinates and names
remain empty; neither nearest-stop matching nor machine translation is used.
