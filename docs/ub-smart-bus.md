# UB Smart Bus data

CardBal's Ulaanbaatar snapshot is generated from the service used by the
official Android application `com.uscc.ubbus`, published by Ulaanbaatar Smart
Card LLC. Google Play describes the app as providing routes, route structure,
nearby stops, and live arrivals. The inspected APK is version `3.25.0804`
(SHA-256 `159b7819fa488bdb9e5de01f7ac7b96035fc741d70a4172c72cb38851ac116b4`).

The application talks to `app.uscc.mn:63002` using a binary TCP protocol. Each
packet has a 7-byte little-endian header, a body, a CRC16/MODBUS value, and an
ETX byte. Static data comes from these request/response pairs:

| Request | Response | Data |
| --- | --- | --- |
| `05/09` | `05/10` | route or station search |
| `05/13` | `05/14` | ordered stations for a route |

Language `0` returns Mongolian and language `1` returns English. An empty
station search exposes only 255 rows because its total and starting position
are unsigned bytes. The downloader therefore enumerates every route, fetches
every route's full stop sequence, and unions those stops with station-search
results. The current snapshot has 139 routes, 1,499 unique stations, and 4,925
route-station rows.

Run:

```sh
python3 scripts/build_cross_platform_station_assets.py --target ulaanbaatar
```

The downloader validates non-zero response CRCs, pagination totals,
Mongolian/English ID alignment, foreign keys, and SQLite integrity. Production
responses currently send a zero response CRC, matching the official client's
behavior. Output rows do not contain collection or matching metadata.

The service's English catalog is incomplete for some newer station IDs. Those
values use deterministic MNS 5217:2012 Cyrillic-to-Latin transliteration at
generation time. Route and station IDs remain the service's integer IDs.

The U-money transaction layout uses a seven-digit BCD station field, while the
current catalog includes eight- and nine-digit station IDs. No card-to-catalog
ID transformation is asserted until it can be verified against real U-money
card records.

References:

- [UB Smart Bus on Google Play](https://play.google.com/store/apps/details?id=com.uscc.ubbus)
- [Archived APK metadata](https://apkpure.net/ub-smart-bus/com.uscc.ubbus)
- [Tmoney's Ulaanbaatar system overview](https://eng.tmoney.co.kr/en/aeb/global/oNm/oNmUlnMng.dev)
- [MNS 5217:2012 transliteration table](https://en.wiktionary.org/wiki/Wiktionary:Mongolian_transliteration)
