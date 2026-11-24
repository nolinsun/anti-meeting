@preconcurrency import AVFoundation
import CoreAudio
import CoreAudioTypes
import Darwin
import Foundation

private final class TapGenerationContext: PooledBufferGeneration, @unchecked Sendable {
    let id: Int
    let converter: AVAudioConverter
    let monoSourceFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat
    let sourceASBD: AudioStreamBasicDescription
    let bufferPool: PCMBufferPool
    var lastEndHostTimeNs: UInt64 = 0

    init(
        id: Int,
        converter: AVAudioConverter,
        monoSourceFormat: AVAudioFormat,
        sourceFormat: AVAudioFormat,
        sourceASBD: AudioStreamBasicDescription
    ) {
        self.id = id
        self.converter = converter
        self.monoSourceFormat = monoSourceFormat
        self.sourceFormat = sourceFormat
        self.sourceASBD = sourceASBD
        let poolCap = min(
            PCMBufferPool.defaultMaxPooledCapacity,
            max(4096, AVAudioFrameCount(ceil(sourceFormat.sampleRate * 0.1)))
        )
        self.bufferPool = PCMBufferPool(format: sourceFormat, prewarmCount: 16, defaultCapacity: poolCap)
    }
}

private final class TapInputConsumedFlag: @unchecked Sendable {
    var used = false
}

private struct RetiredIOProc: @unchecked Sendable {
    let deviceID: AudioDeviceID
    let procID: AudioDeviceIOProcID
}

/// Process-wide retirement registry so CoreAudio HAL objects that temporarily refuse destruction
/// (busy/stale hardware transition) continue being retried across probes and future sessions (P2-1).
private final class HALRetirementRegistry: @unchecked Sendable {
    static let shared = HALRetirementRegistry()
    private let lock = NSLock()
    private var ioProcs: [RetiredIOProc] = []
    private var aggregateIDs: [AudioObjectID] = []
    private var tapIDs: [AudioObjectID] = []
    private var flushInFlight = false
    private var flushGroup: DispatchGroup?

    var isEmpty: Bool {
        lock.withLock {
            !flushInFlight && ioProcs.isEmpty && aggregateIDs.isEmpty && tapIDs.isEmpty
        }
    }

    func retireIOProc(deviceID: AudioDeviceID, procID: AudioDeviceIOProcID) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        lock.withLock {
            ioProcs.append(RetiredIOProc(deviceID: deviceID, procID: procID))
        }
    }

    func retireAggregate(_ aggID: AudioObjectID) {
        guard aggID != AudioObjectID(kAudioObjectUnknown) else { return }
        lock.withLock {
            aggregateIDs.append(aggID)
        }
    }

    func retireTap(_ tapObjID: AudioObjectID) {
        guard tapObjID != AudioObjectID(kAudioObjectUnknown) else { return }
        lock.withLock {
            tapIDs.append(tapObjID)
        }
    }

    /// Asynchronously retries destroying any retired HAL objects while honoring `deadline` strictly (P1-2 #4).
    @discardableResult
    func flushIfNeeded(deadline: DispatchTime, isBenign: @escaping @Sendable (OSStatus) -> Bool) -> Bool {
        let waitGroup: DispatchGroup? = lock.withLock {
            if !flushInFlight && ioProcs.isEmpty && aggregateIDs.isEmpty && tapIDs.isEmpty {
                return nil
            }
            if !flushInFlight {
                flushInFlight = true
                let g = DispatchGroup()
                g.enter()
                flushGroup = g

                let pendingIO = ioProcs
                let pendingAgg = aggregateIDs
                let pendingTaps = tapIDs
                ioProcs.removeAll(keepingCapacity: true)
                aggregateIDs.removeAll(keepingCapacity: true)
                tapIDs.removeAll(keepingCapacity: true)

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    var failedIO: [RetiredIOProc] = []
                    for entry in pendingIO {
                        _ = AudioDeviceStop(entry.deviceID, entry.procID)
                        if !isBenign(AudioDeviceDestroyIOProcID(entry.deviceID, entry.procID)) {
                            failedIO.append(entry)
                        }
                    }
                    var failedAgg: [AudioObjectID] = []
                    for aggID in pendingAgg {
                        if !isBenign(AudioHardwareDestroyAggregateDevice(aggID)) {
                            failedAgg.append(aggID)
                        }
                    }
                    var failedTaps: [AudioObjectID] = []
                    for tapObjID in pendingTaps {
                        if !isBenign(AudioHardwareDestroyProcessTap(tapObjID)) {
                            failedTaps.append(tapObjID)
                        }
                    }
                    if let self {
                        self.lock.withLock {
                            if !failedIO.isEmpty { self.ioProcs.append(contentsOf: failedIO) }
                            if !failedAgg.isEmpty { self.aggregateIDs.append(contentsOf: failedAgg) }
                            if !failedTaps.isEmpty { self.tapIDs.append(contentsOf: failedTaps) }
                            self.flushInFlight = false
                            if self.flushGroup === g {
                                self.flushGroup = nil
                            }
                        }
                    }
                    g.leave()
                }
            }
            return flushGroup
        }

        if let waitGroup {
            let res = waitGroup.wait(timeout: deadline)
            guard res == .success else { return false }
        }
        return isEmpty
    }

    @discardableResult
    func retryAndCheckEmpty(isBenign: @escaping @Sendable (OSStatus) -> Bool) -> Bool {
        flushIfNeeded(deadline: .now() + .milliseconds(150), isBenign: isBenign)
    }

    func retryDestroyAll(isBenign: @escaping @Sendable (OSStatus) -> Bool) {
        _ = flushIfNeeded(deadline: .now() + .milliseconds(100), isBenign: isBenign)
    }
}

final class SystemAudioCapture: @unchecked Sendable {
    private let onSamples: @Sendable ([Float], UInt64) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let onGap: @Sendable (Double, Double, String) -> Void
    private let onError: @Sendable (String) -> Void
    private let onFatalError: @Sendable (String) -> Void
    private let onOutputDeviceChanged: @Sendable (String?) -> Void
    private let onSystemAudioStatusChanged: @Sendable (String) -> Void
    private let reportGlobalPermission: Bool
    private let sessionEpoch: UInt64?
    private let hasOtherAudioOutput: @Sendable () -> Bool

    private let lifecycleQueue = DispatchQueue(label: "io.github.nolinsun.meeting.sysaudio.lifecycle")
    private let ioQueue = DispatchQueue(label: "io.github.nolinsun.meeting.sysaudio.io", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "io.github.nolinsun.meeting.sysaudio.processing")
    private let listenerQueue = DispatchQueue(label: "io.github.nolinsun.meeting.sysaudio.listener")
    private let queueLock = NSLock()
    private let statusPublishLock = NSLock()

    private let targetFormat: AVAudioFormat
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var activeGeneration: TapGenerationContext?
    private var nextGenerationId: Int = 0
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?
    private var livenessTimer: DispatchSourceTimer?

    private let captureQueue = AudioCaptureQueue<TapGenerationContext>(capacity: 256)
    private var currentActiveGenerationId: Int = 0
    private var lastUsableBufferUptime: Double = 0
    private var stopCutoffUptime: Double?
    private var activeOutageStartUptime: Double?
    private var activeOutageReason: String?
    private var exhaustedFatalReported = false
    private var hasStartedTapOnce = false
    private var isRunning = false
    private var isReconfiguring = false
    private var smoothedLevel: Double = 0.0

    // Per-session permission / silence tracker.
    private var hasSeenNonZeroAudio = false
    private var cumulativeCallbackSec: Double = 0.0
    private var reportedSilentWarning = false

    init(
        onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void,
        onGap: @escaping @Sendable (Double, Double, String) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onFatalError: @escaping @Sendable (String) -> Void,
        onOutputDeviceChanged: @escaping @Sendable (String?) -> Void,
        onSystemAudioStatusChanged: @escaping @Sendable (String) -> Void,
        reportGlobalPermission: Bool = true,
        sessionEpoch: UInt64? = nil,
        hasOtherAudioOutput: @escaping @Sendable () -> Bool = SystemAudioCapture.hasOtherProcessRunningOutput
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.onGap = onGap
        self.onError = onError
        self.onFatalError = onFatalError
        self.onOutputDeviceChanged = onOutputDeviceChanged
        self.onSystemAudioStatusChanged = onSystemAudioStatusChanged
        self.reportGlobalPermission = reportGlobalPermission
        self.sessionEpoch = sessionEpoch
        self.hasOtherAudioOutput = hasOtherAudioOutput
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ChunkWriter.sampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    static func tryFlushRetiredHALObjects(deadline: DispatchTime = .now() + .milliseconds(150)) -> Bool {
        HALRetirementRegistry.shared.flushIfNeeded(deadline: deadline, isBenign: Self.isBenignHALStatus)
    }

    private func publishSystemAudioStatus(_ status: String) {
        if reportGlobalPermission {
            PermissionChecker.updateSystemAudioStatus(status, expectedEpoch: sessionEpoch)
        }
        onSystemAudioStatusChanged(status)
    }

    func start(updateGlobalPermissionOnStart: Bool = true) throws -> String? {
        try lifecycleQueue.sync {
            if isRunning {
                return Self.defaultOutputDeviceName()
            }
            isRunning = true
            hasSeenNonZeroAudio = false
            cumulativeCallbackSec = 0.0
            reportedSilentWarning = false
            hasStartedTapOnce = false

            let nowUp = ProcessInfo.processInfo.systemUptime
            statusPublishLock.withLock {
                queueLock.withLock {
                    currentActiveGenerationId = 0
                    lastUsableBufferUptime = nowUp
                    stopCutoffUptime = nil
                    activeOutageStartUptime = nil
                    activeOutageReason = nil
                    exhaustedFatalReported = false
                }
                if updateGlobalPermissionOnStart {
                    publishSystemAudioStatus("unverified")
                }
            }
            captureQueue.clear()

            do {
                guard HALRetirementRegistry.shared.retryAndCheckEmpty(isBenign: Self.isBenignHALStatus) else {
                    throw NSError(
                        domain: "SystemAudioCapture",
                        code: -15,
                        userInfo: [NSLocalizedDescriptionKey: "旧的系统音频 HAL 对象尚未释放，无法创建新的 Tap"]
                    )
                }
                try startTapOnLifecycleQueue()
                hasStartedTapOnce = true
                installOutputDeviceListenerOnLifecycleQueue()
                startLivenessTimerOnLifecycleQueue()
                return Self.defaultOutputDeviceName()
            } catch {
                isRunning = false
                hasStartedTapOnce = false
                stopLivenessTimerOnLifecycleQueue()
                removeOutputDeviceListenerOnLifecycleQueue()
                cleanupTapHardwareOnLifecycleQueue()
                if updateGlobalPermissionOnStart {
                    statusPublishLock.withLock {
                        publishSystemAudioStatus("tap_failed")
                    }
                }
                throw error
            }
        }
    }

    func stop() {
        let stopEntryUptime: Double = statusPublishLock.withLock {
            queueLock.withLock {
                let t = ProcessInfo.processInfo.systemUptime
                stopCutoffUptime = t
                return t
            }
        }

        let (flushGen, startedBeforeStop): (TapGenerationContext?, Bool) = lifecycleQueue.sync {
            let started = hasStartedTapOnce
            isRunning = false
            isReconfiguring = false
            stopLivenessTimerOnLifecycleQueue()
            removeOutputDeviceListenerOnLifecycleQueue()
            stopIOOnLifecycleQueue()
            return (activeGeneration, started)
        }

        ioQueue.sync {}
        if let flushGen {
            enqueueFlushGeneration(flushGen)
        }
        processingQueue.sync {
            drainQueue()
            statusPublishLock.withLock {
                smoothedLevel = 0.0
                onLevel(0.0)
            }
        }

        lifecycleQueue.sync {
            statusPublishLock.withLock {
                queueLock.withLock {
                    currentActiveGenerationId = 0
                }
            }
            destroyHardwareObjectsOnLifecycleQueue()
            activeGeneration = nil
        }

        // Evaluate outage/stall against frozen stopEntryUptime and pre-stop capture-time coverage (P1-3).
        let stopOutage: (start: Double, reason: String, emitFatal: Bool)? = queueLock.withLock {
            let alreadyFatal = exhaustedFatalReported
            if let start = activeOutageStartUptime {
                let reason = activeOutageReason ?? (alreadyFatal ? "system_audio_lost" : "system_audio_unrecovered")
                activeOutageStartUptime = nil
                activeOutageReason = nil
                return (start, reason, !alreadyFatal)
            }
            if startedBeforeStop && (stopEntryUptime - lastUsableBufferUptime) >= 2.0 {
                return (lastUsableBufferUptime, "system_audio_stalled", !alreadyFatal)
            }
            return nil
        }

        if let outage = stopOutage {
            onGap(outage.start, max(outage.start, stopEntryUptime), outage.reason)
            statusPublishLock.withLock {
                publishSystemAudioStatus("tap_failed")
            }
            if outage.emitFatal {
                onFatalError("系统音频捕获在停止前发生中断/停滞 (\(outage.reason))")
            }
        } else {
            statusPublishLock.withLock {
                if !hasSeenNonZeroAudio && reportedSilentWarning {
                    reportedSilentWarning = false
                    publishSystemAudioStatus("unverified")
                }
            }
        }
    }

    private func startTapOnLifecycleQueue() throws {
        guard HALRetirementRegistry.shared.retryAndCheckEmpty(isBenign: Self.isBenignHALStatus) else {
            throw NSError(
                domain: "SystemAudioCapture",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "旧的系统音频 HAL 对象尚未释放，拒绝创建重复 Tap"]
            )
        }

        var excludeProcessObjects: [AudioObjectID] = []
        if let ownObj = Self.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier) {
            excludeProcessObjects.append(ownObj)
        }

        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: excludeProcessObjects)
        tapDescription.name = "MeetingNotesSystemTap"
        tapDescription.isPrivate = true
        tapDescription.isExclusive = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw NSError(
                domain: "SystemAudioCapture",
                code: Int(tapStatus),
                userInfo: [NSLocalizedDescriptionKey: "创建系统音频 Process Tap 失败 (OSStatus=\(tapStatus))"]
            )
        }

        let tapUID = Self.readTapUID(tapID: newTapID) ?? tapDescription.uuid.uuidString

        let sourceASBD: AudioStreamBasicDescription
        do {
            sourceASBD = try Self.readTapFormat(tapID: newTapID)
        } catch {
            destroyOrRetainTap(newTapID, context: "readTapFormat失败清理")
            throw error
        }

        guard let sourceFormat = Self.makeAVAudioFormat(from: sourceASBD),
              let monoSourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceASBD.mSampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat)
        else {
            destroyOrRetainTap(newTapID, context: "创建转换器失败清理")
            throw NSError(
                domain: "SystemAudioCapture",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "无法为系统音频格式创建重采样转换器 (\(sourceASBD.mSampleRate)Hz, \(sourceASBD.mChannelsPerFrame)ch)"]
            )
        }

        let newAggID: AudioObjectID
        do {
            newAggID = try Self.createTapOnlyAggregateDevice(tapUID: tapUID)
        } catch {
            destroyOrRetainTap(newTapID, context: "创建聚合设备失败清理")
            throw error
        }

        nextGenerationId += 1
        let gen = TapGenerationContext(
            id: nextGenerationId,
            converter: converter,
            monoSourceFormat: monoSourceFormat,
            sourceFormat: sourceFormat,
            sourceASBD: sourceASBD
        )

        self.tapID = newTapID
        self.aggregateDeviceID = newAggID
        self.activeGeneration = gen

        // Give the new generation a fresh grace window and mark its ID active under statusPublishLock -> queueLock (P1-2 #6).
        let nowUp = ProcessInfo.processInfo.systemUptime
        statusPublishLock.withLock {
            queueLock.withLock {
                currentActiveGenerationId = gen.id
                lastUsableBufferUptime = nowUp
            }
        }

        var createdIOProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProcID,
            newAggID,
            ioQueue
        ) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            guard let pcm = Self.makePCMBuffer(
                from: inInputData,
                asbd: gen.sourceASBD,
                format: gen.sourceFormat,
                bufferPool: gen.bufferPool
            ) else {
                return
            }

            let ticks: UInt64
            if (inInputTime.pointee.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue) != 0 {
                ticks = inInputTime.pointee.mHostTime
            } else {
                ticks = mach_absolute_time()
            }
            let hostNs = MicCapture.hostTicksToNanoseconds(ticks)
            self.enqueueInputBuffer(pcm, generation: gen, hostTimeNs: hostNs)
        }

        guard procStatus == noErr, let validProcID = createdIOProcID else {
            cleanupTapHardwareOnLifecycleQueue()
            throw NSError(
                domain: "SystemAudioCapture",
                code: Int(procStatus),
                userInfo: [NSLocalizedDescriptionKey: "创建系统音频 IOProc 失败 (OSStatus=\(procStatus))"]
            )
        }

        self.ioProcID = validProcID

        let startStatus = AudioDeviceStart(newAggID, validProcID)
        guard startStatus == noErr else {
            cleanupTapHardwareOnLifecycleQueue()
            throw NSError(
                domain: "SystemAudioCapture",
                code: Int(startStatus),
                userInfo: [NSLocalizedDescriptionKey: "启动系统音频聚合设备失败 (OSStatus=\(startStatus))"]
            )
        }

        onOutputDeviceChanged(Self.defaultOutputDeviceName())
    }

    private func stopIOOnLifecycleQueue() {
        let devID = aggregateDeviceID
        guard devID != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID else {
            ioProcID = nil
            return
        }

        let stopStatus = AudioDeviceStop(devID, procID)
        if !Self.isBenignHALStatus(stopStatus) {
            onError("停止系统音频 IO 失败 (OSStatus=\(stopStatus))")
        }

        let destroyProcStatus = AudioDeviceDestroyIOProcID(devID, procID)
        if !Self.isBenignHALStatus(destroyProcStatus) {
            HALRetirementRegistry.shared.retireIOProc(deviceID: devID, procID: procID)
            onError("销毁系统音频 IOProc 失败 (OSStatus=\(destroyProcStatus))")
        }
        ioProcID = nil
    }

    private func destroyOrRetainAggregate(_ aggID: AudioObjectID, context: String) {
        guard aggID != AudioObjectID(kAudioObjectUnknown) else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggID)
        if !Self.isBenignHALStatus(status) {
            HALRetirementRegistry.shared.retireAggregate(aggID)
            onError("\(context): 销毁聚合设备失败 (OSStatus=\(status))")
        }
    }

    private func destroyOrRetainTap(_ tapObjID: AudioObjectID, context: String) {
        guard tapObjID != AudioObjectID(kAudioObjectUnknown) else { return }
        let status = AudioHardwareDestroyProcessTap(tapObjID)
        if !Self.isBenignHALStatus(status) {
            HALRetirementRegistry.shared.retireTap(tapObjID)
            onError("\(context): 销毁 Process Tap 失败 (OSStatus=\(status))")
        }
    }

    private func destroyHardwareObjectsOnLifecycleQueue() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            let agg = aggregateDeviceID
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            destroyOrRetainAggregate(agg, context: "关闭捕获")
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let t = tapID
            tapID = AudioObjectID(kAudioObjectUnknown)
            destroyOrRetainTap(t, context: "关闭捕获")
        }
        HALRetirementRegistry.shared.retryDestroyAll(isBenign: Self.isBenignHALStatus)
    }

    private func cleanupTapHardwareOnLifecycleQueue() {
        statusPublishLock.withLock {
            queueLock.withLock {
                currentActiveGenerationId = 0
            }
        }
        stopIOOnLifecycleQueue()
        destroyHardwareObjectsOnLifecycleQueue()
        activeGeneration = nil
    }

    private func installOutputDeviceListenerOnLifecycleQueue() {
        guard outputListenerBlock == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.triggerRecovery(reason: "output_device_changed")
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            listenerQueue,
            block
        )
        if status == noErr {
            outputListenerBlock = block
        } else {
            onError("注册默认输出设备变更监听失败 (OSStatus=\(status))")
        }
    }

    private func removeOutputDeviceListenerOnLifecycleQueue() {
        guard let block = outputListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            listenerQueue,
            block
        )
        if Self.isBenignHALStatus(status) {
            outputListenerBlock = nil
        } else {
            onError("移除默认输出设备监听失败 (OSStatus=\(status))")
        }
    }

    private func startLivenessTimerOnLifecycleQueue() {
        stopLivenessTimerOnLifecycleQueue()
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + .milliseconds(1500), repeating: .milliseconds(1500))
        timer.setEventHandler { [weak self] in
            self?.checkCallbackLivenessOnLifecycleQueue()
        }
        timer.resume()
        livenessTimer = timer
    }

    private func stopLivenessTimerOnLifecycleQueue() {
        livenessTimer?.cancel()
        livenessTimer = nil
    }

    private func checkCallbackLivenessOnLifecycleQueue() {
        guard isRunning, !isReconfiguring else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let lastCovered = queueLock.withLock { lastUsableBufferUptime }
        if max(0.0, now - lastCovered) >= 4.0 {
            triggerRecovery(reason: "system_audio_stalled", outageStartOverride: lastCovered)
        }
    }

    private func triggerRecovery(reason: String, outageStartOverride: Double? = nil) {
        lifecycleQueue.async { [weak self] in
            guard let self, self.isRunning, !self.isReconfiguring else { return }
            self.isReconfiguring = true
            let nowUp = ProcessInfo.processInfo.systemUptime
            let gapStartUptime = outageStartOverride.map { min($0, nowUp) } ?? nowUp
            let prevGen = self.activeGeneration

            self.statusPublishLock.withLock {
                self.queueLock.withLock {
                    self.currentActiveGenerationId = 0
                    if self.activeOutageStartUptime == nil {
                        self.activeOutageStartUptime = gapStartUptime
                    }
                    if self.activeOutageReason == nil {
                        self.activeOutageReason = reason
                    }
                }
            }

            self.stopIOOnLifecycleQueue()
            self.destroyHardwareObjectsOnLifecycleQueue()
            self.activeGeneration = nil

            if let prevGen {
                self.enqueueFlushGeneration(prevGen)
            }

            self.attemptRestartOnLifecycleQueue(gapStartUptime: gapStartUptime, gapReason: reason, attempt: 1)
        }
    }

    private func attemptRestartOnLifecycleQueue(gapStartUptime: Double, gapReason: String, attempt: Int) {
        let delay: TimeInterval = attempt == 1 ? 0.30 : 0.60
        lifecycleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.isRunning else {
                self.isReconfiguring = false
                return
            }
            do {
                try self.startTapOnLifecycleQueue()
                // Outage stays open until a usable buffer from the new generation is processed (P1-3).
                self.isReconfiguring = false
            } catch {
                if attempt < 2 {
                    self.attemptRestartOnLifecycleQueue(gapStartUptime: gapStartUptime, gapReason: gapReason, attempt: attempt + 1)
                } else {
                    self.isReconfiguring = false
                    self.isRunning = false
                    self.stopLivenessTimerOnLifecycleQueue()
                    self.removeOutputDeviceListenerOnLifecycleQueue()
                    self.cleanupTapHardwareOnLifecycleQueue()
                    // Keep outage open until session stop() and serialize level=0 + tap_failed under statusPublishLock (P1-3).
                    self.statusPublishLock.withLock {
                        self.queueLock.withLock {
                            self.currentActiveGenerationId = 0
                            if self.activeOutageStartUptime == nil {
                                self.activeOutageStartUptime = gapStartUptime
                            }
                            self.activeOutageReason = "system_audio_lost"
                            self.exhaustedFatalReported = true
                        }
                        self.smoothedLevel = 0.0
                        self.onLevel(0.0)
                        self.publishSystemAudioStatus("tap_failed")
                    }
                    self.onFatalError("系统音频捕获中断且恢复失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func enqueueInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        generation: TapGenerationContext,
        hostTimeNs: UInt64,
        captureUptime: Double? = nil
    ) {
        if captureQueue.enqueueAudio(buffer, generation: generation, hostTimeNs: hostTimeNs, captureUptime: captureUptime) {
            processingQueue.async { [weak self] in
                self?.drainQueue()
            }
        }
    }

    private func enqueueFlushGeneration(_ generation: TapGenerationContext) {
        if captureQueue.enqueueFlushGeneration(generation) {
            processingQueue.async { [weak self] in
                self?.drainQueue()
            }
        }
    }

    private func drainQueue() {
        while true {
            let (nextItem, overflowSpan) = captureQueue.popNext()
            if let span = overflowSpan {
                onGap(span.start, span.end, "system_audio_queue_overflow")
            }

            guard let item = nextItem else {
                if overflowSpan != nil { continue }
                break
            }
            switch item {
            case .audio(let buffer, let generation, let hostTimeNs, let captureUptime):
                processInputItem(buffer: buffer, generation: generation, hostTimeNs: hostTimeNs, captureUptime: captureUptime)
                generation.bufferPool.recycle(buffer)
            case .flushGeneration(let generation):
                flushConverter(generation)
            }
        }
    }

    private func processInputItem(
        buffer: AVAudioPCMBuffer,
        generation: TapGenerationContext,
        hostTimeNs: UInt64,
        captureUptime: Double
    ) {
        guard let monoInput = AudioDownmix.toMonoFloat32(buffer), monoInput.frameLength > 0 else { return }
        let conv = generation.converter

        let ratio = targetFormat.sampleRate / max(1.0, monoInput.format.sampleRate)
        let outCapacity = max(AVAudioFrameCount(512), AVAudioFrameCount(ceil(Double(monoInput.frameLength) * ratio)) + 64)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        let consumedFlag = TapInputConsumedFlag()
        let status = conv.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumedFlag.used {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedFlag.used = true
            outStatus.pointee = .haveData
            return monoInput
        }

        if status == .error {
            onError("系统音频格式转换失败: \(error?.localizedDescription ?? "unknown")")
            return
        }

        let inputDurSec = Double(monoInput.frameLength) / max(1.0, monoInput.format.sampleRate)
        let inputDurNs = UInt64((inputDurSec * 1_000_000_000.0).rounded())
        generation.lastEndHostTimeNs = hostTimeNs &+ inputDurNs

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0, let channelPtr = outputBuffer.floatChannelData?[0] else {
            return
        }

        // Advance coverage heartbeat ONLY for pre-stop buffers from the active generation (P1-3).
        let recoveredOutage: (start: Double, reason: String)? = queueLock.withLock {
            guard generation.id == currentActiveGenerationId, !exhaustedFatalReported else {
                return nil
            }
            if let cutoff = stopCutoffUptime, captureUptime >= cutoff {
                return nil
            }
            let maxAllowedEnd = stopCutoffUptime ?? ProcessInfo.processInfo.systemUptime
            let coveredEndUptime = min(maxAllowedEnd, captureUptime + inputDurSec)
            lastUsableBufferUptime = max(lastUsableBufferUptime, coveredEndUptime)
            guard let start = activeOutageStartUptime else {
                return nil
            }
            let reason = activeOutageReason ?? "system_audio_recovered"
            activeOutageStartUptime = nil
            activeOutageReason = nil
            return (start, reason)
        }
        if let recoveredOutage {
            onGap(recoveredOutage.start, max(recoveredOutage.start, captureUptime), recoveredOutage.reason)
        }

        let samples = Array(UnsafeBufferPointer(start: channelPtr, count: frameCount))
        onSamples(samples, hostTimeNs)

        var maxAbs: Float = 0.0
        var sumSquares: Double = 0.0
        for s in samples {
            let absVal = abs(s)
            if absVal > maxAbs { maxAbs = absVal }
            let v = Double(s)
            sumSquares += v * v
        }

        let rms = sqrt(sumSquares / Double(frameCount))
        let db = 20.0 * log10(max(rms, 1e-6))
        let normalized = min(1.0, max(0.0, (db + 55.0) / 50.0))
        let chunkDurSec = Double(frameCount) / Double(ChunkWriter.sampleRate)

        // Check active generation + exhaustion atomically WITH onLevel and status publication inside statusPublishLock -> queueLock (P1-3 / P2 #5).
        statusPublishLock.withLock {
            let canEmit = queueLock.withLock {
                generation.id == currentActiveGenerationId && !exhaustedFatalReported && stopCutoffUptime == nil
            }
            guard canEmit else { return }

            smoothedLevel = smoothedLevel * 0.6 + normalized * 0.4
            onLevel(smoothedLevel)

            let hasSignal = (maxAbs > 1e-5)
            if hasSignal {
                if !hasSeenNonZeroAudio {
                    hasSeenNonZeroAudio = true
                    publishSystemAudioStatus("granted")
                }
                return
            }

            guard !hasSeenNonZeroAudio else { return }
            cumulativeCallbackSec += chunkDurSec
            if !reportedSilentWarning {
                if cumulativeCallbackSec >= 3.0 {
                    if hasOtherAudioOutput() {
                        reportedSilentWarning = true
                        cumulativeCallbackSec = 0.0
                        publishSystemAudioStatus("silent_or_denied")
                    } else {
                        // System is genuinely quiet right now; keep status unverified and re-check periodically.
                        cumulativeCallbackSec = 1.5
                    }
                }
            } else if cumulativeCallbackSec >= 0.5 {
                cumulativeCallbackSec = 0.0
                if !hasOtherAudioOutput() {
                    reportedSilentWarning = false
                    publishSystemAudioStatus("unverified")
                }
            }
        }
    }

    private func flushConverter(_ generation: TapGenerationContext) {
        let conv = generation.converter
        var cursorHostTimeNs = generation.lastEndHostTimeNs
        for _ in 0..<16 {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            let frameCount = Int(outBuf.frameLength)
            if frameCount > 0, let ptr = outBuf.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
                onSamples(samples, cursorHostTimeNs)
                let durNs = UInt64((Double(frameCount) / targetFormat.sampleRate * 1_000_000_000.0).rounded())
                cursorHostTimeNs = cursorHostTimeNs &+ durNs
            }
            if status == .endOfStream || status == .error || frameCount == 0 {
                break
            }
        }
        conv.reset()
    }

    // MARK: - Permission Probe

    /// Enforces a single hard wall-clock deadline spanning HAL startup, signal observation, and teardown (P1-2).
    static func probePermission(
        deadlineMs: Int = 650,
        deadline: DispatchTime? = nil,
        cancelSemaphore: DispatchSemaphore? = nil,
        onTeardownComplete: (@Sendable () -> Void)? = nil
    ) -> String {
        probePermissionDetailed(
            deadlineMs: deadlineMs,
            deadline: deadline,
            cancelSemaphore: cancelSemaphore,
            onTeardownComplete: onTeardownComplete
        ).status
    }

    static func probePermissionDetailed(
        deadlineMs: Int = 650,
        deadline: DispatchTime? = nil,
        cancelSemaphore: DispatchSemaphore? = nil,
        onTeardownComplete: (@Sendable () -> Void)? = nil
    ) -> (status: String, tapStarted: Bool) {
        final class ProbeState: @unchecked Sendable {
            private let lock = NSLock()
            let finishSem = DispatchSemaphore(value: 0)
            let cleanupDoneSem = DispatchSemaphore(value: 0)
            var finishedWaiting = false
            var cancelled = false
            var seenSignal = false
            var startFailed = false
            var tapStarted = false
            var otherAudioPlaying = false
            var teardownNotified = false
            var probeCapture: SystemAudioCapture?

            func setSignal() {
                let notify = lock.withLock { () -> Bool in
                    if seenSignal { return false }
                    seenSignal = true
                    return true
                }
                if notify { finishSem.signal() }
            }

            func setStartFailed() {
                lock.withLock { startFailed = true }
                finishSem.signal()
            }

            func setCancelled() {
                lock.withLock { cancelled = true }
                finishSem.signal()
            }

            func markTapStarted(otherPlaying: Bool) {
                lock.withLock {
                    tapStarted = true
                    if otherPlaying {
                        otherAudioPlaying = true
                    }
                }
            }

            func noteOtherAudioPlaying() {
                lock.withLock {
                    otherAudioPlaying = true
                }
            }

            func markDoneWaiting() {
                lock.withLock { finishedWaiting = true }
            }

            func attachStartedCapture(_ cap: SystemAudioCapture) -> Bool {
                lock.withLock {
                    if finishedWaiting || cancelled { return false }
                    probeCapture = cap
                    return true
                }
            }

            func result() -> (
                seenSignal: Bool,
                startFailed: Bool,
                tapStarted: Bool,
                otherAudioPlaying: Bool,
                cancelled: Bool,
                capture: SystemAudioCapture?
            ) {
                lock.withLock {
                    (seenSignal, startFailed, tapStarted, otherAudioPlaying, cancelled, probeCapture)
                }
            }

            func notifyTeardownOnce(_ callback: (@Sendable () -> Void)?) {
                let shouldRun = lock.withLock { () -> Bool in
                    if teardownNotified { return false }
                    teardownNotified = true
                    return true
                }
                if shouldRun {
                    callback?()
                }
            }
        }

        let now = DispatchTime.now()
        let hardDeadline: DispatchTime
        if let deadline {
            hardDeadline = deadline
        } else {
            let budgetNs = UInt64(max(1, deadlineMs)) * 1_000_000
            let headroomNs = min(UInt64(15_000_000), budgetNs / 5)
            hardDeadline = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds &+ (budgetNs - headroomNs))
        }
        guard hardDeadline.uptimeNanoseconds > now.uptimeNanoseconds else {
            onTeardownComplete?()
            return ("unverified", false)
        }
        let rawRemainingNs = hardDeadline.uptimeNanoseconds - now.uptimeNanoseconds
        let wakeupSlackNs: UInt64 = (deadline != nil) ? min(UInt64(4_000_000), rawRemainingNs / 8) : 0
        let waitDeadline = DispatchTime(uptimeNanoseconds: hardDeadline.uptimeNanoseconds - wakeupSlackNs)
        let effectiveRemainingNs = waitDeadline.uptimeNanoseconds > now.uptimeNanoseconds
            ? (waitDeadline.uptimeNanoseconds - now.uptimeNanoseconds)
            : 0
        let teardownReserveNs = min(UInt64(50_000_000), effectiveRemainingNs / 3)
        let observeDeadline = DispatchTime(uptimeNanoseconds: waitDeadline.uptimeNanoseconds - teardownReserveNs)
        let state = ProbeState()

        let probe = SystemAudioCapture(
            onSamples: { samples, _ in
                for s in samples where abs(s) > 1e-5 {
                    state.setSignal()
                    break
                }
            },
            onLevel: { _ in },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { _ in },
            reportGlobalPermission: false
        )

        if let cancelSemaphore {
            DispatchQueue.global(qos: .userInitiated).async {
                if cancelSemaphore.wait(timeout: waitDeadline) == .success {
                    state.setCancelled()
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try probe.start(updateGlobalPermissionOnStart: false)
                let playingAtStart = Self.hasOtherProcessRunningOutput()
                state.markTapStarted(otherPlaying: playingAtStart)
                if !state.attachStartedCapture(probe) {
                    probe.stop()
                    state.notifyTeardownOnce(onTeardownComplete)
                    state.cleanupDoneSem.signal()
                }
            } catch {
                state.setStartFailed()
                state.notifyTeardownOnce(onTeardownComplete)
                state.cleanupDoneSem.signal()
            }
        }

        _ = state.finishSem.wait(timeout: observeDeadline)
        state.markDoneWaiting()

        var snapshot = state.result()
        if !snapshot.seenSignal && snapshot.tapStarted && !snapshot.cancelled && !snapshot.otherAudioPlaying {
            if Self.hasOtherProcessRunningOutput() {
                state.noteOtherAudioPlaying()
                snapshot = state.result()
            }
        }
        if let activeCap = snapshot.capture {
            DispatchQueue.global(qos: .utility).async {
                activeCap.stop()
                state.notifyTeardownOnce(onTeardownComplete)
                state.cleanupDoneSem.signal()
            }
            _ = state.cleanupDoneSem.wait(timeout: waitDeadline)
        } else if !snapshot.startFailed {
            let briefCleanup = min(waitDeadline, DispatchTime.now() + .milliseconds(35))
            _ = state.cleanupDoneSem.wait(timeout: briefCleanup)
        }

        if snapshot.startFailed { return ("tap_failed", false) }
        if snapshot.seenSignal { return ("granted", snapshot.tapStarted) }
        if snapshot.tapStarted && snapshot.otherAudioPlaying { return ("silent_or_denied", true) }
        return ("unverified", snapshot.tapStarted)
    }

    static func hasOtherProcessRunningOutput() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }

        var processIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        var actualSize = dataSize
        let listStatus: OSStatus = processIDs.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                0,
                nil,
                &actualSize,
                base
            )
        }
        guard listStatus == noErr else { return false }

        let actualCount = min(count, Int(actualSize) / MemoryLayout<AudioObjectID>.size)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for i in 0..<actualCount {
            let procObj = processIDs[i]
            guard procObj != AudioObjectID(kAudioObjectUnknown) else { continue }

            var procPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(procObj, &pidAddr, 0, nil, &pidSize, &procPID)
            if pidStatus == noErr && procPID == ownPID {
                continue
            }

            var isRunningOutput: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            let outStatus = AudioObjectGetPropertyData(procObj, &outAddr, 0, nil, &outSize, &isRunningOutput)
            if outStatus == noErr && isRunningOutput != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - CoreAudio Helpers

    private static func isBenignHALStatus(_ status: OSStatus) -> Bool {
        status == noErr ||
        status == kAudioHardwareBadObjectError ||
        status == kAudioHardwareBadDeviceError
    }

    private static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var targetPID = pid
        var processObj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &targetPID) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &processObj
            )
        }
        guard status == noErr, processObj != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return processObj
    }

    private static func readTapUID(tapID: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }

    private static func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw NSError(
                domain: "SystemAudioCapture",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "读取系统音频 Tap 流格式失败 (OSStatus=\(status))"]
            )
        }
        return asbd
    }

    private static func createTapOnlyAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let subTapConfig: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let tapOnlyConfig: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingNotesSystemAggregate",
            kAudioAggregateDeviceUIDKey: "io.github.nolinsun.meeting.agg.\(UUID().uuidString)",
            kAudioAggregateDeviceTapListKey: [subTapConfig],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(tapOnlyConfig as CFDictionary, &aggID)
        guard status == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            throw NSError(
                domain: "SystemAudioCapture",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "创建系统音频聚合设备失败 (OSStatus=\(status))"]
            )
        }
        return aggID
    }

    private static func makeAVAudioFormat(from asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        var mutable = asbd
        if let exact = AVAudioFormat(streamDescription: &mutable) {
            return exact
        }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let common: AVAudioCommonFormat? = {
            if isFloat && asbd.mBitsPerChannel == 32 { return .pcmFormatFloat32 }
            if isFloat && asbd.mBitsPerChannel == 64 { return .pcmFormatFloat64 }
            if isSignedInt && asbd.mBitsPerChannel == 16 { return .pcmFormatInt16 }
            if isSignedInt && asbd.mBitsPerChannel == 32 { return .pcmFormatInt32 }
            return nil
        }()
        guard let common else { return nil }
        return AVAudioFormat(
            commonFormat: common,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(max(1, asbd.mChannelsPerFrame)),
            interleaved: !isNonInterleaved
        )
    }

    private static func makePCMBuffer(
        from inputData: UnsafePointer<AudioBufferList>,
        asbd: AudioStreamBasicDescription,
        format: AVAudioFormat,
        bufferPool: PCMBufferPool? = nil
    ) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        guard channels > 0, asbd.mChannelsPerFrame == format.channelCount else { return nil }

        let expectedBufferCount = format.isInterleaved ? 1 : channels
        let expectedChannelsPerBuffer = UInt32(format.isInterleaved ? channels : 1)
        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        guard bytesPerSample > 0 else { return nil }
        let expectedBytesPerFrame = Int(expectedChannelsPerBuffer) * bytesPerSample
        guard asbd.mBytesPerFrame > 0, Int(asbd.mBytesPerFrame) == expectedBytesPerFrame else {
            return nil
        }

        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard srcList.count == expectedBufferCount else { return nil }

        var expectedFrames: Int? = nil
        for i in 0..<srcList.count {
            let buf = srcList[i]
            guard buf.mData != nil,
                  buf.mNumberChannels == expectedChannelsPerBuffer,
                  buf.mDataByteSize > 0,
                  Int(buf.mDataByteSize) % expectedBytesPerFrame == 0
            else {
                return nil
            }
            let framesHere = Int(buf.mDataByteSize) / expectedBytesPerFrame
            guard framesHere > 0 else { return nil }
            if let prev = expectedFrames {
                if prev != framesHere { return nil }
            } else {
                expectedFrames = framesHere
            }
        }

        guard let frameCount = expectedFrames, frameCount > 0 else { return nil }

        let pcmBuffer: AVAudioPCMBuffer
        if let pooled = bufferPool?.checkout(frameCount: AVAudioFrameCount(frameCount)) {
            pcmBuffer = pooled
        } else if let allocated = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) {
            allocated.frameLength = AVAudioFrameCount(frameCount)
            pcmBuffer = allocated
        } else {
            return nil
        }

        let dstList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard dstList.count == srcList.count else { return nil }

        for i in 0..<srcList.count {
            let srcBytes = Int(srcList[i].mDataByteSize)
            guard let sData = srcList[i].mData,
                  let dData = dstList[i].mData,
                  Int(dstList[i].mDataByteSize) >= srcBytes
            else {
                return nil
            }
            memcpy(dData, sData, srcBytes)
            dstList[i].mDataByteSize = UInt32(srcBytes)
        }
        return pcmBuffer
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var deviceID = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                0,
                nil,
                &size,
                &deviceID
            )
            if status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 {
                return deviceID
            }
        }
        return nil
    }

    static func defaultOutputDeviceName() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else {
            return nil
        }
        return cfName as String
    }

    // Verifies stereo left/right downmix, malformed/zero-stride buffer rejection, and silence/granted transitions.
    static func runConversionAndSilenceSelfTest() throws {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let mono48Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to build 48k formats"])
        }
        let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ChunkWriter.sampleRate), channels: 1, interleaved: false)!

        // 1. Reject malformed 3-buffer layout AND zero mBytesPerFrame ASBD (P0-2 regression).
        var stereoBufA = [Float](repeating: 0.1, count: 1024)
        var stereoBufB = [Float](repeating: 0.1, count: 1024)
        var extraMonoBuf = [Float](repeating: 0.2, count: 1024)
        let rawListPtr = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(rawListPtr.unsafeMutablePointer) }
        stereoBufA.withUnsafeMutableBytes { aPtr in
            stereoBufB.withUnsafeMutableBytes { bPtr in
                extraMonoBuf.withUnsafeMutableBytes { cPtr in
                    rawListPtr[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(aPtr.count), mData: aPtr.baseAddress)
                    rawListPtr[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bPtr.count), mData: bPtr.baseAddress)
                    rawListPtr[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(cPtr.count), mData: cPtr.baseAddress)
                }
            }
        }
        if makePCMBuffer(from: rawListPtr.unsafePointer, asbd: stereoFormat.streamDescription.pointee, format: stereoFormat) != nil {
            throw NSError(domain: "SystemAudioSelfTest", code: -8, userInfo: [NSLocalizedDescriptionKey: "Malformed 3-buffer layout was not rejected"])
        }

        let validListPtr = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(validListPtr.unsafeMutablePointer) }
        stereoBufA.withUnsafeMutableBytes { aPtr in
            stereoBufB.withUnsafeMutableBytes { bPtr in
                validListPtr[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(aPtr.count), mData: aPtr.baseAddress)
                validListPtr[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bPtr.count), mData: bPtr.baseAddress)
            }
        }
        var zeroStrideAsbd = stereoFormat.streamDescription.pointee
        zeroStrideAsbd.mBytesPerFrame = 0
        if makePCMBuffer(from: validListPtr.unsafePointer, asbd: zeroStrideAsbd, format: stereoFormat) != nil {
            throw NSError(domain: "SystemAudioSelfTest", code: -10, userInfo: [NSLocalizedDescriptionKey: "Zero mBytesPerFrame ASBD was not rejected"])
        }

        // 2. Right-only and Left-only stereo 48kHz -> 16kHz mono downmix preservation (P1-6).
        for activeChannel in [0, 1] {
            guard let conv = AVAudioConverter(from: mono48Format, to: dstFormat) else {
                throw NSError(domain: "SystemAudioSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter"])
            }
            final class ChannelBox: @unchecked Sendable {
                private let lock = NSLock()
                var samples: [Float] = []
                func add(_ s: [Float]) { lock.withLock { samples.append(contentsOf: s) } }
                func all() -> [Float] { lock.withLock { samples } }
            }
            let box = ChannelBox()
            let cap = SystemAudioCapture(
                onSamples: { samples, _ in box.add(samples) },
                onLevel: { _ in },
                onGap: { _, _, _ in },
                onError: { _ in },
                onFatalError: { _ in },
                onOutputDeviceChanged: { _ in },
                onSystemAudioStatusChanged: { _ in }
            )
            let gen = TapGenerationContext(id: 1, converter: conv, monoSourceFormat: mono48Format, sourceFormat: stereoFormat, sourceASBD: stereoFormat.streamDescription.pointee)
            for b in 0..<10 {
                guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800) else {
                    throw NSError(domain: "SystemAudioSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
                }
                buf.frameLength = 4800
                memset(buf.floatChannelData![0], 0, 4800 * MemoryLayout<Float>.size)
                memset(buf.floatChannelData![1], 0, 4800 * MemoryLayout<Float>.size)
                let ptr = buf.floatChannelData![activeChannel]
                for j in 0..<4800 {
                    let t = Double(b * 4800 + j) / 48_000.0
                    ptr[j] = 0.5 * Float(sin(2.0 * .pi * 660.0 * t))
                }
                cap.enqueueInputBuffer(buf, generation: gen, hostTimeNs: UInt64(b) * 100_000_000, captureUptime: 0)
            }
            cap.enqueueFlushGeneration(gen)
            cap.processingQueue.sync { cap.drainQueue() }
            let out = box.all()
            let rms = sqrt(out.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, out.count)))
            guard rms > 0.08 else {
                throw NSError(
                    domain: "SystemAudioSelfTest",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "Stereo channel \(activeChannel) lost during downmix (rms=\(rms))"]
                )
            }
        }

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var samples: [Float] = []
            var statuses: [String] = []
            func appendSamples(_ s: [Float]) { lock.withLock { samples.append(contentsOf: s) } }
            func appendStatus(_ st: String) { lock.withLock { statuses.append(st) } }
            func snapshot() -> ([Float], [String]) { lock.withLock { (samples, statuses) } }
        }

        // 3a. Quiet 3.5s silence when no other process outputs audio stays silent-free (never false-warns silent_or_denied).
        guard let convQuiet = AVAudioConverter(from: mono48Format, to: dstFormat) else {
            throw NSError(domain: "SystemAudioSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create quiet converter"])
        }
        let quietCollector = Collector()
        let quietCapture = SystemAudioCapture(
            onSamples: { samples, _ in quietCollector.appendSamples(samples) },
            onLevel: { _ in },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { quietCollector.appendStatus($0) },
            reportGlobalPermission: false,
            hasOtherAudioOutput: { false }
        )
        let quietGen = TapGenerationContext(
            id: 1,
            converter: convQuiet,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        quietCapture.queueLock.withLock {
            quietCapture.currentActiveGenerationId = quietGen.id
        }
        let framesPerBuf = 4800
        for b in 0..<35 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(framesPerBuf)) else {
                throw NSError(domain: "SystemAudioSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
            }
            buf.frameLength = AVAudioFrameCount(framesPerBuf)
            for ch in 0..<2 {
                memset(buf.floatChannelData![ch], 0, framesPerBuf * MemoryLayout<Float>.size)
            }
            quietCapture.enqueueInputBuffer(buf, generation: quietGen, hostTimeNs: UInt64(b) * 100_000_000, captureUptime: Double(b) * 0.1)
        }
        quietCapture.processingQueue.sync { quietCapture.drainQueue() }
        let (_, quietStatuses) = quietCollector.snapshot()
        guard !quietStatuses.contains("silent_or_denied") else {
            throw NSError(
                domain: "SystemAudioSelfTest",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: "Quiet 3.5s buffers falsely triggered silent_or_denied: \(quietStatuses)"]
            )
        }

        // 3b. 3.5s silence while another process IS outputting audio -> "silent_or_denied", followed by signal -> "granted".
        guard let conv = AVAudioConverter(from: mono48Format, to: dstFormat) else {
            throw NSError(domain: "SystemAudioSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter"])
        }

        let collector = Collector()
        let capture = SystemAudioCapture(
            onSamples: { samples, _ in collector.appendSamples(samples) },
            onLevel: { _ in },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { collector.appendStatus($0) },
            reportGlobalPermission: false,
            hasOtherAudioOutput: { true }
        )

        let gen = TapGenerationContext(
            id: 1,
            converter: conv,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        capture.queueLock.withLock {
            capture.currentActiveGenerationId = gen.id
        }

        for b in 0..<35 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(framesPerBuf)) else {
                throw NSError(domain: "SystemAudioSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
            }
            buf.frameLength = AVAudioFrameCount(framesPerBuf)
            for ch in 0..<2 {
                memset(buf.floatChannelData![ch], 0, framesPerBuf * MemoryLayout<Float>.size)
            }
            capture.enqueueInputBuffer(buf, generation: gen, hostTimeNs: UInt64(b) * 100_000_000, captureUptime: Double(b) * 0.1)
        }
        capture.processingQueue.sync { capture.drainQueue() }

        let (_, statusesAfterSilence) = collector.snapshot()
        guard statusesAfterSilence.contains("silent_or_denied") else {
            throw NSError(
                domain: "SystemAudioSelfTest",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "3.5s zero buffers failed to trigger silent_or_denied: \(statusesAfterSilence)"]
            )
        }

        for b in 0..<10 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(framesPerBuf)) else {
                throw NSError(domain: "SystemAudioSelfTest", code: -5, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
            }
            buf.frameLength = AVAudioFrameCount(framesPerBuf)
            let left = buf.floatChannelData![0]
            let right = buf.floatChannelData![1]
            for j in 0..<framesPerBuf {
                let sampleIdx = b * framesPerBuf + j
                let t = Double(sampleIdx) / 48_000.0
                let v = 0.25 * Float(sin(2.0 * .pi * 660.0 * t))
                left[j] = v
                right[j] = v
            }
            capture.enqueueInputBuffer(buf, generation: gen, hostTimeNs: UInt64(35 + b) * 100_000_000, captureUptime: Double(35 + b) * 0.1)
        }
        capture.enqueueFlushGeneration(gen)
        capture.processingQueue.sync { capture.drainQueue() }

        let (allSamples, allStatuses) = collector.snapshot()
        guard allStatuses.last == "granted" else {
            throw NSError(
                domain: "SystemAudioSelfTest",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Non-zero audio did not transition to granted: \(allStatuses)"]
            )
        }
        guard allSamples.count >= 71_500 && allSamples.count <= 72_500 else {
            throw NSError(
                domain: "SystemAudioSelfTest",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected 48k stereo -> 16k mono frame count: \(allSamples.count)"]
            )
        }

        // 3c. Transition back to "unverified" when quiet stream closes or capture stops cleanly without signal.
        final class OutputToggleBox: @unchecked Sendable {
            private let lock = NSLock()
            var active = true
            func set(_ v: Bool) { lock.withLock { active = v } }
            func get() -> Bool { lock.withLock { active } }
        }
        let toggleBox = OutputToggleBox()
        let toggleCollector = Collector()
        guard let conv3c = AVAudioConverter(from: mono48Format, to: dstFormat) else {
            throw NSError(domain: "SystemAudioSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter 3c"])
        }
        let toggleCap = SystemAudioCapture(
            onSamples: { _, _ in },
            onLevel: { _ in },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { toggleCollector.appendStatus($0) },
            reportGlobalPermission: false,
            hasOtherAudioOutput: { toggleBox.get() }
        )
        let gen3c = TapGenerationContext(
            id: 1,
            converter: conv3c,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        toggleCap.queueLock.withLock {
            toggleCap.currentActiveGenerationId = gen3c.id
        }
        for b in 0..<35 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(framesPerBuf)) else {
                throw NSError(domain: "SystemAudioSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
            }
            buf.frameLength = AVAudioFrameCount(framesPerBuf)
            for ch in 0..<2 { memset(buf.floatChannelData![ch], 0, framesPerBuf * MemoryLayout<Float>.size) }
            toggleCap.enqueueInputBuffer(buf, generation: gen3c, hostTimeNs: UInt64(b) * 100_000_000, captureUptime: Double(b) * 0.1)
        }
        toggleCap.processingQueue.sync { toggleCap.drainQueue() }
        toggleBox.set(false)
        for b in 35..<42 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(framesPerBuf)) else {
                throw NSError(domain: "SystemAudioSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
            }
            buf.frameLength = AVAudioFrameCount(framesPerBuf)
            for ch in 0..<2 { memset(buf.floatChannelData![ch], 0, framesPerBuf * MemoryLayout<Float>.size) }
            toggleCap.enqueueInputBuffer(buf, generation: gen3c, hostTimeNs: UInt64(b) * 100_000_000, captureUptime: Double(b) * 0.1)
        }
        toggleCap.processingQueue.sync { toggleCap.drainQueue() }
        let (_, toggleStatuses) = toggleCollector.snapshot()
        guard toggleStatuses == ["silent_or_denied", "unverified"] else {
            throw NSError(
                domain: "SystemAudioSelfTest",
                code: -41,
                userInfo: [NSLocalizedDescriptionKey: "Expected silent_or_denied -> unverified reset when stream stops, got \(toggleStatuses)"]
            )
        }

        // 4. Stale generation must NOT close active outage or prevent stop() stall detection (P1-3).
        final class OutageCollector: @unchecked Sendable {
            private let lock = NSLock()
            var gaps: [(Double, Double, String)] = []
            var fatals: [String] = []
            var statuses: [String] = []
            var drainedSamples = 0
            var barrierTimedOut = false
            func addGap(_ s: Double, _ e: Double, _ r: String) { lock.withLock { gaps.append((s, e, r)) } }
            func addFatal(_ msg: String) { lock.withLock { fatals.append(msg) } }
            func addStatus(_ st: String) { lock.withLock { statuses.append(st) } }
            func addSamples(_ count: Int) { lock.withLock { drainedSamples += count } }
            func markBarrierTimedOut() { lock.withLock { barrierTimedOut = true } }
            func isBarrierTimedOut() -> Bool { lock.withLock { barrierTimedOut } }
            func drainedCount() -> Int { lock.withLock { drainedSamples } }
            func snapshot() -> ([(Double, Double, String)], [String], [String]) {
                lock.withLock { (gaps, fatals, statuses) }
            }
        }

        let outageBox = OutageCollector()
        let outageCap = SystemAudioCapture(
            onSamples: { _, _ in },
            onLevel: { _ in },
            onGap: { s, e, r in outageBox.addGap(s, e, r) },
            onError: { _ in },
            onFatalError: { outageBox.addFatal($0) },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { outageBox.addStatus($0) },
            reportGlobalPermission: false
        )
        guard let convOld = AVAudioConverter(from: mono48Format, to: dstFormat),
              let convNew = AVAudioConverter(from: mono48Format, to: dstFormat),
              let staleBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800),
              let liveBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800)
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -10, userInfo: [NSLocalizedDescriptionKey: "Outage self-test alloc failed"])
        }
        staleBuf.frameLength = 4800
        liveBuf.frameLength = 4800
        for ch in 0..<2 {
            memset(staleBuf.floatChannelData![ch], 0, 4800 * MemoryLayout<Float>.size)
            memset(liveBuf.floatChannelData![ch], 0, 4800 * MemoryLayout<Float>.size)
        }
        let staleGen = TapGenerationContext(
            id: 1,
            converter: convOld,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        let activeGen = TapGenerationContext(
            id: 2,
            converter: convNew,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        outageCap.queueLock.withLock {
            outageCap.currentActiveGenerationId = 2
            outageCap.activeOutageStartUptime = 100.0
            outageCap.activeOutageReason = "output_device_changed"
            outageCap.lastUsableBufferUptime = 100.0
        }
        outageCap.enqueueInputBuffer(staleBuf, generation: staleGen, hostTimeNs: 0, captureUptime: 100.1)
        outageCap.processingQueue.sync { outageCap.drainQueue() }
        let (gapsAfterStale, _, _) = outageBox.snapshot()
        guard gapsAfterStale.isEmpty,
              outageCap.queueLock.withLock({ outageCap.activeOutageStartUptime != nil && outageCap.lastUsableBufferUptime == 100.0 })
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -11, userInfo: [NSLocalizedDescriptionKey: "Stale generation falsely closed outage or advanced heartbeat"])
        }

        // Now active generation buffer DOES close the open outage and advances lastUsableBufferUptime.
        outageCap.enqueueInputBuffer(liveBuf, generation: activeGen, hostTimeNs: 0, captureUptime: 100.5)
        outageCap.processingQueue.sync { outageCap.drainQueue() }
        let (gapsAfterActive, _, _) = outageBox.snapshot()
        guard gapsAfterActive.count == 1,
              gapsAfterActive[0].2 == "output_device_changed",
              outageCap.queueLock.withLock({ outageCap.activeOutageStartUptime == nil })
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -12, userInfo: [NSLocalizedDescriptionKey: "Active generation failed to close open outage"])
        }

        // 5. Silent callback halt (>= 2.0s before 4s watchdog fires) emits system_audio_stalled on stop().
        let stallBox = OutageCollector()
        let stallCap = SystemAudioCapture(
            onSamples: { _, _ in },
            onLevel: { _ in },
            onGap: { s, e, r in stallBox.addGap(s, e, r) },
            onError: { _ in },
            onFatalError: { stallBox.addFatal($0) },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { stallBox.addStatus($0) },
            reportGlobalPermission: false
        )
        let oldUptime = max(0.0, ProcessInfo.processInfo.systemUptime - 2.4)
        stallCap.lifecycleQueue.sync {
            stallCap.hasStartedTapOnce = true
            stallCap.queueLock.withLock {
                stallCap.lastUsableBufferUptime = oldUptime
            }
        }
        stallCap.stop()
        let (stallGaps, stallFatals, stallStatuses) = stallBox.snapshot()
        guard stallGaps.contains(where: { $0.2 == "system_audio_stalled" && ($0.1 - $0.0) >= 2.0 }),
              stallFatals.count == 1,
              stallStatuses.last == "tap_failed"
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -13, userInfo: [NSLocalizedDescriptionKey: "stop() failed to flag >= 2.0s callback stall"])
        }

        // 6. Session-epoch protection rejects stale permission updates and releases cleanly.
        let savedPerm = PermissionChecker.systemAudioStatus()
        defer { PermissionChecker.updateSystemAudioStatus(savedPerm) }
        PermissionChecker.updateSystemAudioStatus("unverified")
        guard let epoch1 = PermissionChecker.acquireExclusiveTapForDualSession(timeoutMs: 50) else {
            throw NSError(domain: "SystemAudioSelfTest", code: -14, userInfo: [NSLocalizedDescriptionKey: "Failed to acquire initial tap epoch"])
        }
        PermissionChecker.updateSystemAudioStatus("granted", expectedEpoch: epoch1)
        // Re-acquiring while epoch1 is active must return nil; after release, epoch2 succeeds.
        guard PermissionChecker.acquireExclusiveTapForDualSession(timeoutMs: 20) == nil else {
            PermissionChecker.releaseExclusiveTapForDualSession(epoch: epoch1)
            throw NSError(domain: "SystemAudioSelfTest", code: -15, userInfo: [NSLocalizedDescriptionKey: "Allowed second dual acquisition before epoch1 released"])
        }
        PermissionChecker.releaseExclusiveTapForDualSession(epoch: epoch1)
        guard let epoch2 = PermissionChecker.acquireExclusiveTapForDualSession(timeoutMs: 50) else {
            throw NSError(domain: "SystemAudioSelfTest", code: -16, userInfo: [NSLocalizedDescriptionKey: "Failed to acquire epoch2 after epoch1 released"])
        }
        defer { PermissionChecker.releaseExclusiveTapForDualSession(epoch: epoch2) }
        PermissionChecker.updateSystemAudioStatus("tap_failed", expectedEpoch: epoch1) // Stale epoch must be ignored
        guard epoch2 != epoch1, PermissionChecker.systemAudioStatus() == "granted" else {
            throw NSError(domain: "SystemAudioSelfTest", code: -17, userInfo: [NSLocalizedDescriptionKey: "Stale session epoch overwrote permission status"])
        }

        // 7. Delayed 2.5s-old 40ms active-generation packet must NOT mask a >=2s stall on stop() (P1-3).
        let delayedBox = OutageCollector()
        let delayedCap = SystemAudioCapture(
            onSamples: { _, _ in },
            onLevel: { _ in },
            onGap: { s, e, r in delayedBox.addGap(s, e, r) },
            onError: { _ in },
            onFatalError: { delayedBox.addFatal($0) },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { delayedBox.addStatus($0) },
            reportGlobalPermission: false
        )
        guard let delayedConv = AVAudioConverter(from: mono48Format, to: dstFormat),
              let delayedBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 1920)
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -18, userInfo: [NSLocalizedDescriptionKey: "Delayed packet alloc failed"])
        }
        delayedBuf.frameLength = 1920 // 40ms @ 48kHz
        for ch in 0..<2 {
            memset(delayedBuf.floatChannelData![ch], 0, 1920 * MemoryLayout<Float>.size)
        }
        let delayedGen = TapGenerationContext(
            id: 7,
            converter: delayedConv,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        let nowRef = ProcessInfo.processInfo.systemUptime
        delayedCap.lifecycleQueue.sync {
            delayedCap.hasStartedTapOnce = true
            delayedCap.activeGeneration = delayedGen
            delayedCap.queueLock.withLock {
                delayedCap.currentActiveGenerationId = 7
                delayedCap.lastUsableBufferUptime = max(0.0, nowRef - 2.6)
            }
        }
        delayedCap.enqueueInputBuffer(delayedBuf, generation: delayedGen, hostTimeNs: 0, captureUptime: max(0.0, nowRef - 2.5))
        delayedCap.stop()
        let (delayedGaps, delayedFatals, delayedStatuses) = delayedBox.snapshot()
        guard delayedGaps.contains(where: { $0.2 == "system_audio_stalled" && ($0.1 - $0.0) >= 2.0 }),
              delayedFatals.count == 1,
              delayedStatuses.last == "tap_failed"
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -19, userInfo: [NSLocalizedDescriptionKey: "Delayed old 40ms packet masked >=2s stall on stop()"])
        }

        // 8. Stale generation non-zero audio after exhaustion/teardown drains PCM but NEVER flips tap_failed -> granted.
        final class PCMCollector: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func add(_ n: Int) { lock.withLock { count += n } }
            func total() -> Int { lock.withLock { count } }
        }
        let staleBox = OutageCollector()
        let stalePCM = PCMCollector()
        let stalePermCap = SystemAudioCapture(
            onSamples: { samples, _ in stalePCM.add(samples.count) },
            onLevel: { _ in },
            onGap: { s, e, r in staleBox.addGap(s, e, r) },
            onError: { _ in },
            onFatalError: { staleBox.addFatal($0) },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { staleBox.addStatus($0) },
            reportGlobalPermission: false
        )
        guard let convStalePerm = AVAudioConverter(from: mono48Format, to: dstFormat),
              let loudBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800)
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -20, userInfo: [NSLocalizedDescriptionKey: "Stale perm alloc failed"])
        }
        loudBuf.frameLength = 4800
        for j in 0..<4800 {
            let v = 0.5 * Float(sin(2.0 * .pi * 440.0 * Double(j) / 48_000.0))
            loudBuf.floatChannelData![0][j] = v
            loudBuf.floatChannelData![1][j] = v
        }
        let oldGenPerm = TapGenerationContext(
            id: 1,
            converter: convStalePerm,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        stalePermCap.queueLock.withLock {
            stalePermCap.currentActiveGenerationId = 0
        }
        stalePermCap.enqueueInputBuffer(loudBuf, generation: oldGenPerm, hostTimeNs: 0, captureUptime: 50.0)
        stalePermCap.enqueueFlushGeneration(oldGenPerm)
        stalePermCap.processingQueue.sync { stalePermCap.drainQueue() }
        let (_, _, staleStatuses) = staleBox.snapshot()
        guard stalePCM.total() >= 1500, !staleStatuses.contains("granted") else {
            throw NSError(domain: "SystemAudioSelfTest", code: -21, userInfo: [NSLocalizedDescriptionKey: "Stale generation audio falsely published granted or lost PCM: pcm=\(stalePCM.total()) statuses=\(staleStatuses)"])
        }

        // 9. In-flight audio whose generation exhausts WHILE onSamples runs must NOT publish level or revert tap_failed -> granted.
        final class Test9Hooks: @unchecked Sendable {
            private let lock = NSLock()
            let enteredSamples = DispatchSemaphore(value: 0)
            let resumeSamples = DispatchSemaphore(value: 0)
            var maxNonZeroLevel = 0.0
            var statuses: [String] = []
            func recordLevel(_ lv: Double) { lock.withLock { if lv > maxNonZeroLevel { maxNonZeroLevel = lv } } }
            func addStatus(_ s: String) { lock.withLock { statuses.append(s) } }
            func snapshot() -> (Double, [String]) { lock.withLock { (maxNonZeroLevel, statuses) } }
        }
        let hooks9 = Test9Hooks()
        let inflightCap = SystemAudioCapture(
            onSamples: { _, _ in
                hooks9.enteredSamples.signal()
                _ = hooks9.resumeSamples.wait(timeout: .now() + .seconds(2))
            },
            onLevel: { hooks9.recordLevel($0) },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { hooks9.addStatus($0) },
            reportGlobalPermission: false
        )
        guard let conv9 = AVAudioConverter(from: mono48Format, to: dstFormat),
              let loudBuf9 = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800)
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -22, userInfo: [NSLocalizedDescriptionKey: "Test 9 conv alloc failed"])
        }
        loudBuf9.frameLength = 4800
        for j in 0..<4800 {
            let v = 0.5 * Float(sin(2.0 * .pi * 440.0 * Double(j) / 48_000.0))
            loudBuf9.floatChannelData![0][j] = v
            loudBuf9.floatChannelData![1][j] = v
        }
        let gen9 = TapGenerationContext(
            id: 9,
            converter: conv9,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        inflightCap.queueLock.withLock {
            inflightCap.currentActiveGenerationId = 9
            inflightCap.lastUsableBufferUptime = ProcessInfo.processInfo.systemUptime
        }
        inflightCap.enqueueInputBuffer(loudBuf9, generation: gen9, hostTimeNs: 0, captureUptime: ProcessInfo.processInfo.systemUptime)
        guard hooks9.enteredSamples.wait(timeout: .now() + .seconds(2)) == .success else {
            throw NSError(domain: "SystemAudioSelfTest", code: -23, userInfo: [NSLocalizedDescriptionKey: "Test 9 did not reach onSamples"])
        }
        inflightCap.statusPublishLock.withLock {
            inflightCap.queueLock.withLock {
                inflightCap.currentActiveGenerationId = 0
                inflightCap.exhaustedFatalReported = true
            }
            inflightCap.publishSystemAudioStatus("tap_failed")
        }
        hooks9.resumeSamples.signal()
        inflightCap.processingQueue.sync {}
        let (lvl9, st9) = hooks9.snapshot()
        guard lvl9 == 0.0, st9.last == "tap_failed", !st9.contains("granted") else {
            throw NSError(domain: "SystemAudioSelfTest", code: -24, userInfo: [NSLocalizedDescriptionKey: "In-flight exhaustion reverted status or emitted level: lvl=\(lvl9) st=\(st9)"])
        }

        // 10. Buffer captured AFTER stop() entry must NOT advance heartbeat past stopCutoffUptime or hide pre-stop stall.
        let postStopBox = OutageCollector()
        let postStopCap = SystemAudioCapture(
            onSamples: { samples, _ in postStopBox.addSamples(samples.count) },
            onLevel: { _ in },
            onGap: { s, e, r in postStopBox.addGap(s, e, r) },
            onError: { _ in },
            onFatalError: { postStopBox.addFatal($0) },
            onOutputDeviceChanged: { _ in },
            onSystemAudioStatusChanged: { postStopBox.addStatus($0) },
            reportGlobalPermission: false
        )
        guard let conv10 = AVAudioConverter(from: mono48Format, to: dstFormat),
              let loudBuf10 = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800)
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -25, userInfo: [NSLocalizedDescriptionKey: "Test 10 conv alloc failed"])
        }
        loudBuf10.frameLength = 4800
        for j in 0..<4800 {
            let v = 0.5 * Float(sin(2.0 * .pi * 440.0 * Double(j) / 48_000.0))
            loudBuf10.floatChannelData![0][j] = v
            loudBuf10.floatChannelData![1][j] = v
        }
        let gen10 = TapGenerationContext(
            id: 10,
            converter: conv10,
            monoSourceFormat: mono48Format,
            sourceFormat: stereoFormat,
            sourceASBD: stereoFormat.streamDescription.pointee
        )
        let ref10 = ProcessInfo.processInfo.systemUptime
        postStopCap.lifecycleQueue.sync {
            postStopCap.hasStartedTapOnce = true
            postStopCap.activeGeneration = gen10
            postStopCap.queueLock.withLock {
                postStopCap.currentActiveGenerationId = 10
                postStopCap.lastUsableBufferUptime = max(0.0, ref10 - 2.35)
            }
        }
        // Deterministic Case 10: pause processingQueue until stop() atomically installs stopCutoffUptime,
        // verify generation 10 is still active before enqueueing post-cutoff buffer, then release.
        let enteredBarrier10 = DispatchSemaphore(value: 0)
        let releaseBarrier10 = DispatchSemaphore(value: 0)
        postStopCap.processingQueue.async {
            enteredBarrier10.signal()
            if releaseBarrier10.wait(timeout: .now() + .seconds(10)) != .success {
                postStopBox.markBarrierTimedOut()
            }
        }
        guard enteredBarrier10.wait(timeout: .now() + .seconds(2)) == .success else {
            throw NSError(domain: "SystemAudioSelfTest", code: -27, userInfo: [NSLocalizedDescriptionKey: "Test 10 barrier failed"])
        }
        let stopDone10 = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            postStopCap.stop()
            stopDone10.signal()
        }
        var cutoffRef10: Double? = nil
        let spinLimit10 = DispatchTime.now() + .seconds(5)
        while DispatchTime.now() < spinLimit10 {
            cutoffRef10 = postStopCap.queueLock.withLock { postStopCap.stopCutoffUptime }
            if cutoffRef10 != nil { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard let cutoff10 = cutoffRef10 else {
            releaseBarrier10.signal()
            throw NSError(domain: "SystemAudioSelfTest", code: -28, userInfo: [NSLocalizedDescriptionKey: "stop() did not install stopCutoffUptime"])
        }
        let (genBeforeEnqueue10, cutoffBeforeEnqueue10) = postStopCap.queueLock.withLock {
            (postStopCap.currentActiveGenerationId, postStopCap.stopCutoffUptime)
        }
        guard !postStopBox.isBarrierTimedOut(),
              genBeforeEnqueue10 == 10,
              cutoffBeforeEnqueue10 == cutoff10
        else {
            releaseBarrier10.signal()
            throw NSError(domain: "SystemAudioSelfTest", code: -30, userInfo: [NSLocalizedDescriptionKey: "Test 10 barrier expired or generation cleared before post-stop enqueue"])
        }
        postStopCap.enqueueInputBuffer(loudBuf10, generation: gen10, hostTimeNs: 0, captureUptime: cutoff10 + 0.07)
        releaseBarrier10.signal()
        guard stopDone10.wait(timeout: .now() + .seconds(10)) == .success else {
            throw NSError(domain: "SystemAudioSelfTest", code: -29, userInfo: [NSLocalizedDescriptionKey: "Test 10 stop() timed out"])
        }
        let (gaps10, fatals10, st10) = postStopBox.snapshot()
        guard !postStopBox.isBarrierTimedOut(),
              postStopBox.drainedCount() > 0,
              gaps10.contains(where: { $0.2 == "system_audio_stalled" && ($0.1 - $0.0) >= 2.0 }),
              fatals10.count == 1,
              st10.last == "tap_failed"
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -26, userInfo: [NSLocalizedDescriptionKey: "Post-stop buffer masked pre-stop 2.35s stall or failed drain: barrierTimeout=\(postStopBox.isBarrierTimedOut()) drained=\(postStopBox.drainedCount()) gaps=\(gaps10) fatals=\(fatals10)"])
        }

        // 11. Already-expired probePermission deadline must return "unverified" immediately and invoke teardown once.
        final class Counter11: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func inc() { lock.withLock { count += 1 } }
            func get() -> Int { lock.withLock { count } }
        }
        let teardownCount11 = Counter11()
        let t0Expired = DispatchTime.now()
        let expiredRes11 = SystemAudioCapture.probePermission(
            deadline: t0Expired,
            onTeardownComplete: { teardownCount11.inc() }
        )
        let elapsedExpiredNs = DispatchTime.now().uptimeNanoseconds &- t0Expired.uptimeNanoseconds
        guard expiredRes11 == "unverified",
              teardownCount11.get() == 1,
              elapsedExpiredNs < 25_000_000
        else {
            throw NSError(domain: "SystemAudioSelfTest", code: -31, userInfo: [NSLocalizedDescriptionKey: "Expired probePermission failed: res=\(expiredRes11) teardown=\(teardownCount11.get()) ns=\(elapsedExpiredNs)"])
        }
    }
}
