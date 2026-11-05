# QUESTSCAN 検証記録

2026年11月5日に、アプリのソース `fb525c22ba12909237230bc05834f0cf97de11f4` を検証しました。GitHub Actionsの [実行結果](https://github.com/akeyy1010/QUESTSCAN/actions/runs/41974412506) は **success** です。設定画面を含む最新ソースの検証です。

## Apple SDKの検証

macOS 14のGitHub Actionsランナーで、Xcode 15.4／Apple Swift 5.10を使用しました。iOS 16.0を最低ターゲットとして、設定画面を含む全SwiftソースをAppleのiPhoneOS SDKでコンパイルし、実行バイナリへのリンクまで成功しました。最終ログにはSwiftコンパイルのwarning／errorはありません。

`Package.swift` についても、Xcode内のAppleProductTypesモジュールを検出し、PackageDescription 5.7指定で型チェックが成功しました。AppInfo.plistとPrivacyInfo.xcprivacyの構文検証も成功しました。ただし、これはSwift Playgroundsアプリそのものを操作してパッケージを開いた試験ではありません。Playgroundsでの初回オープンと実行、利用者の署名設定は実機環境で確認が必要です。

## 自動テスト

書き出し・保存の統合テストは **1,751項目が合格**しました。追加テストでは撮影感度、枚数・形状・画像品質の上限、設定のUserDefaults永続化と復元を確認しています。CRC32の既知ベクトル、ZIPのローカルヘッダと中央ディレクトリ、64バイトアラインメント、ファイル名安全性、USD形状・UV・マテリアル接続、編集画像の反映、有限値と不正メッシュの拒否、JSONの原子的保存、UUID不一致、外部パス、シンボリックリンク、壊れたファイル、200MB上限も検査しています。

デモ形状・写真投影のテストでは、35部分・8,252三角形のデモルームについて、法線の長さ、外向きの頂点順序、縮退面の除外、JSON往復を検査しました。カメラの逆行列、移動・回転、JPEG縮小後も不変なUV、画像の上下、画角外と背後の除外、正常／不明／遮蔽深度、最適写真の選択、元法線保持、アンカー・分類境界、60,000面上限、512部分上限が合格しています。512部分のストレスケースで選択された768面が欠落しないことも確認しました。

タップ選択の三角形レイキャストでは、最も近い面の選択、空間の空振り、レイ背後の除外、ゼロ方向・非有限値の安全な拒否が合格しました。

## iPhone・iPadシミュレータ

iPhone 15 ProとiPad Pro 11-inch M4のシミュレータで、iOSアプリのインストール、ホーム・設定・デモルームの起動、スクリーンショット取得が成功しました。設定では感度、写真枚数、解像度、JPEG画質、形状上限、ワイヤーフレームを操作できる画面を目視確認しました。両端末でRealityKitのデモルームも描画されます。

実際に取得した画像は [iPhoneホーム](Screenshots/iphone-home.png)、[iPhone設定](Screenshots/iphone-settings.png)、[iPhoneデモ](Screenshots/iphone-demo.png)、[iPadホーム](Screenshots/ipad-home.png)、[iPad設定](Screenshots/ipad-settings.png)、[iPadデモ](Screenshots/ipad-demo.png) です。デザインモックアップではありません。

この起動試験は全ボタンの操作自動化ではありません。ドラッグ・ピンチ・ColorPicker・共有シート・保存後の再起動などの総合UI受け入れテストは、実機チェックリストで確認してください。シミュレータはAR非対応と正しく表示され、実カメラとLiDARを試したことにはなりません。

## USDZの独立検証

CIから取得した4つのUSDZを、アプリの実装とは別の標準ZIPライブラリとOpenUSD 26.11で検査しました。デモルーム、実JPEG付きの1三角形モデル、単色モデル、接続検証用の合成テクスチャモデルのすべてで、CRC、非圧縮、64バイトアラインメント、USDパース、メートル単位・Y-up、トポロジー、法線、マテリアルバインド、パッケージ内画像参照が成功しました。

実JPEG付きモデルの画像はPillowでもデコードし、100×80ピクセルの正常なRGB画像として読み込めることを確認しました。`textured-test.usdz` だけはAPI接続試験用の合成バイト列であり、写真のデコード成功として扱っていません。独立検証の機械可読結果は [OpenUSD.json](ValidationArtifacts/OpenUSD.json) です。

OpenUSDで読み込めることは、すべてのiOS版Quick Lookや他アプリで同じ表示になる保証ではありません。Quick Lookでの実写真テクスチャ、色、向き、共有後の表示は実機確認項目として残しています。

## 配布ZIP

`Dist/QUESTSCAN.swiftpm.zip` は、リポジトリの `QUESTSCAN.swiftpm` をそのままZIPへ格納したものです。21ファイルの全パスと内容がソースと一致し、ZIPのCRC検査も成功しました。内訳はSwiftファイル19個とプロパティリスト2個です。展開すると `QUESTSCAN.swiftpm` フォルダが得られます。

SHA-256は `be63d8f52ae44d3705d8062e3a25fd2e7b3c29fa0a48db5c65e7fc8739840ebc` です。[配布チェック結果](ValidationArtifacts/Package.json) と [チェックサム](../Dist/SHA256SUMS.txt) を添付しています。

## 実機で残る確認

実カメラ画像の取得と向き、LiDARメッシュの実空間一致、端末上の投影品質・遮蔽、セッション中断からの復帰、長時間利用の発熱・メモリ、iPadの共有シート、Quick Lookの最終表示、Swift Playgroundsでのパッケージ起動、Apple署名は未実施です。[実機テスト項目](DeviceTestChecklist.md) に整理しています。

これらが未実施のため、実機動作検証済み、計測精度保証、完全な家具自動分割、App Store提出完了とは表現しません。非LiDAR端末は平面スキャンであり、家具を含む完全な3D再構成ではありません。
