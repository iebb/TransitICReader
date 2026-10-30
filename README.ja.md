# CardBal / TransitICReader

[English](README.md) | [简体中文](README.zh-CN.md) | 日本語

このファイルは README.md の日本語訳です。内容に相違がある場合は英語版が優先されます。
リンク先の開発ドキュメントは英語です。

iPhone と Android 向けの交通系 IC カードリーダーです。Core NFC、ISO-DEP、FeliCa を通じて、
対応カードの残高と履歴を読み取ります。読み取れる項目はカードの種類と端末によって異なります。
カードへの書き込みやチャージの機能はありません。

## リポジトリ構成

| ディレクトリ | 内容 |
| --- | --- |
| `ios/CardBal/` | SwiftUI アプリ、Core NFC リーダー、デコーダー、iOS のランタイムリソース |
| `CardBal.xcodeproj/` | Xcode と Xcode Cloud の固定エントリポイント |
| `android/` | Android アプリ、Gradle wrapper、NFC リーダー、ユニットテスト |
| `tools/stations/` | リビジョン固定の CSV のコンパイルと統合データベースのパッケージング |
| `tools/boundaries/` | 地理カタログのメンテナンス |
| `tools/maintenance/stations/` | 明示的に実行する上流データの調査・取り込みツール |
| `tools/ios/` | アーカイブ、実機実行、ログ取得の補助スクリプト |
| `tests/` | Python と本番 Swift コードの回帰テスト |
| `data/` | カタログのリビジョン固定、地理入力、オフラインのメンテナンス入力 |
| `services/station-reports/` | 駅情報報告 API とレビュー画面 |
| `design/cards/` | カード券面の元素材と参考画像 |
| `docs/` | デコードの解説、データの出典表示、開発ガイド、調査 |

## ビルド

両アプリで共有する駅データをコンパイルします。

```sh
python3 -m tools.stations.build --source csv --target all
```

データソースは公開されている [iebb/card-stations](https://github.com/iebb/card-stations) の
CSV カタログで、`data/stations/card-stations.lock.json` でリビジョンを固定しています。
コンパイル結果は Git 管理外の `build/stations/` に生成され、各アプリには必要なランタイム
ファイルだけが配置されます。[駅データ](docs/data/station-assets.md)を参照してください。

iPhone 版は、Core NFC に対応した最新の Xcode で `CardBal.xcodeproj` を開きます。
シミュレーター向けのビルドに Firebase の設定は不要です。

```sh
xcodebuild -project CardBal.xcodeproj -scheme CardBal \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Android 版は、JDK 17 と Android SDK 36 をインストールしてから次を実行します。

```sh
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

Android のビルドは共通のカタログコンパイラーを自動で呼び出します。リリース署名には
ローカルの非公開設定または環境変数を使い、署名用の鍵などはリポジトリに含まれていません。
[Android のセットアップ](android/README.md)を参照してください。

## 開発

- [テストとビルドチェック](docs/development/testing.md)
- [TestFlight、Play 内部テスト、ストア公開の手動ワークフロー](docs/development/releases.md)
- [カードのデコード](docs/decoding/cards.md)
- [追加カードの実現可能性とプラットフォームの制約](docs/research/card-support.md)
- [駅データと出典表示](docs/data/station-assets.md)
- [駅情報報告サービス](services/station-reports/README.md)

互換用コマンド `python3 scripts/build_cross_platform_station_assets.py` も、引き続き共通
コンパイラーに処理を渡します。

## 駅データの出典

両アプリの駅・路線・経路データは、公開 CSV カタログ
[iebb/card-stations](https://github.com/iebb/card-stations) から、
`data/stations/card-stations.lock.json` で固定したリビジョンを使ってコンパイルしています。
修正は出典を添えて、同リポジトリへの Pull Request でお送りください。カタログには次の
データが含まれます。

| データ | 出典 | ライセンス |
| --- | --- | --- |
| 日本の駅・路線・線路形状 | Seo-4d696b75 氏の [station_database](https://github.com/Seo-4d696b75/station_database) | CC BY-SA 4.0 |
| 日本の FeliCa 駅コードとバス事業者コード | CardBal のコード表 | 上流の許諾は記録なし |
| 交通聯合（T-Union）と上海 City Union の駅・路線・改札 | [読卡識途 / Trip Reader データ](https://github.com/domosekai/tripreader-data)（Domosekai Limited と貢献者） | CC BY 4.0 |
| 中国と韓国の座標・名称・地図参照 | [OpenStreetMap 貢献者](https://www.openstreetmap.org/copyright) | ODbL 1.0 |
| 韓国の駅コードと名称 | KORAIL KOTRIS、韓国国土交通部（MOLIT）、ソウル特別市、釜山 BIMS、KRIC、大邱交通公社 | 各提供元の条件。ソウル市のデータは KOGL 第1類 |
| 韓国の補足名称 | [Wikidata](https://www.wikidata.org/wiki/Wikidata:Licensing) | CC0 1.0 |
| ウランバートルの停留所と路線 | UB Smart Bus（Ulaanbaatar Smart Card LLC） | ライセンスの記録なし |

`data/boundaries/` の市・省レベルの境界は [geoBoundaries](https://www.geoboundaries.org)
（CC BY 4.0、Runfola ほか 2020）、OpenStreetMap（ODbL 1.0）、
[Natural Earth](https://www.naturalearthdata.com)（パブリックドメイン）に基づきます。
各 JSON カタログには国ごとのレイヤーの元ライセンスが記録されています。
`data/maintenance/` のレビュー済み入力は OpenStreetMap と読卡識途に由来します。

パスごとのライセンスとライセンス全文は
[card-stations/licenses](https://github.com/iebb/card-stations/blob/master/licenses/README.md)
にあります。[読卡識途データの出所](docs/data/tripreader.md)と
[UB Smart Bus のデータ](docs/data/ub-smart-bus.md)も参照してください。

## ライセンス

個別のライセンス表記があるファイルを除き、プロジェクト独自のコードは
[BSD 3-Clause License](LICENSE) で公開しています。Clipper の移植コードと
上流テストデータには [GPL-3.0 以降](docs/licenses/FareBot-GPL-3.0.txt)、
Macau Pass の移植コードには [TU-Reader の MIT 表記](docs/licenses/TU-Reader-MIT.txt) が適用されます。

駅・地図・境界データには上記の上流ライセンスが適用され、BSD ライセンスの対象外です。
同梱の `cardbal_transit.sqlite` と Android の駅データはこれらの出典を改変したもので、
各出典の表示義務と継承条件を引き継ぎます。Android アプリの Manrope フォントは
[SIL Open Font License 1.1](android/third_party/Manrope-OFL.txt) で提供されています。
カード券面の画像、カード名、ロゴは各発行元に帰属し、BSD ライセンスの対象外です。
