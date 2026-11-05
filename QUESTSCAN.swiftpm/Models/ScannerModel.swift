import SwiftUI
import ARKit
import AVFoundation
import UIKit
import Combine

@MainActor
final class ScannerModel: ObservableObject {
    enum AppScreen { case home, scanning, processing, editor }
    @Published var screen: AppScreen = .home
    @Published var statistics = ScanStatistics()
    @Published var options = ScanOptions()
    @Published var document: SceneDocument?
    @Published var selectedPartID: UUID?
    @Published var library: [LibraryEntry] = []
    @Published var errorMessage: String?
    @Published var statusMessage = "空間を、次のアイデアへ。"
    @Published var processingProgress: Double = 0
    @Published var isPaused = false
    @Published var isBusy = false
    @Published var shareURL: URL?
    @Published var showShare = false
    @Published var showWireframe = false
    @Published var editRevision = 0
    @Published var undoAvailable = false
    @Published var redoAvailable = false
    @Published var permissionDenied = false
    let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    let supportsAR = ARWorldTrackingConfiguration.isSupported
    let arManager = ARManager()

    private struct Edit {
        let partID: UUID
        let before: ColorAdjustment
        var after: ColorAdjustment
        var date: Date
    }
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private let processingQueue = DispatchQueue(label: "com.questscan.processing", qos: .userInitiated)
    private let storageQueue = DispatchQueue(label: "com.questscan.storage", qos: .utility)
    private var operationID = UUID()
    private var subscriptions = Set<AnyCancellable>()

    var selectedPart: ScenePart? {
        document?.parts.first { $0.id == selectedPartID }
    }

    init() {
        options = ScanOptions.stored()
        arManager.onStatistics = { [weak self] value in self?.statistics = value }
        arManager.onError = { [weak self] message in
            guard let self = self, self.screen == .scanning else { return }
            self.arManager.pause()
            self.isPaused = true
            self.errorMessage = message
        }
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self = self, self.screen == .scanning else { return }
                self.arManager.pause()
                self.isPaused = true
                self.statusMessage = "バックグラウンド移行で一時停止しました。戻ったら再開してください。"
            }.store(in: &subscriptions)
        refreshLibrary()
    }

    func applyScanOptions(_ value: ScanOptions) {
        let safe = value.sanitized()
        guard safe != options else { return }
        options = safe
        safe.persist()
        if screen == .scanning { arManager.updateOptions(safe) }
    }

    func startScan() {
        guard !isBusy else { return }
        guard supportsAR else {
            errorMessage = "この端末ではAR空間スキャンを利用できません。デモルームで編集・書き出しをお試しください。"
            return
        }
        isBusy = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginScan()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if granted { self.beginScan() } else { self.cameraDenied() }
                }
            }
        default: cameraDenied()
        }
    }

    private func cameraDenied() {
        isBusy = false
        permissionDenied = true
        errorMessage = "カメラへのアクセスが許可されていません。「設定」でQUESTSCANのカメラを許可してください。許可しない場合でもデモルームを利用できます。"
    }

    private func beginScan() {
        operationID = UUID()
        arManager.reset()
        statistics = ScanStatistics()
        permissionDenied = false
        isBusy = false
        isPaused = false
        document = nil
        selectedPartID = nil
        clearHistory()
        statusMessage = hasLiDAR ? "床・壁・家具を、少しずつ異なる角度から撮影してください。" : "平面スキャン: 床や壁を撮影してください。家具の立体形状は復元されません。"
        UIApplication.shared.isIdleTimerDisabled = true
        screen = .scanning
    }

    func pauseOrResume() {
        guard screen == .scanning else { return }
        if isPaused { arManager.resume() } else { arManager.pause() }
        isPaused.toggle()
        statusMessage = isPaused ? "一時停止中。位置を大きく変えずに再開してください。" : "同じ面を、角度と距離を変えて撮影してください。"
    }

    func captureNow() {
        guard screen == .scanning, !isPaused else { return }
        arManager.captureNow()
    }

    func finishScan() {
        guard screen == .scanning, !isBusy else { return }
        isBusy = true
        arManager.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        arManager.snapshot { [weak self] meshes, photos, mode, stats in
            guard let self = self else { return }
            guard meshes.contains(where: { !$0.indices.isEmpty }) else {
                self.isBusy = false
                self.isPaused = true
                self.errorMessage = "まだ面を検出できていません。再開して、模様のある床や壁にカメラをゆっくり向けてください。"
                return
            }
            self.arManager.stop()
            self.statistics = stats
            self.processingProgress = 0
            self.screen = .processing
            self.statusMessage = "メッシュに撮影画像を投影しています…"
            let token = self.operationID
            let name = "スキャン " + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            self.processingQueue.async { [weak self] in
                do {
                    var result = try TextureProjector.build(meshes: meshes, photos: photos, mode: mode, name: name) { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self, self.operationID == token else { return }
                            self.processingProgress = min(1, max(0, progress))
                        }
                    }
                    if stats.retentionLimited { result.warnings.append("取得上限により一部メッシュを間引き、または古い部分を省略しています。広い部屋は分けてスキャンしてください。") }
                    result.document.qualityNotes = result.warnings
                    result.document.photosCaptured = photos.count
                    result.document.thumbnailJPEG = photos.first?.jpeg
                    let built = result
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.operationID == token else { return }
                        self.document = built.document
                        self.selectedPartID = nil
                        self.showWireframe = false
                        self.editRevision += 1
                        self.processingProgress = 1
                        self.isBusy = false
                        self.screen = .editor
                        self.statusMessage = built.warnings.isEmpty ? "スキャンを生成しました。部分をタップして編集できます。" : built.warnings.joined(separator: "\n")
                        self.saveDocument()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.operationID == token else { return }
                        self.isBusy = false
                        self.screen = .home
                        self.errorMessage = "3D生成に失敗しました: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func cancelScan() {
        operationID = UUID()
        arManager.stop()
        arManager.reset()
        UIApplication.shared.isIdleTimerDisabled = false
        isBusy = false
        isPaused = false
        screen = .home
        statusMessage = "スキャンを中止しました。撮影画像は保存していません。"
    }

    func openDemo() {
        guard !isBusy else { return }
        operationID = UUID()
        document = DemoScene.make()
        selectedPartID = nil
        clearHistory()
        showWireframe = false
        editRevision += 1
        screen = .editor
        statusMessage = "デモルームです。実際に撮影された空間ではありません。"
    }

    func refreshLibrary() {
        storageQueue.async { [weak self] in
            do {
                let entries = try ScanLibrary.entries()
                DispatchQueue.main.async { [weak self] in self?.library = entries }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.errorMessage = "保存一覧を読み込めません: \(error.localizedDescription)" }
            }
        }
    }

    func open(_ entry: LibraryEntry) {
        guard !isBusy else { return }
        isBusy = true
        storageQueue.async { [weak self] in
            do {
                let loaded = try ScanLibrary.load(entry)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.document = loaded
                    self.selectedPartID = nil
                    self.clearHistory()
                    self.showWireframe = false
                    self.editRevision += 1
                    self.isBusy = false
                    self.screen = .editor
                    self.statusMessage = "端末内に保存したスキャンを開きました。"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.errorMessage = "スキャンを開けません: \(error.localizedDescription)"
                }
            }
        }
    }

    func delete(_ entry: LibraryEntry) {
        guard !isBusy else { return }
        isBusy = true
        storageQueue.async { [weak self] in
            do {
                try ScanLibrary.delete(entry)
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.refreshLibrary()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.errorMessage = "削除に失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    func saveDocument() {
        guard !isBusy, let copy = document else { return }
        isBusy = true
        storageQueue.async { [weak self] in
            do {
                try ScanLibrary.save(copy)
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.statusMessage = "端末内に保存しました。撮影画像は外部へ送信されていません。"
                    self?.refreshLibrary()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.errorMessage = "保存に失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    func exportDocument() {
        guard !isBusy, let copy = document else { return }
        isBusy = true
        statusMessage = "編集を反映したUSDZを作成しています…"
        storageQueue.async { [weak self] in
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QUESTSCAN-Exports", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Keep only the current and most recent export, so repeated sharing cannot grow without bound.
                let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for url in old { try? FileManager.default.removeItem(at: url) }
                let url = folder.appendingPathComponent("QUESTSCAN-\(copy.id.uuidString.prefix(8)).usdz")
                try USDZExporter.export(copy, to: url)
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.shareURL = url
                    self?.showShare = true
                    self?.statusMessage = "USDZを作成しました。共有先を選択してください。"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.isBusy = false
                    self?.errorMessage = "USDZ書き出しに失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    func returnHome() {
        guard !isBusy else { return }
        if document != nil { saveDocument() }
        selectedPartID = nil
        screen = .home
    }

    func selectPart(_ id: UUID?) { selectedPartID = id }

    func updateAdjustment(_ adjustment: ColorAdjustment) {
        guard !isBusy, let id = selectedPartID, let index = document?.parts.firstIndex(where: { $0.id == id }), let before = document?.parts[index].adjustment, before != adjustment else { return }
        var safe = adjustment
        safe.red = clamp(safe.red, 0, 1); safe.green = clamp(safe.green, 0, 1); safe.blue = clamp(safe.blue, 0, 1)
        safe.tintAmount = clamp(safe.tintAmount, 0, 1)
        safe.brightness = clamp(safe.brightness, -0.5, 0.5)
        safe.contrast = clamp(safe.contrast, 0.25, 2)
        safe.saturation = clamp(safe.saturation, 0, 2)
        guard before != safe else { return }
        let now = Date()
        if var last = undoStack.last, last.partID == id, now.timeIntervalSince(last.date) < 0.65, redoStack.isEmpty {
            last.after = safe; last.date = now; undoStack[undoStack.count - 1] = last
        } else {
            undoStack.append(Edit(partID: id, before: before, after: safe, date: now))
            if undoStack.count > 80 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        document?.parts[index].adjustment = safe
        editRevision += 1
        updateHistoryFlags()
    }

    func resetSelected() { updateAdjustment(.identity) }

    func undo() {
        guard !isBusy, let edit = undoStack.popLast(), let index = document?.parts.firstIndex(where: { $0.id == edit.partID }) else { return }
        document?.parts[index].adjustment = edit.before
        selectedPartID = edit.partID
        redoStack.append(edit)
        editRevision += 1
        updateHistoryFlags()
    }

    func redo() {
        guard !isBusy, var edit = redoStack.popLast(), let index = document?.parts.firstIndex(where: { $0.id == edit.partID }) else { return }
        document?.parts[index].adjustment = edit.after
        selectedPartID = edit.partID
        edit.date = .distantPast
        undoStack.append(edit)
        editRevision += 1
        updateHistoryFlags()
    }

    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        value.isFinite ? min(upper, max(lower, value)) : lower
    }
    private func updateHistoryFlags() { undoAvailable = !undoStack.isEmpty; redoAvailable = !redoStack.isEmpty }
    private func clearHistory() { undoStack.removeAll(); redoStack.removeAll(); updateHistoryFlags() }
}

typealias AppScreen = ScannerModel.AppScreen
