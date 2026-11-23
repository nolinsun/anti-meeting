import AppKit
import Foundation

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let coordinator: RecorderCoordinator
    private let onQuit: () -> Void
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "准备就绪", action: nil, keyEquivalent: "")
    private let inputDeviceItem = NSMenuItem(title: "输入设备: 检测中...", action: nil, keyEquivalent: "")
    private let outputDeviceItem = NSMenuItem(title: "输出设备: 检测中...", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "停止录制并封包", action: #selector(stopRecording), keyEquivalent: "")
    private let openDataItem = NSMenuItem(title: "打开会议数据目录", action: #selector(openDataDirectory), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出 MeetingRecorder", action: #selector(quitApp), keyEquivalent: "q")

    nonisolated static func shouldBeVisible(forState state: String) -> Bool {
        state == "starting" || state == "recording" || state == "finalizing"
    }

    init(coordinator: RecorderCoordinator, onQuit: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onQuit = onQuit
        super.init()

        setupMenu()
        refreshUI(coordinator.snapshot())
    }

    private func setupMenu() {
        stateItem.isEnabled = false
        inputDeviceItem.isEnabled = false
        outputDeviceItem.isEnabled = false

        stopItem.target = self
        openDataItem.target = self
        quitItem.target = self

        menu.delegate = self
        menu.addItem(stateItem)
        menu.addItem(inputDeviceItem)
        menu.addItem(outputDeviceItem)
        menu.addItem(.separator())
        menu.addItem(stopItem)
        menu.addItem(openDataItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    @MainActor
    func refreshFromCoordinator() {
        update(snapshot: coordinator.snapshot())
    }

    func update(snapshot: RecorderStateSnapshot) {
        refreshUI(snapshot)
        if snapshot.state == "recording" {
            startTimerIfNeeded()
        } else {
            stopTimer()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI(coordinator.snapshot())
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshUI(self.coordinator.snapshot())
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let existing = statusItem {
            return existing
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item
        return item
    }

    private func removeStatusItemIfPresent() {
        guard let existing = statusItem else { return }
        NSStatusBar.system.removeStatusItem(existing)
        statusItem = nil
    }

    private func refreshUI(_ snap: RecorderStateSnapshot) {
        guard Self.shouldBeVisible(forState: snap.state) else {
            stopTimer()
            removeStatusItemIfPresent()
            return
        }

        let item = ensureStatusItem()
        guard let button = item.button else { return }

        let modeLabel = (snap.mode == "dual") ? "双轨录制" : "仅麦克风"

        switch snap.state {
        case "recording":
            let elapsed = Self.formatDuration(snap.elapsedSec)
            let symbol = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = symbol?.withSymbolConfiguration(config)
            button.title = " \(elapsed)"
            stateItem.title = "录制中 · \(elapsed)（\(modeLabel) · 已提交 \(snap.committedChunkCount) 片）"
            stopItem.title = "停止录制并封包"
            stopItem.isEnabled = true
        case "starting":
            button.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Starting")
            button.title = " 启动中"
            stateItem.title = "正在初始化采集通道（\(modeLabel)）..."
            stopItem.title = "启动中..."
            stopItem.isEnabled = false
        default: // finalizing
            button.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Finalizing")
            button.title = " 封包中"
            stateItem.title = "正在封包最后一段音频（\(modeLabel)）..."
            stopItem.title = "封包中..."
            stopItem.isEnabled = false
        }

        inputDeviceItem.title = "输入设备: \(snap.inputDeviceName ?? "未检测到")"
        outputDeviceItem.isHidden = snap.mode != "dual"
        outputDeviceItem.title = "输出设备: \(snap.outputDeviceName ?? "系统默认输出")"
    }

    @objc private func stopRecording() {
        let snap = coordinator.snapshot()
        guard snap.state == "recording" else { return }
        let currentId = snap.meetingId
        let coord = coordinator
        Task { @MainActor [weak self] in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? coord.stopSession(meetingId: currentId)
                    cont.resume()
                }
            }
            self?.refreshUI(coord.snapshot())
        }
    }

    @objc private func openDataDirectory() {
        let dir = coordinator.dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quitApp() {
        onQuit()
    }

    private static func formatDuration(_ sec: Double) -> String {
        let total = max(0, Int(sec))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
