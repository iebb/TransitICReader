# CardBal Portable Station Assets

This directory is the platform-neutral source of truth for generated station data.
The iOS app consumes copies in `CardBal/Resources`. Country-specific legacy
assets can also be synchronized to an Android checkout, but the unified CardBal
catalogs are iOS/portable assets only.

Build and sync the Japanese IC, China T-Union, Korean mode, Ulaanbaatar, and
three unified CardBal databases:

```sh
python3 scripts/build_cross_platform_station_assets.py --target all --skip-tunion-osm --offline-tunion-source
```

Run without `--skip-tunion-osm` when intentionally refreshing OpenStreetMap
matches. Country-specific assets remain SQLite plus JSON/CSV metadata for their
existing platform consumers.

An `all` build creates these normalized cross-country catalogs after the source
databases are ready:

- `cardbal_stations.sqlite` — stations, resolver identifiers, lines, and edges.
- `cardbal_cities.sqlite` — supported city boundaries and visit-evidence keys.
- `cardbal_provinces.sqlite` — province boundaries and province-only evidence.

The packager combines the freshly generated station databases in this directory
with the finalized boundary, coverage, and Korean station resources in
`CardBal/Resources`. It validates station → city → province references across
all three SQLite files before replacing them. These unified files are copied to
CardBal iOS and are deliberately excluded from Android synchronization.

Refresh only the Ulaanbaatar bus snapshot from the service used by
`com.uscc.ubbus`:

```sh
python3 scripts/build_cross_platform_station_assets.py --target ulaanbaatar
```

The normalized Ulaanbaatar outputs are `ulaanbaatar_stations.tsv`,
`ulaanbaatar_routes.tsv`, `ulaanbaatar_route_stations.tsv`, and
`ulaanbaatar_transit.sqlite`. The TSV and SQLite tables contain current-state
fields only. English names supplied by UB Smart Bus are retained; missing or
Cyrillic English values receive deterministic MNS 5217:2012 romanization.
