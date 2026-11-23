import Foundation

struct TrackWindowStats: Sendable {
    let startSample: Int64
    let endSample: Int64
    let micMeanSquare: Double
    let remoteMeanSquare: Double
    let micDb: Double
    let remoteDb: Double
    let absCorrelation: Double
}

final class SpeakerWindowAccumulator: @unchecked Sendable {
    static let windowSampleCount = 4000 // 250ms @ 16kHz
    static let minTrailingSamples = 800 // 50ms unvoiced tail threshold

    private var baseStartSample: Int64 = 0
    private var currentSampleCount: Int = 0
    private var micSumSquares: Double = 0
    private var remoteSumSquares: Double = 0
    private var crossSumProduct: Double = 0
    private var winMic: [Float] = []
    private var winRemote: [Float] = []
    private var completedWindows: [TrackWindowStats] = []

    func reset(chunkAudioStartSample: Int64) {
        baseStartSample = chunkAudioStartSample
        currentSampleCount = 0
        micSumSquares = 0
        remoteSumSquares = 0
        crossSumProduct = 0
        winMic.removeAll(keepingCapacity: true)
        winRemote.removeAll(keepingCapacity: true)
        completedWindows.removeAll(keepingCapacity: true)
    }

    func append(mic: [Float], remote: [Float]) {
        let count = min(mic.count, remote.count)
        guard count > 0 else { return }

        var i = 0
        while i < count {
            let need = Self.windowSampleCount - currentSampleCount
            let take = min(need, count - i)
            for j in 0..<take {
                let mf = mic[i + j]
                let rf = remote[i + j]
                let m = Double(mf)
                let r = Double(rf)
                micSumSquares += m * m
                remoteSumSquares += r * r
                crossSumProduct += m * r
                winMic.append(mf)
                winRemote.append(rf)
            }
            currentSampleCount += take
            i += take

            if currentSampleCount >= Self.windowSampleCount {
                flushWindow()
            }
        }
    }

    func finishChunkWindows() -> [TrackWindowStats] {
        if currentSampleCount >= Self.minTrailingSamples {
            flushWindow()
        } else if currentSampleCount > 0 {
            let count = Double(currentSampleCount)
            let micMS = micSumSquares / count
            let remoteMS = remoteSumSquares / count
            let micDb = Self.round1(10.0 * log10(max(micMS, 1e-12)))
            let remoteDb = Self.round1(10.0 * log10(max(remoteMS, 1e-12)))
            let corr = computeWindowCorrelation(micDb: micDb, remoteDb: remoteDb)
            if SpeakerTimelineBuilder.classifyWindow(micDb: micDb, remoteDb: remoteDb, absCorrelation: corr) != nil {
                flushWindow()
            } else {
                currentSampleCount = 0
                micSumSquares = 0
                remoteSumSquares = 0
                crossSumProduct = 0
                winMic.removeAll(keepingCapacity: true)
                winRemote.removeAll(keepingCapacity: true)
            }
        }
        return completedWindows
    }

    private func computeWindowCorrelation(micDb: Double, remoteDb: Double) -> Double {
        let denom = sqrt(max(1e-18, micSumSquares * remoteSumSquares))
        var best = min(1.0, abs(crossSumProduct) / denom)
        // Require at least 75% overlap (maxLag <= window/4) so short tail windows don't collapse to 1-sample correlation = 1.0 (P2-2).
        let maxLag = min(128, currentSampleCount / 4)
        guard best <= 0.25,
              micDb > SpeakerTimelineBuilder.micActiveThresholdDb,
              remoteDb > -28.0,
              micDb < remoteDb - 18.0,
              winMic.count == currentSampleCount,
              winRemote.count == currentSampleCount,
              maxLag >= 1
        else {
            return best
        }

        let total = currentSampleCount
        for lag in -maxLag...maxLag where lag != 0 {
            let startM = lag > 0 ? lag : 0
            let startR = lag > 0 ? 0 : -lag
            let overlap = total - abs(lag)
            var dot: Double = 0
            var subMicSq: Double = 0
            var subRemSq: Double = 0
            for k in 0..<overlap {
                let m = Double(winMic[startM + k])
                let r = Double(winRemote[startR + k])
                dot += m * r
                subMicSq += m * m
                subRemSq += r * r
            }
            let subDenom = sqrt(max(1e-18, subMicSq * subRemSq))
            let corr = min(1.0, abs(dot) / subDenom)
            if corr > best {
                best = corr
                if best > 0.6 { break }
            }
        }
        return best
    }

    private func flushWindow() {
        let count = Double(max(1, currentSampleCount))
        let start = baseStartSample
        let end = start + Int64(max(1, currentSampleCount))
        let micMS = micSumSquares / count
        let remoteMS = remoteSumSquares / count
        let micDb = Self.round1(10.0 * log10(max(micMS, 1e-12)))
        let remoteDb = Self.round1(10.0 * log10(max(remoteMS, 1e-12)))
        let corr = computeWindowCorrelation(micDb: micDb, remoteDb: remoteDb)

        completedWindows.append(
            TrackWindowStats(
                startSample: start,
                endSample: end,
                micMeanSquare: micMS,
                remoteMeanSquare: remoteMS,
                micDb: micDb,
                remoteDb: remoteDb,
                absCorrelation: corr
            )
        )

        baseStartSample = end
        currentSampleCount = 0
        micSumSquares = 0
        remoteSumSquares = 0
        crossSumProduct = 0
        winMic.removeAll(keepingCapacity: true)
        winRemote.removeAll(keepingCapacity: true)
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }
}

enum SpeakerTimelineBuilder {
    static let micActiveThresholdDb = -42.0
    static let remoteActiveThresholdDb = -45.0

    static func classifyWindow(micDb: Double, remoteDb: Double, absCorrelation: Double = 1.0) -> String? {
        let micActive = micDb > micActiveThresholdDb
        let remoteActive = remoteDb > remoteActiveThresholdDb

        if micActive && remoteActive {
            // Disambiguate correlated acoustic speaker echo from independent simultaneous voices (P2-2).
            if remoteDb > -28.0 && micDb < remoteDb - 18.0 && absCorrelation > 0.25 {
                return "remote"
            }
            return "both"
        }
        if micActive { return "me" }
        if remoteActive { return "remote" }
        return nil
    }

    static func buildChunkTimeline(
        chunkId: String,
        chunkIndex: Int,
        audioRangeSec: [Double],
        responsibleRangeSec: [Double],
        windows: [TrackWindowStats],
        sampleRate: Int64 = ChunkWriter.sampleRate
    ) -> ChunkTimeline {
        struct SegmentAccumulator {
            var startSec: Double
            var endSec: Double
            var speaker: String
            var micEnergyDurSum: Double
            var remoteEnergyDurSum: Double
            var totalDur: Double
        }

        var rawSegments: [SegmentAccumulator] = []

        for win in windows {
            guard let label = classifyWindow(micDb: win.micDb, remoteDb: win.remoteDb, absCorrelation: win.absCorrelation) else {
                continue
            }
            let startSec = roundSec(Double(win.startSample) / Double(sampleRate))
            let endSec = roundSec(Double(win.endSample) / Double(sampleRate))
            let dur = Double(max(1, win.endSample - win.startSample)) / Double(sampleRate)

            if let lastIdx = rawSegments.indices.last,
               rawSegments[lastIdx].speaker == label,
               abs(rawSegments[lastIdx].endSec - startSec) <= 0.05
            {
                rawSegments[lastIdx].endSec = endSec
                rawSegments[lastIdx].micEnergyDurSum += win.micMeanSquare * dur
                rawSegments[lastIdx].remoteEnergyDurSum += win.remoteMeanSquare * dur
                rawSegments[lastIdx].totalDur += dur
            } else {
                rawSegments.append(
                    SegmentAccumulator(
                        startSec: startSec,
                        endSec: endSec,
                        speaker: label,
                        micEnergyDurSum: win.micMeanSquare * dur,
                        remoteEnergyDurSum: win.remoteMeanSquare * dur,
                        totalDur: dur
                    )
                )
            }
        }

        // Convert accumulated linear energy to dB and round ONCE per output segment (P2-2).
        let segments = rawSegments.map { acc in
            let avgMicMS = acc.micEnergyDurSum / max(1e-6, acc.totalDur)
            let avgRemoteMS = acc.remoteEnergyDurSum / max(1e-6, acc.totalDur)
            return SpeakerSegment(
                startSec: acc.startSec,
                endSec: acc.endSec,
                speaker: acc.speaker,
                micDb: round1(10.0 * log10(max(avgMicMS, 1e-12))),
                remoteDb: round1(10.0 * log10(max(avgRemoteMS, 1e-12)))
            )
        }

        return ChunkTimeline(
            schemaVersion: 1,
            chunkId: chunkId,
            chunkIndex: chunkIndex,
            audioRangeSec: audioRangeSec,
            responsibleRangeSec: responsibleRangeSec,
            windowMs: 250,
            segments: segments
        )
    }

    private static func roundSec(_ value: Double) -> Double {
        (value * 1000.0).rounded() / 1000.0
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10.0).rounded() / 10.0
    }
}

final class DualTrackMixer: @unchecked Sendable {
    static let blockSize = 640                // 40ms @ 16kHz
    static let maxDriftBufferSamples = 16_000 // 1.0s bounded ingress FIFO cap
    static let trimmedKeepSamples = 6_400     // 400ms retained on overflow trim
    static let lagPadThresholdSamples = 3_200 // 200ms threshold before zero-padding missing track
    static let maxAlignmentPadSamples = 32_000
    static let syncToleranceSamples: Int64 = 320 // 20ms jitter tolerance on subsequent blocks

    private let stateLock = NSLock()
    private let mixerQueue = DispatchQueue(label: "com.antigravity.meeting.dualmixer")
    private let realTimeClock: Bool
    private let onMixedBlock: @Sendable ([Float], [Float], [Float]) -> Void
    private let onDriftGap: (@Sendable (Double, Double, String) -> Void)?

    private var timer: DispatchSourceTimer?
    private var micFIFO = SampleFIFO()
    private var remoteFIFO = SampleFIFO()
    private var originHostTimeNs: UInt64?
    private var originUptime: Double = 0
    private var originUptimeInitialized = false
    private var micAnchored = false
    private var remoteAnchored = false
    private var hasEmittedAnyBlock = false
    private var emittedSamples: Int64 = 0
    private var timelineBaseSamples: Int64 = 0
    private var micPendingSkipSamples: Int64 = 0
    private var remotePendingSkipSamples: Int64 = 0
    private var finished = false

    init(
        realTimeClock: Bool = true,
        onMixedBlock: @escaping @Sendable ([Float], [Float], [Float]) -> Void,
        onDriftGap: (@Sendable (Double, Double, String) -> Void)? = nil
    ) {
        self.realTimeClock = realTimeClock
        self.onMixedBlock = onMixedBlock
        self.onDriftGap = onDriftGap
    }

    func start() {
        mixerQueue.async { [weak self] in
            guard let self else { return }
            let shouldStartTimer = self.stateLock.withLock {
                !self.finished && self.realTimeClock && self.timer == nil
            }
            guard shouldStartTimer else { return }
            let t = DispatchSource.makeTimerSource(queue: self.mixerQueue)
            t.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in
                self?.drainOnMixerQueue(allowLagPadding: true)
            }
            let activated = self.stateLock.withLock { () -> Bool in
                if self.finished { return false }
                self.timer = t
                return true
            }
            if activated {
                t.resume()
            } else {
                t.cancel()
            }
        }
    }

    func appendMic(_ samples: [Float], hostTimeNs: UInt64 = 0) {
        appendTrack(isMic: true, samples: samples, hostTimeNs: hostTimeNs)
    }

    func appendRemote(_ samples: [Float], hostTimeNs: UInt64 = 0) {
        appendTrack(isMic: false, samples: samples, hostTimeNs: hostTimeNs)
    }

    private func appendTrack(isMic: Bool, samples: [Float], hostTimeNs: UInt64) {
        guard !samples.isEmpty else { return }

        var reportedGap: (startSample: Int64, endSample: Int64, reason: String, originUp: Double)?

        stateLock.withLock {
            guard !finished else { return }
            if !originUptimeInitialized {
                originUptime = (hostTimeNs > 0)
                    ? MicCapture.hostTimeToUptime(hostTimeNs)
                    : ProcessInfo.processInfo.systemUptime
                originUptimeInitialized = true
            }
            if let g = alignAndAppendTrackLocked(isMic: isMic, hostTimeNs: hostTimeNs, samples: samples) {
                reportedGap = (g.startSample, g.endSample, g.reason, originUptime)
            }
        }

        if let gap = reportedGap {
            let sr = Double(ChunkWriter.sampleRate)
            onDriftGap?(
                gap.originUp + Double(gap.startSample) / sr,
                gap.originUp + Double(gap.endSample) / sr,
                gap.reason
            )
        }

        if !realTimeClock {
            mixerQueue.sync {
                drainOnMixerQueue(allowLagPadding: false)
            }
        }
    }

    /// Advances the shared timeline head for BOTH tracks in lockstep, returning `[oldHead, newHead)`
    /// in timeline samples so neither track ever desynchronizes across overflows or large shared gaps (P1-1).
    private func advanceSharedTimelineLocked(
        to newHeadSample: Int64,
        reason: String
    ) -> (startSample: Int64, endSample: Int64, reason: String)? {
        let oldHead = timelineBaseSamples + emittedSamples
        let advance = newHeadSample - oldHead
        guard advance > 0 else { return nil }
        timelineBaseSamples += advance
        let maxDrop = Int(min(advance, Int64(Int.max)))
        let micDrop = Int64(micFIFO.dropOldest(maxDrop))
        micPendingSkipSamples += (advance - micDrop)
        let remoteDrop = Int64(remoteFIFO.dropOldest(maxDrop))
        remotePendingSkipSamples += (advance - remoteDrop)
        return (oldHead, newHeadSample, reason)
    }

    /// Continuous host-time alignment, shared big-gap advancement, and bounded FIFO trim (P1-1).
    private func alignAndAppendTrackLocked(
        isMic: Bool,
        hostTimeNs: UInt64,
        samples: [Float]
    ) -> (startSample: Int64, endSample: Int64, reason: String)? {
        var outSamples = samples
        var emittedGap: (startSample: Int64, endSample: Int64, reason: String)?

        if hostTimeNs > 0 {
            let wasAnchoredBefore = isMic ? micAnchored : remoteAnchored
            if isMic { micAnchored = true } else { remoteAnchored = true }

            if let origin = originHostTimeNs {
                let canRewindOrigin: Bool = {
                    guard timelineBaseSamples == 0, !wasAnchoredBefore, !hasEmittedAnyBlock, hostTimeNs < origin else {
                        return false
                    }
                    let otherIsNonEmpty = isMic ? (remoteFIFO.count > 0 && micFIFO.count == 0) : (micFIFO.count > 0 && remoteFIFO.count == 0)
                    guard otherIsNonEmpty else { return false }
                    let deltaBackSec = Double(origin - hostTimeNs) / 1_000_000_000.0
                    let shiftSamples = Int64((deltaBackSec * Double(ChunkWriter.sampleRate)).rounded())
                    let otherFifoCount = Int64(isMic ? remoteFIFO.count : micFIFO.count)
                    guard shiftSamples > 0, shiftSamples + otherFifoCount <= Int64(Self.maxDriftBufferSamples) else {
                        return false
                    }
                    if isMic { remoteFIFO.appendLeadingZeros(Int(shiftSamples)) } else { micFIFO.appendLeadingZeros(Int(shiftSamples)) }
                    originHostTimeNs = hostTimeNs
                    originUptime = max(0.0, originUptime - deltaBackSec)
                    return true
                }()

                if !canRewindOrigin {
                    let deltaSec: Double
                    if hostTimeNs >= origin {
                        deltaSec = Double(hostTimeNs - origin) / 1_000_000_000.0
                    } else {
                        deltaSec = -Double(origin - hostTimeNs) / 1_000_000_000.0
                    }
                    let targetStartSample = Int64((deltaSec * Double(ChunkWriter.sampleRate)).rounded())
                    let fifoHead = timelineBaseSamples + emittedSamples
                    let currentFifoCount = Int64(isMic ? micFIFO.count : remoteFIFO.count)
                    let currentPending = isMic ? micPendingSkipSamples : remotePendingSkipSamples
                    let currentEndSample = fifoHead + currentFifoCount - currentPending
                    let gapSamples = targetStartSample - currentEndSample
                    let tolerance: Int64 = wasAnchoredBefore ? Self.syncToleranceSamples : 0

                    if gapSamples > tolerance {
                        var remainingGap = gapSamples
                        if currentPending > 0 {
                            let canceled = min(remainingGap, currentPending)
                            if isMic { micPendingSkipSamples -= canceled } else { remotePendingSkipSamples -= canceled }
                            remainingGap -= canceled
                        }

                        if currentFifoCount + remainingGap + Int64(outSamples.count) > Int64(Self.maxDriftBufferSamples) {
                            // Jump both tracks cleanly via shared timeline advancement instead of hitting maxAlignmentPadSamples + double-trimming (P1-1).
                            let keepBudget = Int64(max(Self.trimmedKeepSamples, min(outSamples.count, Self.maxDriftBufferSamples)))
                            let newEnd = targetStartSample + Int64(outSamples.count)
                            let newHead = max(fifoHead, newEnd - keepBudget)
                            if let advGap = advanceSharedTimelineLocked(
                                to: newHead,
                                reason: isMic ? "mic_gap_advanced" : "remote_gap_advanced"
                            ) {
                                emittedGap = advGap
                            }
                            if isMic { micPendingSkipSamples = 0 } else { remotePendingSkipSamples = 0 }

                            let updatedHead = timelineBaseSamples + emittedSamples
                            let updatedFifoCount = Int64(isMic ? micFIFO.count : remoteFIFO.count)
                            let padAfter = targetStartSample - (updatedHead + updatedFifoCount)
                            if padAfter > 0 {
                                let padCount = Int(padAfter)
                                if isMic { micFIFO.appendZeros(padCount) } else { remoteFIFO.appendZeros(padCount) }
                            } else if padAfter < 0 {
                                let trimCount = min(outSamples.count, Int(-padAfter))
                                if trimCount > 0 {
                                    outSamples = (trimCount == outSamples.count) ? [] : Array(outSamples.dropFirst(trimCount))
                                }
                            }
                        } else if remainingGap > 0 {
                            let pad = Int(remainingGap)
                            if isMic { micFIFO.appendZeros(pad) } else { remoteFIFO.appendZeros(pad) }
                        }
                    } else if gapSamples < -tolerance {
                        let skip = min(outSamples.count, Int(-gapSamples))
                        if skip > 0 {
                            outSamples = (skip == outSamples.count) ? [] : Array(outSamples.dropFirst(skip))
                        }
                    }
                }
            } else {
                originHostTimeNs = hostTimeNs
                originUptime = MicCapture.hostTimeToUptime(hostTimeNs)
                originUptimeInitialized = true
            }
        }

        outSamples = consumePendingSkipLocked(isMic: isMic, samples: outSamples)
        guard !outSamples.isEmpty else { return emittedGap }

        if isMic {
            micFIFO.append(outSamples)
            if micFIFO.count > Self.maxDriftBufferSamples {
                let excess = Int64(micFIFO.count - Self.trimmedKeepSamples)
                let oldHead = timelineBaseSamples + emittedSamples
                if let trimGap = advanceSharedTimelineLocked(to: oldHead + excess, reason: "mic_drift_trimmed") {
                    emittedGap = trimGap
                }
            }
        } else {
            remoteFIFO.append(outSamples)
            if remoteFIFO.count > Self.maxDriftBufferSamples {
                let excess = Int64(remoteFIFO.count - Self.trimmedKeepSamples)
                let oldHead = timelineBaseSamples + emittedSamples
                if let trimGap = advanceSharedTimelineLocked(to: oldHead + excess, reason: "remote_drift_trimmed") {
                    emittedGap = trimGap
                }
            }
        }
        return emittedGap
    }

    private func consumePendingSkipLocked(isMic: Bool, samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let pending = isMic ? micPendingSkipSamples : remotePendingSkipSamples
        guard pending > 0 else { return samples }
        let skip = min(Int64(samples.count), pending)
        if isMic {
            micPendingSkipSamples -= skip
        } else {
            remotePendingSkipSamples -= skip
        }
        let skipInt = Int(skip)
        return skipInt == samples.count ? [] : Array(samples.dropFirst(skipInt))
    }

    func finish() {
        mixerQueue.sync {
            let activeTimer: DispatchSourceTimer? = stateLock.withLock {
                guard !finished else { return nil }
                finished = true
                let t = timer
                timer = nil
                return t
            }
            activeTimer?.cancel()

            while let pair = popNextBlock(allowLagPadding: false, drainRemainder: true) {
                emitSyncedBlock(mic: pair.mic, remote: pair.remote)
            }
        }
    }

    private func drainOnMixerQueue(allowLagPadding: Bool) {
        while true {
            guard let pair = popNextBlock(allowLagPadding: allowLagPadding, drainRemainder: false) else {
                break
            }
            emitSyncedBlock(mic: pair.mic, remote: pair.remote)
        }
    }

    private func popNextBlock(allowLagPadding: Bool, drainRemainder: Bool) -> (mic: [Float], remote: [Float])? {
        stateLock.withLock {
            if !drainRemainder && finished {
                return nil
            }

            if micFIFO.count >= Self.blockSize && remoteFIFO.count >= Self.blockSize {
                hasEmittedAnyBlock = true
                emittedSamples += Int64(Self.blockSize)
                return (micFIFO.pop(Self.blockSize), remoteFIFO.pop(Self.blockSize))
            }

            if allowLagPadding {
                if micFIFO.count > Self.lagPadThresholdSamples && remoteFIFO.count < Self.blockSize {
                    hasEmittedAnyBlock = true
                    emittedSamples += Int64(Self.blockSize)
                    return (
                        micFIFO.pop(Self.blockSize),
                        remoteFIFO.popUpTo(Self.blockSize, padTo: Self.blockSize)
                    )
                }
                if remoteFIFO.count > Self.lagPadThresholdSamples && micFIFO.count < Self.blockSize {
                    hasEmittedAnyBlock = true
                    emittedSamples += Int64(Self.blockSize)
                    return (
                        micFIFO.popUpTo(Self.blockSize, padTo: Self.blockSize),
                        remoteFIFO.pop(Self.blockSize)
                    )
                }
            }

            if drainRemainder {
                let remaining = max(micFIFO.count, remoteFIFO.count)
                if remaining > 0 {
                    hasEmittedAnyBlock = true
                    let count = min(Self.blockSize, remaining)
                    emittedSamples += Int64(count)
                    return (
                        micFIFO.popUpTo(count, padTo: count),
                        remoteFIFO.popUpTo(count, padTo: count)
                    )
                }
            }

            return nil
        }
    }

    private func emitSyncedBlock(mic: [Float], remote: [Float]) {
        let count = min(mic.count, remote.count)
        guard count > 0 else { return }
        var mix = [Float](repeating: 0, count: count)
        for i in 0..<count {
            mix[i] = Self.softLimit(mic[i] + remote[i])
        }
        onMixedBlock(
            mix,
            mic.count == count ? mic : Array(mic.prefix(count)),
            remote.count == count ? remote : Array(remote.prefix(count))
        )
    }

    static func softLimit(_ x: Float) -> Float {
        let absX = abs(x)
        if absX <= 0.85 {
            return x
        }
        let excess = absX - 0.85
        let compressed = 0.85 + 0.14 * Float(tanh(Double(excess) / 0.14))
        return x >= 0 ? compressed : -compressed
    }

    // MARK: - Self-Tests

    static func runSelfTest(outputDir: URL) throws {
        let t0Ns: UInt64 = 10_000_000_000

        // Test A: Startup host-time alignment + mid-session 120ms remote dropout resynchronization (P1-1 regression).
        final class SyncCollector: @unchecked Sendable {
            private let lock = NSLock()
            var mic: [Float] = []
            var remote: [Float] = []
            func add(mic m: [Float], remote r: [Float]) {
                lock.withLock {
                    mic.append(contentsOf: m)
                    remote.append(contentsOf: r)
                }
            }
            func all() -> ([Float], [Float]) { lock.withLock { (mic, remote) } }
        }

        // Subtest A1: +50ms startup offset (reverse delivery).
        let syncBox = SyncCollector()
        let syncMixer = DualTrackMixer(realTimeClock: false) { _, mic, remote in
            syncBox.add(mic: mic, remote: remote)
        }
        syncMixer.start()
        var micSyncSamples = [Float](repeating: 0, count: 3200)
        micSyncSamples[1600] = 0.8
        var remoteSyncSamples = [Float](repeating: 0, count: 2400)
        remoteSyncSamples[800] = 0.8
        syncMixer.appendRemote(remoteSyncSamples, hostTimeNs: t0Ns + 50_000_000)
        syncMixer.appendMic(micSyncSamples, hostTimeNs: t0Ns)
        syncMixer.finish()
        let (alignedMic, alignedRemote) = syncBox.all()
        guard alignedMic.count == 3200, alignedRemote.count == 3200,
              alignedMic[1600] > 0.7, alignedRemote[1600] > 0.7
        else {
            throw NSError(domain: "DualTrackSelfTest", code: -11, userInfo: [NSLocalizedDescriptionKey: "Startup offset sync failed"])
        }

        // Subtest A2: Mid-session 120ms (1920-sample) remote dropout under realTimeClock mixer -> simultaneous pulse lands at index 3840.
        let dropBox = SyncCollector()
        let dropMixer = DualTrackMixer(realTimeClock: true) { _, mic, remote in
            dropBox.add(mic: mic, remote: remote)
        }
        dropMixer.start()
        for b in 0..<8 { // 0..320ms in 40ms (640-sample) blocks
            var micB = [Float](repeating: 0, count: 640)
            if b == 6 { micB[0] = 0.8 } // pulse at 240ms = frame 3840
            dropMixer.appendMic(micB, hostTimeNs: t0Ns + UInt64(b) * 40_000_000)

            // Remote delivers 0..80ms (b=0,1), drops out 80..200ms (b=2,3,4), resumes at b=5 (200ms) -> 120ms dropout.
            if b < 2 || b >= 5 {
                var remB = [Float](repeating: 0, count: 640)
                if b == 6 { remB[0] = 0.8 } // same physical pulse at 240ms = frame 3840
                dropMixer.appendRemote(remB, hostTimeNs: t0Ns + UInt64(b) * 40_000_000)
            }
            Thread.sleep(forTimeInterval: 0.015)
        }
        dropMixer.finish()
        let (dropMic, dropRemote) = dropBox.all()
        guard dropMic.count >= 5120, dropRemote.count >= 5120,
              dropMic[3840] > 0.7, dropRemote[3840] > 0.7
        else {
            let mIdx = dropMic.firstIndex(where: { $0 > 0.7 }) ?? -1
            let rIdx = dropRemote.firstIndex(where: { $0 > 0.7 }) ?? -1
            throw NSError(domain: "DualTrackSelfTest", code: -15, userInfo: [NSLocalizedDescriptionKey: "120ms dropout desync: micPulse=\(mIdx), remotePulse=\(rIdx)"])
        }

        // Test B: P2-2 Uncorrelated independent voices vs correlated echo + 1000-window single-rounding energy accumulation.
        let acc = SpeakerWindowAccumulator()
        acc.reset(chunkAudioStartSample: 0)
        // Build a 250ms window with uncorrelated 440Hz (-31 dB mic) and 660Hz (-9 dB remote).
        var indepMic = [Float](repeating: 0, count: 4000)
        var indepRem = [Float](repeating: 0, count: 4000)
        for j in 0..<4000 {
            let t = Double(j) / 16_000.0
            indepMic[j] = 0.04 * Float(sin(2.0 * .pi * 440.0 * t))
            indepRem[j] = 0.50 * Float(sin(2.0 * .pi * 660.0 * t))
        }
        acc.append(mic: indepMic, remote: indepRem)
        let indepWins = acc.finishChunkWindows()
        guard indepWins.count == 1,
              SpeakerTimelineBuilder.classifyWindow(micDb: indepWins[0].micDb, remoteDb: indepWins[0].remoteDb, absCorrelation: indepWins[0].absCorrelation) == "both"
        else {
            throw NSError(domain: "DualTrackSelfTest", code: -13, userInfo: [NSLocalizedDescriptionKey: "Uncorrelated 440Hz/660Hz independent voices misclassified (corr=\(indepWins.first?.absCorrelation ?? -1))"])
        }

        // Build 1000 consecutive "me" windows: 1 window @ -10 dB + 999 windows @ -40 dB -> exact energy average = -37.0 dB.
        var manyWindows: [TrackWindowStats] = []
        let e10 = pow(10.0, -10.0 / 10.0)
        let e40 = pow(10.0, -40.0 / 10.0)
        for w in 0..<1000 {
            let ms = w == 0 ? e10 : e40
            let db = w == 0 ? -10.0 : -40.0
            manyWindows.append(
                TrackWindowStats(
                    startSample: Int64(w * 4000),
                    endSample: Int64((w + 1) * 4000),
                    micMeanSquare: ms,
                    remoteMeanSquare: 1e-12,
                    micDb: db,
                    remoteDb: -120.0,
                    absCorrelation: 0.0
                )
            )
        }
        let tl1000 = SpeakerTimelineBuilder.buildChunkTimeline(
            chunkId: "chunk_test",
            chunkIndex: 1,
            audioRangeSec: [0, 250],
            responsibleRangeSec: [0, 250],
            windows: manyWindows
        )
        guard let merged = tl1000.segments.first, abs(merged.micDb - (-37.0)) <= 0.15 else {
            throw NSError(domain: "DualTrackSelfTest", code: -12, userInfo: [NSLocalizedDescriptionKey: "1000-window single-rounding energy average failed: got \(tl1000.segments.first?.micDb ?? 0), expected -37.0"])
        }

        // Test C: Full 10s ChunkWriter(.dual) end-to-end 3-track AAC + timeline test.
        let fm = FileManager.default
        let meetingDir = outputDir.appendingPathComponent("meetings/dual_self_test_001")
        let chunksDir = meetingDir.appendingPathComponent("chunks")
        let timelinesDir = meetingDir.appendingPathComponent("timelines")
        if fm.fileExists(atPath: meetingDir.path) {
            try fm.removeItem(at: meetingDir)
        }
        try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: timelinesDir, withIntermediateDirectories: true)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var chunks: [ChunkRecord] = []
            var errors: [String] = []
            func addChunk(_ c: ChunkRecord) { lock.withLock { chunks.append(c) } }
            func addError(_ e: String) { lock.withLock { errors.append(e) } }
            func result() -> ([ChunkRecord], [String]) { lock.withLock { (chunks.sorted { $0.index < $1.index }, errors) } }
        }

        let collector = Collector()
        let writer = try ChunkWriter(
            chunksDir: chunksDir,
            mode: .dual,
            timelinesDir: timelinesDir,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { collector.addChunk($0) },
            onChunkFailed: { collector.addError($0) }
        )

        let mixer = DualTrackMixer(realTimeClock: false) { mix, mic, remote in
            writer.appendDualSamples(mix: mix, mic: mic, remote: remote)
        }
        mixer.start()

        let sampleRate = Double(ChunkWriter.sampleRate)
        let totalSamples = 10 * Int(ChunkWriter.sampleRate)
        var idx = 0
        while idx < totalSamples {
            let count = min(640, totalSamples - idx)
            var micBuf = [Float](repeating: 0, count: count)
            var remoteBuf = [Float](repeating: 0, count: count)

            for j in 0..<count {
                let s = idx + j
                let t = Double(s) / sampleRate
                if t < 3.0 {
                    micBuf[j] = 0.25 * Float(sin(2.0 * .pi * 440.0 * t))
                } else if t < 6.0 {
                    remoteBuf[j] = 0.25 * Float(sin(2.0 * .pi * 660.0 * t))
                } else if t < 9.0 {
                    micBuf[j] = 0.25 * Float(sin(2.0 * .pi * 440.0 * t))
                    remoteBuf[j] = 0.25 * Float(sin(2.0 * .pi * 660.0 * t))
                } else {
                    remoteBuf[j] = 0.50 * Float(sin(2.0 * .pi * 660.0 * t))
                    micBuf[j] = 0.04 * Float(sin(2.0 * .pi * 660.0 * t))
                }
            }

            let tsNs = t0Ns + UInt64((Double(idx) / sampleRate * 1_000_000_000.0).rounded())
            mixer.appendMic(micBuf, hostTimeNs: tsNs)
            mixer.appendRemote(remoteBuf, hostTimeNs: tsNs)
            idx += count
        }

        mixer.finish()
        let finishRes = writer.finishAll()
        let (committed, errors) = collector.result()

        guard finishRes.failedCount == 0, errors.isEmpty else {
            throw NSError(domain: "DualTrackSelfTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Dual chunk write failed: \(errors)"])
        }
        guard committed.count == 3 else {
            throw NSError(domain: "DualTrackSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Expected 3 dual chunks, got \(committed.count)"])
        }

        for dir in [chunksDir, timelinesDir] {
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            if let tmp = names.first(where: { $0.hasSuffix(".tmp") }) {
                throw NSError(domain: "DualTrackSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "Lingering tmp file \(tmp)"])
            }
        }

        var allSpeakers: [String] = []
        var sawEchoRejectedRemoteTail = false
        let decoder = JSONDecoder()

        for chunk in committed {
            guard let micRel = chunk.micPath, let remoteRel = chunk.remotePath, let timelineRel = chunk.timelinePath else {
                throw NSError(domain: "DualTrackSelfTest", code: -4, userInfo: [NSLocalizedDescriptionKey: "Dual chunk \(chunk.id) missing mic/remote/timeline paths"])
            }
            for rel in [chunk.audioPath, micRel, remoteRel, timelineRel] {
                let abs = meetingDir.appendingPathComponent(rel).path
                guard fm.fileExists(atPath: abs) else {
                    throw NSError(domain: "DualTrackSelfTest", code: -5, userInfo: [NSLocalizedDescriptionKey: "Missing file \(rel)"])
                }
            }
            let timelineData = try Data(contentsOf: meetingDir.appendingPathComponent(timelineRel))
            let timeline = try decoder.decode(ChunkTimeline.self, from: timelineData)
            for seg in timeline.segments {
                allSpeakers.append(seg.speaker)
                if seg.endSec > 9.2 && seg.speaker == "remote" {
                    sawEchoRejectedRemoteTail = true
                }
            }
        }

        for expected in ["me", "remote", "both"] {
            guard allSpeakers.contains(expected) else {
                throw NSError(domain: "DualTrackSelfTest", code: -6, userInfo: [NSLocalizedDescriptionKey: "Missing speaker '\(expected)' in timelines: \(allSpeakers)"])
            }
        }
        guard sawEchoRejectedRemoteTail else {
            throw NSError(domain: "DualTrackSelfTest", code: -7, userInfo: [NSLocalizedDescriptionKey: "Echo bleed rejection did not classify 9-10s tail as remote"])
        }

        let manifest = MeetingManifest(
            schemaVersion: 1,
            id: "dual_self_test_001",
            title: "Dual Self Test",
            mode: "dual",
            appTarget: "all_system",
            status: "recorded",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: finishRes.totalDurationSec,
            chunks: finishRes.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: finishRes.failedCount,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(manifest, to: meetingDir.appendingPathComponent("manifest.json"))

        // 5. Drift-trim synchronization keeps matching impulses aligned across tracks (P1-1).
        final class DriftCollector: @unchecked Sendable {
            private let lock = NSLock()
            var mic: [Float] = []
            var remote: [Float] = []
            var driftGaps: [String] = []
            func append(_ m: [Float], _ r: [Float]) { lock.withLock { mic.append(contentsOf: m); remote.append(contentsOf: r) } }
            func addGap(_ r: String) { lock.withLock { driftGaps.append(r) } }
            func snapshot() -> ([Float], [Float], [String]) { lock.withLock { (mic, remote, driftGaps) } }
        }
        let driftBox = DriftCollector()
        let driftMixer = DualTrackMixer(
            realTimeClock: false,
            onMixedBlock: { _, m, r in driftBox.append(m, r) },
            onDriftGap: { _, _, reason in driftBox.addGap(reason) }
        )
        let overflowTotal = Self.maxDriftBufferSamples + 3200
        let trimmedExpected = overflowTotal - Self.trimmedKeepSamples // 19_200 - 6_400 = 12_800
        let pulseOffset = trimmedExpected + 1000
        let blockSz = 1600
        var rCursor = 0
        while rCursor < overflowTotal {
            let n = min(blockSz, overflowTotal - rCursor)
            var buf = [Float](repeating: 0.0, count: n)
            if pulseOffset >= rCursor && pulseOffset < rCursor + n {
                buf[pulseOffset - rCursor] = 0.9
            }
            let ts = t0Ns + UInt64((Double(rCursor) / sampleRate * 1_000_000_000.0).rounded())
            driftMixer.appendRemote(buf, hostTimeNs: ts)
            rCursor += n
        }
        var mCursor = 0
        while mCursor < overflowTotal {
            let n = min(blockSz, overflowTotal - mCursor)
            var buf = [Float](repeating: 0.0, count: n)
            if pulseOffset >= mCursor && pulseOffset < mCursor + n {
                buf[pulseOffset - mCursor] = 0.9
            }
            let ts = t0Ns + UInt64((Double(mCursor) / sampleRate * 1_000_000_000.0).rounded())
            driftMixer.appendMic(buf, hostTimeNs: ts)
            mCursor += n
        }
        driftMixer.finish()
        let (syncedMic, syncedRemote, driftGaps) = driftBox.snapshot()
        guard driftGaps.contains("remote_drift_trimmed"),
              let micPeakIdx = syncedMic.firstIndex(where: { $0 > 0.5 }),
              let remotePeakIdx = syncedRemote.firstIndex(where: { $0 > 0.5 }),
              abs(micPeakIdx - remotePeakIdx) <= 1
        else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "Drift trim desynchronized mic/remote pulses"]
            )
        }

        // Subcase 5b: remote overflows and trims, while mic resumes AFTER trim point at sample 12_000.
        let driftBox2 = DriftCollector()
        let driftMixer2 = DualTrackMixer(
            realTimeClock: false,
            onMixedBlock: { _, m, r in driftBox2.append(m, r) },
            onDriftGap: { _, _, reason in driftBox2.addGap(reason) }
        )
        rCursor = 0
        while rCursor < overflowTotal {
            let n = min(blockSz, overflowTotal - rCursor)
            var buf = [Float](repeating: 0.0, count: n)
            if pulseOffset >= rCursor && pulseOffset < rCursor + n {
                buf[pulseOffset - rCursor] = 0.9
            }
            let ts = t0Ns + UInt64((Double(rCursor) / sampleRate * 1_000_000_000.0).rounded())
            driftMixer2.appendRemote(buf, hostTimeNs: ts)
            rCursor += n
        }
        mCursor = 12_000
        while mCursor < overflowTotal {
            let n = min(blockSz, overflowTotal - mCursor)
            var buf = [Float](repeating: 0.0, count: n)
            if pulseOffset >= mCursor && pulseOffset < mCursor + n {
                buf[pulseOffset - mCursor] = 0.9
            }
            let ts = t0Ns + UInt64((Double(mCursor) / sampleRate * 1_000_000_000.0).rounded())
            driftMixer2.appendMic(buf, hostTimeNs: ts)
            mCursor += n
        }
        driftMixer2.finish()
        let (lateMic, lateRemote, _) = driftBox2.snapshot()
        guard let micPeakIdx2 = lateMic.firstIndex(where: { $0 > 0.5 }),
              let remotePeakIdx2 = lateRemote.firstIndex(where: { $0 > 0.5 }),
              abs(micPeakIdx2 - remotePeakIdx2) <= 1
        else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -18,
                userInfo: [NSLocalizedDescriptionKey: "Post-trim late-resuming mic desynchronized from remote pulse"]
            )
        }

        // Subcase 5c: BOTH tracks pause simultaneously for 3.0s (48,000 samples) and resume together at frame 48,000 (P1-1).
        let driftBox3 = DriftCollector()
        let driftMixer3 = DualTrackMixer(
            realTimeClock: false,
            onMixedBlock: { _, m, r in driftBox3.append(m, r) },
            onDriftGap: { _, _, reason in driftBox3.addGap(reason) }
        )
        let initBlock = [Float](repeating: 0.01, count: 640)
        driftMixer3.appendMic(initBlock, hostTimeNs: t0Ns)
        driftMixer3.appendRemote(initBlock, hostTimeNs: t0Ns)
        var resumeBlock = [Float](repeating: 0.0, count: 640)
        resumeBlock[100] = 0.9
        let resumeNs = t0Ns + UInt64((48_000.0 / sampleRate * 1_000_000_000.0).rounded())
        driftMixer3.appendRemote(resumeBlock, hostTimeNs: resumeNs)
        driftMixer3.appendMic(resumeBlock, hostTimeNs: resumeNs)
        driftMixer3.finish()
        let (sharedMic, sharedRemote, _) = driftBox3.snapshot()
        guard let micPeakIdx3 = sharedMic.firstIndex(where: { $0 > 0.5 }),
              let remotePeakIdx3 = sharedRemote.firstIndex(where: { $0 > 0.5 }),
              abs(micPeakIdx3 - remotePeakIdx3) <= 1
        else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -19,
                userInfo: [NSLocalizedDescriptionKey: "Simultaneous 3s pause lost or desynchronized impulses"]
            )
        }

        // Subcase 5d: Drift-trim gap timestamp uses pre-trim timeline head [0, 0.700], not shifted by +0.400s.
        final class TimedGapBox: @unchecked Sendable {
            private let lock = NSLock()
            var gaps: [(Double, Double, String)] = []
            func add(_ s: Double, _ e: Double, _ r: String) { lock.withLock { gaps.append((s, e, r)) } }
            func all() -> [(Double, Double, String)] { lock.withLock { gaps } }
        }
        let timedBox = TimedGapBox()
        let timedMixer = DualTrackMixer(
            realTimeClock: false,
            onMixedBlock: { _, _, _ in },
            onDriftGap: { s, e, r in timedBox.add(s, e, r) }
        )
        let baseNs = MicCapture.hostTicksToNanoseconds(mach_absolute_time())
        let originUptimeSnap = ProcessInfo.processInfo.systemUptime
        var pushed = 0
        while pushed < 17_600 {
            let chunk = [Float](repeating: 0.0, count: 1600)
            let ts = baseNs + UInt64((Double(pushed) / sampleRate * 1_000_000_000.0).rounded())
            timedMixer.appendRemote(chunk, hostTimeNs: ts)
            pushed += 1600
        }
        timedMixer.finish()
        let timedGaps = timedBox.all()
        guard let dg = timedGaps.first(where: { $0.2 == "remote_drift_trimmed" }),
              abs(dg.0 - originUptimeSnap) < 0.05,
              abs((dg.1 - dg.0) - 0.700) < 0.01
        else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Drift-trim gap timestamp offset error: got \(timedGaps) origin=\(originUptimeSnap)"]
            )
        }

        // 6. 9-sample delayed acoustic echo (90 deg quadrature @ 444.4 Hz) still classifies as remote (P2-2).
        let echoAcc = SpeakerWindowAccumulator()
        echoAcc.reset(chunkAudioStartSample: 0)
        var echoMic = [Float](repeating: 0, count: 4000)
        var echoRemote = [Float](repeating: 0, count: 4000)
        let freqEcho = 16_000.0 / 36.0 // 9 samples == 90 degree phase shift (zero-lag corr ~ 0)
        for j in 0..<4000 {
            let t = Double(j) / 16_000.0
            echoRemote[j] = 0.45 * Float(sin(2.0 * .pi * freqEcho * t))
            if j >= 9 {
                let tDel = Double(j - 9) / 16_000.0
                echoMic[j] = 0.028 * Float(sin(2.0 * .pi * freqEcho * tDel))
            }
        }
        echoAcc.append(mic: echoMic, remote: echoRemote)
        let echoWins = echoAcc.finishChunkWindows()
        let echoTimeline = SpeakerTimelineBuilder.buildChunkTimeline(
            chunkId: "chunk_echo",
            chunkIndex: 0,
            audioRangeSec: [0.0, 0.25],
            responsibleRangeSec: [0.0, 0.25],
            windows: echoWins
        )
        guard echoTimeline.segments.count == 1, echoTimeline.segments[0].speaker == "remote" else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -16,
                userInfo: [NSLocalizedDescriptionKey: "9-sample delayed acoustic echo misclassified: \(echoTimeline.segments)"]
            )
        }

        // Subcase 6b: 129-sample tail window with 3-cycle vs 7-cycle independent cosines classifies as both (P2-2).
        let tailAcc = SpeakerWindowAccumulator()
        tailAcc.reset(chunkAudioStartSample: 0)
        var indMic = [Float](repeating: 0, count: 129)
        var indRemote = [Float](repeating: 0, count: 129)
        for k in 0..<129 {
            indRemote[k] = 0.45 * Float(cos(2.0 * .pi * 3.0 * Double(k) / 129.0)) // ~ -10 dB
            indMic[k] = 0.028 * Float(cos(2.0 * .pi * 7.0 * Double(k) / 129.0))   // ~ -34 dB
        }
        tailAcc.append(mic: indMic, remote: indRemote)
        let tailWins = tailAcc.finishChunkWindows()
        let tailTimeline = SpeakerTimelineBuilder.buildChunkTimeline(
            chunkId: "chunk_tail_indep",
            chunkIndex: 0,
            audioRangeSec: [0.0, Double(129) / 16_000.0],
            responsibleRangeSec: [0.0, Double(129) / 16_000.0],
            windows: tailWins
        )
        guard tailTimeline.segments.count == 1, tailTimeline.segments[0].speaker == "both" else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "129-sample independent cosines misclassified as echo: \(tailTimeline.segments)"]
            )
        }

        // 7. Original PCM SegmentWeighting regression: 4000 samples @ -40 dB + 1 sample @ 1.0 -> -34.6 dB.
        let weightAcc = SpeakerWindowAccumulator()
        weightAcc.reset(chunkAudioStartSample: 0)
        var wMic = [Float](repeating: 0.01, count: 4001)
        wMic[4000] = 1.0
        let wRemote = [Float](repeating: 0.0, count: 4001)
        weightAcc.append(mic: wMic, remote: wRemote)
        let weightWins = weightAcc.finishChunkWindows()
        let weightTl = SpeakerTimelineBuilder.buildChunkTimeline(
            chunkId: "chunk_weight",
            chunkIndex: 0,
            audioRangeSec: [0.0, Double(4001) / 16_000.0],
            responsibleRangeSec: [0.0, Double(4001) / 16_000.0],
            windows: weightWins
        )
        guard weightTl.segments.count == 1,
              weightTl.segments[0].speaker == "me",
              weightTl.segments[0].micDb == -34.6
        else {
            throw NSError(
                domain: "DualTrackSelfTest",
                code: -17,
                userInfo: [NSLocalizedDescriptionKey: "Window energy weighting mismatch: got \(weightTl.segments) expected micDb=-34.6"]
            )
        }

        // Subcase 5e: Out-of-order first packets with 3.0s (48,000-sample) offset keep remote + mic pulses aligned (P1-1).
        for useRT in [false, true] {
            let oooBox = DriftCollector()
            let oooMixer = DualTrackMixer(
                realTimeClock: useRT,
                onMixedBlock: { _, m, r in oooBox.append(m, r) },
                onDriftGap: { _, _, reason in oooBox.addGap(reason) }
            )
            if useRT { oooMixer.start() }
            let pastNs = MicCapture.hostTicksToNanoseconds(mach_absolute_time()) - 5_000_000_000
            let tPlus3Ns = pastNs + 3_000_000_000
            var pulseBuf = [Float](repeating: 0.0, count: 640)
            pulseBuf[100] = 0.9
            let earlyMicBuf = [Float](repeating: 0.01, count: 640)
            oooMixer.appendRemote(pulseBuf, hostTimeNs: tPlus3Ns)
            oooMixer.appendMic(earlyMicBuf, hostTimeNs: pastNs)
            oooMixer.appendMic(pulseBuf, hostTimeNs: tPlus3Ns)
            oooMixer.finish()
            let (oooMic, oooRemote, _) = oooBox.snapshot()
            guard let micPeak = oooMic.firstIndex(where: { $0 > 0.5 }),
                  let remotePeak = oooRemote.firstIndex(where: { $0 > 0.5 }),
                  abs(micPeak - remotePeak) <= 1
            else {
                throw NSError(
                    domain: "DualTrackSelfTest",
                    code: -22,
                    userInfo: [NSLocalizedDescriptionKey: "Out-of-order 3s first packets lost or desynchronized pulse (rt=\(useRT))"]
                )
            }
        }
    }
}

private struct SampleFIFO {
    private var buffer: [Float] = []
    private var headIndex: Int = 0

    var count: Int {
        buffer.count - headIndex
    }

    mutating func append(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
    }

    mutating func appendZeros(_ zeroCount: Int) {
        guard zeroCount > 0 else { return }
        buffer.append(contentsOf: repeatElement(0.0 as Float, count: zeroCount))
    }

    mutating func appendLeadingZeros(_ zeroCount: Int) {
        guard zeroCount > 0 else { return }
        if headIndex >= zeroCount {
            headIndex -= zeroCount
            for i in headIndex..<(headIndex + zeroCount) {
                buffer[i] = 0.0
            }
            return
        }
        let active = headIndex < buffer.count ? Array(buffer[headIndex...]) : []
        var prefix = [Float](repeating: 0.0, count: zeroCount)
        prefix.append(contentsOf: active)
        buffer = prefix
        headIndex = 0
    }

    mutating func pop(_ n: Int) -> [Float] {
        let take = min(n, count)
        let slice = Array(buffer[headIndex..<(headIndex + take)])
        headIndex += take
        compactIfNeeded()
        return slice
    }

    mutating func popUpTo(_ maxCount: Int, padTo targetCount: Int) -> [Float] {
        var out = pop(maxCount)
        if out.count < targetCount {
            out.append(contentsOf: repeatElement(0.0 as Float, count: targetCount - out.count))
        }
        return out
    }

    @discardableResult
    mutating func dropOldest(_ dropCount: Int) -> Int {
        let take = min(max(0, dropCount), count)
        if take > 0 {
            headIndex += take
            compactIfNeeded()
        }
        return take
    }

    @discardableResult
    mutating func dropOldestKeeping(_ keepCount: Int) -> Int {
        let dropCount = max(0, count - max(0, keepCount))
        if dropCount > 0 {
            headIndex += dropCount
            compactIfNeeded()
        }
        return dropCount
    }

    private mutating func compactIfNeeded() {
        if headIndex >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            headIndex = 0
        } else if headIndex > 8192 {
            buffer.removeFirst(headIndex)
            headIndex = 0
        }
    }
}
