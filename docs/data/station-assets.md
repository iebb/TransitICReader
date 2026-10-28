# Station data

The authoritative contribution database is
[iebb/card-stations](https://github.com/iebb/card-stations). Its normalized CSVs
contain codes, names, lines, coordinates, and real OSM references. Japanese IC
uses a shared station catalog, T-Union uses city files, Korean cards use company
or mode files, and U-money uses city files. Korean transport modes are separate.

`data/stations/card-stations.lock.json` selects one full Git commit. Update it
after merging a data contribution, then compile the data and review the bundled
iOS database change:

```sh
python3 -m tools.stations.build --source csv --target all
# Test a local contribution explicitly:
python3 -m tools.stations.build --target all --csv-source ../card-stations
```

The default compiler fetches or reuses the exact clean checkout under ignored
`.external/card-stations`. An explicit `--csv-source` or
`CARDBAL_STATIONS_SOURCE` permits local contribution testing without changing the
pin. Normal builds do not call upstream station services.

## Inputs and outputs

- `data/boundaries/` is the single copy of finalized city/province boundaries and
  transit-coverage rules used by the unified database builder.
- `data/maintenance/` holds the reviewed historical T-Union inputs used only by
  explicit upstream maintenance. They are not runtime app resources.
- `build/stations/` contains ignored compiler outputs, provenance/checksum
  manifests, country databases and the unified database.
- `ios/CardBal/Resources/` holds the iOS runtime SQLite database and the small
  CSV/JSON registries still read directly by the production decoders.
- Android generates exactly its four data payloads plus its own filtered
  manifest under `android/app/build/generated/`; these files are not committed.

The obsolete Japanese JSON lookup, the old 820-entry Korean alias snapshot,
duplicate geographic inputs, and duplicate portable databases are retired.
Generated compatibility files are projected to the consumers that use them.
The manifests exclude stale unrelated files in an output directory.

The unified SQLite catalog stores stations, exact lookup keys, lines, graph
edges, supported city/province boundaries and source attribution. It retains the
pinned CSV revision. Japanese rail drawing decodes detailed prefix-compressed
geohash vertices; edges without verified geometry use station segments.

## Maintenance and attribution

The explicit import tools under `tools/maintenance/stations/` remain available for
research against their original sources. Use `--source upstream` only for a
maintenance import; review/import the result into card-stations before adopting
it in the app. The normal application build uses the CSV catalog.

[Trip Reader provenance](tripreader.md), [UB Smart Bus](ub-smart-bus.md), and
[card-stations source terms](https://github.com/iebb/card-stations/blob/master/DATA_SOURCES.md)
retain the source-specific attribution. OSM-derived data is subject to ODbL;
Japanese station_database data retains its source terms. The app repository does
not relicense those inputs or bundle private card histories.
