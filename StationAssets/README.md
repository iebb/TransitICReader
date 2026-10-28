# CardBal Portable Station Assets

This directory contains generated platform-neutral station assets. The source of
truth is the CSV catalog in [iebb/card-stations](https://github.com/iebb/card-stations),
pinned by `card-stations.lock.json`. Japanese IC uses one shared station CSV;
T-Union uses city files, Korean cards use company/mode files, and U-money uses
city files. Normal builds validate and compile CSVs without contacting upstream
station services. Xcode runs this step before copying resources.
The contributor CSVs contain codes, names, lines, coordinates, and real OSM
references. Korean mode names and classes are joined from `modes.csv` at build
time. Importer metadata is generated only where a legacy format requires it.

Routing comes from separate edge and ordered-stop CSVs in the same pinned
catalog. Japanese edge geometry is clipped from station_database rail
polylines, then stored as prefix-compressed geohash paths. The app decodes
vertices when drawing a route; unmatched edges retain their station fallback.
The iOS app consumes copies in `CardBal/Resources`. Country-specific legacy
assets can also be synchronized to an Android checkout, but the unified CardBal
database is an iOS/portable asset only.

Build and sync the Japanese IC, China T-Union, Korean mode, Ulaanbaatar, and
the unified CardBal transit database:

```sh
python3 scripts/build_cross_platform_station_assets.py --target all
# Test a local CSV contribution (or set CARDBAL_STATIONS_SOURCE for Xcode):
python3 scripts/build_cross_platform_station_assets.py --target all --csv-source ../card-stations
```

The `card-stations-manifest.json` records the source revision, source digest,
input checksums, output checksums, and whether an explicit local checkout has
uncommitted edits. The unified runtime retains the catalog revision in `sources`.
Update the lock's full commit SHA after merging a CSV contribution. The historical
network importers require explicit `--source upstream`; import their finalized
results into a temporary CSV catalog and review the diff in card-stations before
updating the pin. Country-specific SQLite and JSON/CSV assets remain as generator inputs
and for legacy Android consumers; the CardBal iOS target bundles only the
unified SQLite database.

China station enrichment reads every city directory in the pinned
`domosekai/tripreader-data` source tree and a reviewed three-station supplement
from Trip Reader 1.7.17. Station prefixes and exact terminal IDs are stored
separately. Refresh the China assets and the iOS runtime database with:

```sh
python3 scripts/build_cross_platform_station_assets.py --target tunion --skip-tunion-osm --rebuild-unified --no-sync-android
```

This normal command compiles the pinned CSV data. For a maintenance source
refresh, explicitly add `--source upstream`; `--offline-tunion-source` then reads
the historical source snapshot instead of downloading it.
See [Trip Reader data](../docs/tripreader-data.md) for attribution, the comparison
results, and the supported record fields.

An `all` build creates this normalized cross-country catalog after the source
databases are ready:

- `cardbal_transit.sqlite` — stations, canonical resolver identifiers, lines,
  edges, supported city and province boundaries, and authoritative city and
  province identifiers.

The packager combines the freshly generated station databases in this directory
with the finalized boundary, coverage, and Korean station resources in
`CardBal/Resources`. It validates station → city → province references inside
the unified SQLite file before replacing it. The iOS resource build links
`cardbal_transit.sqlite`, not the country-specific source databases, Korean TSV,
or boundary/coverage JSON inputs. The unified database is deliberately excluded
from Android synchronization. Partial source refreshes rebuild the iOS database
when `--rebuild-unified` is specified. The weekly station-data workflow compiles
the pinned CSV catalog. Upstream stop refreshes are reviewed in card-stations
before the app adopts a new revision.

Refresh only the Ulaanbaatar bus snapshot from the service used by
`com.uscc.ubbus`:

```sh
python3 scripts/build_cross_platform_station_assets.py --source upstream --target ulaanbaatar --rebuild-unified
```

The normalized Ulaanbaatar outputs are `ulaanbaatar_stations.tsv`,
`ulaanbaatar_routes.tsv`, `ulaanbaatar_route_stations.tsv`, and
`ulaanbaatar_transit.sqlite`. The TSV and SQLite tables contain current-state
fields only. English names supplied by UB Smart Bus are retained; missing or
Cyrillic English values receive deterministic MNS 5217:2012 romanization.

Shanghai CU terminal prefixes are included in both Chinese source and unified
databases under `cityunion_terminal_prefixes`. Of the 614 published mappings,
577 have unambiguous TU station links, also exposed through the separate
`cn.cityunion.terminal_prefix` namespace. The other 37 retain names and source
provenance without guessed coordinates. See the
[Shanghai review](../docs/shanghai-dual-application-review.md).
