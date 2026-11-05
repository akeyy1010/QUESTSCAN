import SwiftUI

@MainActor
struct ScanSettingsView: View {
    @ObservedObject var model: ScannerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: ScanOptions

    init(model: ScannerModel) {
        self.model = model
        _draft = State(initialValue: model.options)
    }

    private var photoQualityChoices: [(Double, String)] {
        [(0.58, "節約"), (0.72, "標準"), (0.85, "高画質")]
    }

    var body: some View {
        ZStack {
            CyberBackground()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summary
                        captureSection
                        qualitySection
                        guidance
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                footer
            }
        }
        .foregroundColor(CyberColor.text)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: draft.sensitivity) { value in draft.selectSensitivity(value) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QUESTSCAN / PREFERENCES")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2).foregroundColor(CyberColor.cyan)
                Text("スキャン設定").font(.headline)
            }
            Spacer()
            CyberIconButton(symbol: "xmark", label: "設定を閉じる") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var summary: some View {
        CyberPanel(accent: CyberColor.lilac) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2).foregroundColor(CyberColor.lilac).frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text("撮り方をカスタマイズ").font(.subheadline.weight(.semibold))
                    Text("設定はこの端末に保存され、次回以降のスキャンにも適用されます。カメラ映像や写真は設定の保存対象ではありません。")
                        .font(.caption).foregroundColor(CyberColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var captureSection: some View {
        CyberPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                CyberSectionHeading(eyebrow: "01 / CAPTURE", title: "撮影", detail: "自動撮影の頻度と写真の上限を調整します。")
                Toggle(isOn: $draft.autoCapture) {
                    Label("自動撮影", systemImage: "camera.aperture").font(.subheadline.weight(.medium))
                }
                .tint(CyberColor.cyan)
                .accessibilityHint("移動量とカメラ角度の変化に応じて写真を自動撮影します")

                VStack(alignment: .leading, spacing: 9) {
                    Label("自動撮影の感度", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.medium))
                    Picker("自動撮影の感度", selection: $draft.sensitivity) {
                        ForEach(CaptureSensitivity.allCases) { sensitivity in
                            Text(sensitivity.title).tag(sensitivity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("移動や回転がどのくらいあったら写真を撮るかを選びます")
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(CaptureSensitivity.allCases) { value in
                                Button {
                                    draft.selectSensitivity(value)
                                } label: {
                                    HStack {
                                        Text(value.title)
                                        Spacer()
                                        if draft.sensitivity == value { Image(systemName: "checkmark.circle.fill") }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .padding(.horizontal, 12)
                                    .background(CyberColor.raised)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(draft.sensitivity == value ? .isSelected : [])
                            }
                        }
                    }
                    Text(draft.sensitivity.detail)
                        .font(.caption).foregroundColor(CyberColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("撮影間隔: 最短約\(draft.captureInterval, specifier: "%.1f")秒。位置追跡中にのみ撮影します。")
                        .font(.caption2).foregroundColor(CyberColor.muted)
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Label("写真の最大枚数", systemImage: "photo.stack")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 4)
                        Picker("写真の最大枚数", selection: $draft.maxPhotos) {
                            ForEach(ScanOptions.photoLimitChoices, id: \.self) { count in
                                Text("最大 \(count.formatted()) 枚").tag(count)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text("最大 \(draft.maxPhotos.formatted()) 枚")
                                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                            }
                            .foregroundColor(CyberColor.cyan)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .background(CyberColor.raised)
                            .clipShape(Capsule())
                        }
                        .pickerStyle(.menu)
                    }
                    Text("最大1,000枚まで選択できます。手動撮影も含みます。高枚数モードでは写真を最大640px・1枚180KB、深度を64pxに自動縮小してメモリを抑えます。")
                        .font(.caption2).foregroundColor(CyberColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var qualitySection: some View {
        CyberPanel(accent: CyberColor.lilac, padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                CyberSectionHeading(eyebrow: "02 / QUALITY", title: "写真と形状", detail: "画質を上げるほど、保存容量と処理負荷が増えます。")

                VStack(alignment: .leading, spacing: 9) {
                    Label("写真の解像度", systemImage: "viewfinder")
                        .font(.subheadline.weight(.medium))
                    Picker("写真の解像度", selection: $draft.photoLongEdge) {
                        Text("960 px・軽量").tag(960)
                        Text("1,280 px・高精細").tag(1_280)
                    }
                    .pickerStyle(.segmented)
                    Text("長辺の上限です。低電力モードでは端末負荷を抑えるため最大960 pxで記録します。")
                        .font(.caption2).foregroundColor(CyberColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Label("JPEGの画質", systemImage: "photo")
                        .font(.subheadline.weight(.medium))
                    Picker("JPEGの画質", selection: $draft.jpegQuality) {
                        ForEach(photoQualityChoices.indices, id: \.self) { index in
                            Text(photoQualityChoices[index].1).tag(photoQualityChoices[index].0)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("高画質ほど写真の細部を保ちやすくなります。撮影前に設定してください。")
                        .font(.caption2).foregroundColor(CyberColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Label("形状の最大三角形数", systemImage: "triangle")
                        .font(.subheadline.weight(.medium))
                    Picker("形状の最大三角形数", selection: $draft.maxTriangles) {
                        Text("20,000・軽量").tag(20_000)
                        Text("40,000・標準").tag(40_000)
                        Text("60,000・高精細").tag(60_000)
                    }
                    .pickerStyle(.segmented)
                    Text("上限を超える形状は均等に間引かれます。細部を優先するほど端末のメモリ・処理時間が増えます。")
                        .font(.caption2).foregroundColor(CyberColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $draft.wireframe) {
                    Label("スキャン中にメッシュ線を表示", systemImage: "square.3.layers.3d")
                        .font(.subheadline.weight(.medium))
                }
                .tint(CyberColor.lilac)
            }
        }
    }

    private var guidance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundColor(CyberColor.cyan)
            Text("撮影済みの写真には画質設定の変更は反映されません。高枚数モードの3D化では処理負荷を制限するため、最大128枚を時間順に均等選択して投影します。高感度設定は写真の重複が増える場合があります。")
                .font(.caption).foregroundColor(CyberColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().overlay(CyberColor.border)
            HStack(spacing: 12) {
                Button {
                    draft = ScanOptions()
                } label: {
                    Label("初期設定に戻す", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CyberButtonStyle(kind: .secondary))
                Button {
                    model.applyScanOptions(draft)
                    dismiss()
                } label: {
                    Label("設定を保存", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CyberButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(CyberColor.ink.opacity(0.98))
    }
}
