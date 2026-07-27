# Korean Trip Atlas

Static Cloudflare Pages visualizer for every row in the CardBal Korean trip-record D1 dataset.

## Data model

- `stationToken`: opaque bytes 05–08. It is stable, but it is not a public Seoul/KRIC station ID.
- `transportModeCode`: bytes 09–10 matched as an unsigned big-endian KOTRIS transport-mode code. The KORAIL table is official; applying it to this card field is a CardBal corpus inference.
- `locationCode`: the exact six-byte fingerprint used for confirmed place matches.
- `timestampLayout`: strict seven-byte BCD first; standard operators then use a 33-bit packed clock. Mybi-family blocks remain `operator_opaque` counters rather than fabricated dates.
- Full SHA-256 card IDs and raw 52-byte records are retained in the public
  snapshot. Plaintext card-number suffixes are deliberately omitted.

The vendored UTF-8 code table in `scripts/sources/` is converted from the unrestricted KORAIL KOTRIS CSV published at <https://www.data.go.kr/data/15121099/fileData.do>.

Station inputs are vendored under `scripts/sources/`: MOLIT's annual nationwide
settlement inventory and newer selector deltas, the Seoul Big Data Campus
station table, Busan BIMS, Busan Metro, and Daegu Transportation Corporation.
`scripts/build_korean_station_aliases.py` emits only exact observed six-byte
fingerprints. It accepts exact settlement-ID joins; capital rail, Busan, Daegu,
and Jeju mappings use documented system-specific transforms with their
provenance retained per alias. The code-190 dated Seoul result maps only the
place and does not invent a system identity. Review candidates are retained as
exclusions and are not published as names.

## Coordinates and official translated names

The app has 820 sourced station aliases. The stricter coordinate layer places
355 aliases covering 2,316 of 3,681 rows (62.9%). Exact coordinate sources are
the [Seoul TOPIS station master](https://data.seoul.go.kr/dataList/OA-21232/S/1/datasetView.do?tab=A),
[MOLIT nationwide bus-stop locations](https://www.data.go.kr/data/15067528/fileData.do),
[Busan BIMS](https://www.data.go.kr/data/15092750/openapi.do),
[Busan Metro station coordinates](https://www.data.go.kr/data/15043686/fileData.do),
and KRIC/Daegu operator data. Five conflicting names and 123 ambiguous
mobile/province matches remain unplotted. Jeju names remain attributed, but its
settlement identifiers cannot be exact-joined to the current nine-digit local
BIS coordinate identifiers, so no Jeju coordinate is guessed.

Official translated labels are kept verbatim and independently sourced:

- English: 186 aliases / 1,806 rows.
- Hanja: 158 aliases / 1,578 rows.
- Chinese: 177 aliases / 1,717 rows; traditional Chinese is available for 45
  aliases.
- Japanese: 177 aliases / 1,717 rows.

Sources include [Seoul Metro multilingual station names](https://www.data.go.kr/data/15044232/fileData.do),
[Busan Transportation Corporation station pages](https://work.humetro.busan.kr/homepage/default/stationinfo/page/list01.do?menu_no=1001010201),
and KRIC's official [Line 9](https://www.data.go.kr/data/15041811/fileData.do),
[AREX](https://www.data.go.kr/data/15041034/fileData.do),
[Daegu Line 2](https://www.data.go.kr/data/15041045/fileData.do), and
[Shinbundang](https://www.data.go.kr/data/15041033/fileData.do) datasets. Hanja
is stored separately from Chinese, and missing translations remain blank; the
build does not machine-translate or fuzzy-match station names.

## Refresh, verify, and deploy

```sh
CLOUDFLARE_ACCOUNT_ID=599ee1cd6c4d3dc453d290c4c0477e76 npm run data:refresh
npm test
npm run build
CLOUDFLARE_ACCOUNT_ID=599ee1cd6c4d3dc453d290c4c0477e76 npm run deploy
```

The refresh command now generates the canonical local JSON and SQLite archive
under `../../datasets/korean-transit/`, validates it, and copies the identical
JSON bytes into the Pages app. The lower-level site builder remains available
as `npm run data:site-only`; it accepts `--sqlite /path/to/export.sqlite`.

The canonical generator can rebuild without Cloudflare access:

```sh
python3 ../../scripts/generate_korean_transit_dataset.py \
  --source-sqlite ../../datasets/korean-transit/cardbal-korean-transit.sqlite
```

To regenerate the app's station alias resource after replacing the dated MOLIT snapshot or corpus snapshot:

```sh
python3 ../../scripts/build_korean_station_aliases.py
```

The Jeju name-mapping artifact itself is reproducible from its two vendored
official district responses with
`python3 ../../scripts/generate_molit_jeju_mappings.py`; this does not create a
coordinate bridge.
