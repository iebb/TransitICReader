# Geographic inputs

These four finalized JSON catalogs are the single build-time copy of city and
province geometry plus participation/coverage rules. The unified SQLite builder
uses them; neither app bundles these source JSON files directly.

Maintenance modules are `tools.boundaries.cities`, `tools.boundaries.provinces`,
and `tools.boundaries.optimize`. Their optional dependencies and reviewed China
relation manifest live with those tools. Existing source/attribution fields in
the JSON catalogs remain authoritative.
