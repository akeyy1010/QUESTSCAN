# QUESTSCAN 検証記録

2026年11月5日、1,000枚上限変更の**前**のソース `fb525c22ba12909237230bc05834f0cf97de11f4` で検証し、GitHub Actionsの [実行結果](https://github.com/akeyy1010/QUESTSCAN/actions/runs/41974412506) は **success** でした。2026年11月6日に1,000枚上限と適応メモリ制限を加えた `49ee6afc7351311d4bc4a636bd15d656855cb045` をpushしましたが、push runとworkflow_dispatchの両方が最初のstep開始前にGitHub側から `cancelled` となりました（[push run](https://github.com/akeyy1010/QUESTSCAN/actions/runs/42131680722)、[workflow_dispatch run](https://github.com/akeyy1010/QUESTSCAN/actions/runs/42131903654)）。そのため、この最新版のApple SDKビルド・新規テスト・シミュレータ試験は**未確認**です。既知のコンパイル成功を最新版の合格として扱っていません。

## Apple SDKの検証

直前版 (`fb525c2`) はmacOS 14のGitHub Actionsランナーで、Xcode 15.4／Apple Swift 5.10を使用してiOS 16.0向けにコンパイル・リンクし、warning／errorなしで成功しました。最新版 (`49ee6af`) に対するCIは2回とも最初のステップ前にキャンセルされ、同じビルドを実行できていません。

`Package.swift` についても、Xcode内のAppleProductTypesモジュールを検出し、PackageDescription 5.7指定で型チェックが成功しました。AppInfo.plistとPrivacyInfo.xcprivacyの構文検証も成功しました。ただし、これはSwift Playgroundsアプリそのものを操作してパッケージを開いた試験ではありません。Playgroundsでの初回オープンと実行、利用者の署名設定は実機環境で確認が必要です。

## 自動テスト

直前版で書き出し・保存の統合テスト **1,751項目が合格**しました。1,000枚変更には旧32枚設定の移行と1000枚上限の回帰テストを新たに追加しましたが、最新版ではCIが開始前にキャンセルされたため未実行です。前回合格分には撮影感度・設定永続化のほか、CRC32、ZIP、USD形状・UV・マテリアル、安全な原子的保存、シンボリックリンク、壊れたファイル、200MB上限が含まれます。

デモ形状・写真投影のテストでは、35部分・8,252三角形のデモルームについて、法線の長さ、外向きの頂点順序、縮退面の除外、JSON往復を検査しました。カメラの逆行列、移動・回転、JPEG縮小後も不変なUV、画像の上下、画角外と背後の除外、正常／不明／遮蔽深度、最適写真の選択、元法線保持、アンカー・分類境界、60,000面上限、512部分上限が合格しています。512部分のストレスケースで選択された768面が欠落しないことも確認しました。

タップ選択の三角形レイキャストでは、最も近い面の選択、空間の空振り、レイ背後の除外、ゼロ方向・非有限値の安全な拒否が合格しました。

## iPhone・iPadシミュレータ

iPhone 15 ProとiPad Pro 11-inch M4では直前版でホーム・設定・デモルーム起動を確認しました。ただし保存済みの設定画面スクリーンショットは既定32枚の旧画面です。新しい1,000枚メニューを含む画面確認はCIが開始前にキャンセルされたため未実施であり、下記の旧画像を最新版の証拠として扱わないでください。

直前版で取得した画像は [iPhoneホーム](Screenshots/iphone-home.png)、[iPhone設定（旧上限）](Screenshots/iphone-settings.png)、[iPhoneデモ](Screenshots/iphone-demo.png)、[iPadホーム](Screenshots/ipad-home.png)、[iPad設定（旧上限）](Screenshots/ipad-settings.png)、[iPadデモ](Screenshots/ipad-demo.png) です。デザインモックアップではありませんが、設定スクリーンショットの枚数上限表示は旧版です。

この起動試験は全ボタンの操作自動化ではありません。ドラッグ・ピンチ・ColorPicker・共有シート・保存後の再起動などの総合UI受け入れテストは、実機チェックリストで確認してください。シミュレータはAR非対応と正しく表示され、実カメラとLiDARを試したことにはなりません。

## USDZの独立検証

CIから取得した4つのUSDZを、アプリの実装とは別の標準ZIPライブラリとOpenUSD 26.11で検査しました。デモルーム、実JPEG付きの1三角形モデル、単色モデル、接続検証用の合成テクスチャモデルのすべてで、CRC、非圧縮、64バイトアラインメント、USDパース、メートル単位・Y-up、トポロジー、法線、マテリアルバインド、パッケージ内画像参照が成功しました。

実JPEG付きモデルの画像はPillowでもデコードし、100×80ピクセルの正常なRGB画像として読み込めることを確認しました。`textured-test.usdz` だけはAPI接続試験用の合成バイト列であり、写真のデコード成功として扱っていません。独立検証の機械可読結果は [OpenUSD.json](ValidationArtifacts/OpenUSD.json) です。

OpenUSDで読み込めることは、すべてのiOS版Quick Lookや他アプリで同じ表示になる保証ではありません。Quick Lookでの実写真テクスチャ、色、向き、共有後の表示は実機確認項目として残しています。

## 配布ZIP

`Dist/QUESTSCAN.swiftpm.zip` は、リポジトリの `QUESTSCAN.swiftpm` をそのままZIPへ格納したものです。21ファイルの全パスと内容がソースと一致し、ZIPのCRC検査も成功しました。内訳はSwiftファイル19個とプロパティリスト2個です。展開すると `QUESTSCAN.swiftpm` フォルダが得られます。1000枚モードの画像・深度縮小と最大128枚投影も含みます。

SHA-256は `606f8891f9b864a553e3fbdef0361b7f6588e54d4dd29dd18f17c827de362406` です。[配布チェック結果](ValidationArtifacts/Package.json) と [チェックサム](../Dist/SHA256SUMS.txt) を添付しています。これはZIP構造とソース一致の検査であり、未完了のApple SDKビルド・端末画面試験の代替ではありません。

## 実機で残る確認

実カメラ画像の取得と向き、LiDARメッシュの実空間一致、端末上の投影品質・遮蔽、セッション中断からの復帰、長時間利用の発熱・メモリ、iPadの共有シート、Quick Lookの最終表示、Swift Playgroundsでのパッケージ起動、Apple署名は未実施です。[実機テスト項目](DeviceTestChecklist.md) に整理しています。

これらが未実施のため、実機動作検証済み、計測精度保証、完全な家具自動分割、App Store提出完了とは表現しません。非LiDAR端末は平面スキャンであり、家具を含む完全な3D再構成ではありません。
