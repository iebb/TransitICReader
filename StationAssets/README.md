# CardBal Portable Station Assets

This directory is the platform-neutral source of truth for generated station data.
The iOS app consumes copies in `CardBal/Resources`. Country-specific legacy
assets can also be synchronized to an Android checkout, but the unified CardBal
database is an iOS/portable asset only.

Build and sync the Japanese IC, China T-Union, Korean mode, Ulaanbaatar, and
the unified CardBal transit database:

```sh
python3 scripts/build_cross_platform_station_assets.py --target all --skip-tunion-osm --offline-tunion-source
```

Run without `--skip-tunion-osm` when intentionally refreshing OpenStreetMap
matches. Country-specific SQLite and JSON/CSV assets remain as generator inputs
and for legacy Android consumers; the CardBal iOS target bundles only the
unified SQLite database.

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
when `--rebuild-unified` is specified. The weekly UB Smart Bus workflow uses
this option so iOS receives refreshed stops.

Refresh only the Ulaanbaatar bus snapshot from the service used by
`com.uscc.ubbus`:

```sh
python3 scripts/build_cross_platform_station_assets.py --target ulaanbaatar --rebuild-unified
```

The normalized Ulaanbaatar outputs are `ulaanbaatar_stations.tsv`,
`ulaanbaatar_routes.tsv`, `ulaanbaatar_route_stations.tsv`, and
`ulaanbaatar_transit.sqlite`. The TSV and SQLite tables contain current-state
fields only. English names supplied by UB Smart Bus are retained; missing or
Cyrillic English values receive deterministic MNS 5217:2012 romanization.
