import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @ObservedObject var model: ScannerModel
    @State private var showGuide = false
    @State private var confirmCancel = false
    @State private var confirmBack = false
    @State private var pendingDeletion: LibraryEntry?
    @State private var confirmDeletion = false

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CyberBackground()
                screen(size: geometry.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundColor(CyberColor.text)
        .tint(CyberColor.cyan)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showGuide) {
            PrivacyGuideView(hasLiDAR: model.hasLiDAR, supportsAR: model.supportsAR)
        }
        .sheet(isPresented: $model.showShare) {
            if let url = model.shareURL {
                ShareSheet(url: url)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.badge.ellipsis").font(.largeTitle)
                    Text("共有するファイルがありません")
                    Button("閉じる") { model.showShare = false }.buttonStyle(CyberButtonStyle())
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
        .alert("操作を完了できませんでした", isPresented: errorPresented) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "もう一度お試しください。")
        }
        .confirmationDialog("スキャンを中止しますか？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("スキャンを破棄", role: .destructive) { model.cancelScan() }
            Button("続ける", role: .cancel) { }
        } message: {
            Text("撮影中の写真と形状は保存されません。")
        }
        .confirmationDialog("ホームに戻りますか？", isPresented: $confirmBack, titleVisibility: .visible) {
            Button("保存してホームへ") { model.returnHome() }
            Button("編集を続ける", role: .cancel) { }
        } message: {
            Text("現在の編集を端末内に保存してホームに戻ります。外部への送信は行いません。保存に失敗した場合はお知らせします。")
        }
        .confirmationDialog("保存したスキャンを削除しますか？", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let entry = pendingDeletion { model.delete(entry) }
                pendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("「\(pendingDeletion?.name ?? "スキャン")」を端末から削除します。この操作は取り消せません。")
        }
    }

    @ViewBuilder
    private func screen(size: CGSize) -> some View {
        switch model.screen {
        case .home:
            HomeScreenView(model: model, availableWidth: size.width, onGuide: { showGuide = true }, onDelete: { entry in
                pendingDeletion = entry
                confirmDeletion = true
            })
        case .scanning:
            ScanScreenView(model: model, availableSize: size, onCancel: { confirmCancel = true }, onGuide: { showGuide = true })
        case .processing:
            ProcessingScreenView(model: model)
        case .editor:
            EditorScreenView(model: model, availableSize: size, onBack: { confirmBack = true }, onGuide: { showGuide = true })
        }
    }
}

// MARK: - Welcome & local library

@MainActor
private struct HomeScreenView: View {
    @ObservedObject var model: ScannerModel
    let availableWidth: CGFloat
    let onGuide: () -> Void
    let onDelete: (LibraryEntry) -> Void
    @Environment(\.openURL) private var openURL
    private var wide: Bool { availableWidth >= 760 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                hero
                entryActions
                hardwareCard
                librarySection
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("端末内で処理・保存。共有はあなたの操作で。")
                }
                .font(.caption2)
                .foregroundColor(CyberColor.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, wide ? 36 : 20)
            .padding(.top, 16)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.refreshLibrary() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 25, weight: .light))
                .foregroundColor(CyberColor.cyan)
            VStack(alignment: .leading, spacing: 3) {
                Text("QUESTSCAN").font(.system(size: 18, weight: .bold, design: .monospaced)).tracking(2.2)
                Text("空間を持ち歩く、3Dスキャナー").font(.system(size: 10)).foregroundColor(CyberColor.muted)
            }
            Spacer(minLength: 8)
            CyberIconButton(symbol: "questionmark", label: "使い方とプライバシー", color: CyberColor.lilac, action: onGuide)
        }
    }

    private var hero: some View {
        Group {
            if wide {
                HStack(spacing: 22) {
                    heroCopy.frame(maxWidth: .infinity, alignment: .leading)
                    heroArt.frame(maxWidth: .infinity).frame(height: 340)
                }
                .padding(30)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    heroCopy.padding(.horizontal, 22).padding(.top, 24)
                    heroArt.frame(height: 230)
                }
            }
        }
        .background(LinearGradient(colors: [CyberColor.panel, CyberColor.lilac.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(CyberColor.cyan.opacity(0.18), lineWidth: 1))
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("CAPTURE / CREATE / EXPLORE").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.7).foregroundColor(CyberColor.cyan)
            Text("空間を、\n次のかたちへ。")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            Text("部屋のかたちと色を記録。\n3Dで眺めて、色を変えて、USDZで共有。")
                .font(.subheadline)
                .foregroundColor(CyberColor.muted)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                StatusPill(text: "オンデバイス", symbol: "iphone")
                StatusPill(text: "USDZ", symbol: "cube", color: CyberColor.lilac)
            }
        }
    }

    private var heroArt: some View {
        ZStack(alignment: .bottomTrailing) {
            TechnicalRoomArt()
                .padding(.horizontal, 4)
            Text("CONCEPT ROOM / 手続き生成イラスト")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(CyberColor.muted.opacity(0.7))
                .padding(16)
        }
    }

    private var scanButton: some View {
        Button { model.startScan() } label: {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder").font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.permissionDenied ? "カメラ許可を再確認" : "新しいスキャン")
                    Text(model.hasLiDAR ? "LiDARで空間の形状を記録" : "カメラで検出した平面を記録")
                        .font(.caption2).opacity(0.75)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CyberButtonStyle())
        .disabled(!model.supportsAR || model.isBusy)
        .accessibilityHint(model.supportsAR ? "カメラを使用して新しいスキャンを開始します" : "この端末ではARスキャンに対応していません")
    }

    private var demoButton: some View {
        Button { model.openDemo() } label: {
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent").font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("デモルームを開く")
                    Text("カメラ不要で編集を体験").font(.caption2).opacity(0.75)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CyberButtonStyle(kind: .secondary))
        .disabled(model.isBusy)
    }

    @ViewBuilder private var entryActions: some View {
        if wide {
            HStack(spacing: 14) { scanButton; demoButton }
        } else {
            VStack(spacing: 12) { scanButton; demoButton }
        }
    }

    private var hardwareCard: some View {
        CyberPanel(accent: model.hasLiDAR ? CyberColor.cyan : CyberColor.lilac, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.hasLiDAR ? "sensor.tag.radiowaves.forward" : "camera.metering.center.weighted")
                        .font(.title2).foregroundColor(model.hasLiDAR ? CyberColor.cyan : CyberColor.lilac)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hardwareTitle).font(.subheadline.weight(.semibold))
                        Text(hardwareDetail).font(.caption).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.permissionDenied {
                    Divider().overlay(CyberColor.border)
                    Text("カメラへのアクセスがオフです。設定で許可するか、デモをご利用ください。")
                        .font(.caption).foregroundColor(CyberColor.warning)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("カメラの設定を開く", systemImage: "gearshape").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CyberButtonStyle(kind: .secondary))
                }
            }
        }
    }

    private var hardwareTitle: String {
        if !model.supportsAR { return "AR非対応の端末です" }
        return model.hasLiDAR ? "LiDARを利用できます" : "LiDARなし・平面スキャンを利用できます"
    }

    private var hardwareDetail: String {
        if !model.supportsAR { return "実空間のスキャンは利用できません。デモの3D表示・色編集・保存と書き出しは体験できます。" }
        if model.hasLiDAR { return "観測できた面のメッシュとカメラ写真を記録します。見えていない面や透明・反射面の復元は保証されません。" }
        return "検出した壁・床などの平面に写真を投影します。家具の細かな立体形状を復元するLiDARメッシュではありません。"
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                CyberSectionHeading(eyebrow: "YOUR SPACES", title: "保存したスキャン")
                Spacer()
                Text("\(model.library.count) 件").font(.system(.caption, design: .monospaced)).foregroundColor(CyberColor.muted)
            }
            if model.library.isEmpty {
                CyberPanel(accent: CyberColor.lilac) {
                    HStack(spacing: 15) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .light)).foregroundColor(CyberColor.lilac)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("最初の空間を、ここに。").font(.subheadline.weight(.semibold))
                            Text("スキャンやデモを編集し、「保存」でライブラリに追加できます。")
                                .font(.caption).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 300 : 280), spacing: 16)], spacing: 16) {
                    ForEach(model.library) { entry in
                        LibraryCard(entry: entry, onOpen: { model.open(entry) }, onDelete: { onDelete(entry) })
                            .disabled(model.isBusy)
                    }
                }
            }
        }
    }
}

private struct LibraryCard: View {
    let entry: LibraryEntry
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.name).font(.headline).foregroundColor(CyberColor.text).lineLimit(2)
                        HStack {
                            Text(entry.mode.title).font(.caption2).foregroundColor(CyberColor.cyan)
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundColor(CyberColor.muted)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name)、\(entry.mode.title)を開く")
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.date, style: .date)
                    Text("\(entry.triangleCount.formatted()) 三角形").font(.system(size: 10, design: .monospaced))
                }
                .font(.caption2).foregroundColor(CyberColor.muted)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(CyberColor.muted).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.name)を削除")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        }
        .background(CyberColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(CyberColor.border, lineWidth: 1))
    }

    private var thumbnail: some View {
        ZStack {
            CyberColor.raised
            if let data = entry.thumbnailJPEG, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(height: 140).clipped()
            } else {
                Image(systemName: "cube.transparent").font(.system(size: 44, weight: .ultraLight)).foregroundColor(CyberColor.cyan.opacity(0.65))
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Live capture

@MainActor
private struct ScanScreenView: View {
    @ObservedObject var model: ScannerModel
    let availableSize: CGSize
    let onCancel: () -> Void
    let onGuide: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var compact: Bool { availableSize.height < 590 || dynamicTypeSize.isAccessibilitySize }
    private var landscape: Bool { availableSize.width > availableSize.height && availableSize.height < 550 }
    private var elapsed: String {
        let seconds = Int(max(0, model.statistics.elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        ZStack {
            ARViewContainer(model: model).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.78), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            if !compact { scanReticle.allowsHitTesting(false) }
            if landscape {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) {
                        header
                        trackingBanner
                        Spacer(minLength: 0)
                    }
                    capturePanel.frame(width: min(360, availableSize.width * 0.49))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: compact ? 8 : 14) {
                    header
                    trackingBanner
                    Spacer(minLength: 8)
                    capturePanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CyberIconButton(symbol: "xmark", label: "スキャンを中止", action: onCancel).disabled(model.isBusy)
            VStack(alignment: .leading, spacing: 5) {
                Text("空間をスキャン").font(.headline)
                if !compact { StatusPill(text: model.hasLiDAR ? "LiDAR メッシュ" : "平面スキャン", symbol: "viewfinder") }
            }
            Spacer(minLength: 0)
            if !landscape { Text(elapsed).font(.system(.subheadline, design: .monospaced)).monospacedDigit().accessibilityLabel("経過時間 \(elapsed)") }
            CyberIconButton(symbol: "questionmark", label: "スキャンのコツ", action: onGuide)
        }
    }

    private var trackingBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: model.isPaused ? "pause.circle.fill" : (model.statistics.trackingGood ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle"))
                .foregroundColor(model.isPaused ? CyberColor.lilac : (model.statistics.trackingGood ? CyberColor.cyan : CyberColor.warning))
            Text(model.isPaused ? "一時停止中・撮影と形状の記録を停止" : model.statistics.trackingMessage)
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(CyberColor.ink.opacity(0.83))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 660)
        .accessibilityElement(children: .combine)
    }

    private var scanReticle: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder").font(.system(size: 84, weight: .ultraLight)).foregroundColor(CyberColor.cyan.opacity(0.45))
            Text("ゆっくり移動して、別の角度から")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1).foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.3)).clipShape(Capsule())
        }
        .offset(y: -40)
        .accessibilityHidden(true)
    }

    private var capturePanel: some View {
        CyberPanel(padding: compact ? 12 : 17) {
            VStack(spacing: compact ? 10 : 14) {
                if !compact { coverageSummary }
                HStack(spacing: 12) {
                    MetricTile(value: "\(model.statistics.photoCount)/\(model.options.maxPhotos)", label: "記録写真", symbol: "camera")
                    MetricTile(value: model.statistics.triangleCount.formatted(), label: "三角形", symbol: "triangle", accent: CyberColor.lilac)
                    MetricTile(value: String(format: "%.1f m²", model.statistics.surfaceArea), label: "観測面積", symbol: "square.dashed")
                }
                if compact {
                    Text("観測面の写真カバー率 \(coveragePercent)% ・部屋全体の完成度ではありません")
                        .font(.caption2).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(CyberColor.border)
                HStack(spacing: 16) {
                    Toggle("自動撮影", isOn: $model.options.autoCapture)
                    Toggle("メッシュ線", isOn: $model.options.wireframe)
                }
                .font(.caption2).tint(CyberColor.cyan).disabled(model.isBusy)
                captureActions
                if !compact {
                    Text(model.statistics.photoCount >= model.options.maxPhotos ? "写真の上限に達しました。形状の記録は続けられます。" : "写っていない面は単色になる場合があります。明るい場所で壁・床を見渡してください。")
                        .font(.caption2).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 660)
    }

    private var coveragePercent: Int {
        let value = model.statistics.coverage
        return Int((value.isFinite ? min(max(value, 0), 1) : 0) * 100)
    }

    private var coverageSummary: some View {
        HStack(spacing: 16) {
            CoverageGauge(progress: model.statistics.coverage, diameter: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text("観測面の写真カバー率").font(.subheadline.weight(.semibold))
                Text("見つかった面を写真で覆えた割合。\n部屋全体の完成度ではありません。")
                    .font(.caption2).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var captureActions: some View {
        HStack(spacing: 10) {
            CyberIconButton(symbol: model.isPaused ? "play.fill" : "pause.fill", label: model.isPaused ? "スキャンを再開" : "スキャンを一時停止", color: CyberColor.lilac) { model.pauseOrResume() }
                .disabled(model.isBusy)
            CyberIconButton(symbol: "camera.fill", label: "写真を手動で記録", color: CyberColor.cyan) { model.captureNow() }
                .disabled(model.isPaused || model.isBusy || !model.statistics.trackingGood || model.statistics.photoCount >= model.options.maxPhotos)
            Button { model.finishScan() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                    Text("終了して3Dを生成")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CyberButtonStyle())
            .disabled(model.isBusy || model.statistics.triangleCount == 0)
            .accessibilityHint("観測した形状と記録写真から3Dモデルを生成します")
        }
    }
}

// MARK: - Honest processing state

@MainActor
private struct ProcessingScreenView: View {
    @ObservedObject var model: ScannerModel
    private var progress: Double {
        model.processingProgress.isFinite ? min(max(model.processingProgress, 0), 0.98) : 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                HStack {
                    Text("QUESTSCAN").font(.system(.caption, design: .monospaced).weight(.bold)).tracking(3)
                    Spacer()
                    StatusPill(text: "端末内で処理中", symbol: "lock.shield", color: CyberColor.lilac)
                }
                TechnicalRoomArt().frame(height: 240)
                VStack(spacing: 12) {
                    Text("観測した空間を、3Dへ。")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("形状を整え、写真を面に投影しています。\nこの画面のまま、しばらくお待ちください。")
                        .font(.subheadline).foregroundColor(CyberColor.muted).multilineTextAlignment(.center)
                }
                CyberPanel(accent: CyberColor.lilac) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            ProgressView().tint(CyberColor.cyan).accessibilityHidden(true)
                            Text("3Dモデルを生成中").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(.headline, design: .monospaced)).foregroundColor(CyberColor.cyan)
                        }
                        ProgressView(value: progress, total: 1).tint(CyberColor.cyan)
                            .accessibilityLabel("3D生成の処理進捗")
                            .accessibilityValue("\(Int(progress * 100))パーセント")
                        Text(model.statusMessage.isEmpty ? "処理を準備しています" : model.statusMessage)
                            .font(.caption).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                        Divider().overlay(CyberColor.border)
                        HStack(spacing: 16) {
                            MetricTile(value: model.statistics.photoCount.formatted(), label: "記録写真", symbol: "photo")
                            MetricTile(value: model.statistics.triangleCount.formatted(), label: "入力三角形", symbol: "triangle", accent: CyberColor.lilac)
                        }
                    }
                }
                Text("表示は処理段階の目安です。書き出し準備が完了すると編集画面に切り替わります。")
                    .font(.caption2).foregroundColor(CyberColor.muted).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Native 3D editor

@MainActor
private struct EditorScreenView: View {
    @ObservedObject var model: ScannerModel
    let availableSize: CGSize
    let onBack: () -> Void
    let onGuide: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var wide: Bool { availableSize.width >= 760 || (availableSize.width > 620 && availableSize.height < 520) }

    var body: some View {
        VStack(spacing: 12) {
            header
            if wide && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 16) {
                    viewer.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        inspector
                        exportActions
                    }
                    .frame(width: min(350, availableSize.width * 0.40))
                }
            } else {
                VStack(spacing: 12) {
                    viewer.frame(height: max(160, min(300, availableSize.height * 0.34)))
                    inspector
                    exportActions
                }
            }
        }
        .padding(.horizontal, wide ? 22 : 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            CyberIconButton(symbol: "chevron.left", label: "保存してホームに戻る", action: onBack).disabled(model.isBusy)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.document?.name ?? "3Dエディター").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.document?.mode.title ?? "3Dモデル")
                    Text("/")
                    Text("\(model.document?.parts.count ?? 0) パーツ")
                }
                .font(.caption2).foregroundColor(CyberColor.muted)
            }
            Spacer(minLength: 0)
            CyberIconButton(symbol: "questionmark", label: "3D編集の使い方", color: CyberColor.lilac, action: onGuide)
        }
    }

    private var viewer: some View {
        ZStack {
            CyberColor.ink
            EditorViewContainer(model: model)
            VStack {
                HStack(spacing: 7) {
                    StatusPill(text: "3D VIEW", symbol: "cube.transparent")
                    if model.document?.mode == .demo {
                        StatusPill(text: "デモ・撮影データではありません", color: CyberColor.lilac)
                    }
                    Spacer(minLength: 0)
                }
                Spacer()
                if let selected = model.selectedPart {
                    HStack(spacing: 8) {
                        Image(systemName: selected.classification.symbol).foregroundColor(CyberColor.lilac)
                        Text(selected.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Button { model.selectPart(nil) } label: {
                            Image(systemName: "xmark").frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .accessibilityLabel("パーツの選択を解除")
                    }
                    .padding(.leading, 12).padding(.trailing, 3)
                    .background(CyberColor.panel.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                viewerInstructions
            }
            .padding(12)
            if model.isBusy {
                VStack(spacing: 10) {
                    ProgressView().tint(CyberColor.cyan)
                    Text("処理中…").font(.caption)
                }
                .padding(22)
                .background(CyberColor.ink.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityElement(children: .combine)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(CyberColor.cyan.opacity(0.18), lineWidth: 1))
    }

    private var viewerInstructions: some View {
        VStack(spacing: 4) {
            Text("1本指で回転 · ピンチで拡大 · タップで選択")
            Text("2本指で移動 · ダブルタップで視点リセット")
        }
        .font(.system(size: 10))
        .foregroundColor(CyberColor.muted)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(CyberColor.ink.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                editorToolbar
                partSelection
                SelectedColorControls(model: model)
                documentInfo
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            CyberIconButton(symbol: "arrow.uturn.backward", label: "色の変更を取り消す") { model.undo() }
                .disabled(!model.undoAvailable || model.isBusy)
            CyberIconButton(symbol: "arrow.uturn.forward", label: "色の変更をやり直す") { model.redo() }
                .disabled(!model.redoAvailable || model.isBusy)
            Spacer(minLength: 6)
            Toggle(isOn: $model.showWireframe) {
                Label("メッシュ線", systemImage: "cube.transparent").font(.caption2)
            }
            .tint(CyberColor.lilac)
            .disabled(model.isBusy)
            .accessibilityLabel("3Dモデルのメッシュ線を表示")
        }
    }

    private var partSelection: some View {
        CyberPanel(accent: CyberColor.lilac, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                CyberSectionHeading(eyebrow: "01 / SELECT", title: "編集するパーツ", detail: "3Dモデルをタップ、または一覧から選択。")
                if (model.document?.parts.isEmpty ?? true) {
                    Text("編集できるパーツがありません").font(.caption).foregroundColor(CyberColor.muted)
                } else if wide {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(model.document?.parts ?? []) { part in
                                PartSelectionRow(part: part, selected: part.id == model.selectedPartID) { model.selectPart(part.id) }
                            }
                        }
                    }
                    .frame(maxHeight: 175)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 8) {
                            ForEach(model.document?.parts ?? []) { part in
                                PartSelectionRow(part: part, selected: part.id == model.selectedPartID) { model.selectPart(part.id) }
                                    .frame(width: 170)
                            }
                        }
                        .padding(.bottom, 3)
                    }
                }
            }
        }
        .disabled(model.isBusy)
    }

    private var documentInfo: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let document = model.document {
                HStack(spacing: 16) {
                    Label("\(document.triangleCount.formatted()) 三角形", systemImage: "triangle")
                    Label("\(document.photosCaptured) 写真", systemImage: "photo")
                }
                .font(.caption2).foregroundColor(CyberColor.muted)
                if document.mode == .planes {
                    Text("平面スキャンです。検出した面のみを表示し、家具の立体形状は復元していません。")
                        .font(.caption2).foregroundColor(CyberColor.warning)
                }
                if let notes = document.qualityNotes, !notes.isEmpty {
                    Text(notes.joined(separator: "\n"))
                        .font(.caption2).foregroundColor(CyberColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(model.statusMessage)
                .font(.caption2).foregroundColor(CyberColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
        .accessibilityElement(children: .combine)
    }

    private var exportActions: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button { model.saveDocument() } label: {
                    Label("保存", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(CyberButtonStyle(kind: .secondary))
                .accessibilityHint("現在の編集を端末内のライブラリに保存します")
                Button { model.exportDocument() } label: {
                    Label("USDZを共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(CyberButtonStyle())
                .accessibilityHint("色の編集を反映したUSDZファイルを作成し、共有メニューを開きます")
            }
            .disabled(model.isBusy || model.document == nil)
            Text("保存は端末内。USDZは選んだ共有先にのみ送信。")
                .font(.system(size: 10)).foregroundColor(CyberColor.muted)
                .multilineTextAlignment(.center)
        }
    }
}

private struct PartSelectionRow: View {
    let part: ScenePart
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: part.classification.symbol)
                    .font(.system(size: 17, weight: .light))
                    .foregroundColor(selected ? CyberColor.lilac : CyberColor.muted)
                    .frame(width: 23)
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.name).font(.caption.weight(.semibold)).foregroundColor(CyberColor.text).lineLimit(1)
                    Text("\(part.classification.title) · \(part.triangleCount.formatted()) 面")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(CyberColor.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundColor(CyberColor.lilac) }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? CyberColor.lilac.opacity(0.13) : CyberColor.raised.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? CyberColor.lilac.opacity(0.55) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(part.name)、\(part.classification.title)")
        .accessibilityValue(selected ? "選択中" : "未選択")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct SelectedColorControls: View {
    @ObservedObject var model: ScannerModel
    @State private var confirmReset = false

    private var adjustment: ColorAdjustment { model.selectedPart?.adjustment ?? .identity }
    private var tintColor: Color {
        Color(.sRGB, red: Double(adjustment.red), green: Double(adjustment.green), blue: Double(adjustment.blue), opacity: 1)
    }

    var body: some View {
        CyberPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    CyberSectionHeading(eyebrow: "02 / COLOR", title: "色と質感を整える")
                    Spacer()
                    Button { confirmReset = true } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                    }
                    .foregroundColor(CyberColor.muted)
                    .buttonStyle(.plain)
                    .disabled(model.selectedPart == nil || model.isBusy || adjustment == .identity)
                    .accessibilityLabel("選択したパーツの色調整をリセット")
                }
                if let selected = model.selectedPart {
                    Text(selected.name).font(.caption.weight(.semibold)).foregroundColor(CyberColor.lilac)
                    sliders
                    Divider().overlay(CyberColor.border)
                    tintControls
                    Text(selected.textureJPEG == nil ? "写真テクスチャのない面にも、色と色調整が反映されます。" : "写真の色調と素材の着色を調整します。変更はUSDZにも反映されます。")
                        .font(.caption2).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 13) {
                        Image(systemName: "hand.tap").font(.title2).foregroundColor(CyberColor.cyan)
                        Text("パーツを選択すると、明るさ・コントラスト・彩度・色を変更できます。")
                            .font(.caption).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .disabled(model.isBusy)
        .confirmationDialog("このパーツの色調整をリセットしますか？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("元の色に戻す", role: .destructive) { model.resetSelected() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("明るさ・コントラスト・彩度・着色を初期値に戻します。変更後も「取り消す」で戻せます。")
        }
    }

    private var sliders: some View {
        VStack(spacing: 12) {
            AdjustmentSlider(title: "明るさ", symbol: "sun.max", value: valueBinding(\.brightness), range: -0.5...0.5, neutral: 0, unit: "%")
            AdjustmentSlider(title: "コントラスト", symbol: "circle.lefthalf.filled", value: valueBinding(\.contrast), range: 0.25...2, neutral: 1, unit: "%")
            AdjustmentSlider(title: "彩度", symbol: "drop", value: valueBinding(\.saturation), range: 0...2, neutral: 1, unit: "%")
        }
    }

    private var tintControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("着色カラー").font(.caption.weight(.semibold))
                Spacer()
                Text("TINT").font(.system(size: 9, design: .monospaced)).tracking(2).foregroundColor(CyberColor.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
                ForEach(TintPreset.presets) { preset in
                    swatch(preset)
                }
            }
            ColorPicker("カスタムカラー", selection: customColorBinding, supportsOpacity: false)
                .font(.caption)
                .padding(11)
                .frame(minHeight: 48)
                .background(CyberColor.raised)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("カスタム着色カラーを選ぶ")
            AdjustmentSlider(title: "色の強さ", symbol: "paintbrush.pointed", value: valueBinding(\.tintAmount), range: 0...1, neutral: 0, unit: "%")
        }
    }

    private func valueBinding(_ keyPath: WritableKeyPath<ColorAdjustment, Float>) -> Binding<Double> {
        Binding(get: { Double(adjustment[keyPath: keyPath]) }, set: { value in
            var next = adjustment
            next[keyPath: keyPath] = Float(value)
            model.updateAdjustment(next)
        })
    }

    private var customColorBinding: Binding<Color> {
        Binding(get: { tintColor }, set: { color in
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            var next = adjustment
            next.red = Float(red)
            next.green = Float(green)
            next.blue = Float(blue)
            if next.tintAmount == 0 { next.tintAmount = 0.65 }
            model.updateAdjustment(next)
        })
    }

    private func swatch(_ preset: TintPreset) -> some View {
        let selected = abs(adjustment.red - preset.red) < 0.005 && abs(adjustment.green - preset.green) < 0.005 && abs(adjustment.blue - preset.blue) < 0.005
        return Button {
            var next = adjustment
            next.red = preset.red
            next.green = preset.green
            next.blue = preset.blue
            if next.tintAmount == 0 { next.tintAmount = 0.65 }
            model.updateAdjustment(next)
        } label: {
            ZStack {
                Circle().fill(preset.color).frame(width: 28, height: 28)
                if selected {
                    Circle().stroke(CyberColor.text, lineWidth: 1.5).frame(width: 36, height: 36)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(preset.name == "ミッドナイト" ? .white : CyberColor.ink)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("着色カラー、\(preset.name)")
        .accessibilityValue(selected ? "選択中" : "未選択")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TintPreset: Identifiable {
    let name: String
    let red: Float
    let green: Float
    let blue: Float
    var id: String { name }
    var color: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: 1) }
    static let presets: [TintPreset] = [
        TintPreset(name: "ホワイト", red: 1, green: 1, blue: 1),
        TintPreset(name: "シアン", red: 0.27, green: 0.94, blue: 0.94),
        TintPreset(name: "ライラック", red: 0.73, green: 0.66, blue: 1),
        TintPreset(name: "コーラル", red: 1, green: 0.56, blue: 0.61),
        TintPreset(name: "サンド", red: 0.92, green: 0.80, blue: 0.62),
        TintPreset(name: "ミント", red: 0.58, green: 0.92, blue: 0.76),
        TintPreset(name: "ミッドナイト", red: 0.15, green: 0.20, blue: 0.31)
    ]
}

// MARK: - Guide & privacy

private struct PrivacyGuideView: View {
    let hasLiDAR: Bool
    let supportsAR: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CyberBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GUIDE / PRIVACY").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(CyberColor.cyan)
                        Text("使い方とプライバシー").font(.headline)
                    }
                    Spacer()
                    CyberIconButton(symbol: "xmark", label: "ガイドを閉じる") { dismiss() }
                }
                .padding(20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        guideSection(symbol: "viewfinder", title: "01  空間を記録する", accent: CyberColor.cyan, paragraphs: [
                            "明るい場所で、模様のある壁や床にカメラをゆっくり向けてください。近すぎず、同じ面を角度と距離を変えて撮影すると写真を投影しやすくなります。",
                            "自動撮影は位置・角度の変化に応じて写真を記録します。カメラボタンで手動撮影もできます。一時停止中は写真と形状の記録を止めます。",
                            "「観測面の写真カバー率」は、検出した面を写真で覆えた割合の目安です。部屋全体の完成度や、見えていない場所まで記録できたことを示しません。スキャン中は最大99%で表示します。"
                        ])
                        guideSection(symbol: "iphone", title: "この端末のスキャン方式", accent: CyberColor.lilac, paragraphs: [hardwareExplanation,
                            "鏡、透明なガラス、光沢面、暗い場所、模様のない壁は正確に記録できない場合があります。隠れた面や物の裏側は自動では復元しません。",
                            "撮影を終了すると、観測した形状から3Dを生成します。写真を投影できない面は単色になる場合があります。デモルームは手続き生成した例で、撮影データではありません。"
                        ])
                        guideSection(symbol: "cube.transparent", title: "02  3Dを眺めて、色を変える", accent: CyberColor.cyan, paragraphs: [
                            "1本指で回転、ピンチで拡大縮小、2本指で表示の中心を移動できます。ダブルタップで視点をリセットします。",
                            "3Dモデルをタップするか、パーツ一覧から選んでください。明るさ・コントラスト・彩度・着色カラーと色の強さを調整できます。",
                            "取り消し・やり直しに対応しています。リセットは選択パーツの色だけを初期値に戻します。メッシュ線は形状を確認するための表示です。"
                        ])
                        guideSection(symbol: "lock.shield", title: "03  あなたの空間は、あなたの端末に", accent: CyberColor.lilac, paragraphs: [
                            "カメラ画像と形状は端末内で処理します。アプリがスキャンや写真をサーバーへ送信することはありません。カメラへの許可はスキャン時にのみ必要です。",
                            "完成したスキャンは端末内に保存されます。「保存」で現在の編集を更新でき、ホームに戻る際も保存します。ライブラリから確認して削除できます。",
                            "「USDZを共有」は編集を反映したファイルを作成して、iOSの共有メニューを開きます。共有先に写真由来のテクスチャや室内形状が含まれることを確認してから送信してください。",
                            "人物、住所、書類、画面など、写り込む情報にご注意ください。許可なく他人や私有空間を撮影せず、移動中は周囲の安全を優先してください。"
                        ])
                        Text("QUESTSCAN · カメラから、あなたの次のアイデアへ。")
                            .font(.caption2).foregroundColor(CyberColor.muted).padding(.vertical, 12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundColor(CyberColor.text)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var hardwareExplanation: String {
        if !supportsAR { return "この端末ではARスキャンを利用できません。カメラ不要のデモで3D表示・色編集・保存とUSDZ共有を利用できます。" }
        if hasLiDAR { return "LiDARに対応しています。ARKitが観測した面のメッシュを記録し、撮影写真を形状へ投影します。" }
        return "LiDARは搭載されていません。ARKitが検出した壁・床などの平面を記録します。家具などの細かな立体形状を復元するLiDARメッシュとは異なります。"
    }

    private func guideSection(symbol: String, title: String, accent: Color, paragraphs: [String]) -> some View {
        CyberPanel(accent: accent) {
            VStack(alignment: .leading, spacing: 13) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.bold)).foregroundColor(accent)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.subheadline).foregroundColor(CyberColor.muted)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
