# Chinese station reports: 2026-11-01

Read-only review covered 21 pending reports. Report statuses were not changed.
This note records aggregate findings and lookup keys only, without private
card/device identifiers, raw histories, report notes or location pins.

## Applied changes

| Area | Evidence and outcome |
| --- | --- |
| Shenzhen | The same TU station-field key was reported for 后瑞 / Line 1 and 岗厦 / Line 10. Its earlier 后瑞 alias is removed. Terminal-based lookup replaces it on iOS and Android. |
| Shenzhen terminals | 284 station-level prefixes from public Trip Reader `Guangdong/Shenzhen/cu.csv`; 30 line/operator prefixes excluded. Retain names and lines, without invented map coordinates or TU station links. |
| Hong Kong | The observed TU city `0344` displays 香港 and resolves to the existing `9101` boundary. Station-level identity remains unresolved. |
| Shanghai | CU `2000` is 上海市; TU Shanghai is `2900`. Existing station and boundary mappings remain. Android now uses 上海市 in the card title, region and unresolved transaction location. |
| Chengdu | Keep the two previously verified exact aliases for 西南交大 and 春熙路. |

The catalog has 5,715 TU station keys, 4,662 exact TU terminal mappings,
614 Shanghai CU prefixes, and 284 Shenzhen CU prefixes. Prefixes are
additional identifiers, not additional physical station positions.

## Shenzhen format and source

[Trip Reader's Shenzhen README](https://github.com/domosekai/tripreader-data/blob/c5584d6b8d9a39d7162b7b9781134be52db66186/Guangdong/Shenzhen/README.md)
specifies CU file `18` terminals and TU file `1E` terminals in the same format.
The [public CSV](https://github.com/domosekai/tripreader-data/blob/c5584d6b8d9a39d7162b7b9781134be52db66186/Guangdong/Shenzhen/cu.csv)
uses CU city `5180`, distinct from TU city `5840`. Examples:

| Prefix | Station | Line |
| --- | --- | --- |
| `518068035` | 后瑞 | 1号线 |
| `518068007` | 岗厦 | 1号线 |
| `518040013` | 岗厦 | 10号线 |
| `518068008` | 会展中心 | 1号线 |

Trip Reader 1.7.17 provides format evidence: in TU travel records for city
`5840`, terminal prefix `00000002` selects the CU-style lookup, using `5180`
plus the terminal's final four bytes. CardBal implements the rule independently
and only uses the public CSV's station-level prefixes. The APK contributes no
new station data or copied code.

Unknown Shenzhen trips preserve the eight-byte terminal in their report key
(`TU:5840:1E:<terminal>`). They no longer repeat the seven-byte field that
caused conflicting reports. Known name-only prefixes have no physical map key.
The local Shenzhen Tong reader's history remains separate from this TU/CU
terminal lookup.

CSV attribution: Domosekai Limited and Trip Reader data contributors,
CC BY 4.0, revision `c5584d6b8d9a39d7162b7b9781134be52db66186`.
`cu.csv` SHA-256:
`2cd1e70674ebf94cad8de3db6016da134afd71fe8bcd6d964556cfaff684fa98`.

## Hong Kong and deferred reports

The [UN M49 registry](https://unstats.un.org/unsd/methodology/m49/overview/)
identifies Hong Kong with numeric code `344`. The observed travel city field
`0344` is treated as an alias, without changing the existing TU registry.
[Chongqing's government notice of 31 March 2025](https://cq.gov.cn/ywdt/bmts/202503/t20250331_14468183.html)
confirms MTR acceptance of T-Union cards from 22 March 2025. The reported
station name 铜锣湾 does not establish how the seven-byte MTR field is encoded.
No station alias is added.

Two Xiamen reports for 马青路 / Line 2 lack codes; the catalog already has
`39300209` for that name. City Union-family reports for Chengdu and Ningbo
also lack lookup codes. Name matches alone cannot resolve an unknown record
format, so these reports remain deferred.

## Local source and validation

The CSV edits were published on 2026-11-02 in `iebb/card-stations` commit
`a8e923c85ab61135640ae7a13d52055cbe578c67`. CardBal pins that commit; normal
Xcode and Gradle builds include the reviewed data as shown in
[the data documentation](../data/tripreader.md#chinese-station-report-review-2026-11-01).

The CSV compiler validates city-specific prefix lengths and rejects cross-city
station links. Its tests cover the retracted alias and all 284 Shenzhen rows.
The Swift production resolver/decoder harness checks conflicting station
fields, correct terminal discrimination, unknown terminals, wrong cities, CU
Shanghai naming and the historical-date guard. Android has synthetic metadata
and terminal-discriminator tests. Generated assets retain source-row parity,
SQLite integrity and foreign-key checks.
