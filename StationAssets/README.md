# CardBal Portable Station Assets

This directory is the platform-neutral source of truth for generated station data.
The iOS app consumes copies in `CardBal/Resources`, and the Android app consumes
copies in `android/app/src/main/assets`.

Build and sync both Japanese IC and China T-Union assets:

```sh
python3 scripts/build_cross_platform_station_assets.py --target all --skip-tunion-osm --offline-tunion-source
```

Run without `--skip-tunion-osm` when intentionally refreshing OpenStreetMap
matches. The default runtime format is SQLite plus JSON/CSV metadata because both
iOS and Android can consume those files directly.
