# CardBal / TransitICReader

[English](README.md) | 简体中文 | [日本語](README.ja.md)

本文是 README.md 的中文译本，如有出入以英文版为准。链接的开发文档为英文。

适用于 iPhone 和 Android 的交通 IC 卡读卡器。应用通过 Core NFC、ISO-DEP 和 FeliCa
读取受支持卡片中的余额和记录；可读取的字段取决于卡种和手机。应用不提供写卡或充值功能。

## 仓库结构

| 目录 | 用途 |
| --- | --- |
| `ios/CardBal/` | SwiftUI 应用、Core NFC 读卡器、解码器和 iOS 运行时资源 |
| `CardBal.xcodeproj/` | 稳定的 Xcode 与 Xcode Cloud 工程入口 |
| `android/` | Android 应用、Gradle wrapper、NFC 读卡器和单元测试 |
| `tools/stations/` | 编译锁定版本的 CSV 并打包统一数据库 |
| `tools/boundaries/` | 地理目录维护 |
| `tools/maintenance/stations/` | 需显式运行的上游调研和导入工具 |
| `tools/ios/` | 归档、真机运行和日志辅助脚本 |
| `tests/` | Python 和生产 Swift 代码的回归测试 |
| `data/` | 目录版本锁定、地理输入和离线维护输入 |
| `services/station-reports/` | 站点报告 API 和审核界面 |
| `design/cards/` | 卡面原始素材和参考图 |
| `docs/` | 解码说明、数据署名、开发指南和调研 |

## 构建

编译两个应用共用的站点数据：

```sh
python3 -m tools.stations.build --source csv --target all
```

数据源是公开的 [iebb/card-stations](https://github.com/iebb/card-stations) CSV 目录，
由 `data/stations/card-stations.lock.json` 锁定版本。编译输出生成在 Git 忽略的
`build/stations/` 下，每个应用只接收自己需要的运行时文件。参见[站点数据](docs/data/station-assets.md)。

iPhone：用支持 Core NFC 的最新版 Xcode 打开 `CardBal.xcodeproj`。模拟器构建不需要
Firebase 配置：

```sh
xcodebuild -project CardBal.xcodeproj -scheme CardBal \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Android：安装 JDK 17 和 Android SDK 36，然后运行：

```sh
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

Android 构建会自动调用共用的目录编译器。发布签名使用本地私有设置或环境变量，仓库中
不包含任何签名材料。参见 [Android 设置](android/README.md)。

## 开发

- [测试与构建检查](docs/development/testing.md)
- [TestFlight、Play 内部测试和商店发布的手动工作流](docs/development/releases.md)
- [卡片解码](docs/decoding/cards.md)
- [更多卡种的可行性与平台限制](docs/research/card-support.md)
- [站点数据与署名](docs/data/station-assets.md)
- [站点报告服务](services/station-reports/README.md)

兼容命令 `python3 scripts/build_cross_platform_station_assets.py` 仍会转发给共用编译器。

## 站点数据来源

两个应用的车站、线路和路径数据都编译自公开的
[iebb/card-stations](https://github.com/iebb/card-stations) CSV 目录，版本锁定在
`data/stations/card-stations.lock.json`。如需更正，请附上来源，向该仓库提交 Pull Request。
该目录合并了以下数据：

| 数据 | 来源 | 许可 |
| --- | --- | --- |
| 日本车站、线路和铁路线形 | Seo-4d696b75 的 [station_database](https://github.com/Seo-4d696b75/station_database) | CC BY-SA 4.0 |
| 日本 FeliCa 车站代码和巴士公司代码 | CardBal 代码表 | 未记录上游授权 |
| 交通联合和上海 City Union 的车站、线路和闸机 | [读卡识途 / Trip Reader 数据](https://github.com/domosekai/tripreader-data)，Domosekai Limited 及贡献者 | CC BY 4.0 |
| 中国和韩国的坐标、名称和地图引用 | [OpenStreetMap 贡献者](https://www.openstreetmap.org/copyright) | ODbL 1.0 |
| 韩国车站代码和名称 | KORAIL KOTRIS、韩国国土交通部（MOLIT）、首尔特别市、釜山 BIMS、KRIC、大邱交通公社 | 各发布方条款；首尔市数据为 KOGL 第 1 类 |
| 韩国补充名称 | [Wikidata](https://www.wikidata.org/wiki/Wikidata:Licensing) | CC0 1.0 |
| 乌兰巴托站点和线路 | UB Smart Bus，Ulaanbaatar Smart Card LLC | 未记录许可 |

`data/boundaries/` 中的城市和省级轮廓来自 [geoBoundaries](https://www.geoboundaries.org)
（CC BY 4.0；Runfola 等，2020）、OpenStreetMap（ODbL 1.0）和
[Natural Earth](https://www.naturalearthdata.com)（公有领域）。每个 JSON 目录都记录了各国
图层的底层许可。`data/maintenance/` 中经过审核的输入来自 OpenStreetMap 和读卡识途。

按路径划分的许可和许可全文见
[card-stations/licenses](https://github.com/iebb/card-stations/blob/master/licenses/README.md)。
另请参阅[读卡识途数据来源](docs/data/tripreader.md)和 [UB Smart Bus 数据](docs/data/ub-smart-bus.md)。

## 许可

除另有许可声明的文件外，项目原创代码以 [BSD 3-Clause License](LICENSE) 发布。
Clipper 改编代码及上游测试样本保留 [GPL-3.0 或更新版本](docs/licenses/FareBot-GPL-3.0.txt)
许可；澳门通改编代码保留 [TU-Reader 的 MIT 声明](docs/licenses/TU-Reader-MIT.txt)。

车站、地图和边界数据沿用上文所列的上游许可，不适用 BSD 许可。随附的
`cardbal_transit.sqlite` 和 Android 站点数据改编自这些来源，保留其署名和相同方式共享条款。
Android 应用中的 Manrope 字体采用 [SIL Open Font License 1.1](android/third_party/Manrope-OFL.txt)。
卡面图案、卡片名称和标志归各发行方所有，不在 BSD 许可范围内。
