@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation

final class PCMBufferPool: @unchecked Sendable {
    static let defaultMaxPooledCapacity: AVAudioFrameCount = 32_768

    private let lock = NSLock()
    private let format: AVAudioFormat
    private var defaultCapacity: AVAudioFrameCount
    private var pool: [AVAudioPCMBuffer] = []
    private let maxPoolSize: Int
    private let maxPooledCapacity: AVAudioFrameCount = PCMBufferPool.defaultMaxPooledCapacity

    init(
        format: AVAudioFormat,
        prewarmCount: Int = 16,
        defaultCapacity: AVAudioFrameCount = 4096,
        maxPoolSize: Int = 48
    ) {
        self.format = format
        self.defaultCapacity = min(Self.defaultMaxPooledCapacity, max(512, defaultCapacity))
        self.maxPoolSize = max(4, maxPoolSize)
        for _ in 0..<prewarmCount {
            if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.defaultCapacity) {
                pool.append(buf)
            }
        }
    }

    var availableCount: Int {
        lock.withLock { pool.count }
    }

    var currentDefaultCapacity: AVAudioFrameCount {
        lock.withLock { defaultCapacity }
    }

    func checkout(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let (desiredCap, recycled): (AVAudioFrameCount, AVAudioPCMBuffer?) = lock.withLock {
            if frameCount > defaultCapacity && frameCount <= maxPooledCapacity {
                defaultCapacity = frameCount
                pool.removeAll { $0.frameCapacity < frameCount }
            }
            if let idx = pool.lastIndex(where: { $0.frameCapacity >= frameCount }) {
                return (max(frameCount, defaultCapacity), pool.remove(at: idx))
            }
            return (max(frameCount, defaultCapacity), nil)
        }

        if let recycled {
            recycled.frameLength = frameCount
            return recycled
        }

        guard let allocated = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: desiredCap) else {
            return nil
        }
        allocated.frameLength = frameCount
        return allocated
    }

    func recycle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format == format, buffer.frameCapacity <= maxPooledCapacity else { return }
        lock.withLock {
            guard buffer.frameCapacity >= defaultCapacity else { return }
            if pool.count < maxPoolSize {
                buffer.frameLength = 0
                pool.append(buffer)
            }
        }
    }
}

enum CircularRingPushResult<Element> {
    case inserted(evicted: Element?)
    case droppedIncoming
}

struct CircularRing<Element> {
    private var storage: [Element?]
    private var head: Int = 0
    private var tail: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        let safeCap = max(2, capacity)
        self.capacity = safeCap
        self.storage = Array(repeating: nil, count: safeCap)
    }

    /// Pushes an audio item. If full, evicts the OLDEST non-control element so control markers
    /// (such as `.flushGeneration`) are NEVER evicted, returning the evicted element.
    @discardableResult
    mutating func pushAudioOverwrite(_ item: Element, isControl: (Element) -> Bool) -> CircularRingPushResult<Element> {
        var evicted: Element? = nil
        if count == capacity {
            evicted = evictOldestAudioLocked(isControl: isControl)
            if evicted == nil {
                // Ring consists exclusively of control items; caller must recycle/account incoming item.
                return .droppedIncoming
            }
        }
        storage[tail] = item
        tail = (tail + 1) % capacity
        count += 1
        return .inserted(evicted: evicted)
    }

    /// Pushes a control item (e.g. `.flushGeneration`). If full, evicts the oldest non-control
    /// audio item to make room; returns any evicted audio item.
    @discardableResult
    mutating func pushControl(_ item: Element, isControl: (Element) -> Bool) -> Element? {
        var evicted: Element? = nil
        if count == capacity {
            evicted = evictOldestAudioLocked(isControl: isControl)
            if evicted == nil {
                // Fall back to evicting head only if somehow full of control markers.
                evicted = pop()
            }
        }
        storage[tail] = item
        tail = (tail + 1) % capacity
        count += 1
        return evicted
    }

    mutating func pop() -> Element? {
        guard count > 0 else { return nil }
        let item = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return item
    }

    mutating func removeAll() {
        for i in 0..<capacity {
            storage[i] = nil
        }
        head = 0
        tail = 0
        count = 0
    }

    private mutating func evictOldestAudioLocked(isControl: (Element) -> Bool) -> Element? {
        guard count > 0 else { return nil }
        var victimOffset: Int? = nil
        for offset in 0..<count {
            let idx = (head + offset) % capacity
            if let elem = storage[idx], !isControl(elem) {
                victimOffset = offset
                break
            }
        }
        guard let offset = victimOffset else { return nil }
        let victimIdx = (head + offset) % capacity
        let victim = storage[victimIdx]

        // Shift elements [0..<offset] right by one slot to keep head contiguous and preserve exact order.
        var pos = offset
        while pos > 0 {
            let dstIdx = (head + pos) % capacity
            let srcIdx = (head + pos - 1) % capacity
            storage[dstIdx] = storage[srcIdx]
            pos -= 1
        }
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return victim
    }
}

protocol PooledBufferGeneration: AnyObject, Sendable {
    var bufferPool: PCMBufferPool { get }
}

final class AudioCaptureQueue<Generation: PooledBufferGeneration>: @unchecked Sendable {
    enum Item: @unchecked Sendable {
        case audio(buffer: AVAudioPCMBuffer, generation: Generation, hostTimeNs: UInt64, captureUptime: Double)
        case flushGeneration(Generation)

        var isControlMarker: Bool {
            if case .flushGeneration = self { return true }
            return false
        }
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var head: Int = 0
    private var audioCount: Int = 0
    private let maxAudioCapacity: Int
    private var overflowStartUptime: Double?
    private var overflowEndUptime: Double?
    private var isDraining = false

    init(capacity: Int = 256) {
        self.maxAudioCapacity = max(2, capacity)
    }

    func clear() {
        var recycleList: [(AVAudioPCMBuffer, Generation)] = []
        lock.withLock {
            while head < items.count {
                let item = items[head]
                head += 1
                if case .audio(let buf, let gen, _, _) = item {
                    recycleList.append((buf, gen))
                }
            }
            items.removeAll(keepingCapacity: false)
            head = 0
            audioCount = 0
            overflowStartUptime = nil
            overflowEndUptime = nil
            isDraining = false
        }
        for (buf, gen) in recycleList {
            gen.bufferPool.recycle(buf)
        }
    }

    /// Enqueues a copied PCM buffer, bounding queued audio frames to `maxAudioCapacity`
    /// while preserving every distinct control marker in exact FIFO order.
    @discardableResult
    func enqueueAudio(
        _ buffer: AVAudioPCMBuffer,
        generation: Generation,
        hostTimeNs: UInt64,
        captureUptime: Double? = nil
    ) -> Bool {
        let ts = captureUptime ?? Self.hostTimeToUptime(hostTimeNs)
        var recycleTarget: (AVAudioPCMBuffer, Generation)? = nil
        var shouldDispatchDrain = false

        lock.withLock {
            if audioCount >= maxAudioCapacity {
                if let oldestAudioIdx = (head..<items.count).first(where: {
                    if case .audio = items[$0] { return true }
                    return false
                }) {
                    let evicted = items.remove(at: oldestAudioIdx)
                    audioCount -= 1
                    if case .audio(let oldBuf, let oldGen, _, let oldStart) = evicted {
                        let dur = Double(oldBuf.frameLength) / max(1.0, oldBuf.format.sampleRate)
                        recordOverflowSpanLocked(start: oldStart, end: oldStart + dur)
                        recycleTarget = (oldBuf, oldGen)
                    }
                }
            }

            items.append(.audio(buffer: buffer, generation: generation, hostTimeNs: hostTimeNs, captureUptime: ts))
            audioCount += 1
            compactIfNeededLocked()

            if !isDraining {
                isDraining = true
                shouldDispatchDrain = true
            }
        }

        if let (buf, gen) = recycleTarget {
            gen.bufferPool.recycle(buf)
        }
        return shouldDispatchDrain
    }

    /// Enqueues a flushGeneration control marker without dropping distinct pending generation markers.
    /// Adjacent duplicate markers for the exact same generation instance are coalesced cleanly.
    @discardableResult
    func enqueueFlushGeneration(_ generation: Generation) -> Bool {
        var shouldDispatchDrain = false

        lock.withLock {
            if head < items.count,
               let last = items.last,
               case .flushGeneration(let prevGen) = last,
               ObjectIdentifier(prevGen) == ObjectIdentifier(generation)
            {
                // Coalesce duplicate adjacent flush marker for the same generation.
            } else {
                items.append(.flushGeneration(generation))
            }

            if !isDraining {
                isDraining = true
                shouldDispatchDrain = true
            }
        }

        return shouldDispatchDrain
    }

    /// Pops the next queued item plus any accumulated evicted overflow gap `[start, end]`.
    func popNext() -> (item: Item?, overflowSpan: (start: Double, end: Double)?) {
        lock.withLock {
            let span: (start: Double, end: Double)?
            if let start = overflowStartUptime, let end = overflowEndUptime, end > start {
                span = (start, end)
            } else {
                span = nil
            }
            overflowStartUptime = nil
            overflowEndUptime = nil

            if head < items.count {
                let popped = items[head]
                head += 1
                if case .audio = popped {
                    audioCount = max(0, audioCount - 1)
                }
                compactIfNeededLocked()
                return (popped, span)
            }
            if span != nil {
                return (nil, span)
            }
            isDraining = false
            return (nil, nil)
        }
    }

    private func compactIfNeededLocked() {
        if head >= items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 {
            items.removeFirst(head)
            head = 0
        }
    }

    private func recordOverflowSpanLocked(start: Double, end: Double) {
        let clampedEnd = max(start, end)
        overflowStartUptime = overflowStartUptime.map { min($0, start) } ?? start
        overflowEndUptime = overflowEndUptime.map { max($0, clampedEnd) } ?? clampedEnd
    }

    static func hostTimeToUptime(_ hostTimeNs: UInt64) -> Double {
        MicCapture.hostTimeToUptime(hostTimeNs)
    }
}

enum AudioDownmix {
    /// Converts any mono or multi-channel PCM buffer (Float32, Float64, Int16, Int32; interleaved or planar)
    /// into a mono Float32 buffer at the input's native sample rate by averaging all channels equally.
    static func toMonoFloat32(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard frames > 0, channels > 0, input.format.sampleRate > 0 else { return nil }

        if channels == 1 && input.format.commonFormat == .pcmFormatFloat32 {
            return input
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: input.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength),
        let dst = monoBuf.floatChannelData?[0]
        else {
            return nil
        }
        monoBuf.frameLength = input.frameLength

        let invChannels = 1.0 / Float(channels)
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))

        switch input.format.commonFormat {
        case .pcmFormatFloat32:
            if !input.format.isInterleaved, let planeData = input.floatChannelData {
                let p0 = planeData[0]
                for i in 0..<frames { dst[i] = p0[i] }
                for ch in 1..<channels {
                    let pch = planeData[ch]
                    for i in 0..<frames { dst[i] += pch[i] }
                }
                if channels > 1 {
                    for i in 0..<frames { dst[i] *= invChannels }
                }
                return monoBuf
            } else if let raw = srcList.first?.mData {
                let count = Int(srcList[0].mDataByteSize) / MemoryLayout<Float>.size
                guard count >= frames * channels else { return nil }
                let interleaved = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    var sum: Float = 0
                    let base = i * channels
                    for ch in 0..<channels {
                        sum += interleaved[base + ch]
                    }
                    dst[i] = sum * invChannels
                }
                return monoBuf
            }

        case .pcmFormatFloat64:
            if !input.format.isInterleaved, srcList.count >= channels {
                var pointers: [UnsafePointer<Double>] = []
                for ch in 0..<channels {
                    guard let m = srcList[ch].mData,
                          Int(srcList[ch].mDataByteSize) >= frames * MemoryLayout<Double>.size
                    else { return nil }
                    pointers.append(UnsafePointer(m.assumingMemoryBound(to: Double.self)))
                }
                for i in 0..<frames {
                    var sum = 0.0
                    for ch in 0..<channels { sum += pointers[ch][i] }
                    dst[i] = Float(sum) * invChannels
                }
                return monoBuf
            } else if let raw = srcList.first?.mData {
                let count = Int(srcList[0].mDataByteSize) / MemoryLayout<Double>.size
                guard count >= frames * channels else { return nil }
                let interleaved = raw.assumingMemoryBound(to: Double.self)
                for i in 0..<frames {
                    var sum = 0.0
                    let base = i * channels
                    for ch in 0..<channels { sum += interleaved[base + ch] }
                    dst[i] = Float(sum) * invChannels
                }
                return monoBuf
            }

        case .pcmFormatInt16:
            let scale: Float = 1.0 / 32768.0
            if !input.format.isInterleaved, let planeData = input.int16ChannelData {
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += Float(planeData[ch][i]) * scale }
                    dst[i] = sum * invChannels
                }
                return monoBuf
            } else if let raw = srcList.first?.mData {
                let count = Int(srcList[0].mDataByteSize) / MemoryLayout<Int16>.size
                guard count >= frames * channels else { return nil }
                let interleaved = raw.assumingMemoryBound(to: Int16.self)
                for i in 0..<frames {
                    var sum: Float = 0
                    let base = i * channels
                    for ch in 0..<channels { sum += Float(interleaved[base + ch]) * scale }
                    dst[i] = sum * invChannels
                }
                return monoBuf
            }

        case .pcmFormatInt32:
            let scale: Float = 1.0 / 2147483648.0
            if !input.format.isInterleaved, let planeData = input.int32ChannelData {
                for i in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += Float(planeData[ch][i]) * scale }
                    dst[i] = sum * invChannels
                }
                return monoBuf
            } else if let raw = srcList.first?.mData {
                let count = Int(srcList[0].mDataByteSize) / MemoryLayout<Int32>.size
                guard count >= frames * channels else { return nil }
                let interleaved = raw.assumingMemoryBound(to: Int32.self)
                for i in 0..<frames {
                    var sum: Float = 0
                    let base = i * channels
                    for ch in 0..<channels { sum += Float(interleaved[base + ch]) * scale }
                    dst[i] = sum * invChannels
                }
                return monoBuf
            }

        default:
            return nil
        }

        return nil
    }
}

private final class MicGenerationContext: PooledBufferGeneration, @unchecked Sendable {
    let id: Int
    let converter: AVAudioConverter
    let monoSourceFormat: AVAudioFormat
    let bufferPool: PCMBufferPool
    var lastEndHostTimeNs: UInt64 = 0

    init(id: Int, converter: AVAudioConverter, monoSourceFormat: AVAudioFormat, sourceFormat: AVAudioFormat) {
        self.id = id
        self.converter = converter
        self.monoSourceFormat = monoSourceFormat
        let poolCap = min(
            PCMBufferPool.defaultMaxPooledCapacity,
            max(4096, AVAudioFrameCount(ceil(sourceFormat.sampleRate * 0.1)))
        )
        self.bufferPool = PCMBufferPool(format: sourceFormat, prewarmCount: 16, defaultCapacity: poolCap)
    }
}

private final class InputConsumedFlag: @unchecked Sendable {
    var used = false
}

final class MicCapture: @unchecked Sendable {
    private let onSamples: @Sendable ([Float], UInt64) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let onGap: @Sendable (Double, Double, String) -> Void
    private let onError: @Sendable (String) -> Void
    private let onFatalError: @Sendable (String) -> Void
    private let onDeviceChanged: @Sendable (String?) -> Void
    private let onFirstHostTime: @Sendable (UInt64) -> Void

    private let lifecycleQueue = DispatchQueue(label: "io.github.nolinsun.meeting.mic.lifecycle")
    private let processingQueue = DispatchQueue(label: "io.github.nolinsun.meeting.mic.processing")
    private let stateLock = NSLock()

    private var engine: AVAudioEngine?
    private var activeGeneration: MicGenerationContext?
    private var nextGenerationId: Int = 0
    private let targetFormat: AVAudioFormat

    private let captureQueue = AudioCaptureQueue<MicGenerationContext>(capacity: 256)
    private var isRunning = false
    private var isReconfiguring = false
    private var configObserver: NSObjectProtocol?
    private var smoothedLevel: Double = 0.0
    private var reportedFirstHostTime = false

    init(
        onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void,
        onGap: @escaping @Sendable (Double, Double, String) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onFatalError: @escaping @Sendable (String) -> Void,
        onDeviceChanged: @escaping @Sendable (String?) -> Void,
        onFirstHostTime: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.onGap = onGap
        self.onError = onError
        self.onFatalError = onFatalError
        self.onDeviceChanged = onDeviceChanged
        self.onFirstHostTime = onFirstHostTime
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ChunkWriter.sampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    func start() throws -> String? {
        try lifecycleQueue.sync {
            if isRunning {
                return Self.defaultInputDeviceName()
            }
            isRunning = true
            stateLock.withLock {
                reportedFirstHostTime = false
            }
            captureQueue.clear()
            do {
                try startEngineOnLifecycleQueue()
                return Self.defaultInputDeviceName()
            } catch {
                isRunning = false
                cleanupEngineOnLifecycleQueue()
                throw error
            }
        }
    }

    func stop() {
        let flushGen: MicGenerationContext? = lifecycleQueue.sync {
            isRunning = false
            isReconfiguring = false
            if let observer = configObserver {
                NotificationCenter.default.removeObserver(observer)
                configObserver = nil
            }
            if let activeEngine = engine {
                activeEngine.inputNode.removeTap(onBus: 0)
                activeEngine.stop()
            }
            return activeGeneration
        }

        if let gen = flushGen {
            enqueueFlushGeneration(gen)
        }

        processingQueue.sync {
            drainQueue()
            smoothedLevel = 0.0
            onLevel(0.0)
        }

        lifecycleQueue.sync {
            engine = nil
            activeGeneration = nil
        }
    }

    private func startEngineOnLifecycleQueue() throws {
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            throw NSError(
                domain: "MicCapture",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "未检测到可用麦克风输入设备（请检查系统声音输入设置）"]
            )
        }

        guard let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let newConverter = AVAudioConverter(from: monoSourceFormat, to: targetFormat)
        else {
            throw NSError(
                domain: "MicCapture",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "无法创建麦克风音频重采样转换器 (\(hwFormat.sampleRate)Hz -> 16kHz)"]
            )
        }

        nextGenerationId += 1
        let gen = MicGenerationContext(
            id: nextGenerationId,
            converter: newConverter,
            monoSourceFormat: monoSourceFormat,
            sourceFormat: hwFormat
        )
        self.engine = newEngine
        self.activeGeneration = gen

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            guard let self else { return }
            let ticks = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            let hostNs = Self.hostTicksToNanoseconds(ticks)
            self.recordFirstHostTimeIfNeeded(hostNs)
            self.enqueueInputBuffer(buffer, generation: gen, hostTimeNs: hostNs)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        newEngine.prepare()
        try newEngine.start()
        onDeviceChanged(Self.defaultInputDeviceName())
    }

    private func cleanupEngineOnLifecycleQueue() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let activeEngine = engine {
            activeEngine.inputNode.removeTap(onBus: 0)
            activeEngine.stop()
        }
        engine = nil
        activeGeneration = nil
    }

    private func recordFirstHostTimeIfNeeded(_ hostTimeNs: UInt64) {
        let shouldReport = stateLock.withLock { () -> Bool in
            if reportedFirstHostTime { return false }
            reportedFirstHostTime = true
            return true
        }
        if shouldReport {
            onFirstHostTime(hostTimeNs)
        }
    }

    private func enqueueInputBuffer(_ buffer: AVAudioPCMBuffer, generation: MicGenerationContext, hostTimeNs: UInt64) {
        guard let copy = copyPCMBuffer(buffer, pool: generation.bufferPool) else { return }
        if captureQueue.enqueueAudio(copy, generation: generation, hostTimeNs: hostTimeNs) {
            processingQueue.async { [weak self] in
                self?.drainQueue()
            }
        }
    }

    private func enqueueFlushGeneration(_ generation: MicGenerationContext) {
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
                onGap(span.start, span.end, "audio_queue_overflow")
            }

            guard let item = nextItem else {
                if overflowSpan != nil { continue }
                break
            }
            switch item {
            case .audio(let buffer, let generation, let hostTimeNs, _):
                processInputItem(buffer: buffer, generation: generation, hostTimeNs: hostTimeNs)
                generation.bufferPool.recycle(buffer)
            case .flushGeneration(let generation):
                flushConverter(generation)
            }
        }
    }

    private func processInputItem(buffer: AVAudioPCMBuffer, generation: MicGenerationContext, hostTimeNs: UInt64) {
        guard let monoInput = AudioDownmix.toMonoFloat32(buffer), monoInput.frameLength > 0 else { return }
        let conv = generation.converter

        let ratio = targetFormat.sampleRate / max(1.0, monoInput.format.sampleRate)
        let outCapacity = max(AVAudioFrameCount(512), AVAudioFrameCount(ceil(Double(monoInput.frameLength) * ratio)) + 64)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        let consumedFlag = InputConsumedFlag()
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
            onError("音频格式转换失败: \(error?.localizedDescription ?? "unknown")")
            return
        }

        let inputDurNs = UInt64((Double(monoInput.frameLength) / monoInput.format.sampleRate * 1_000_000_000.0).rounded())
        generation.lastEndHostTimeNs = hostTimeNs &+ inputDurNs

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0, let channelPtr = outputBuffer.floatChannelData?[0] else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channelPtr, count: frameCount))
        onSamples(samples, hostTimeNs)

        var sumSquares: Double = 0.0
        for s in samples {
            let v = Double(s)
            sumSquares += v * v
        }
        let rms = sqrt(sumSquares / Double(frameCount))
        let db = 20.0 * log10(max(rms, 1e-6))
        let normalized = min(1.0, max(0.0, (db + 55.0) / 50.0))
        smoothedLevel = smoothedLevel * 0.6 + normalized * 0.4
        onLevel(smoothedLevel)
    }

    private func flushConverter(_ generation: MicGenerationContext) {
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

    private func handleConfigurationChange() {
        lifecycleQueue.async { [weak self] in
            guard let self, self.isRunning, !self.isReconfiguring else { return }
            self.isReconfiguring = true
            let gapStartUptime = ProcessInfo.processInfo.systemUptime
            let prevGen = self.activeGeneration
            self.cleanupEngineOnLifecycleQueue()

            if let prevGen {
                self.enqueueFlushGeneration(prevGen)
            }

            self.attemptRestartOnLifecycleQueue(gapStartUptime: gapStartUptime, attempt: 1)
        }
    }

    private func attemptRestartOnLifecycleQueue(gapStartUptime: Double, attempt: Int) {
        let delay: TimeInterval = attempt == 1 ? 0.25 : 0.50
        lifecycleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.isRunning else {
                self.isReconfiguring = false
                return
            }
            do {
                try self.startEngineOnLifecycleQueue()
                self.isReconfiguring = false
                let gapEndUptime = ProcessInfo.processInfo.systemUptime
                self.onGap(gapStartUptime, gapEndUptime, "audio_device_changed")
            } catch {
                if attempt < 2 {
                    self.attemptRestartOnLifecycleQueue(gapStartUptime: gapStartUptime, attempt: attempt + 1)
                } else {
                    self.isReconfiguring = false
                    self.isRunning = false
                    let gapEndUptime = ProcessInfo.processInfo.systemUptime
                    self.onGap(gapStartUptime, gapEndUptime, "audio_device_lost")
                    self.onFatalError("音频设备切换后恢复采集失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func copyPCMBuffer(_ src: AVAudioPCMBuffer, pool: PCMBufferPool) -> AVAudioPCMBuffer? {
        guard src.frameLength > 0, let copy = pool.checkout(frameCount: src.frameLength) else {
            return nil
        }
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let count = min(srcList.count, dstList.count)
        for i in 0..<count {
            if let sData = srcList[i].mData, let dData = dstList[i].mData {
                let bytes = min(Int(srcList[i].mDataByteSize), Int(dstList[i].mDataByteSize))
                memcpy(dData, sData, bytes)
                dstList[i].mDataByteSize = UInt32(bytes)
            }
        }
        return copy
    }

    static func hostTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom > 0 else { return ticks }
        let (prod, overflow) = ticks.multipliedReportingOverflow(by: UInt64(info.numer))
        if !overflow {
            return prod / UInt64(info.denom)
        }
        return UInt64((Double(ticks) * Double(info.numer)) / Double(info.denom))
    }

    static func hostTimeToUptime(_ hostTimeNs: UInt64) -> Double {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        guard hostTimeNs > 0 else { return nowUptime }
        let nowHostNs = hostTicksToNanoseconds(mach_absolute_time())
        if nowHostNs >= hostTimeNs {
            let deltaSec = Double(nowHostNs - hostTimeNs) / 1_000_000_000.0
            return max(0.0, nowUptime - deltaSec)
        } else {
            let deltaSec = Double(hostTimeNs - nowHostNs) / 1_000_000_000.0
            return nowUptime + deltaSec
        }
    }

    static func defaultInputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
        guard status == noErr, deviceID != 0 else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name)
        guard nameStatus == noErr, let cfName = name?.takeRetainedValue() else {
            return nil
        }
        return cfName as String
    }

    // Verifies 48kHz->16kHz tail drain, stereo right-only mic downmix, and pooled/control-safe ring behavior.
    static func runConverterTailDrainSelfTest() throws {
        guard let mono48Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let stereo48Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mono48Format, to: dstFormat)
        else {
            throw NSError(domain: "MicCaptureSelfTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize 48k->16k converter"])
        }

        // 1. P1-4 regression: 40 consecutive 4096-frame checkouts & returns reuse pooled buffer instances.
        let testPool = PCMBufferPool(format: stereo48Format, prewarmCount: 2, defaultCapacity: 4096)
        var seenPointers: Set<ObjectIdentifier> = []
        for _ in 0..<40 {
            guard let b = testPool.checkout(frameCount: 4096) else {
                throw NSError(domain: "MicCaptureSelfTest", code: -20, userInfo: [NSLocalizedDescriptionKey: "Pool checkout failed"])
            }
            seenPointers.insert(ObjectIdentifier(b))
            testPool.recycle(b)
        }
        guard seenPointers.count <= 2 else {
            throw NSError(
                domain: "MicCaptureSelfTest",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "PCMBufferPool allocated \(seenPointers.count) buffers instead of reusing pool"]
            )
        }

        // 2. P1-5 regression: full ring preserves control markers when pushed before/after audio overflow.
        var testRing = CircularRing<Int>(capacity: 4)
        let isControl: (Int) -> Bool = { $0 < 0 }
        _ = testRing.pushAudioOverwrite(1, isControl: isControl)
        _ = testRing.pushControl(-99, isControl: isControl)
        _ = testRing.pushAudioOverwrite(2, isControl: isControl)
        _ = testRing.pushAudioOverwrite(3, isControl: isControl)
        _ = testRing.pushAudioOverwrite(4, isControl: isControl) // overflows: must evict 1, NOT -99!
        _ = testRing.pushAudioOverwrite(5, isControl: isControl) // overflows: must evict 2, NOT -99!
        var drained: [Int] = []
        while let v = testRing.pop() { drained.append(v) }
        guard drained == [-99, 3, 4, 5] else {
            throw NSError(
                domain: "MicCaptureSelfTest",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "CircularRing evicted control marker or corrupted order: \(drained)"]
            )
        }

        // 2b. Verify ring overflow emits non-zero duration gap interval (P1-4/P1-5).
        var ovRing = CircularRing<AudioCaptureQueue<MicGenerationContext>.Item>(capacity: 2)
        let ovGen = MicGenerationContext(id: 99, converter: conv, monoSourceFormat: mono48Format, sourceFormat: mono48Format)
        var droppedDurSec = 0.0
        for k in 0..<3 {
            guard let b = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800) else { break }
            b.frameLength = 4800 // 0.1s
            if case .inserted(let evicted) = ovRing.pushAudioOverwrite(
                .audio(buffer: b, generation: ovGen, hostTimeNs: 0, captureUptime: Double(k) * 0.1),
                isControl: { $0.isControlMarker }
            ),
               let evicted,
               case .audio(let eb, _, _, _) = evicted {
                droppedDurSec += Double(eb.frameLength) / eb.format.sampleRate
            }
        }
        guard abs(droppedDurSec - 0.1) < 0.01 else {
            throw NSError(domain: "MicCaptureSelfTest", code: -23, userInfo: [NSLocalizedDescriptionKey: "Overflow dropped duration mismatch: \(droppedDurSec)"])
        }

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var samples: [Float] = []
            func append(_ s: [Float]) { lock.withLock { samples.append(contentsOf: s) } }
            func all() -> [Float] { lock.withLock { samples } }
        }

        // 3. Stereo right-only mic input -> must preserve right channel via AudioDownmix + converter.
        let rightCollector = Collector()
        let rightCap = MicCapture(
            onSamples: { samples, _ in rightCollector.append(samples) },
            onLevel: { _ in },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onDeviceChanged: { _ in }
        )
        let rightGen = MicGenerationContext(id: 1, converter: conv, monoSourceFormat: mono48Format, sourceFormat: stereo48Format)
        for b in 0..<10 {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: stereo48Format, frameCapacity: 4800) else {
                throw NSError(domain: "MicCaptureSelfTest", code: -10, userInfo: [NSLocalizedDescriptionKey: "PCM alloc failed"])
            }
            pcm.frameLength = 4800
            let left = pcm.floatChannelData![0]
            let right = pcm.floatChannelData![1]
            memset(left, 0, 4800 * MemoryLayout<Float>.size)
            for j in 0..<4800 {
                let t = Double(b * 4800 + j) / 48_000.0
                right[j] = 0.5 * Float(sin(2.0 * .pi * 550.0 * t))
            }
            rightCap.enqueueInputBuffer(pcm, generation: rightGen, hostTimeNs: UInt64(b) * 100_000_000)
        }
        rightCap.enqueueFlushGeneration(rightGen)
        rightCap.processingQueue.sync { rightCap.drainQueue() }
        let rightOut = rightCollector.all()
        let rightRMS = sqrt(rightOut.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, rightOut.count)))
        guard rightRMS > 0.08 else {
            throw NSError(
                domain: "MicCaptureSelfTest",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Right-only stereo mic dropped during downmix (rms=\(rightRMS))"]
            )
        }

        // 4. 2.0s 48kHz tail drain check.
        guard let conv2 = AVAudioConverter(from: mono48Format, to: dstFormat) else {
            throw NSError(domain: "MicCaptureSelfTest", code: -12, userInfo: [NSLocalizedDescriptionKey: "Converter init failed"])
        }
        let collector = Collector()
        let capture = MicCapture(
            onSamples: { samples, _ in collector.append(samples) },
            onLevel: { _ in },
            onGap: { _, _, _ in },
            onError: { _ in },
            onFatalError: { _ in },
            onDeviceChanged: { _ in }
        )

        let gen = MicGenerationContext(id: 2, converter: conv2, monoSourceFormat: mono48Format, sourceFormat: mono48Format)
        let totalInFrames = 96_000
        let chunkFrames = 4000
        var idx = 0
        while idx < totalInFrames {
            let count = min(chunkFrames, totalInFrames - idx)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: AVAudioFrameCount(count)) else {
                throw NSError(domain: "MicCaptureSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
            }
            pcm.frameLength = AVAudioFrameCount(count)
            let ptr = pcm.floatChannelData![0]
            for j in 0..<count {
                let sampleIdx = idx + j
                let t = Double(sampleIdx) / 48_000.0
                let isTailPulse = sampleIdx >= (totalInFrames - 12_000)
                let amp: Float = isTailPulse ? 0.5 : 0.1
                let freq = isTailPulse ? 1200.0 : 440.0
                ptr[j] = amp * Float(sin(2.0 * .pi * freq * t))
            }
            let ts = UInt64((Double(idx) / 48_000.0) * 1_000_000_000.0)
            capture.enqueueInputBuffer(pcm, generation: gen, hostTimeNs: ts)
            idx += count
        }

        capture.enqueueFlushGeneration(gen)
        capture.processingQueue.sync {
            capture.drainQueue()
        }

        let out = collector.all()
        guard out.count >= 31_800 && out.count <= 32_200 else {
            throw NSError(
                domain: "MicCaptureSelfTest",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected drained output frame count: \(out.count) (expected ~32000)"]
            )
        }

        let tailSlice = Array(out.suffix(1600))
        let tailRMS = sqrt(tailSlice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tailSlice.count))
        guard tailRMS > 0.15 else {
            throw NSError(
                domain: "MicCaptureSelfTest",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Final tail audio pulse lost during converter drain (tailRMS=\(tailRMS))"]
            )
        }

        // 5. PCMBufferPool full-pool 8192-frame upgrade & 192kHz (19200-frame) reuse checks.
        let fullPool = PCMBufferPool(format: mono48Format, prewarmCount: 48, defaultCapacity: 4096, maxPoolSize: 48)
        guard fullPool.availableCount == 48 else {
            throw NSError(domain: "MicCaptureSelfTest", code: -13, userInfo: [NSLocalizedDescriptionKey: "Pool prewarm mismatch"])
        }
        guard let upgraded8192 = fullPool.checkout(frameCount: 8192) else {
            throw NSError(domain: "MicCaptureSelfTest", code: -14, userInfo: [NSLocalizedDescriptionKey: "8192 checkout failed"])
        }
        guard upgraded8192.frameCapacity >= 8192, fullPool.availableCount == 0 else {
            throw NSError(domain: "MicCaptureSelfTest", code: -15, userInfo: [NSLocalizedDescriptionKey: "Stale 4096 buffers were not evicted on 8192 upgrade"])
        }
        fullPool.recycle(upgraded8192)
        guard fullPool.availableCount == 1,
              let reused8192 = fullPool.checkout(frameCount: 8192),
              ObjectIdentifier(reused8192) == ObjectIdentifier(upgraded8192)
        else {
            throw NSError(domain: "MicCaptureSelfTest", code: -16, userInfo: [NSLocalizedDescriptionKey: "8192 buffer was not reused after recycle"])
        }

        guard let fmt192 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 192_000, channels: 2, interleaved: false) else {
            throw NSError(domain: "MicCaptureSelfTest", code: -17, userInfo: [NSLocalizedDescriptionKey: "192k format alloc failed"])
        }
        let pool192 = PCMBufferPool(format: fmt192, prewarmCount: 4, defaultCapacity: 4096, maxPoolSize: 8)
        guard let buf192 = pool192.checkout(frameCount: 19_200), buf192.frameCapacity == 19_200 else {
            throw NSError(domain: "MicCaptureSelfTest", code: -18, userInfo: [NSLocalizedDescriptionKey: "192k 19200-frame checkout failed"])
        }
        pool192.recycle(buf192)
        guard let reused192 = pool192.checkout(frameCount: 19_200),
              ObjectIdentifier(reused192) == ObjectIdentifier(buf192)
        else {
            throw NSError(domain: "MicCaptureSelfTest", code: -19, userInfo: [NSLocalizedDescriptionKey: "192k 19200-frame buffer was not pooled for reuse"])
        }

        // 6. AudioCaptureQueue evicted-buffer timestamp attribution without evicting audio on control enqueue.
        let testQueue = AudioCaptureQueue<MicGenerationContext>(capacity: 3)
        guard let b0 = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800),
              let b1 = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800),
              let b2 = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800),
              let b3 = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800),
              let b4 = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800)
        else {
            throw NSError(domain: "MicCaptureSelfTest", code: -20, userInfo: [NSLocalizedDescriptionKey: "Queue test PCM alloc failed"])
        }
        b0.frameLength = 4800 // 0.1s
        b1.frameLength = 4800 // 0.1s
        b2.frameLength = 4800 // 0.1s
        b3.frameLength = 4800 // 0.1s
        b4.frameLength = 4800 // 0.1s
        testQueue.enqueueAudio(b0, generation: gen, hostTimeNs: 0, captureUptime: 10.0)
        testQueue.enqueueAudio(b1, generation: gen, hostTimeNs: 0, captureUptime: 10.1)
        testQueue.enqueueAudio(b2, generation: gen, hostTimeNs: 0, captureUptime: 10.2)
        // Evicts b0 [10.0, 10.1)
        testQueue.enqueueAudio(b3, generation: gen, hostTimeNs: 0, captureUptime: 10.3)
        // Evicts b1 [10.1, 10.2)
        testQueue.enqueueAudio(b4, generation: gen, hostTimeNs: 0, captureUptime: 10.4)
        // Control flush preserves remaining audio b2, b3, b4 without extra audio loss.
        testQueue.enqueueFlushGeneration(gen)
        let firstPop = testQueue.popNext()
        guard let span = firstPop.overflowSpan,
              abs(span.start - 10.0) < 0.001,
              abs(span.end - 10.2) < 0.001
        else {
            throw NSError(
                domain: "MicCaptureSelfTest",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Evicted queue span mismatch: \(String(describing: firstPop.overflowSpan))"]
            )
        }
        // Drain b3, b4 and verify final item is the preserved flushGeneration control marker.
        _ = testQueue.popNext()
        _ = testQueue.popNext()
        let tailCtrl = testQueue.popNext()
        guard case .flushGeneration = tailCtrl.item else {
            throw NSError(domain: "MicCaptureSelfTest", code: -21, userInfo: [NSLocalizedDescriptionKey: "Trailing flushGeneration missing after audio overflow"])
        }

        // 7. 384 kHz format clamps pool defaultCapacity <= 32,768 so small callbacks reuse buffers cleanly.
        guard let fmt384 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 384_000, channels: 2, interleaved: false) else {
            throw NSError(domain: "MicCaptureSelfTest", code: -24, userInfo: [NSLocalizedDescriptionKey: "384k format alloc failed"])
        }
        let pool384 = PCMBufferPool(format: fmt384, prewarmCount: 4, defaultCapacity: 38_400, maxPoolSize: 8)
        guard pool384.currentDefaultCapacity == PCMBufferPool.defaultMaxPooledCapacity else {
            throw NSError(domain: "MicCaptureSelfTest", code: -25, userInfo: [NSLocalizedDescriptionKey: "384k pool defaultCapacity exceeded 32768"])
        }
        var seen384: Set<ObjectIdentifier> = []
        for _ in 0..<40 {
            guard let b = pool384.checkout(frameCount: 4096) else {
                throw NSError(domain: "MicCaptureSelfTest", code: -26, userInfo: [NSLocalizedDescriptionKey: "384k checkout failed"])
            }
            seen384.insert(ObjectIdentifier(b))
            pool384.recycle(b)
        }
        guard seen384.count <= 2, pool384.availableCount > 0 else {
            throw NSError(domain: "MicCaptureSelfTest", code: -27, userInfo: [NSLocalizedDescriptionKey: "384k 4096-frame callbacks were not reused: unique=\(seen384.count) pool=\(pool384.availableCount)"])
        }

        // 8. 257 distinct flushGeneration control markers must all survive in exact FIFO order; adjacent duplicate coalesced.
        let ctrlQueue = AudioCaptureQueue<MicGenerationContext>(capacity: 256)
        var gens: [MicGenerationContext] = []
        gens.reserveCapacity(257)
        for gid in 1...257 {
            let g = MicGenerationContext(id: gid, converter: conv, monoSourceFormat: mono48Format, sourceFormat: mono48Format)
            gens.append(g)
            ctrlQueue.enqueueFlushGeneration(g)
        }
        // Adjacent duplicate for generation 257 should coalesce cleanly.
        ctrlQueue.enqueueFlushGeneration(gens[256])

        var poppedIds: [Int] = []
        while true {
            let next = ctrlQueue.popNext()
            guard let item = next.item else { break }
            if case .flushGeneration(let poppedGen) = item {
                poppedIds.append(poppedGen.id)
            }
        }
        guard poppedIds == Array(1...257) else {
            throw NSError(domain: "MicCaptureSelfTest", code: -28, userInfo: [NSLocalizedDescriptionKey: "Distinct control markers lost or out of order: count=\(poppedIds.count)"])
        }

        // Old control-plus-audio queue preserves control markers alongside audio without dropping incoming audio.
        let ctrlFullQueue = AudioCaptureQueue<MicGenerationContext>(capacity: 2)
        ctrlFullQueue.enqueueFlushGeneration(gen)
        ctrlFullQueue.enqueueFlushGeneration(gen)
        guard let bDrop = AVAudioPCMBuffer(pcmFormat: mono48Format, frameCapacity: 4800) else {
            throw NSError(domain: "MicCaptureSelfTest", code: -22, userInfo: [NSLocalizedDescriptionKey: "Drop test PCM alloc failed"])
        }
        bDrop.frameLength = 4800
        ctrlFullQueue.enqueueAudio(bDrop, generation: gen, hostTimeNs: 0, captureUptime: 42.5)
        let ctrlPop1 = ctrlFullQueue.popNext()
        let ctrlPop2 = ctrlFullQueue.popNext()
        guard case .flushGeneration = ctrlPop1.item,
              case .audio(_, _, _, let tsKeep) = ctrlPop2.item,
              abs(tsKeep - 42.5) < 0.001
        else {
            throw NSError(domain: "MicCaptureSelfTest", code: -23, userInfo: [NSLocalizedDescriptionKey: "Control-heavy queue failed to preserve control + incoming audio"])
        }
    }
}
