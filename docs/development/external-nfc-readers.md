# External NFC readers and Singapore integration

**iPad and macOS require a compatible external NFC card reader.** iPhone can
choose built-in NFC or an external USB CCID reader in the scan screen.

The USB path uses public CryptoTokenKit APIs. Apple documents CCID support from
iOS 16 and iPadOS 16.1; ACS lists ACR122U as CCID compliant. Actual iPhone/iPad
compatibility still depends on the unit, adapter, OS driver and available power;
a powered hub may be necessary. Those physical configurations remain untested.
Mac Catalyst with the connected ACR122U has been physically verified with Edy
and an EZ-Link CEPAS v2 card, plus a local 天府通 CPU card. The latter uses its
own application and cash/top-up files; see the [Trip Reader comparison](../decoding/tianfutong.md).
Native iPhone CEPAS discovery remains supported
where Core NFC exposes the implicit application through ISO 7816 or MIFARE.
SimplyGo backend account balances are outside this local reader.

- [Apple smart-card support](https://support.apple.com/guide/deployment/use-a-smart-card-on-iphone-and-ipad-dep8b8c8927a/web)
- [Apple CryptoTokenKit](https://developer.apple.com/documentation/cryptotokenkit/tksmartcard)
- [ACS ACR122U API manual](https://www.acs.com.hk/download-manual/419/API-ACR122U-2.04.pdf)

## Reader interaction

On iPhone, the segmented control explicitly selects **iPhone NFC** or
**External Reader**. The choice is saved. Plugging in a reader does not switch
sources or begin a scan. iPad and Mac always use external readers and display
that requirement even when the welcome panel is hidden.

Scan is disabled until the chosen source is available. With multiple external
readers, Automatic chooses a stable sorted reader name; an explicitly selected
reader that disconnects never silently falls back to a different device.
Source/reader controls are disabled during a scan. External cancellation stops
publication of the result and closes the session once the current system
command completes or times out. Launch scanning still respects its preference.

`CardTransport` separates decoder commands from hardware. The Core NFC adapter
preserves native ISO 7816, MIFARE and FeliCa behavior. The ACR122U adapter sends
its documented PN532 Direct Transmit commands only to ACR122 readers. FeliCa
polling returns PMm and request data, matching Core NFC; IDm is a separate
property. ISO cards are not repolled as FeliCa. Each external session resets
card application state before probing the implicit CEPAS purse.

Other CCID readers can exchange ISO APDUs. FeliCa requires a compatible
reader-specific adapter. ACR122U has no ISO 15693 support. The external path
returns the first readable interface; select ISO 14443 explicitly for the
mainland interface of a dual-mode Octopus card. Native dual-interface scanning
retains its existing behavior.

## Singapore stations and maps

`data/stations/SingaporeTransit.json` is a 28 KB offline sidecar with 181 station
groups, 213 public platform/line codes and 166 CEPAS aliases. It is bundled
directly; application builds do not fetch LTA. Names and Chinese translations
come from LTA's January 2025 names workbook. Coordinates are representative
centroids of the September 2026 station footprints, transformed from SVY21 to
WGS84. Interchange platform codes are grouped by official station name. The
country outline is Natural Earth's public-domain 1:10m Singapore geometry.

The classic CEPAS alias table is incomplete for newer network extensions.
Unknown aliases remain visible as raw codes and are not guessed. Known MRT
station pairs receive names and namespaced `SG:` identifiers. The trip map
shows their endpoints and connecting segments; these segments do not claim to
be an exact travelled rail alignment. Activation, retail and top-up metadata
never become station evidence. The atlas counts proven Singapore rail records
against the Singapore city-state boundary at either overview level.

| Card alias | Public code | Station |
| --- | --- | --- |
| PMN | CC4 | Promenade / 宝门廊 |
| NTD | DT11 | Newton / 纽顿 |
| NEW | NS21 | Newton / 纽顿 |
| CTH | EW13 | City Hall / 政府大厦 |

The atlas's country options, outlines and extents are limited to countries
represented by saved card applications. A saved card with no history still
makes its country available; it does not fabricate a visit. Deleting the last
matching card removes that country and resets an unavailable selection to All.
The default card title is **EZLink**, including legacy `EZ-Link (CEPAS)` records.
Custom user titles remain authoritative.

Refresh explicitly using `tools/stations/build_singapore_transit.py` with the
four downloaded inputs. It needs `xlrd`, `pyshp` and `pyproj`. Source URLs and
SHA-256 hashes are retained in the sidecar. The current LTA footprint format is
polygonal and some `STN_NAM` fields contain multiple codes separated by `/`;
the importer handles these instead of assuming the old point schema.

- [LTA static datasets](https://datamall.lta.gov.sg/content/datamall/en/static-data.html)
- [LTA names workbook](https://datamall.lta.gov.sg/content/dam/datamall/datasets/Geospatial/Train%20Station%20Codes%20and%20Chinese%20Names.zip)
- [LTA station footprints](https://datamall.lta.gov.sg/content/dam/datamall/datasets/Geospatial/TrainStation_Sep2026.zip)
- [CEPAS alias reference](https://github.com/metrodroid/metrodroid/blob/master/data/ezlink/mapping.csv)
- [Singapore Open Data Licence](https://datamall.lta.gov.sg/content/datamall/en/SingaporeOpenDataLicence.html)

The app's Credits contains the LTA attribution and licence link. The alias
mapping is factual data; upstream decoder source code was not copied.

## Verification

The physical EZ-Link card produced its stored-value balance and four history
records: two MRT fares, a top-up and an activation event. Activation record
amount bytes are metadata, not money. Both activation types are represented as
zero-charge events and covered by synthetic regressions. Existing 16-byte
local CEPAS records remain readable alongside the newer tagged history format,
and the two encodings deduplicate during rescans.

The application uses Apple's `NumberFormatter` for SGD without overriding its
symbol. With the tested English/Japan locale it produces `SGD`; English/Singapore
produces `$`. An always-`S$` style would require an explicit override.

Raw customer captures and card identifiers are not repository fixtures. Tests
exercise synthetic reader framing, status and malformed replies, explicit
reader selection, station resolution, legacy history migration and wallet
country visibility, alongside the existing decoder regression suite.
