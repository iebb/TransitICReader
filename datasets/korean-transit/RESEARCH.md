# Korean transit attribution findings

Research snapshot: 2026-07-27 09:05 JST. The canonical corpus has 3,681 rows,
192 hashed cards, 1,026 exact six-byte location fingerprints, and 83 observed
transport-mode values.

## Result

- 3,086 rows (83.8%) and 820 fingerprints have a cited official station row.
- 872 rows / 525 fingerprints use a direct, exact settlement-station ID join.
- 2,214 rows / 295 fingerprints use a documented, system-scoped transform and
  then an exact official-row join.
- 3,527 rows (95.8%) match an official KOTRIS or Seoul mode-table row. Including
  separately labeled institutional and corpus associations, 3,647 rows (99.1%)
  have some system-level attribution.
- 595 rows / 206 fingerprints remain unnamed. Unknowns are retained as raw
  tokens rather than filled by fuzzy station-name or geographic matching.

## Coordinate and multilingual enrichment

- 355 aliases have exact cited coordinates, covering 2,316 rows (62.9% of the
  corpus and 75.0% of rows that already have a station identity).
- 186 aliases / 1,806 rows have official English names; 158 / 1,578 have Hanja;
  177 / 1,717 have Chinese; and 177 / 1,717 have Japanese. Traditional Chinese
  is available for 45 aliases and is stored separately from simplified Chinese.
- Coordinate, identity, translation, and Hanja provenance remain separate. No
  coordinate is accepted through nearest-neighbor or fuzzy-name matching, and
  no station translation is machine-generated.

The coordinate layer uses the [Seoul TOPIS station master](https://data.seoul.go.kr/dataList/OA-21232/S/1/datasetView.do?tab=A),
the [MOLIT nationwide bus-stop location inventory](https://www.data.go.kr/data/15067528/fileData.do),
[Busan BIMS](https://www.data.go.kr/data/15092750/openapi.do), and the official
[Busan Metro coordinate dataset](https://www.data.go.kr/data/15043686/fileData.do).
Official translations come from [Seoul Metro](https://www.data.go.kr/data/15044232/fileData.do),
[Busan Transportation Corporation](https://work.humetro.busan.kr/homepage/default/stationinfo/page/list01.do?menu_no=1001010201),
and KRIC line datasets. Jeju station identities remain accepted, but no Jeju
coordinates are published because the settlement IDs cannot be exact-joined to
the current nine-digit local BIS identifiers.

## Accepted station relations

| Relation | Rows | Fingerprints | Evidence boundary |
| --- | ---: | ---: | --- |
| Nationwide bus settlement ID | 872 | 525 | Eight decimal token digits ending in zero; drop that zero and require one exact official annual/selector ID. |
| Capital rail stable crosswalk | 1,451 | 141 | High-only exact fingerprint crosswalk to official current station rows; legacy relation is inferred. |
| Additional capital rail high tier | 135 | 18 | Every cited MOLIT row number/ID/name is rechecked; 12 also recheck a Seoul CSV row. Nine hypotheses remain excluded. |
| Busan BIMS bus | 305 | 43 | Busan KOTRIS modes only; low 16 bits little-endian to a collision-free five-digit official ARS ID. |
| Busan Metro | 250 | 28 | Mode 870 only; scoped Mybi station-byte transform to an exact official station row. |
| Daegu Line 2 | 4 | 4 | Mode 872 only; event selects one token half, then the exact operator station code. |
| Jeju buses | 67 | 59 | Modes 990/994/995 only; discard one variant digit and require a unique exact ID across 3,400 official selector rows. |
| Seoul code 190 places | 2 | 2 | Exact trip-date selector rows for 옥수 and 잠실. The code's system/operator identity remains unresolved. |

The KORAIL KOTRIS mode source is the official [319-row transport-mode table](https://www.data.go.kr/data/15121099/fileData.do).
Station identities come primarily from the [MOLIT nationwide settlement
inventory](https://www.data.go.kr/data/15128614/fileData.do), the dated [MOLIT
bus-stop selector](https://www.data.go.kr/data/15142032/openapi.do), the [Seoul
Big Data Campus station table](https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13),
[Busan BIMS](https://www.data.go.kr/data/15092750/openapi.do), and [Daegu
Transportation Corporation](https://www.data.go.kr/data/15061835/fileData.do).

## Rail namespace finding

The raw four-byte card token is not a current public Seoul/KRIC station ID.
Official MT12 and RSI documentation explicitly models internal and external
station numbers as separate fields, but does not publish the needed row-level
historical crosswalk. CardBal therefore keeps the observed legacy number apart
from `publicStationId` and labels every relation as inferred:

- [2018 MOLIT/KRRI MT12 schema report](https://www.codil.or.kr/filebank/original/RK/OTKCRK190216/OTKCRK190216.pdf)
- [2021 MTC/KOTI RSI schema report](https://www.codil.or.kr/filebank/original/RK/OTKCRK240571/OTKCRK240571.pdf)

## Deliberately withheld

- Nine capital-rail hypotheses (Incheon Line 2, Ui-Sinseol, Sillim, and later
  Bundang tokens) have coherent route/distance evidence but no sufficiently
  stable public legacy relation. They remain in the high-only artifact as
  exclusions, never as displayed names.
- Mode 877 strongly resembles Busan-Gimhae Light Rail for two fingerprints, but
  877 is absent from the official KOTRIS table; the candidate is not integrated.
- Modes 950, 971, 980, 970, 972, and 926 have too little geographic evidence.
  Mode 950 is Pocheon-associated at card level but its tokens do not exact-join
  the dated official selector.
- Modes 901, 905, 909, and 928 share sentinel/malformed-looking layouts;
  coincidental station-ID matches are rejected.
- Busan Metro IDs 148 and 180 remain unresolved rather than extrapolated.

## Time and field parsing

Standard records use the observed 33-bit packed clock
`[year:7 month:4 day:5][hour:5 minute:6 second:6]`. Strict seven-byte BCD is
accepted first where valid. Mybi-family bytes 11–17 remain two raw 24-bit
counters plus a flag because no defensible epoch was found. This produces 2,805
plausible timestamps (76.2%) and 1,219 paired journey candidates without
inventing dates for operator-opaque rows.

## Reproduce

```sh
python3 scripts/generate_molit_jeju_mappings.py
python3 scripts/build_korean_station_aliases.py
python3 scripts/generate_korean_transit_dataset.py \
  --source-sqlite datasets/korean-transit/cardbal-korean-transit.sqlite
```

The final JSON SHA-256 is
`9054c685b666a1188de9dd2f4ae10f5112e4bce2d469cae3b359664c8366ff96`;
the SQLite SHA-256 is
`671b1b032e584f5b0da9bfcc095a10ca6d072f643ac816e33844eb89b5df60e7`.
