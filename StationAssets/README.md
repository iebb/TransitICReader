# CardBal Portable Station Assets

This directory is the platform-neutral source of truth for generated station data.
The iOS app consumes copies in `CardBal/Resources`, and the Android app consumes
copies in `android/app/src/main/assets`.

Build and sync the Japanese IC, China T-Union, Korean mode, and Ulaanbaatar
assets:

```sh
python3 scripts/build_cross_platform_station_assets.py --target all --skip-tunion-osm --offline-tunion-source
```

Run without `--skip-tunion-osm` when intentionally refreshing OpenStreetMap
matches. The default runtime format is SQLite plus JSON/CSV metadata because both
iOS and Android can consume those files directly.

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
