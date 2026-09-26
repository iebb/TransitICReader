# Trip Reader / 读卡识途 station data

CardBal's China station catalog was compared with the official
[Trip Reader download directory](https://support.domosekai.com/download/),
its `tripreader-1.7.17-cn.apk`, and the author's
[public dataset](https://github.com/domosekai/tripreader-data).
The directory's newest listed Android download was 1.7.17 when checked on
2026-09-24. This was a static data and decoder review, not an Android UI or
physical-card test.

A follow-up [Shanghai dual-application review](shanghai-dual-application-review.md)
compares City Union and T-Union selection, balances, history reconciliation,
and the separate Shanghai CU station mappings, now integrated in the iOS reader.

## Integrated coverage

The existing 5,586 station-code mappings retained their names and coordinates.
The update adds 127 mappings, bringing the total to **5,713**:

| City | Added mappings | Source |
| --- | ---: | --- |
| Ningbo | 79 short-form station codes | Published `Zhejiang/Ningbo/metro-tu.csv` |
| Xiamen | 45 BRT stop codes | Published `Fujian/Xiamen/brt-tu.csv`, also present in the APK |
| Taizhou | 3 rail station codes | APK rail table: 仙居南 `34503113`, 临海南 `34503116`, 台州西 `34503119` |

Seventy-eight Ningbo aliases inherit the existing coordinates only where city,
station name, transport type, and mapped OSM identity agree unambiguously.
The remaining additions have no fabricated coordinates. Existing route edges
are preserved. The decoder's JSON registry also receives 78 station codes that
were already in SQLite but missing from the JSON lookup.

The source and unified databases also contain **4,662 exact terminal mappings**:

| City | Terminal mappings | Record field |
| --- | ---: | --- |
| Hangzhou | 3,403 | SFI `18`, full 6-byte terminal |
| Nanjing | 580 | SFI `18`, full 6-byte terminal, bicycle stops |
| Shaoxing | 469 | SFI `18`, full 6-byte terminal |
| Jiaxing | 163 | SFI `18`, full 6-byte terminal |
| Dalian | 35 | SFI `1E`, full 8-byte terminal, BRT stops |
| Hefei | 12 | SFI `1E`, full 8-byte terminal, BRT stops |

Terminal IDs live in `tunion_terminal_stations`, separate from the
`cn.tunion.station_key` identifier namespace. Each row preserves its city,
record kind, stop name, line, source, and optional station-code link. The APK's
4,014 exact gate-to-station relationships take precedence; other links require
an unambiguous same-city name and transport type. A gate number never becomes
a physical station or a station prefix.

For T-Union purchase records, a full terminal ID can supply the location only
if it has exactly one city match. Travel records first use their station code,
then a full terminal match in the same city. An 8-byte travel terminal can use
the 6-byte table only when its leading two bytes are zero. Top-ups and other
card families do not use T-Union purchase-terminal inference. The raw-details
view and city atlas use the same lookup.

## Source handling

The importer previously traversed only top-level city folders. It now loads
the complete recursive tree at public repository revision
`c5584d6b8d9a39d7162b7b9781134be52db66186`. A truncated tree, failed download,
conflicting mapping, or unexpected code format aborts the refresh. Existing
station names and coordinates take precedence over older CSV names.

The source snapshot contains 4,126 station rows, 781 line rows, terminal rows,
per-file SHA-256 hashes, and attribution. Its line metadata includes operator
and route labels; these labels are not imported as physical stops. The 65
short Xi'an codes describe a terminal subfield rather than the station field.
They are counted as excluded until their record discriminator is implemented.
City Union terminal formats, historical date-dependent names, and other card
protocols are outside this T-Union import.

The three APK supplement rows are in
`scripts/data/tripreader-apk-stations.json`. They were read from
`M0.W.f1054a` in the official APK with SHA-256
`b8cc78e73c3775f602656b4cde46c6ec4994ca364cdf985c5a18c6f68fe111b1`.
The APK's terminal tables also supply 4,014 exact station-code links for the
published gates. Eleven aliases resolve the current name 长安 in place of the
older 长安（东方学院） label; the original CSV name remains in source metadata.
No APK, decompiled application code, or personal card history is included.

## Shanghai City Union

The follow-up import adds **614 CU terminal-prefix mappings** from the same pinned
public `Shanghai/cu.csv`. They remain in `cityunion_terminal_prefixes`, with city
code `2000`; TU Shanghai stays `2900`. The generator links **577** prefixes to TU
station identities only on a unique city/name/line/mode match, exposing those links
as `cn.cityunion.terminal_prefix`. The remaining 37 retain names and provenance
without fabricated coordinates. These are additional identifiers, not 614 new
physical stations. Both portable and iOS databases retain every source row.

## Attribution

Published CSV data is by **Domosekai Limited and the Trip Reader data
contributors**, under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
CardBal normalizes identifiers, combines the rows with existing mappings,
separates record formats, and retains current names when older sources differ.
The APK supplement has separate provenance; the public repository's license
is not asserted for APK-only data. OSM-derived coordinates retain their
[OpenStreetMap attribution](https://www.openstreetmap.org/copyright).

## Refresh and verify

```sh
python3 scripts/build_cross_platform_station_assets.py \
  --target tunion --skip-tunion-osm --rebuild-unified --no-sync-android

# Repeat from the checked-in snapshot, without fetching station sources:
python3 scripts/build_cross_platform_station_assets.py \
  --target tunion --skip-tunion-osm --offline-tunion-source \
  --rebuild-unified --no-sync-android

PYTHONWARNINGS='error::ResourceWarning' python3 -m unittest discover \
  -s scripts/tests -p 'test_*.py' -q
```

Both `StationAssets/` and `CardBal/Resources/` copies must match byte for byte.
The unified generator checks terminal-row parity as well as station/graph
parity, SQLite integrity, and relational invariants before publishing a build.
The Swift regression harness executes the production resolver and record
decoders with station prefixes, terminal collisions, wrong cities, unmatched
gates, and purchase versus top-up records.
