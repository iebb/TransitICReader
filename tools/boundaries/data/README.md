# Reviewed China boundary relations

`china_tunion_osm_relations.json` maps the 368 peer-level T-Union city registry
entries to reviewed OSM administrative relation IDs. The boundary generator uses
these exact identities instead of bulk-geocoding names. The source registry is
generated into `build/stations/TUnionCityCodes.json` from the pinned CSV catalog.

Coverage aliases and province-only cases are maintained in
`data/boundaries/ChinaTransitCoverage.json`. Source attribution and hashes remain
in the manifest and finalized catalogs.
