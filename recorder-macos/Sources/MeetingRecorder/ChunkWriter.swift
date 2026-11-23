@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum RecordingMode: String, Sendable {
    case mic
    case dual
}

private final class AssetWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private struct TrackWriterSlot {
    let role: String // "mic" | "mix" | "remote"
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let tmpURL: URL
    let finalURL: URL
    var writtenSamples: Int64
}

private final class FinalizingTrackSpec: @unchecked Sendable {
    let role: String
    let writerBox: AssetWriterBox
    let input: AVAssetWriterInput
    let tmpURL: URL
    let finalURL: URL
    let writtenSamples: Int64

    init(
        role: String,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        tmpURL: URL,
        finalURL: URL,
        writtenSamples: Int64
    ) {
        self.role = role
        self.writerBox = AssetWriterBox(writer)
        self.input = input
        self.tmpURL = tmpURL
        self.finalURL = finalURL
        self.writtenSamples = writtenSamples
    }
}

private final class ChunkFinalizeBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let onAllFinished: @Sendable () -> Void

    init(trackCount: Int, onAllFinished: @escaping @Sendable () -> Void) {
        self.remaining = trackCount
        self.onAllFinished = onAllFinished
    }

    func trackCompleted() {
        let shouldFinish = lock.withLock { () -> Bool in
            remaining -= 1
            return remaining == 0
        }
        if shouldFinish {
            onAllFinished()
        }
    }
}

final class ChunkWriter: @unchecked Sendable {
    static let sampleRate: Int64 = 16_000
    static let defaultChunkDurationSec: Double = 295.0

    struct FaultInjection: Sendable {
        let role: String
        let afterSamples: Int64
        let chunkIndex: Int?
    }

    private let chunksDir: URL
    private let timelinesDir: URL?
    private let commitsDir: URL
    private let mode: RecordingMode
    private let chunkTargetSamples: Int64
    private let overlapSampleCount: Int
    private let expectsRealTime: Bool
    private let onChunkCommitted: @Sendable (ChunkRecord) -> Void
    private let onChunkFailed: @Sendable (String) -> Void
    private let testFault: FaultInjection?

    private let writerQueue = DispatchQueue(label: "com.antigravity.meeting.chunkwriter")
    private let finishGroup = DispatchGroup()

    private let pcmFormat: AVAudioFormat
    private var globalSamplesWritten: Int64 = 0
    private var currentChunkIndex: Int = 0
    private var currentChunkResponsibleStartSample: Int64 = 0
    private var currentChunkActualSamples: Int64 = 0
    private var currentChunkAudioStartSample: Int64 = 0
    private var expectedChunkWrittenSamples: Int64 = 0
    private var currentChunkFailed: Bool = false

    private var activeTracks: [TrackWriterSlot] = []
    private var mixOverlapTailBuffer: [Float] = []
    private var micOverlapTailBuffer: [Float] = []
    private var remoteOverlapTailBuffer: [Float] = []
    private var chunkInitialMixOverlap: [Float] = []
    private var chunkInitialMicOverlap: [Float] = []
    private var chunkInitialRemoteOverlap: [Float] = []
    private var windowAccumulator = SpeakerWindowAccumulator()

    private let resultsLock = NSLock()
    private var committedChunks: [ChunkRecord] = []
    private var failedChunkIds: Set<String> = []
    private var openFailureCount: Int = 0
    private var finishedAll = false

    init(
        chunksDir: URL,
        mode: RecordingMode = .mic,
        timelinesDir: URL? = nil,
        chunkDurationSec: Double = ChunkWriter.defaultChunkDurationSec,
        expectsRealTime: Bool = true,
        testFault: FaultInjection? = nil,
        onChunkCommitted: @escaping @Sendable (ChunkRecord) -> Void,
        onChunkFailed: @escaping @Sendable (String) -> Void
    ) throws {
        self.chunksDir = chunksDir
        self.mode = mode
        let meetingDir = chunksDir.deletingLastPathComponent()
        self.commitsDir = meetingDir.appendingPathComponent(".commits")
        if mode == .dual {
            self.timelinesDir = timelinesDir ?? meetingDir.appendingPathComponent("timelines")
        } else {
            self.timelinesDir = timelinesDir
        }

        let finiteDuration = chunkDurationSec.isFinite ? chunkDurationSec : Self.defaultChunkDurationSec
        let safeDuration = min(3600.0, max(2.0, finiteDuration))
        self.chunkTargetSamples = Int64((safeDuration * Double(Self.sampleRate)).rounded())
        let overlapSec = min(2.0, safeDuration / 4.0)
        self.overlapSampleCount = max(0, Int((overlapSec * Double(Self.sampleRate)).rounded()))
        self.expectsRealTime = expectsRealTime
        self.testFault = testFault
        self.onChunkCommitted = onChunkCommitted
        self.onChunkFailed = onChunkFailed

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "ChunkWriter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct 16kHz Float32 mono AVAudioFormat"]
            )
        }
        self.pcmFormat = format

        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        if let tDir = self.timelinesDir {
            try FileManager.default.createDirectory(at: tDir, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: self.commitsDir, withIntermediateDirectories: true)
    }

    func appendSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if mode == .dual {
            let zeros = [Float](repeating: 0, count: samples.count)
            appendDualSamples(mix: samples, mic: samples, remote: zeros)
            return
        }
        writerQueue.sync {
            guard !finishedAll else { return }
            appendMicOnQueue(samples)
        }
    }

    func appendDualSamples(mix: [Float], mic: [Float], remote: [Float]) {
        let count = min(mix.count, min(mic.count, remote.count))
        guard count > 0 else { return }
        if mode == .mic {
            appendSamples(mix)
            return
        }
        let mixTrim = mix.count == count ? mix : Array(mix.prefix(count))
        let micTrim = mic.count == count ? mic : Array(mic.prefix(count))
        let remoteTrim = remote.count == count ? remote : Array(remote.prefix(count))
        writerQueue.sync {
            guard !finishedAll else { return }
            appendDualOnQueue(mix: mixTrim, mic: micTrim, remote: remoteTrim)
        }
    }

    func finishAll() -> (chunks: [ChunkRecord], failedCount: Int, totalDurationSec: Double) {
        writerQueue.sync {
            guard !finishedAll else { return }
            finishedAll = true
            if !activeTracks.isEmpty {
                if !currentChunkFailed && (currentChunkActualSamples > 0 || currentChunkIndex == 1) {
                    finalizeCurrentWriterOnQueue()
                } else {
                    cancelCurrentWriterOnQueue()
                }
            }
        }

        finishGroup.wait()

        return resultsLock.withLock {
            let sorted = committedChunks.sorted { $0.index < $1.index }
            let failures = failedChunkIds.count + openFailureCount
            let committedDuration = Self.committedCoverageDuration(for: sorted)
            return (sorted, failures, committedDuration)
        }
    }

    static func committedCoverageDuration(for chunks: [ChunkRecord]) -> Double {
        var intervals: [(start: Double, end: Double)] = []
        intervals.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard chunk.responsibleRangeSec.count >= 2 else { continue }
            let s = chunk.responsibleRangeSec[0]
            let e = chunk.responsibleRangeSec[1]
            guard s.isFinite, e.isFinite, e > s else { continue }
            intervals.append((s, e))
        }
        guard !intervals.isEmpty else { return 0.0 }
        intervals.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var total = 0.0
        var curStart = intervals[0].start
        var curEnd = intervals[0].end
        for iv in intervals.dropFirst() {
            if iv.start <= curEnd {
                curEnd = max(curEnd, iv.end)
            } else {
                total += (curEnd - curStart)
                curStart = iv.start
                curEnd = iv.end
            }
        }
        total += (curEnd - curStart)
        return roundSec(total)
    }

    private func appendMicOnQueue(_ samples: [Float]) {
        var offset = 0
        while offset < samples.count {
            if activeTracks.isEmpty {
                do {
                    guard try openNextWriterOnQueue() else { return }
                } catch {
                    recordOpenFailure("Failed to open chunk writer: \(error.localizedDescription)")
                    return
                }
            }

            let remainingForChunk = max(1, Int(chunkTargetSamples - currentChunkActualSamples))
            let takeCount = min(remainingForChunk, samples.count - offset)
            let slice = Array(samples[offset..<(offset + takeCount)])

            let writtenCount = writeFloatSamples(slice, toTrackIndex: 0)
            guard writtenCount == slice.count else {
                let chunkId = String(format: "chunk_%03d", currentChunkIndex)
                currentChunkFailed = true
                recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) incomplete write (\(writtenCount)/\(slice.count))")
                cancelCurrentWriterOnQueue()
                return
            }

            updateOverlapBuffer(&micOverlapTailBuffer, with: slice)
            expectedChunkWrittenSamples += Int64(takeCount)
            currentChunkActualSamples += Int64(takeCount)
            globalSamplesWritten += Int64(takeCount)
            offset += takeCount

            if currentChunkActualSamples >= chunkTargetSamples {
                finalizeCurrentWriterOnQueue()
            }
        }
    }

    private func appendDualOnQueue(mix: [Float], mic: [Float], remote: [Float]) {
        let total = mix.count
        var offset = 0
        while offset < total {
            if activeTracks.isEmpty {
                do {
                    guard try openNextWriterOnQueue() else { return }
                } catch {
                    recordOpenFailure("Failed to open dual chunk writers: \(error.localizedDescription)")
                    return
                }
            }

            let remainingForChunk = max(1, Int(chunkTargetSamples - currentChunkActualSamples))
            let takeCount = min(remainingForChunk, total - offset)
            let range = offset..<(offset + takeCount)
            let mixSlice = Array(mix[range])
            let micSlice = Array(mic[range])
            let remoteSlice = Array(remote[range])

            let wMix = writeFloatSamples(mixSlice, toTrackIndex: 0)
            let wMic = writeFloatSamples(micSlice, toTrackIndex: 1)
            let wRemote = writeFloatSamples(remoteSlice, toTrackIndex: 2)

            guard wMix == takeCount, wMic == takeCount, wRemote == takeCount else {
                let chunkId = String(format: "chunk_%03d", currentChunkIndex)
                currentChunkFailed = true
                recordChunkFailure(
                    chunkId: chunkId,
                    "Dual chunk \(chunkId) unequal track write (mix=\(wMix), mic=\(wMic), remote=\(wRemote), expected=\(takeCount))"
                )
                cancelCurrentWriterOnQueue()
                return
            }

            updateOverlapBuffer(&mixOverlapTailBuffer, with: mixSlice)
            updateOverlapBuffer(&micOverlapTailBuffer, with: micSlice)
            updateOverlapBuffer(&remoteOverlapTailBuffer, with: remoteSlice)
            windowAccumulator.append(mic: micSlice, remote: remoteSlice)

            expectedChunkWrittenSamples += Int64(takeCount)
            currentChunkActualSamples += Int64(takeCount)
            globalSamplesWritten += Int64(takeCount)
            offset += takeCount

            if currentChunkActualSamples >= chunkTargetSamples {
                finalizeCurrentWriterOnQueue()
            }
        }
    }

    private func openNextWriterOnQueue() throws -> Bool {
        currentChunkIndex += 1
        currentChunkFailed = false
        expectedChunkWrittenSamples = 0
        chunkInitialMixOverlap = mixOverlapTailBuffer
        chunkInitialMicOverlap = micOverlapTailBuffer
        chunkInitialRemoteOverlap = remoteOverlapTailBuffer

        let chunkId = String(format: "chunk_%03d", currentChunkIndex)
        let roles: [String] = (mode == .dual) ? ["mix", "mic", "remote"] : ["mic"]
        var openedSlots: [TrackWriterSlot] = []

        do {
            for role in roles {
                let fileName = String(format: "%@_%03d.m4a", role, currentChunkIndex)
                let tmpName = String(format: ".%@_%03d.%@.m4a.tmp", role, currentChunkIndex, UUID().uuidString)
                let tmpURL = chunksDir.appendingPathComponent(tmpName)
                let finalURL = chunksDir.appendingPathComponent(fileName)

                let writer = try AVAssetWriter(outputURL: tmpURL, fileType: .m4a)
                let outputSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Int(Self.sampleRate),
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 48_000,
                ]
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: outputSettings,
                    sourceFormatHint: pcmFormat.formatDescription
                )
                input.expectsMediaDataInRealTime = expectsRealTime

                guard writer.canAdd(input) else {
                    throw NSError(
                        domain: "ChunkWriter",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter cannot add AAC audio input (\(role))"]
                    )
                }
                writer.add(input)

                guard writer.startWriting() else {
                    let errMsg = writer.error?.localizedDescription ?? "unknown error"
                    throw NSError(
                        domain: "ChunkWriter",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter.startWriting failed (\(role)): \(errMsg)"]
                    )
                }
                writer.startSession(atSourceTime: .zero)

                openedSlots.append(
                    TrackWriterSlot(
                        role: role,
                        writer: writer,
                        input: input,
                        tmpURL: tmpURL,
                        finalURL: finalURL,
                        writtenSamples: 0
                    )
                )
            }
        } catch {
            for slot in openedSlots {
                slot.writer.cancelWriting()
                try? FileManager.default.removeItem(at: slot.tmpURL)
            }
            throw error
        }

        let overlapCount: Int = {
            guard currentChunkIndex > 1 else { return 0 }
            if mode == .mic {
                return micOverlapTailBuffer.count
            }
            return min(mixOverlapTailBuffer.count, min(micOverlapTailBuffer.count, remoteOverlapTailBuffer.count))
        }()

        currentChunkResponsibleStartSample = globalSamplesWritten
        currentChunkAudioStartSample = max(0, globalSamplesWritten - Int64(overlapCount))
        currentChunkActualSamples = 0
        activeTracks = openedSlots

        if mode == .dual {
            windowAccumulator.reset(chunkAudioStartSample: currentChunkAudioStartSample)
        }

        if overlapCount > 0 {
            if mode == .mic {
                let replay = Array(micOverlapTailBuffer.suffix(overlapCount))
                let written = writeFloatSamples(replay, toTrackIndex: 0)
                guard written == overlapCount else {
                    currentChunkFailed = true
                    recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) overlap replay short write (\(written)/\(overlapCount))")
                    cancelCurrentWriterOnQueue()
                    return false
                }
                expectedChunkWrittenSamples += Int64(overlapCount)
            } else {
                let mixReplay = Array(mixOverlapTailBuffer.suffix(overlapCount))
                let micReplay = Array(micOverlapTailBuffer.suffix(overlapCount))
                let remoteReplay = Array(remoteOverlapTailBuffer.suffix(overlapCount))
                let wMix = writeFloatSamples(mixReplay, toTrackIndex: 0)
                let wMic = writeFloatSamples(micReplay, toTrackIndex: 1)
                let wRemote = writeFloatSamples(remoteReplay, toTrackIndex: 2)
                guard wMix == overlapCount, wMic == overlapCount, wRemote == overlapCount else {
                    currentChunkFailed = true
                    recordChunkFailure(
                        chunkId: chunkId,
                        "Dual chunk \(chunkId) overlap replay unequal write (mix=\(wMix), mic=\(wMic), remote=\(wRemote), expected=\(overlapCount))"
                    )
                    cancelCurrentWriterOnQueue()
                    return false
                }
                expectedChunkWrittenSamples += Int64(overlapCount)
                windowAccumulator.append(mic: micReplay, remote: remoteReplay)
            }
        }

        return true
    }

    private func writeFloatSamples(_ samples: [Float], toTrackIndex trackIndex: Int) -> Int {
        guard !samples.isEmpty, trackIndex >= 0, trackIndex < activeTracks.count else { return 0 }

        let chunkId = String(format: "chunk_%03d", currentChunkIndex)
        let role = activeTracks[trackIndex].role
        let writer = activeTracks[trackIndex].writer
        let input = activeTracks[trackIndex].input

        if writer.status == .failed {
            recordChunkFailure(chunkId: chunkId, "AVAssetWriter failed (\(role)): \(writer.error?.localizedDescription ?? "unknown")")
            return 0
        }

        let maxFrames = 4096
        var idx = 0
        while idx < samples.count {
            let count = min(maxFrames, samples.count - idx)

            if let fault = testFault,
               fault.role == role,
               (fault.chunkIndex == nil || fault.chunkIndex == currentChunkIndex),
               activeTracks[trackIndex].writtenSamples >= fault.afterSamples
            {
                recordChunkFailure(chunkId: chunkId, "Injected test short-write fault on \(role)")
                return idx
            }

            let chunk = Array(samples[idx..<(idx + count)])

            var waitIterations = 0
            while !input.isReadyForMoreMediaData && writer.status == .writing && waitIterations < 500 {
                Thread.sleep(forTimeInterval: 0.002)
                waitIterations += 1
            }

            guard input.isReadyForMoreMediaData, writer.status == .writing else {
                recordChunkFailure(chunkId: chunkId, "AVAssetWriterInput not ready (\(role), status=\(writer.status.rawValue))")
                return idx
            }

            let ptsOffset = activeTracks[trackIndex].writtenSamples
            guard let sampleBuffer = makeSampleBuffer(samples: chunk, ptsSampleOffset: ptsOffset) else {
                recordChunkFailure(chunkId: chunkId, "Failed to create CMSampleBuffer (\(role))")
                return idx
            }

            if !input.append(sampleBuffer) {
                recordChunkFailure(chunkId: chunkId, "AVAssetWriterInput.append failed (\(role)): \(writer.error?.localizedDescription ?? "unknown")")
                return idx
            }

            activeTracks[trackIndex].writtenSamples += Int64(count)
            idx += count
        }

        return idx
    }

    private func makeSampleBuffer(samples: [Float], ptsSampleOffset: Int64) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = CMBlockBufferAssureBlockMemory(block)
        guard status == kCMBlockBufferNoErr else { return nil }

        status = samples.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return OSStatus(-12701) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let pts = CMTime(value: ptsSampleOffset, timescale: Int32(Self.sampleRate))
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: pcmFormat.formatDescription,
            sampleCount: samples.count,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }
        return sampleBuffer
    }

    private func updateOverlapBuffer(_ buffer: inout [Float], with samples: [Float]) {
        guard overlapSampleCount > 0 else { return }
        if samples.count >= overlapSampleCount {
            buffer = Array(samples.suffix(overlapSampleCount))
        } else {
            buffer.append(contentsOf: samples)
            if buffer.count > overlapSampleCount {
                buffer.removeFirst(buffer.count - overlapSampleCount)
            }
        }
    }

    private func finalizeCurrentWriterOnQueue() {
        let slots = activeTracks
        guard !slots.isEmpty else { return }

        let index = currentChunkIndex
        let chunkId = String(format: "chunk_%03d", index)
        let audioStartSec = Self.roundSec(Double(currentChunkAudioStartSample) / Double(Self.sampleRate))
        let audioEndSec = Self.roundSec(Double(globalSamplesWritten) / Double(Self.sampleRate))
        let respStartSec = Self.roundSec(Double(currentChunkResponsibleStartSample) / Double(Self.sampleRate))
        let respEndSec = Self.roundSec(Double(globalSamplesWritten) / Double(Self.sampleRate))
        let expectedFrames = expectedChunkWrittenSamples
        let allCountsMatch = !currentChunkFailed && expectedFrames > 0 && slots.allSatisfy { $0.writtenSamples == expectedFrames }
        let writtenDurationSec = Self.roundSec(Double(expectedFrames) / Double(Self.sampleRate))
        let timelineWindows: [TrackWindowStats]? = (mode == .dual) ? windowAccumulator.finishChunkWindows() : nil
        let targetTimelinesDir = timelinesDir
        let targetCommitsDir = commitsDir
        let writerMode = mode

        guard allCountsMatch else {
            cancelCurrentWriterOnQueue()
            if expectedFrames > 0 || slots.contains(where: { $0.writtenSamples > 0 }) {
                recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) track frame counts mismatch (expected=\(expectedFrames))")
            }
            return
        }

        activeTracks.removeAll(keepingCapacity: true)
        expectedChunkWrittenSamples = 0
        chunkInitialMixOverlap = []
        chunkInitialMicOverlap = []
        chunkInitialRemoteOverlap = []

        let specs = slots.map {
            FinalizingTrackSpec(
                role: $0.role,
                writer: $0.writer,
                input: $0.input,
                tmpURL: $0.tmpURL,
                finalURL: $0.finalURL,
                writtenSamples: $0.writtenSamples
            )
        }

        for spec in specs {
            spec.input.markAsFinished()
        }

        finishGroup.enter()

        let barrier = ChunkFinalizeBarrier(trackCount: specs.count) { [weak self] in
            defer { self?.finishGroup.leave() }
            guard let self else { return }

            let fm = FileManager.default

            // 1. Validate EVERY writer finished cleanly and EVERY staged .tmp .m4a file is non-empty BEFORE any rename.
            var totalBytes: Int64 = 0
            for spec in specs {
                if spec.writerBox.writer.status != .completed {
                    let errText = spec.writerBox.writer.error?.localizedDescription ?? "status \(spec.writerBox.writer.status.rawValue)"
                    for cleanupSpec in specs {
                        try? fm.removeItem(at: cleanupSpec.tmpURL)
                    }
                    self.recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) (\(spec.role)) finishWriting failed: \(errText)")
                    return
                }
                let attrs = try? fm.attributesOfItem(atPath: spec.tmpURL.path)
                let tmpSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                guard tmpSize > 0 else {
                    for cleanupSpec in specs {
                        try? fm.removeItem(at: cleanupSpec.tmpURL)
                    }
                    self.recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) (\(spec.role)) staged temp file is 0 bytes")
                    return
                }
                totalBytes += tmpSize
            }

            // 2. Stage timeline JSON into timelines/.chunk_NNN.<uuid>.json.tmp BEFORE renaming any .m4a file.
            var stagedTimelineTmpURL: URL? = nil
            var finalTimelineURL: URL? = nil
            var timelineRelPath: String? = nil

            if writerMode == .dual, let tDir = targetTimelinesDir {
                let timeline = SpeakerTimelineBuilder.buildChunkTimeline(
                    chunkId: chunkId,
                    chunkIndex: index,
                    audioRangeSec: [audioStartSec, audioEndSec],
                    responsibleRangeSec: [respStartSec, respEndSec],
                    windows: timelineWindows ?? []
                )
                let tmpJSON = tDir.appendingPathComponent(".\(chunkId).\(UUID().uuidString).json.tmp")
                let finalJSON = tDir.appendingPathComponent("\(chunkId).json")
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(timeline)
                    try data.write(to: tmpJSON, options: .atomic)
                    let jsonAttrs = try? fm.attributesOfItem(atPath: tmpJSON.path)
                    let jsonSize = (jsonAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    guard jsonSize > 0 else {
                        throw NSError(domain: "ChunkWriter", code: -9, userInfo: [NSLocalizedDescriptionKey: "Timeline temp file wrote 0 bytes"])
                    }
                    stagedTimelineTmpURL = tmpJSON
                    finalTimelineURL = finalJSON
                    timelineRelPath = "timelines/\(chunkId).json"
                } catch {
                    try? fm.removeItem(at: tmpJSON)
                    for cleanupSpec in specs {
                        try? fm.removeItem(at: cleanupSpec.tmpURL)
                    }
                    self.recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) timeline staging failed: \(error.localizedDescription)")
                    return
                }
            }

            // 3. Atomically commit ALL track .m4a files and staged timeline JSON; roll back everything if any rename fails.
            var renamedFinalURLs: [URL] = []
            func rollbackCommit() {
                for spec in specs {
                    try? fm.removeItem(at: spec.tmpURL)
                }
                if let tmpT = stagedTimelineTmpURL {
                    try? fm.removeItem(at: tmpT)
                }
                for published in renamedFinalURLs {
                    try? fm.removeItem(at: published)
                }
            }

            for spec in specs {
                let rc = Darwin.rename(spec.tmpURL.path, spec.finalURL.path)
                guard rc == 0 else {
                    let err = errno
                    rollbackCommit()
                    self.recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) (\(spec.role)) rename failed: errno \(err)")
                    return
                }
                renamedFinalURLs.append(spec.finalURL)
            }

            if let tmpT = stagedTimelineTmpURL, let finalT = finalTimelineURL {
                let rc = Darwin.rename(tmpT.path, finalT.path)
                guard rc == 0 else {
                    let err = errno
                    rollbackCommit()
                    self.recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) timeline rename failed: errno \(err)")
                    return
                }
                renamedFinalURLs.append(finalT)
            }

            let primarySpec = specs.first(where: { $0.role == (writerMode == .dual ? "mix" : "mic") }) ?? specs[0]
            let micSpec = specs.first(where: { $0.role == "mic" })
            let remoteSpec = specs.first(where: { $0.role == "remote" })

            let record = ChunkRecord(
                index: index,
                id: chunkId,
                audioPath: "chunks/\(primarySpec.finalURL.lastPathComponent)",
                micPath: micSpec.map { "chunks/\($0.finalURL.lastPathComponent)" },
                remotePath: remoteSpec.map { "chunks/\($0.finalURL.lastPathComponent)" },
                timelinePath: timelineRelPath,
                audioRangeSec: [audioStartSec, audioEndSec],
                responsibleRangeSec: [respStartSec, respEndSec],
                durationSec: writtenDurationSec,
                byteSize: totalBytes,
                committedAt: AtomicFileWriter.isoNow()
            )

            // 4. Persist durable per-chunk commit marker BEFORE notifying Coordinator so crashes recover it cleanly (P0-4).
            let commitURL = targetCommitsDir.appendingPathComponent("\(chunkId).json")
            do {
                try AtomicFileWriter.writeJSON(record, to: commitURL)
            } catch {
                rollbackCommit()
                try? fm.removeItem(at: commitURL)
                self.recordChunkFailure(chunkId: chunkId, "Chunk \(chunkId) commit record write failed: \(error.localizedDescription)")
                return
            }

            self.resultsLock.withLock {
                self.committedChunks.append(record)
            }

            self.onChunkCommitted(record)
        }

        for spec in specs {
            spec.writerBox.writer.finishWriting {
                barrier.trackCompleted()
            }
        }
    }

    private func cancelCurrentWriterOnQueue() {
        let slots = activeTracks
        activeTracks.removeAll(keepingCapacity: true)
        expectedChunkWrittenSamples = 0
        globalSamplesWritten = currentChunkResponsibleStartSample
        currentChunkActualSamples = 0
        // Restore committed pre-chunk overlap tails so aborted chunk audio never leaks into subsequent chunks (P0-3/P0-4).
        mixOverlapTailBuffer = chunkInitialMixOverlap
        micOverlapTailBuffer = chunkInitialMicOverlap
        remoteOverlapTailBuffer = chunkInitialRemoteOverlap
        chunkInitialMixOverlap = []
        chunkInitialMicOverlap = []
        chunkInitialRemoteOverlap = []
        for slot in slots {
            slot.writer.cancelWriting()
            try? FileManager.default.removeItem(at: slot.tmpURL)
        }
    }

    private func recordChunkFailure(chunkId: String, _ message: String) {
        let isNew = resultsLock.withLock {
            failedChunkIds.insert(chunkId).inserted
        }
        if isNew {
            onChunkFailed(message)
        }
    }

    private func recordOpenFailure(_ message: String) {
        resultsLock.withLock {
            openFailureCount += 1
        }
        onChunkFailed(message)
    }

    private static func roundSec(_ value: Double) -> Double {
        (value * 1000.0).rounded() / 1000.0
    }

    // Regression tests for P0-3 short-write abort, overlap restoration across cancellation, and union coverage math.
    static func runShortWriteFailureSelfTest(tempDir: URL) throws {
        let fm = FileManager.default

        // Part 1: Abort on chunk 1 short write -> 0 committed, 1 failure, 0 orphans.
        let dir1 = tempDir.appendingPathComponent("chunk_fault_test_1")
        let chunksDir1 = dir1.appendingPathComponent("chunks")
        let timelinesDir1 = dir1.appendingPathComponent("timelines")
        if fm.fileExists(atPath: dir1.path) { try fm.removeItem(at: dir1) }

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var committed = 0
            var errors: [String] = []
            func onCommit(_: ChunkRecord) { lock.withLock { committed += 1 } }
            func onFail(_ msg: String) { lock.withLock { errors.append(msg) } }
            func summary() -> (Int, [String]) { lock.withLock { (committed, errors) } }
        }

        let collector1 = Collector()
        let writer1 = try ChunkWriter(
            chunksDir: chunksDir1,
            mode: .dual,
            timelinesDir: timelinesDir1,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            testFault: FaultInjection(role: "remote", afterSamples: 640, chunkIndex: 1),
            onChunkCommitted: { collector1.onCommit($0) },
            onChunkFailed: { collector1.onFail($0) }
        )

        let block = [Float](repeating: 0.1, count: 640)
        writer1.appendDualSamples(mix: block, mic: block, remote: block)
        writer1.appendDualSamples(mix: block, mic: block, remote: block)
        let res1 = writer1.finishAll()
        let (committed1, errors1) = collector1.summary()

        guard res1.chunks.isEmpty, committed1 == 0, res1.failedCount == 1, !errors1.isEmpty, res1.totalDurationSec == 0.0 else {
            throw NSError(domain: "ChunkWriterFaultTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Short-write chunk 1 failed assertions"])
        }
        let leftoverChunks1 = (try? fm.contentsOfDirectory(atPath: chunksDir1.path)) ?? []
        let leftoverTimelines1 = (try? fm.contentsOfDirectory(atPath: timelinesDir1.path)) ?? []
        guard leftoverChunks1.isEmpty && leftoverTimelines1.isEmpty else {
            throw NSError(domain: "ChunkWriterFaultTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "Orphan files remained after failed chunk 1"])
        }
        try? fm.removeItem(at: dir1)

        // Part 2: Chunk 1 succeeds (2.0s), Chunk 2 writes 640 frames then fails & cancels, Chunk 3 succeeds (2.0s).
        // Asserts overlap stays clean (Chunk 3 audioRangeSec starts at 1.5s, responsible [2.0, 4.0], total 4.0s).
        let dir2 = tempDir.appendingPathComponent("chunk_fault_test_2")
        if fm.fileExists(atPath: dir2.path) { try fm.removeItem(at: dir2) }
        let collector2 = Collector()
        let writer2 = try ChunkWriter(
            chunksDir: dir2.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: dir2.appendingPathComponent("timelines"),
            chunkDurationSec: 2.0, // 32_000 samples target, 0.5s (8000 samples) overlap
            expectsRealTime: false,
            testFault: FaultInjection(role: "remote", afterSamples: 8640, chunkIndex: 2),
            onChunkCommitted: { collector2.onCommit($0) },
            onChunkFailed: { collector2.onFail($0) }
        )

        let oneSec = [Float](repeating: 0.1, count: 16_000)
        // Chunk 1: 2.0s healthy
        writer2.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        writer2.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        // Chunk 2: starts cleanly with 8000 overlap, accepts 640 frames of distinct 0.9, then aborts on next 640.
        let badBlock = [Float](repeating: 0.9, count: 640)
        writer2.appendDualSamples(mix: badBlock, mic: badBlock, remote: badBlock)
        writer2.appendDualSamples(mix: badBlock, mic: badBlock, remote: badBlock)
        // Chunk 3: 2.0s healthy
        writer2.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        writer2.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let res2 = writer2.finishAll()

        guard res2.chunks.count == 2, res2.failedCount == 1, res2.totalDurationSec == 4.0,
              res2.chunks[0].audioRangeSec == [0.0, 2.0],
              res2.chunks[1].audioRangeSec == [1.5, 4.0],
              res2.chunks[1].responsibleRangeSec == [2.0, 4.0]
        else {
            throw NSError(
                domain: "ChunkWriterFaultTest",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Post-failure timing/overlap recovery invalid: chunks=\(res2.chunks.map { ($0.id, $0.audioRangeSec, $0.responsibleRangeSec) }), dur=\(res2.totalDurationSec)"]
            )
        }
        try? fm.removeItem(at: dir2)

        // Part 3: Non-contiguous interval union coverage ([0,2] and [4,6] => 4.0s, NOT 6.0s).
        let syntheticChunks = [
            ChunkRecord(index: 1, id: "c1", audioPath: "chunks/m1.m4a", micPath: nil, remotePath: nil, timelinePath: nil, audioRangeSec: [0, 2], responsibleRangeSec: [0, 2], durationSec: 2, byteSize: 1, committedAt: ""),
            ChunkRecord(index: 3, id: "c3", audioPath: "chunks/m3.m4a", micPath: nil, remotePath: nil, timelinePath: nil, audioRangeSec: [3, 6], responsibleRangeSec: [4, 6], durationSec: 3, byteSize: 1, committedAt: ""),
        ]
        guard committedCoverageDuration(for: syntheticChunks) == 4.0 else {
            throw NSError(domain: "ChunkWriterFaultTest", code: -5, userInfo: [NSLocalizedDescriptionKey: "Disjoint responsible range duration did not equal 4.0"])
        }
    }
}
