# QUESTSCAN

Swift Playgrounds用の空間スキャン・3Dカラー編集アプリ。添付された開発計画をもとに、iOS 16以降で動作するSwift App Packageを実装しています。

## 開く

`QUESTSCAN.swiftpm` フォルダをフォルダ名ごと保持してiPadまたはMacへコピーし、Swift Playgroundsで開きます。ARスキャンは対応するiPad／iPhoneの実機で行います。Playgroundsの実行ターゲットはiOSです。

LiDAR対応端末ではARKitメッシュ、非LiDAR端末ではARKitの検出平面を使います。非LiDAR端末の平面スキャンは家具を含む完全な3D再構成ではありません。デモルームではカメラを使わず3D編集を試せます。

## 実装構成

`QUESTSCAN.swiftpm` にSwiftUI・ARKit・RealityKitのソースを格納します。撮影画像は端末内で処理し、観測面への写真投影、部分メッシュの色編集、端末内保存、USDZ書き出し・共有を行います。外部パッケージやクラウドAPIは使用しません。

現在の作業段階: 基盤・データモデルを追加。後続コミットでスキャン、編集、書き出し、検証と利用手順を追加します。

元の仕様は [Docs/OriginalSpecification.md](Docs/OriginalSpecification.md) です。最終的な検証範囲と実機確認項目もDocsへ記録します。
