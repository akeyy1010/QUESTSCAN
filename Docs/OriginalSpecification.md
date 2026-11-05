# Swift Playgrounds 空間スキャン＆3Dカラーアプリ 開発計画書

## 1. 開発環境・プロジェクト概要

* **開発環境:** Swift Playgrounds 4.x (iPadOS / macOS)
* **フレームワーク:** SwiftUI, ARKit, RealityKit, Metal (必要に応じて)
* **アプリ種別:** Swift App Package (`.swiftpm`)
* **ターゲット端末:** LiDAR搭載/非搭載のiPad / iPhone (iOS 16.0 以降推奨)

---

## 2. システム構成・技術選定 (Swift Native)

Swift Playgroundsで動作させるため、iOS標準のフレームワークをフル活用します。

| 機能 | 使用技術・API | 内容 |
| :--- | :--- | :--- |
| **画面・UI** | SwiftUI | 近未来風サイバーUI、プログレスバー、撮影ガイド |
| **空間スキャン** | ARKit (`ARMeshAnchor`) | 3Dメッシュ生成、壁・床・オブジェクトの認識 |
| **3D描画・プレビュー** | RealityKit (`ARView`) | ワイヤーフレーム表示、3Dルームの360度レンダリング |
| **テクスチャ合成** | RealityKit / Core Image | 撮影写真の割り当て、明るさ・コントラストの画像処理 |
| **データ書き出し** | ModelIO / Foundation | `.usdz` フォーマットでの保存・エクスポート |

---

## 3. 実装機能ステップ

### Phase 1: 空間認識とメッシュ表示
* `ARView` を配置し、`ARWorldTrackingConfiguration` を設定。
* `sceneReconstruction = .mesh` を有効化して、空間にサイバー風（ネオンカラー）のワイヤーフレームを表示。

### Phase 2: 自動写真撮影 & カバー率計算
* カメラ移動の軌跡（`ARFrame.camera.transform`）から角度・距離の変化を検知。
* 条件を満たした際に自動でキャプチャ（静止画データ化）。
* メッシュの密度と撮影角度から「スキャン達成度（%）」を計算してUIに反映。

### Phase 3: テクスチャマッピング & オブジェクト色塗り
* 取得したメッシュデータと撮影画像をマッピング。
* レイキャスト（タップ検知）により、選択した家具や部分メッシュごとに色合いや明るさを調整。

### Phase 4: USDZエクスポート & シェア
* 生成した `Entity` またはメッシュを `.usdz` ファイルとして書き出し。
* `UIActivityViewController` を使ってファイル共有やWeb/SNSへの出力に対応。

---

## 4. Swift Playgrounds用 ディレクトリ構造例

```text
MyARRoomApp.swiftpm/
├── MyApp.swift              // アプリのエントリーポイント
├── Views/
│   ├── ContentView.swift    // メイン画面（AR表示 + UIオーバーレイ）
│   ├── ARViewContainer.swift// RealityKit ARViewのSwiftUIブリッジ
│   └── UI/                  // プログレスバー、サイバー風ボタン等
├── AR/
│   ├── ARManager.swift      // ARSessionの管理・設定
│   └── MeshProcessor.swift  // メッシュ解析・テクスチャ割り当て
└── Models/
    └── ScanData.swift       // 撮影画像やメッシュデータの保持構造体
```

---

## 5. 1〜2ヶ月 開発ロードマップ (Swift Playgrounds)

* **Week 1:** Swift Playgroundsでプロジェクト作成、SwiftUI + RealityKit の基本画面作成
* **Week 2:** ARKitによる空間メッシュ描画とネオンシェーダー（サイバー表示）の組み込み
* **Week 3:** 自動キャプチャロジックとプログレスバー表示の実装
* **Week 4:** テクスチャ貼り付け（簡易テクスチャプロジェクション）の実験・実装
* **Week 5:** タップによるオブジェクト選択とカラー調整機能の実装
* **Week 6:** USDZファイル書き出し機能とシェア機能の実装
* **Week 7-8:** 実機テスト（iPad/iPhone）、UI調整、バグ修正