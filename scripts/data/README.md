# China city-boundary sources

`china_tunion_osm_relations.json` is CardBal's reviewed mapping from all 368
peer-level entries in `CardBal/Resources/TUnionCityCodes.json` to unique
OpenStreetMap administrative relations. Macau relation `1867188` is included separately as a
reference boundary because the bundled registry has no Macau transaction code.
Taiwan is outside CardBal's scope.

The source catalog retains those 368 exact registry relations for decoder and
geometry reproducibility. `ChinaTransitCoverage.json` filters the visible City
layer to the 352 exact boundaries in the pinned current T-Union participation
list, plus reference-only Macau. Hong Kong code `9101` remains included. The
participation source lock records Wikipedia revision `93532381` and its fetched
HTML SHA-256; 16 registry-only or non-independent boundaries stay hidden.

The China coverage catalog additionally maps 53 local or historical issuer
codes to their non-stacked parent City boundary. Nine province-wide,
historical multi-city, or composite codes resolve at Province level only,
rather than inventing a City.

The manifest is derived from OpenStreetMap data and is available under the
[ODbL 1.0](https://www.openstreetmap.org/copyright). Its source section records
the SHA-256 of the reviewed Overpass relation-tag snapshot. Geometry is resolved
through Nominatim's lookup endpoint by exact relation ID, never by fuzzy search.

Before output, every Chinese geometry is intersected with Natural Earth's pinned
1:10m land layer. Natural Earth data is [public domain](https://www.naturalearthdata.com/about/terms-of-use/).
The generator verifies both the manifest and land-layer SHA-256 values.
