import AppKit
import Darwin
import Foundation

struct CLIArgs {
    var dataDir: URL
    var socketPath: String
    var chunkSec: Double
    var selfTestDir: URL?

    static func parse() -> CLIArgs {
        let homeSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        var dataDir = homeSupport.appendingPathComponent("AntigravityMeeting")
        var socketOverride: String?
        var chunkSec: Double = ChunkWriter.defaultChunkDurationSec
        var selfTestDir: URL?

        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--data-dir":
                if i + 1 < args.count {
                    dataDir = URL(fileURLWithPath: args[i + 1]).standardized
                    i += 1
                }
            case "--socket":
                if i + 1 < args.count {
                    socketOverride = args[i + 1]
                    i += 1
                }
            case "--chunk-sec":
                if i + 1 < args.count, let v = Double(args[i + 1]), v.isFinite, v >= 2.0 {
                    chunkSec = v
                    i += 1
                }
            case "--self-test":
                if i + 1 < args.count {
                    selfTestDir = URL(fileURLWithPath: args[i + 1])
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        let socketPath = socketOverride ?? dataDir.appendingPathComponent("run/recorder.sock").path
        return CLIArgs(dataDir: dataDir, socketPath: socketPath, chunkSec: chunkSec, selfTestDir: selfTestDir)
    }
}

final class SelfTestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var committedList: [ChunkRecord] = []
    private var failureMessages: [String] = []

    func addCommitted(_ record: ChunkRecord) {
        lock.withLock { committedList.append(record) }
    }

    func addFailure(_ message: String) {
        lock.withLock { failureMessages.append(message) }
    }

    func failures() -> [String] {
        lock.withLock { failureMessages }
    }
}

func runSelfTest(outputDir: URL, chunkSec: Double) -> Int32 {
    let fm = FileManager.default
    let meetingDir = outputDir.appendingPathComponent("meetings/self_test_001")
    let chunksDir = meetingDir.appendingPathComponent("chunks")
    let manifestURL = meetingDir.appendingPathComponent("manifest.json")

    do {
        if fm.fileExists(atPath: meetingDir.path) {
            try fm.removeItem(at: meetingDir)
        }
        try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let collector = SelfTestCollector()

        let writer = try ChunkWriter(
            chunksDir: chunksDir,
            chunkDurationSec: chunkSec,
            expectsRealTime: false,
            onChunkCommitted: { record in
                collector.addCommitted(record)
            },
            onChunkFailed: { msg in
                collector.addFailure(msg)
            }
        )

        // 1. ChunkWriter multi-chunk & overlap test (10s @ 16kHz).
        let sampleRate = Double(ChunkWriter.sampleRate)
        let totalSamples = Int(10.0 * sampleRate)
        let batchSize = 1600 // 100ms per batch
        var idx = 0
        while idx < totalSamples {
            let count = min(batchSize, totalSamples - idx)
            var buf = [Float](repeating: 0, count: count)
            for j in 0..<count {
                let t = Double(idx + j) / sampleRate
                let env = Float(0.5 + 0.5 * sin(2.0 * .pi * 2.0 * t))
                let s1 = Float(sin(2.0 * .pi * 440.0 * t))
                let s2 = Float(0.5 * sin(2.0 * .pi * 880.0 * t))
                buf[j] = 0.25 * env * (s1 + s2)
            }
            writer.appendSamples(buf)
            idx += count
        }

        let result = writer.finishAll()
        let failures = collector.failures()
        guard result.failedCount == 0, failures.isEmpty else {
            fputs("Self-test failed during chunk writing: \(failures.joined(separator: "; "))\n", stderr)
            return 2
        }

        let manifest = MeetingManifest(
            schemaVersion: 1,
            id: "self_test_001",
            title: "Self Test Recording",
            mode: "mic",
            appTarget: "mic_only",
            status: "recorded",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: result.totalDurationSec,
            chunks: result.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: result.failedCount,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(manifest, to: manifestURL)

        let dirContents = try fm.contentsOfDirectory(atPath: chunksDir.path)
        let lingeringTmp = dirContents.filter { $0.hasSuffix(".tmp") }
        guard lingeringTmp.isEmpty else {
            fputs("Self-test found lingering .tmp files: \(lingeringTmp)\n", stderr)
            return 3
        }

        // 2. P0-1: Converter queue drain + .endOfStream tail preservation test (48kHz -> 16kHz).
        do {
            try MicCapture.runConverterTailDrainSelfTest()
        } catch {
            fputs("Self-test failed at converterTailDrain: \(error.localizedDescription)\n", stderr)
            return 4
        }

        // 3. P1-6 & P1-7: Dual-instance socket isolation + strict HTTP 400/413 tests.
        let sockDir = outputDir.appendingPathComponent("sock_test")
        try fm.createDirectory(at: sockDir, withIntermediateDirectories: true)
        do {
            try UnixSocketServer.runSelfTests(tempDir: sockDir)
        } catch {
            fputs("Self-test failed at unixSocketServer: \(error.localizedDescription)\n", stderr)
            return 5
        }
        try? fm.removeItem(at: sockDir)

        // 4. Phase 2: DualTrackMixer + ChunkWriter(.dual) + SpeakerTimelineBuilder test.
        do {
            try DualTrackMixer.runSelfTest(outputDir: outputDir)
        } catch {
            fputs("Self-test failed at dualTrackMixer: \(error.localizedDescription)\n", stderr)
            return 6
        }

        // 5. Phase 2: SystemAudioCapture 48k stereo -> 16k mono + 4-state silence detection + StatusBar visibility test.
        do {
            try SystemAudioCapture.runConversionAndSilenceSelfTest()
        } catch {
            fputs("Self-test failed at systemAudioCapture: \(error.localizedDescription)\n", stderr)
            return 7
        }
        guard StatusBarController.shouldBeVisible(forState: "starting"),
              StatusBarController.shouldBeVisible(forState: "recording"),
              StatusBarController.shouldBeVisible(forState: "finalizing"),
              !StatusBarController.shouldBeVisible(forState: "idle"),
              !StatusBarController.shouldBeVisible(forState: "error")
        else {
            fputs("Self-test failed at StatusBarController visibility rule\n", stderr)
            return 8
        }

        // 6. P0-1, P0-3, P0-4 regression tests: DataDirLock, ChunkWriter short-write abort, and dual orphan recovery.
        do {
            let lockDir = outputDir.appendingPathComponent("lock_test")
            if fm.fileExists(atPath: lockDir.path) { try fm.removeItem(at: lockDir) }
            let l1 = try DataDirLock(dataDir: lockDir)
            var secondBlocked = false
            do {
                let l2 = try DataDirLock(dataDir: lockDir)
                l2.release()
            } catch {
                secondBlocked = true
            }
            l1.release()
            guard secondBlocked else {
                throw NSError(domain: "DataDirLockSelfTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Second DataDirLock succeeded on locked dataDir"])
            }
            try? fm.removeItem(at: lockDir)

            let realTarget = outputDir.appendingPathComponent("lock_symlink_target")
            let symLockDir = outputDir.appendingPathComponent("lock_symlink_dir")
            try? fm.removeItem(at: symLockDir)
            try? fm.removeItem(at: realTarget)
            try fm.createDirectory(at: realTarget, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: symLockDir, withDestinationURL: realTarget)
            var symlinkBlocked = false
            do {
                let symLock = try DataDirLock(dataDir: symLockDir)
                symLock.release()
            } catch {
                symlinkBlocked = true
            }
            var symlinkDotBlocked = false
            do {
                let symLockDot = try DataDirLock(dataDir: URL(fileURLWithPath: symLockDir.path + "/."))
                symLockDot.release()
            } catch {
                symlinkDotBlocked = true
            }
            let targetRunCreated = fm.fileExists(atPath: realTarget.appendingPathComponent("run").path)
            try? fm.removeItem(at: symLockDir)
            try? fm.removeItem(at: realTarget)
            guard symlinkBlocked, symlinkDotBlocked, !targetRunCreated else {
                throw NSError(domain: "DataDirLockSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "DataDirLock allowed symlinked dataDir or created run inside target"])
            }
        } catch {
            fputs("Self-test failed at DataDirLock: \(error.localizedDescription)\n", stderr)
            return 9
        }

        do {
            try ChunkWriter.runShortWriteFailureSelfTest(tempDir: outputDir)
        } catch {
            fputs("Self-test failed at ChunkWriter.runShortWriteFailureSelfTest: \(error.localizedDescription)\n", stderr)
            return 10
        }

        do {
            try RecorderCoordinator.runOrphanRecoverySelfTest(tempDir: outputDir)
        } catch {
            fputs("Self-test failed at RecorderCoordinator.runOrphanRecoverySelfTest: \(error.localizedDescription)\n", stderr)
            return 11
        }

        do {
            try PermissionChecker.runProbeTransitionSelfTest()
        } catch {
            fputs("Self-test failed at PermissionChecker.runProbeTransitionSelfTest: \(error.localizedDescription)\n", stderr)
            return 12
        }

        do {
            try RecorderCoordinator.runSnapshotGapSelfTest(tempDir: outputDir)
        } catch {
            fputs("Self-test failed at RecorderCoordinator.runSnapshotGapSelfTest: \(error.localizedDescription)\n", stderr)
            return 13
        }

        do {
            try RecorderCoordinator.runSleepGracefulFinalizeSelfTest(tempDir: outputDir)
        } catch {
            fputs("Self-test failed at RecorderCoordinator.runSleepGracefulFinalizeSelfTest: \(error.localizedDescription)\n", stderr)
            return 14
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let outData = try encoder.encode(manifest)
        if let jsonStr = String(data: outData, encoding: .utf8) {
            print(jsonStr)
        }
        return 0
    } catch {
        fputs("Self-test error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

@_silgen_name("flock")
private func posixFlock(_ fd: Int32, _ operation: Int32) -> Int32

private final class DataDirLock {
    private var fd: Int32 = -1
    private let lockPath: String

    private static func assertDirectoryNotSymlinkIfPresent(path: String, label: String) throws {
        var st = Darwin.stat()
        if Darwin.lstat(path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            guard fileType == S_IFDIR else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ELOOP),
                    userInfo: [NSLocalizedDescriptionKey: "Refusing non-directory or symlink \(label): \(path)"]
                )
            }
        } else {
            let err = errno
            if err != ENOENT {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(err),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to inspect \(label) \(path): errno \(err)"]
                )
            }
        }
    }

    init(dataDir: URL) throws {
        let normalizedDataDir = dataDir.standardized
        try Self.assertDirectoryNotSymlinkIfPresent(path: normalizedDataDir.path, label: "dataDir")
        let runDir = normalizedDataDir.appendingPathComponent("run")
        try Self.assertDirectoryNotSymlinkIfPresent(path: runDir.path, label: "runDir")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Self.assertDirectoryNotSymlinkIfPresent(path: normalizedDataDir.path, label: "dataDir")
        try Self.assertDirectoryNotSymlinkIfPresent(path: runDir.path, label: "runDir")
        self.lockPath = runDir.appendingPathComponent("daemon.lock").path

        let opened = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to open \(lockPath): errno \(err)"])
        }
        if posixFlock(opened, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            Darwin.close(opened)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Another daemon already holds lock on \(lockPath) (errno \(err))"])
        }
        self.fd = opened
    }

    func release() {
        guard fd >= 0 else { return }
        _ = posixFlock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }

    deinit {
        release()
    }
}

private final class ActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    func touch() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            lastActivityUptime = now
        }
    }

    func idleSeconds() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            max(0.0, now - lastActivityUptime)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cli: CLIArgs
    private let activityTracker = ActivityTracker()
    private let idleTimeoutSeconds: TimeInterval = 600.0
    private var dataDirLock: DataDirLock?
    private var coordinator: RecorderCoordinator?
    private var server: UnixSocketServer?
    private var statusBar: StatusBarController?
    private var idleWatchdogTimer: Timer?
    private var willSleepObserver: NSObjectProtocol?
    private var isTerminating = false

    init(cli: CLIArgs) {
        self.cli = cli
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityTracker.touch()

        // Acquire exclusive dataDir lock BEFORE recovery or socket startup so a second instance never touches active files (P0-1).
        do {
            self.dataDirLock = try DataDirLock(dataDir: cli.dataDir)
        } catch {
            fputs("Refusing startup without exclusive dataDir lock: \(error.localizedDescription)\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }

        let coord = RecorderCoordinator(dataDir: cli.dataDir, defaultChunkDurationSec: cli.chunkSec)
        coord.recoverOrphanedSessionsOnStartup()
        self.coordinator = coord

        let bar = StatusBarController(coordinator: coord) { [weak self] in
            self?.shutdownAndTerminate()
        }
        self.statusBar = bar

        let tracker = activityTracker
        coord.onStateChanged = {
            tracker.touch()
            Task { @MainActor in
                bar.refreshFromCoordinator()
            }
        }

        let srv = UnixSocketServer(
            socketPath: cli.socketPath,
            coordinator: coord,
            onActivity: { tracker.touch() },
            onRequestQuit: { [weak self] in
                Task { @MainActor in
                    self?.shutdownAndTerminate()
                }
            }
        )
        self.server = srv

        do {
            try srv.start()
        } catch {
            fputs("Failed to start UnixSocketServer: \(error.localizedDescription)\n", stderr)
            dataDirLock?.release()
            dataDirLock = nil
            NSApplication.shared.terminate(nil)
            return
        }

        idleWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleTimeout()
            }
        }

        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { _ in
            if coord.isBusy() {
                coord.handleSystemWillSleep()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            willSleepObserver = nil
        }
        idleWatchdogTimer?.invalidate()
        idleWatchdogTimer = nil
        coordinator?.beginShutdown()
        coordinator?.waitForFinalizationIfNeeded()
        server?.stop()
        dataDirLock?.release()
        dataDirLock = nil
    }

    private func checkIdleTimeout() {
        guard let coord = coordinator else { return }
        if coord.isBusy() {
            activityTracker.touch()
            return
        }
        if coord.tryBeginIdleShutdown(idleSeconds: activityTracker.idleSeconds(), threshold: idleTimeoutSeconds) {
            shutdownAndTerminate(alreadySetShutdown: true)
        }
    }

    private func shutdownAndTerminate(alreadySetShutdown: Bool = false) {
        guard !isTerminating else { return }
        isTerminating = true
        idleWatchdogTimer?.invalidate()
        idleWatchdogTimer = nil

        if !alreadySetShutdown {
            coordinator?.beginShutdown()
        }

        guard let coord = coordinator else {
            server?.stop()
            dataDirLock?.release()
            dataDirLock = nil
            NSApplication.shared.terminate(nil)
            return
        }

        let srv = server
        let lock = dataDirLock
        self.dataDirLock = nil
        Task { @MainActor in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    coord.waitForFinalizationIfNeeded()
                    cont.resume()
                }
            }
            srv?.stop()
            lock?.release()
            NSApplication.shared.terminate(nil)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let cli = CLIArgs.parse()

if let selfTestDir = cli.selfTestDir {
    let testChunkSec = cli.chunkSec == ChunkWriter.defaultChunkDurationSec ? 4.0 : cli.chunkSec
    exit(runSelfTest(outputDir: selfTestDir, chunkSec: testChunkSec))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(cli: cli)
app.delegate = delegate
app.run()
