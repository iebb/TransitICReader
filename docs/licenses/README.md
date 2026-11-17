# Licences and credits

## Application code

Original project code is available under the [BSD 3-Clause License](../../LICENSE),
except files with their own licence notices.

Clipper format adaptations from FareBot/Metrodroid and the upstream fixture
retain [GPL-3.0-or-later](FareBot-GPL-3.0.txt) terms. Source attribution and
format details are recorded in [Clipper decoding](../decoding/clipper.md).
Macau Pass adaptations retain [TU-Reader's MIT notice](TU-Reader-MIT.txt);
see [Macau Pass decoding](../decoding/macau-pass.md).

## Station and map data

Both apps compile station, line and route data from the public
[iebb/card-stations](https://github.com/iebb/card-stations) CSV catalog, at the
revision pinned in `data/stations/card-stations.lock.json`. Send corrections
there as pull requests with a source.

| Data | Source | Licence |
| --- | --- | --- |
| Japanese stations, lines and rail geometry | [station_database](https://github.com/Seo-4d696b75/station_database) by Seo-4d696b75 | CC BY-SA 4.0 |
| Japanese FeliCa station and bus codes | CardBal code registries | No upstream grant recorded |
| T-Union and Shanghai City Union stations, lines and gates | [Trip Reader / 读卡识途 data](https://github.com/domosekai/tripreader-data), Domosekai Limited and contributors | CC BY 4.0 |
| China and Korea coordinates, names and map references | [OpenStreetMap contributors](https://www.openstreetmap.org/copyright) | ODbL 1.0 |
| Korean station codes and names | KORAIL KOTRIS, MOLIT, Seoul Metropolitan Government, Busan BIMS, KRIC and Daegu Transportation Corporation | Publisher terms; Seoul data is KOGL Type 1 |
| Supplementary Korean names | [Wikidata](https://www.wikidata.org/wiki/Wikidata:Licensing) | CC0 1.0 |
| Ulaanbaatar stops and routes | UB Smart Bus, Ulaanbaatar Smart Card LLC | No licence recorded |

City and province outlines in `data/boundaries/` come from
[geoBoundaries](https://www.geoboundaries.org) (CC BY 4.0; Runfola et al. 2020),
OpenStreetMap (ODbL 1.0) and [Natural Earth](https://www.naturalearthdata.com)
(public domain). Each JSON catalog records the underlying licence of every
country layer. Inputs in `data/maintenance/` come from OpenStreetMap and
Trip Reader.

Singapore station names and map data retain LTA attribution and the
Singapore Open Data Licence, as described in
[Singapore stations and maps](../development/external-nfc-readers.md#singapore-stations-and-maps).

Station, map and boundary data keep their source licences; the BSD licence
does not apply to them. The bundled `cardbal_transit.sqlite` and Android
station assets retain the sources' attribution and share-alike terms.

Per-path licences and full texts are in
[card-stations/licenses](https://github.com/iebb/card-stations/blob/master/licenses/README.md).
See also [station data](../data/station-assets.md),
[Trip Reader provenance](../data/tripreader.md) and
[UB Smart Bus data](../data/ub-smart-bus.md).

## Fonts and artwork

The Android app's Manrope font is licensed under the
[SIL Open Font License 1.1](../../android/third_party/Manrope-OFL.txt).
Card artwork, names and logos belong to their issuers and are not covered
by the BSD licence. Artwork references and preparation details are in
the [card-face guide](../design/card-faces.md),
[EZ-Link artwork](../design/ezlink-artwork.md) and
[OKICA artwork](../design/okica-card-face.md).
