import AudioToolbox
import AVFoundation
import Darwin
import Foundation

enum CoordinatorError: Error, LocalizedError {
    case conflict(String, meetingId: String?)
    case badRequest(String)
    case permissionDenied(String)
    case notSupportedYet(String)
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let msg, _): return msg
        case .badRequest(let msg): return msg
        case .permissionDenied(let msg): return msg
        case .notSupportedYet(let msg): return msg
        case .internalError(let msg): return msg
        }
    }

    var httpStatus: Int {
        switch self {
        case .conflict: return 409
        case .badRequest: return 400
        case .permissionDenied: return 403
        case .notSupportedYet: return 400
        case .internalError: return 500
        }
    }
}

private final class FinalizationWaiter: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var outcome: Result<(snapshot: RecorderStateSnapshot, manifest: MeetingManifest?), Error>?

    init() {
        group.enter()
    }

    func complete(with result: Result<(snapshot: RecorderStateSnapshot, manifest: MeetingManifest?), Error>) {
        lock.withLock {
            if outcome == nil {
                outcome = result
            }
        }
        group.leave()
    }

    func wait() throws -> (snapshot: RecorderStateSnapshot, manifest: MeetingManifest?) {
        group.wait()
        return try lock.withLock {
            guard let outcome else {
                throw CoordinatorError.internalError("最终封包结果丢失")
            }
            return try outcome.get()
        }
    }
}

private final class StartAttemptWaiter: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var outcome: Result<RecorderStateSnapshot, Error>?

    init() {
        group.enter()
    }

    func complete(with result: Result<RecorderStateSnapshot, Error>) {
        let shouldLeave: Bool = lock.withLock {
            guard outcome == nil else { return false }
            outcome = result
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }

    func wait() throws -> RecorderStateSnapshot {
        group.wait()
        return try lock.withLock {
            guard let outcome else {
                throw CoordinatorError.internalError("会议启动结果丢失")
            }
            return try outcome.get()
        }
    }
}

final class RecorderCoordinator: @unchecked Sendable {
    let dataDir: URL
    private let defaultChunkDurationSec: Double
    private let lock = NSLock()
    private let manifestIOQueue = DispatchQueue(label: "io.github.nolinsun.meeting.manifestio")

    private var state: String = "idle" // idle | starting | recording | finalizing | error
    private var isShuttingDown = false
    private var startingWaiter: StartAttemptWaiter?
    private var finalizationWaiter: FinalizationWaiter?

    private var activeMeetingId: String?
    private var activeTitle: String?
    private var activeMode: String?
    private var activeManifest: MeetingManifest?
    private var activeManifestURL: URL?
    private var activeWriter: ChunkWriter?
    private var activeMixer: DualTrackMixer?
    private var activeMic: MicCapture?
    private var activeSystemAudio: SystemAudioCapture?
    private var activeDualTapEpoch: UInt64?
    private var sessionStartUptime: TimeInterval = 0
    private var meLevel: Double = 0.0
    private var remoteLevel: Double = 0.0
    private var inputDeviceName: String?
    private var outputDeviceName: String?
    private var systemAudioDegraded = false
    private var activeIdempotencyKey: String?
    private var lastError: String?
    private var idempotencyMap: [String: String] = [:]
    private var lastTerminalStop: (meetingId: String, result: Result<(snapshot: RecorderStateSnapshot, manifest: MeetingManifest?), Error>)?

    var onStateChanged: (@Sendable () -> Void)?

    init(dataDir: URL, defaultChunkDurationSec: Double = ChunkWriter.defaultChunkDurationSec) {
        self.dataDir = dataDir
        self.defaultChunkDurationSec = defaultChunkDurationSec
    }

    func snapshot() -> RecorderStateSnapshot {
        lock.withLock {
            buildSnapshotLocked()
        }
    }

    func isBusy() -> Bool {
        lock.withLock {
            state == "starting" || state == "recording" || state == "finalizing"
        }
    }

    func beginShutdown() {
        lock.withLock {
            isShuttingDown = true
        }
    }

    func tryBeginIdleShutdown(idleSeconds: Double, threshold: Double) -> Bool {
        lock.withLock {
            guard !isShuttingDown,
                  (state == "idle" || state == "error"),
                  idleSeconds >= threshold
            else {
                return false
            }
            isShuttingDown = true
            return true
        }
    }

    func recoverOrphanedSessionsOnStartup() {
        let fm = FileManager.default
        let meetingsDir = dataDir.appendingPathComponent("meetings")
        guard let entries = try? fm.contentsOfDirectory(
            at: meetingsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()

        struct StoredFileIdentity: Codable, Hashable {
            let dev: Int64?
            let ino: UInt64?

            init(_ fid: FileIdentity) {
                self.dev = Int64(fid.dev)
                self.ino = UInt64(fid.ino)
            }

            var fileIdentity: FileIdentity? {
                guard let dev, let ino,
                      let d = dev_t(exactly: dev),
                      let i = ino_t(exactly: ino)
                else {
                    return nil
                }
                return FileIdentity(dev: d, ino: i)
            }

            private enum CodingKeys: String, CodingKey {
                case dev
                case ino
            }

            init(from decoder: Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                      let d = try? container.decode(Int64.self, forKey: .dev),
                      let i = try? container.decode(UInt64.self, forKey: .ino)
                else {
                    self.dev = nil
                    self.ino = nil
                    return
                }
                self.dev = d
                self.ino = i
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(dev, forKey: .dev)
                try container.encodeIfPresent(ino, forKey: .ino)
            }
        }

        struct PendingCleanupRecord: Codable {
            let paths: [String]
            let protectedIdentities: [StoredFileIdentity]?

            init(paths: [String], protectedIdentities: [StoredFileIdentity]? = nil) {
                self.paths = paths
                self.protectedIdentities = protectedIdentities
            }

            private enum CodingKeys: String, CodingKey {
                case paths
                case protectedIdentities
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.paths = try container.decode([String].self, forKey: .paths)
                if container.contains(.protectedIdentities) {
                    if (try? container.decodeNil(forKey: .protectedIdentities)) == true {
                        self.protectedIdentities = nil
                    } else if let list = try? container.decode([StoredFileIdentity].self, forKey: .protectedIdentities) {
                        self.protectedIdentities = list
                    } else if let single = try? container.decode(StoredFileIdentity.self, forKey: .protectedIdentities),
                              single.fileIdentity != nil {
                        self.protectedIdentities = [single]
                    } else {
                        self.protectedIdentities = nil
                    }
                } else {
                    self.protectedIdentities = nil
                }
            }
        }

        func isNotFoundError(_ error: Error) -> Bool {
            Self.isNotFoundErrorStatic(error)
        }

        func normalizeRel(_ rel: String) -> String {
            var s = rel
            while s.hasPrefix("./") { s.removeFirst(2) }
            while s.hasPrefix("/") { s.removeFirst() }
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }

        func collectProtectedPathsAndIdentities(
            in dirURL: URL,
            relPaths: [String]
        ) -> (relPaths: Set<String>, identities: Set<FileIdentity>, hadTransientError: Bool) {
            var relSet: Set<String> = []
            var idSet = Set<FileIdentity>()
            let rootFD = Darwin.open(dirURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if rootFD < 0 {
                let err = errno
                let isMissingOrLink = (err == ENOENT || err == ELOOP || err == ENOTDIR)
                return (relSet, idSet, !isMissingOrLink)
            }
            defer { _ = Darwin.close(rootFD) }

            var hadTransient = false
            let allRels = ["manifest.json", ".pending_cleanup.json"] + relPaths
            for raw in allRels {
                let norm = normalizeRel(raw)
                guard !norm.isEmpty else { continue }
                relSet.insert(norm)
                if Self.collectIdentitiesNoFollow(rootFD: rootFD, relPath: norm, into: &idSet) {
                    hadTransient = true
                }
                var cur = norm
                while let slash = cur.lastIndex(of: "/") {
                    cur = String(cur[..<slash])
                    if cur.isEmpty { break }
                    relSet.insert(cur)
                }
            }
            return (relSet, idSet, hadTransient)
        }

        func drainPendingCleanup(
            in dirURL: URL,
            activeManifest: MeetingManifest,
            extraProtectedIdentities: Set<FileIdentity> = []
        ) {
            let pendingURL = dirURL.appendingPathComponent(".pending_cleanup.json")
            let data: Data
            switch Self.readRegularFileDataNoFollow(rootDir: dirURL, relPath: ".pending_cleanup.json", requireNonEmpty: false) {
            case .data(let bytes):
                data = bytes
            case .invalid, .transientError:
                return
            }
            guard !data.isEmpty, let record = try? decoder.decode(PendingCleanupRecord.self, from: data) else {
                if case .regular = Self.lstatKind(at: pendingURL) {
                    _ = Darwin.unlink(pendingURL.path)
                }
                return
            }

            let rootFD = Darwin.open(dirURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard rootFD >= 0 else {
                return
            }
            defer { _ = Darwin.close(rootFD) }

            let chunkRels = activeManifest.chunks.flatMap { chunk in
                [chunk.audioPath, chunk.micPath, chunk.remotePath, chunk.timelinePath].compactMap { $0 }
            }
            let (protectedRelPaths, collectedIdentities, hadCollectError) = collectProtectedPathsAndIdentities(in: dirURL, relPaths: chunkRels)
            if hadCollectError {
                return
            }
            let journalProtected = Set((record.protectedIdentities ?? []).compactMap(\.fileIdentity))
            let isLegacyJournal = ((record.protectedIdentities == nil || journalProtected.isEmpty) && extraProtectedIdentities.isEmpty)
            let protectedIdentities = collectedIdentities
                .union(extraProtectedIdentities)
                .union(journalProtected)
            let protectedLowerRelPaths = Set(protectedRelPaths.map { $0.lowercased() })

            var remaining: [String] = []
            for rawRel in record.paths {
                let rel = normalizeRel(rawRel)
                let relLower = rel.lowercased()
                guard !rel.isEmpty,
                      rel != ".",
                      !rawRel.hasPrefix("/"),
                      !rel.contains(".."),
                      !protectedLowerRelPaths.contains(relLower),
                      !protectedLowerRelPaths.contains(where: { $0.hasPrefix(relLower + "/") })
                else { continue }

                if Self.removeEntryNoFollow(
                    rootFD: rootFD,
                    relPath: rel,
                    protectedIdentities: protectedIdentities,
                    isLegacyJournal: isLegacyJournal,
                    expectedMeetingId: activeManifest.id
                ) == .retryLater {
                    remaining.append(rel)
                }
            }
            if remaining.isEmpty {
                if case .regular = Self.lstatKind(at: pendingURL) {
                    _ = Darwin.unlink(pendingURL.path)
                }
            } else if case .regular = Self.lstatKind(at: pendingURL) {
                try? AtomicFileWriter.writeJSON(
                    PendingCleanupRecord(
                        paths: remaining,
                        protectedIdentities: isLegacyJournal ? nil : protectedIdentities.map(StoredFileIdentity.init)
                    ),
                    to: pendingURL
                )
            }
        }

        func decodeAndValidateAudioFile(in dirURL: URL, relPath: String, expectedDurationSec: Double) -> AssetValidationResult {
            let openedFD: Int32
            let openedSize: Int64
            switch Self.openRegularFileNoFollow(rootDir: dirURL, relPath: relPath) {
            case .opened(let fd, let sz):
                openedFD = fd
                openedSize = sz
            case .invalid:
                return .invalid
            case .transientError:
                return .transientError
            }
            defer { _ = Darwin.close(openedFD) }

            let fdCtx = FDReadContext(fd: openedFD, size: openedSize)
            return withExtendedLifetime(fdCtx) {
                func classifyAudioStatus(_ status: OSStatus, isCodecSetupForAAC: Bool = false) -> AssetValidationResult {
                    if fdCtx.transientReadError {
                        return .transientError
                    }
                    return Self.classifyCoreAudioStatus(status, isCodecSetupForAAC: isCodecSetupForAAC)
                }

                let readProc: AudioFile_ReadProc = { clientData, inPosition, requestCount, buffer, actualCount in
                    let ctx = Unmanaged<FDReadContext>.fromOpaque(clientData).takeUnretainedValue()
                    if inPosition < 0 {
                        actualCount.pointee = 0
                        return OSStatus(kAudioFilePositionError)
                    }
                    var totalRead = 0
                    let want = Int(requestCount)
                    while totalRead < want {
                        let n = Darwin.pread(
                            ctx.fd,
                            buffer.advanced(by: totalRead),
                            want - totalRead,
                            off_t(inPosition) + off_t(totalRead)
                        )
                        if n > 0 {
                            totalRead += n
                            continue
                        }
                        if n == 0 {
                            break
                        }
                        let err = errno
                        if err == EINTR {
                            continue
                        }
                        ctx.transientReadError = true
                        actualCount.pointee = UInt32(totalRead)
                        return OSStatus(err)
                    }
                    actualCount.pointee = UInt32(totalRead)
                    return noErr
                }

                let getSizeProc: AudioFile_GetSizeProc = { clientData in
                    Unmanaged<FDReadContext>.fromOpaque(clientData).takeUnretainedValue().size
                }

                // Use pure C AudioToolbox AudioFile + ExtAudioFile APIs backed by O_NOFOLLOW fd reads
                // so symlinks cannot be followed and malformed files never raise ObjC NSExceptions (P0-4 / #7).
                let rawCtx = Unmanaged.passUnretained(fdCtx).toOpaque()
                let fileTypeHint: AudioFileTypeID = relPath.lowercased().hasSuffix(".m4a") ? kAudioFileM4AType : 0
                var audioFileOpt: AudioFileID?
                let openAFSt = AudioFileOpenWithCallbacks(
                    rawCtx,
                    readProc,
                    nil,
                    getSizeProc,
                    nil,
                    fileTypeHint,
                    &audioFileOpt
                )
                guard openAFSt == noErr, let audioFileID = audioFileOpt else {
                    return classifyAudioStatus(openAFSt)
                }
                defer { _ = AudioFileClose(audioFileID) }

                var extFileOpt: ExtAudioFileRef?
                let wrapSt = ExtAudioFileWrapAudioFileID(audioFileID, false, &extFileOpt)
                guard wrapSt == noErr, let extFile = extFileOpt else {
                    return classifyAudioStatus(wrapSt)
                }
                defer { _ = ExtAudioFileDispose(extFile) }

                var fileASBD = AudioStreamBasicDescription()
                var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                let fmtSt = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &asbdSize, &fileASBD)
                guard fmtSt == noErr else {
                    return classifyAudioStatus(fmtSt)
                }

                var totalDeclared: Int64 = 0
                var lenSize = UInt32(MemoryLayout<Int64>.size)
                let lenSt = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &lenSize, &totalDeclared)
                guard lenSt == noErr else {
                    return classifyAudioStatus(lenSt)
                }

                if fdCtx.transientReadError {
                    return .transientError
                }
                let sr = fileASBD.mSampleRate
                let channels = fileASBD.mChannelsPerFrame
                guard sr > 0, channels > 0, totalDeclared > 0 else {
                    return .invalid
                }

                let isAACSource = (fileASBD.mFormatID == kAudioFormatMPEG4AAC)
                var clientASBD = AudioStreamBasicDescription(
                    mSampleRate: sr,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: 4 * channels,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 4 * channels,
                    mChannelsPerFrame: channels,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
                let setClientSt = ExtAudioFileSetProperty(
                    extFile,
                    kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                    &clientASBD
                )
                guard setClientSt == noErr else {
                    return classifyAudioStatus(setClientSt, isCodecSetupForAAC: isAACSource)
                }

                let maxFrames: UInt32 = 4096
                var scratch = [Float](repeating: 0, count: Int(maxFrames) * Int(channels))
                var decodedFrames: Int64 = 0
                while true {
                    var framesToRead = maxFrames
                    let readSt: OSStatus = scratch.withUnsafeMutableBytes { rawBuf in
                        var abl = AudioBufferList(
                            mNumberBuffers: 1,
                            mBuffers: AudioBuffer(
                                mNumberChannels: channels,
                                mDataByteSize: UInt32(rawBuf.count),
                                mData: rawBuf.baseAddress
                            )
                        )
                        return ExtAudioFileRead(extFile, &framesToRead, &abl)
                    }
                    if readSt != noErr {
                        return classifyAudioStatus(readSt, isCodecSetupForAAC: isAACSource)
                    }
                    if framesToRead == 0 {
                        break
                    }
                    decodedFrames += Int64(framesToRead)
                }

                var tellPos: Int64 = 0
                let tellSt = ExtAudioFileTell(extFile, &tellPos)
                guard tellSt == noErr else {
                    return classifyAudioStatus(tellSt)
                }
                if fdCtx.transientReadError {
                    return .transientError
                }
                guard decodedFrames > 0, decodedFrames >= totalDeclared, tellPos >= totalDeclared else {
                    return .invalid
                }
                if expectedDurationSec > 0.0 {
                    let decodedSec = Double(decodedFrames) / sr
                    if decodedSec + 0.002 < expectedDurationSec * 0.85 {
                        return .invalid
                    }
                }
                return fdCtx.transientReadError ? .transientError : .valid
            }
        }

        func isValidTimelineFile(in dirURL: URL, relPath: String, chunk: ChunkRecord) -> AssetValidationResult {
            let data: Data
            switch Self.readRegularFileDataNoFollow(rootDir: dirURL, relPath: relPath, requireNonEmpty: true) {
            case .data(let bytes):
                data = bytes
            case .invalid:
                return .invalid
            case .transientError:
                return .transientError
            }
            guard let timeline = try? decoder.decode(ChunkTimeline.self, from: data) else {
                return .invalid
            }
            return (timeline.chunkId == chunk.id && timeline.chunkIndex == chunk.index) ? .valid : .invalid
        }

        func extractChunkIdFromFilename(_ rawName: String) -> String? {
            var stem = rawName.lowercased()
            while stem.hasPrefix(".") {
                stem.removeFirst()
            }
            let prefixes = ["mix_", "mic_", "remote_", "audio_", "chunk_"]
            for prefix in prefixes where stem.hasPrefix(prefix) {
                let rest = stem.dropFirst(prefix.count)
                let digits = rest.prefix(while: \.isNumber)
                if !digits.isEmpty {
                    return "chunk_\(digits)"
                }
            }
            return nil
        }

        for dirURL in entries {
            guard case .directory = Self.lstatKind(at: dirURL) else { continue }
            let manifestURL = dirURL.appendingPathComponent("manifest.json")
            guard case .data(let data) = Self.readRegularFileDataNoFollow(rootDir: dirURL, relPath: "manifest.json", requireNonEmpty: true),
                  var manifest = try? decoder.decode(MeetingManifest.self, from: data)
            else { continue }

            guard manifest.status == "recording" || manifest.status == "finalizing" else {
                drainPendingCleanup(in: dirURL, activeManifest: manifest)
                continue
            }

            // Reconcile durable per-chunk commit markers from .commits/; defer meeting completely on transient I/O errors (P0-4).
            var candidateById: [String: ChunkRecord] = [:]
            for c in manifest.chunks {
                candidateById[c.id] = c
            }
            let commitsDir = dirURL.appendingPathComponent(".commits")
            let commitFiles: [URL]
            var commitsDirExists = false
            switch Self.lstatKind(at: commitsDir) {
            case .directory:
                do {
                    commitFiles = try fm.contentsOfDirectory(at: commitsDir, includingPropertiesForKeys: nil)
                    commitsDirExists = true
                } catch {
                    if isNotFoundError(error) {
                        commitFiles = []
                    } else {
                        continue
                    }
                }
            case .transientError:
                continue
            case .notFound, .symlink, .regular, .other:
                commitFiles = []
            }

            var transientReadFailure = false
            for f in commitFiles where f.pathExtension.lowercased() == "json" && !f.lastPathComponent.hasPrefix(".") {
                switch Self.lstatKind(at: f) {
                case .regular:
                    break
                case .transientError:
                    transientReadFailure = true
                case .notFound, .symlink, .directory, .other:
                    continue
                }
                if transientReadFailure { break }
                switch Self.readRegularFileDataNoFollow(
                    rootDir: dirURL,
                    relPath: ".commits/\(f.lastPathComponent)",
                    requireNonEmpty: false
                ) {
                case .data(let cData):
                    if let rec = try? decoder.decode(ChunkRecord.self, from: cData) {
                        candidateById[rec.id] = rec
                    }
                case .invalid:
                    continue
                case .transientError:
                    transientReadFailure = true
                }
                if transientReadFailure { break }
            }
            if transientReadFailure { continue }

            let candidates = candidateById.values.sorted { $0.index < $1.index }
            var validChunks: [ChunkRecord] = []
            for chunk in candidates {
                let expectedDur = (chunk.audioRangeSec.count == 2)
                    ? max(chunk.durationSec, chunk.audioRangeSec[1] - chunk.audioRangeSec[0])
                    : chunk.durationSec

                switch decodeAndValidateAudioFile(in: dirURL, relPath: chunk.audioPath, expectedDurationSec: expectedDur) {
                case .valid: break
                case .invalid: continue
                case .transientError: transientReadFailure = true
                }
                if transientReadFailure { break }

                if let micRel = chunk.micPath {
                    switch decodeAndValidateAudioFile(in: dirURL, relPath: micRel, expectedDurationSec: expectedDur) {
                    case .valid: break
                    case .invalid: continue
                    case .transientError: transientReadFailure = true
                    }
                    if transientReadFailure { break }
                } else if manifest.mode == "dual" {
                    continue
                }

                if let remoteRel = chunk.remotePath {
                    switch decodeAndValidateAudioFile(in: dirURL, relPath: remoteRel, expectedDurationSec: expectedDur) {
                    case .valid: break
                    case .invalid: continue
                    case .transientError: transientReadFailure = true
                    }
                    if transientReadFailure { break }
                } else if manifest.mode == "dual" {
                    continue
                }

                if let timelineRel = chunk.timelinePath {
                    switch isValidTimelineFile(in: dirURL, relPath: timelineRel, chunk: chunk) {
                    case .valid: break
                    case .invalid: continue
                    case .transientError: transientReadFailure = true
                    }
                    if transientReadFailure { break }
                } else if manifest.mode == "dual" {
                    continue
                }

                validChunks.append(chunk)
            }
            if transientReadFailure { continue }

            let validIds = Set(validChunks.map(\.id))
            let droppedCandidateCount = max(0, candidates.count - validChunks.count)

            let validChunkRels = validChunks.flatMap { chunk in
                [chunk.audioPath, chunk.micPath, chunk.remotePath, chunk.timelinePath].compactMap { $0 }
            }
            let (referencedRelPaths, referencedIdentities, hadProtectedCollectError) = collectProtectedPathsAndIdentities(in: dirURL, relPaths: validChunkRels)
            if hadProtectedCollectError { continue }

            // Inspect hidden .tmp staged files and unreferenced orphans BEFORE deleting anything so
            // mid-chunk crash failures are counted and .commits/ survives if manifest write fails (P0-4).
            var unlistedFailedChunkIds = Set<String>()
            var cleanupRelPaths: [String] = []

            for f in commitFiles where f.lastPathComponent.hasPrefix(".") || f.lastPathComponent.hasSuffix(".tmp") {
                let fid: FileIdentity
                switch Self.lstatKind(at: f) {
                case .regular(let id):
                    fid = id
                case .transientError:
                    transientReadFailure = true
                    fid = FileIdentity(dev: 0, ino: 0)
                case .notFound, .symlink, .directory, .other:
                    continue
                }
                if transientReadFailure { break }
                if referencedIdentities.contains(fid) { continue }
                if let cid = extractChunkIdFromFilename(f.lastPathComponent),
                   !validIds.contains(cid),
                   candidateById[cid] == nil {
                    unlistedFailedChunkIds.insert(cid)
                }
            }
            if transientReadFailure { continue }

            func scanSubtree(subRel: String) {
                let subDir = dirURL.appendingPathComponent(subRel)
                switch Self.lstatKind(at: subDir) {
                case .directory:
                    break
                case .transientError:
                    transientReadFailure = true
                    return
                case .notFound, .symlink, .regular, .other:
                    return
                }
                let files: [URL]
                do {
                    files = try fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil)
                } catch {
                    if !isNotFoundError(error) {
                        transientReadFailure = true
                    }
                    return
                }
                for f in files {
                    let name = f.lastPathComponent
                    let rel = "\(subRel)/\(name)"
                    switch Self.lstatKind(at: f) {
                    case .directory:
                        scanSubtree(subRel: rel)
                        if transientReadFailure { return }
                    case .transientError:
                        transientReadFailure = true
                        return
                    case .symlink, .notFound:
                        continue
                    case .regular(let fid), .other(let fid):
                        let matchesRefIdentity = referencedIdentities.contains(fid)
                        let isReferenced = referencedRelPaths.contains(rel) || matchesRefIdentity
                        let isHiddenOrTmp = name.hasPrefix(".") || name.hasSuffix(".tmp")
                        if (isHiddenOrTmp && !matchesRefIdentity) || !isReferenced {
                            if let cid = extractChunkIdFromFilename(name),
                               !validIds.contains(cid),
                               candidateById[cid] == nil {
                                unlistedFailedChunkIds.insert(cid)
                            }
                            cleanupRelPaths.append(rel)
                        }
                    }
                }
            }

            for subName in ["chunks", "timelines"] {
                scanSubtree(subRel: subName)
                if transientReadFailure { break }
            }
            if transientReadFailure { continue }

            if commitsDirExists {
                cleanupRelPaths.append(".commits")
            }

            manifest.chunks = validChunks
            manifest.failedChunkCount += droppedCandidateCount + unlistedFailedChunkIds.count
            manifest.totalDurationSec = ChunkWriter.committedCoverageDuration(for: validChunks)
            manifest.endedAt = manifest.endedAt ?? AtomicFileWriter.isoNow()

            if manifest.chunks.isEmpty && manifest.failedChunkCount == 0 && manifest.lastError == nil {
                manifest.status = "empty"
                manifest.lastError = "上次录制未完成任何有效切片（可能发生异常退出）"
            } else {
                manifest.status = "partial"
                manifest.lastError = manifest.lastError ?? "上次录制意外中断，已保留可用切片"
            }

            let pendingURL = dirURL.appendingPathComponent(".pending_cleanup.json")
            if !cleanupRelPaths.isEmpty {
                do {
                    try AtomicFileWriter.writeJSON(
                        PendingCleanupRecord(
                            paths: cleanupRelPaths,
                            protectedIdentities: referencedIdentities.map(StoredFileIdentity.init)
                        ),
                        to: pendingURL
                    )
                } catch {
                    // Do not update manifest.json if cleanup journal cannot be written cleanly.
                    continue
                }
            } else {
                switch Self.lstatKind(at: pendingURL) {
                case .regular:
                    do {
                        try fm.removeItem(at: pendingURL)
                    } catch {
                        if !isNotFoundError(error) {
                            continue
                        }
                    }
                case .transientError:
                    continue
                case .notFound, .symlink, .directory, .other:
                    break
                }
            }

            do {
                try AtomicFileWriter.writeJSON(manifest, to: manifestURL)
            } catch {
                // Manifest persistence failed: drop .pending_cleanup.json and preserve all files for retry.
                if case .regular = Self.lstatKind(at: pendingURL) {
                    _ = Darwin.unlink(pendingURL.path)
                }
                continue
            }

            drainPendingCleanup(
                in: dirURL,
                activeManifest: manifest,
                extraProtectedIdentities: referencedIdentities
            )
        }
    }

    func startSession(_ req: StartSessionRequest) throws -> RecorderStateSnapshot {
        let mode = (req.mode ?? "mic").trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == "mic" || mode == "dual" else {
            throw CoordinatorError.badRequest("不支持的录制模式: \(mode)，仅支持 mic 或 dual。")
        }

        let trimmedKey = req.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idempotencyKey = (trimmedKey?.isEmpty == false) ? trimmedKey : nil

        let micPerm = PermissionChecker.micStatus()
        if micPerm != "granted" {
            throw CoordinatorError.permissionDenied("麦克风权限未授权（当前状态: \(micPerm)），请先点击授权麦克风。")
        }

        let meetingId = Self.generateMeetingId()
        let meetingTitle: String = {
            let raw = req.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? Self.defaultMeetingTitle(mode: mode) : raw
        }()
        let appTarget = (mode == "dual") ? "all_system" : "mic_only"

        enum ReserveDecision {
            case reserved(StartAttemptWaiter)
            case waitStartingSameKey(StartAttemptWaiter)
            case replayActive(RecorderStateSnapshot)
            case conflict(String, String?)
        }

        let decision: ReserveDecision = lock.withLock {
            if isShuttingDown {
                return .conflict("录音服务正在关闭，请稍后重试。", nil)
            }

            if let key = idempotencyKey {
                if state == "starting", activeIdempotencyKey == key, let waiter = startingWaiter {
                    return .waitStartingSameKey(waiter)
                }
                if let mappedId = idempotencyMap[key] {
                    if state == "recording", activeMeetingId == mappedId {
                        return .replayActive(buildSnapshotLocked())
                    }
                    return .conflict("该启动请求（idempotencyKey）对应的会议 \(mappedId) 已结束。", mappedId)
                }
            }

            if state == "starting" || state == "recording" || state == "finalizing" {
                return .conflict("已有进行中的会议录制（\(activeMeetingId ?? "")），请先停止当前录制。", activeMeetingId)
            }

            let waiter = StartAttemptWaiter()
            self.startingWaiter = waiter
            self.state = "starting"
            self.activeMeetingId = meetingId
            self.activeIdempotencyKey = idempotencyKey
            self.activeTitle = meetingTitle
            self.activeMode = mode
            self.lastError = nil
            self.lastTerminalStop = nil
            return .reserved(waiter)
        }

        let reservedStartingWaiter: StartAttemptWaiter
        switch decision {
        case .replayActive(let snap):
            return snap
        case .waitStartingSameKey(let waiter):
            return try waiter.wait()
        case .conflict(let msg, let activeId):
            throw CoordinatorError.conflict(msg, meetingId: activeId)
        case .reserved(let waiter):
            reservedStartingWaiter = waiter
            onStateChanged?()
        }

        var dualTapEpoch: UInt64? = nil
        var completedStartingWaiter = false
        defer {
            if !completedStartingWaiter {
                lock.withLock {
                    resetSessionLocked(newState: "error", errorMsg: "会议初始化提前终止")
                    if startingWaiter === reservedStartingWaiter {
                        startingWaiter = nil
                    }
                }
                reservedStartingWaiter.complete(with: .failure(CoordinatorError.internalError("会议初始化提前终止")))
            }
        }

        let meetingsRoot = dataDir.appendingPathComponent("meetings")
        var candidateId = meetingId
        var activeMeetingDir = meetingsRoot.appendingPathComponent(candidateId)
        var createdFreshMeetingDir = false

        var createdMic: MicCapture?
        var createdSystemAudio: SystemAudioCapture?
        var createdMixer: DualTrackMixer?
        var createdWriter: ChunkWriter?

        do {
            if mode == "dual" {
                guard let ep = PermissionChecker.acquireExclusiveTapForDualSession(timeoutMs: 250) else {
                    throw CoordinatorError.conflict(
                        "系统音频权限探测或上一场双轨硬件正在清理中，请稍候重试。",
                        meetingId: nil
                    )
                }
                dualTapEpoch = ep
            }

            try FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
            for _ in 0..<16 {
                if mkdir(activeMeetingDir.path, 0o755) == 0 {
                    createdFreshMeetingDir = true
                    break
                }
                let errCode = errno
                if errCode == EEXIST {
                    candidateId = Self.generateMeetingId()
                    activeMeetingDir = meetingsRoot.appendingPathComponent(candidateId)
                    lock.withLock {
                        self.activeMeetingId = candidateId
                    }
                    continue
                }
                throw CoordinatorError.internalError("创建会议目录失败 (errno=\(errCode))")
            }
            guard createdFreshMeetingDir else {
                throw CoordinatorError.internalError("无法分配唯一会议目录，请稍后重试。")
            }

            let meetingId = candidateId
            lock.withLock {
                self.activeMeetingId = meetingId
            }
            let chunksDir = activeMeetingDir.appendingPathComponent("chunks")
            let timelinesDir = activeMeetingDir.appendingPathComponent("timelines")
            let manifestURL = activeMeetingDir.appendingPathComponent("manifest.json")
            let initialManifest = MeetingManifest(
                schemaVersion: 1,
                id: meetingId,
                title: meetingTitle,
                mode: mode,
                appTarget: appTarget,
                status: "recording",
                createdAt: AtomicFileWriter.isoNow(),
                endedAt: nil,
                totalDurationSec: 0,
                chunks: [],
                gaps: [],
                audioCleaned: false,
                failedChunkCount: 0,
                hostTimeOriginNs: nil,
                lastError: nil
            )

            try AtomicFileWriter.writeJSON(initialManifest, to: manifestURL)

            let chunkSec = req.chunkSec ?? defaultChunkDurationSec
            let writer = try ChunkWriter(
                chunksDir: chunksDir,
                mode: mode == "dual" ? .dual : .mic,
                timelinesDir: mode == "dual" ? timelinesDir : nil,
                chunkDurationSec: chunkSec,
                expectsRealTime: true,
                onChunkCommitted: { [weak self] record in
                    self?.handleChunkCommitted(meetingId: meetingId, record: record)
                },
                onChunkFailed: { [weak self] errMsg in
                    self?.handleChunkFailed(meetingId: meetingId, message: errMsg)
                }
            )
            createdWriter = writer

            let mic: MicCapture
            var sysAudio: SystemAudioCapture?
            var mixer: DualTrackMixer?

            if mode == "dual" {
                let dualMixer = DualTrackMixer(
                    realTimeClock: true,
                    onMixedBlock: { mix, micTrack, remoteTrack in
                        writer.appendDualSamples(mix: mix, mic: micTrack, remote: remoteTrack)
                    },
                    onDriftGap: { [weak self] startUp, endUp, reason in
                        self?.recordGap(meetingId: meetingId, startUptime: startUp, endUptime: endUp, reason: reason)
                    }
                )
                mixer = dualMixer
                createdMixer = dualMixer

                mic = MicCapture(
                    onSamples: { samples, hostNs in
                        dualMixer.appendMic(samples, hostTimeNs: hostNs)
                    },
                    onLevel: { [weak self] level in
                        self?.updateMeLevel(meetingId: meetingId, level: level)
                    },
                    onGap: { [weak self] startUp, endUp, reason in
                        self?.recordGap(meetingId: meetingId, startUptime: startUp, endUptime: endUp, reason: reason)
                    },
                    onError: { [weak self] errMsg in
                        self?.recordRuntimeError(meetingId: meetingId, message: errMsg)
                    },
                    onFatalError: { [weak self] errMsg in
                        self?.handleFatalCaptureError(meetingId: meetingId, message: errMsg)
                    },
                    onDeviceChanged: { [weak self] devName in
                        self?.updateDeviceName(meetingId: meetingId, name: devName)
                    },
                    onFirstHostTime: { [weak self] originNs in
                        self?.recordHostTimeOrigin(meetingId: meetingId, originNs: originNs)
                    }
                )

                let captureSys = SystemAudioCapture(
                    onSamples: { samples, hostNs in
                        dualMixer.appendRemote(samples, hostTimeNs: hostNs)
                    },
                    onLevel: { [weak self] level in
                        self?.updateRemoteLevel(meetingId: meetingId, level: level)
                    },
                    onGap: { [weak self] startUp, endUp, reason in
                        self?.recordGap(meetingId: meetingId, startUptime: startUp, endUptime: endUp, reason: reason)
                    },
                    onError: { [weak self] errMsg in
                        self?.recordRuntimeError(meetingId: meetingId, message: errMsg)
                    },
                    onFatalError: { [weak self] errMsg in
                        self?.handleSystemAudioDegraded(meetingId: meetingId, message: errMsg)
                    },
                    onOutputDeviceChanged: { [weak self] devName in
                        self?.updateOutputDeviceName(meetingId: meetingId, name: devName)
                    },
                    onSystemAudioStatusChanged: { [weak self] _ in
                        self?.handleSystemAudioStatusChanged(meetingId: meetingId)
                    },
                    reportGlobalPermission: true,
                    sessionEpoch: dualTapEpoch
                )
                sysAudio = captureSys
                createdSystemAudio = captureSys
            } else {
                mic = MicCapture(
                    onSamples: { samples, _ in
                        writer.appendSamples(samples)
                    },
                    onLevel: { [weak self] level in
                        self?.updateMeLevel(meetingId: meetingId, level: level)
                    },
                    onGap: { [weak self] startUp, endUp, reason in
                        self?.recordGap(meetingId: meetingId, startUptime: startUp, endUptime: endUp, reason: reason)
                    },
                    onError: { [weak self] errMsg in
                        self?.recordRuntimeError(meetingId: meetingId, message: errMsg)
                    },
                    onFatalError: { [weak self] errMsg in
                        self?.handleFatalCaptureError(meetingId: meetingId, message: errMsg)
                    },
                    onDeviceChanged: { [weak self] devName in
                        self?.updateDeviceName(meetingId: meetingId, name: devName)
                    },
                    onFirstHostTime: { [weak self] originNs in
                        self?.recordHostTimeOrigin(meetingId: meetingId, originNs: originNs)
                    }
                )
            }
            createdMic = mic

            lock.withLock {
                self.activeManifest = initialManifest
                self.activeManifestURL = manifestURL
                self.activeWriter = writer
                self.activeMixer = mixer
                self.activeMic = mic
                self.activeSystemAudio = sysAudio
                self.activeDualTapEpoch = dualTapEpoch
                self.sessionStartUptime = ProcessInfo.processInfo.systemUptime
                self.meLevel = 0.0
                self.remoteLevel = 0.0
                self.systemAudioDegraded = false
            }

            mixer?.start()
            let devName = try mic.start()
            let outName: String?
            if let sys = sysAudio {
                do {
                    outName = try sys.start()
                } catch {
                    throw CoordinatorError.internalError("系统音频捕获启动失败（可在系统设置 → 隐私与安全性 → 录屏与系统录音中检查权限）: \(error.localizedDescription)")
                }
            } else {
                outName = SystemAudioCapture.defaultOutputDeviceName()
            }

            let snap: RecorderStateSnapshot = lock.withLock {
                self.state = "recording"
                self.activeMeetingId = meetingId
                if let key = idempotencyKey {
                    self.idempotencyMap[key] = meetingId
                }
                self.activeIdempotencyKey = nil
                self.inputDeviceName = devName
                self.outputDeviceName = outName
                if self.startingWaiter === reservedStartingWaiter {
                    self.startingWaiter = nil
                }
                return buildSnapshotLocked()
            }
            completedStartingWaiter = true
            reservedStartingWaiter.complete(with: .success(snap))

            onStateChanged?()
            return snap
        } catch {
            // Stop hardware, release exclusive tap epoch, and finish disk rollback BEFORE leaving state == "starting" and startingWaiter (P1-9).
            createdMic?.stop()
            createdSystemAudio?.stop()
            if let ep = dualTapEpoch {
                PermissionChecker.releaseExclusiveTapForDualSession(epoch: ep)
            }
            createdMixer?.finish()
            _ = createdWriter?.finishAll()

            manifestIOQueue.sync {}
            var rollbackCleanupErr: String? = nil
            if createdFreshMeetingDir {
                do {
                    try FileManager.default.removeItem(at: activeMeetingDir)
                } catch {
                    if !Self.isNotFoundErrorStatic(error) {
                        rollbackCleanupErr = error.localizedDescription
                    }
                }
            }

            let surfacedError: Error
            let combinedMsg: String
            if let rollbackCleanupErr {
                combinedMsg = "\(error.localizedDescription)（启动回滚清理失败: \(rollbackCleanupErr)）"
                surfacedError = CoordinatorError.internalError(combinedMsg)
            } else {
                combinedMsg = error.localizedDescription
                surfacedError = error
            }

            lock.withLock {
                resetSessionLocked(newState: "error", errorMsg: combinedMsg)
                if self.startingWaiter === reservedStartingWaiter {
                    self.startingWaiter = nil
                }
            }
            completedStartingWaiter = true
            reservedStartingWaiter.complete(with: .failure(surfacedError))
            onStateChanged?()
            throw surfacedError
        }
    }

    func stopSession(meetingId requestedId: String?) throws -> (snapshot: RecorderStateSnapshot, manifest: MeetingManifest?) {
        enum StopAction {
            case proceed(
                mic: MicCapture?,
                sysAudio: SystemAudioCapture?,
                tapEpoch: UInt64?,
                mixer: DualTrackMixer?,
                writer: ChunkWriter?,
                manifestURL: URL?,
                currentId: String,
                waiter: FinalizationWaiter
            )
            case waitFinalizing(FinalizationWaiter)
            case terminalRetry(Result<(snapshot: RecorderStateSnapshot, manifest: MeetingManifest?), Error>)
            case idleNoSession(RecorderStateSnapshot)
            case conflict(String, String?)
        }

        let action: StopAction = lock.withLock {
            if state == "finalizing", let fw = finalizationWaiter {
                if let reqId = requestedId, !reqId.isEmpty, reqId != activeMeetingId {
                    return .conflict("正在封包的是另一场会议（\(activeMeetingId ?? "")）。", activeMeetingId)
                }
                return .waitFinalizing(fw)
            }

            if state == "starting" {
                return .conflict("会议正在初始化中，请稍候再试。", activeMeetingId)
            }

            guard state == "recording", let currentId = activeMeetingId else {
                if let reqId = requestedId, !reqId.isEmpty {
                    if let last = lastTerminalStop, last.meetingId == reqId {
                        return .terminalRetry(last.result)
                    }
                    return .conflict("当前没有正在录制的会议（目标 \(reqId) 已不在录制中）。", activeMeetingId)
                }
                if let last = lastTerminalStop {
                    return .terminalRetry(last.result)
                }
                return .idleNoSession(buildSnapshotLocked())
            }

            if let reqId = requestedId, !reqId.isEmpty, reqId != currentId {
                return .conflict("请求停止的会议 ID（\(reqId)）与当前正在录制的会议（\(currentId)）不匹配。", currentId)
            }

            state = "finalizing"
            let fw = FinalizationWaiter()
            finalizationWaiter = fw
            let tapEpoch = activeDualTapEpoch
            activeDualTapEpoch = nil
            return .proceed(
                mic: activeMic,
                sysAudio: activeSystemAudio,
                tapEpoch: tapEpoch,
                mixer: activeMixer,
                writer: activeWriter,
                manifestURL: activeManifestURL,
                currentId: currentId,
                waiter: fw
            )
        }

        switch action {
        case .idleNoSession(let snap):
            return (snap, nil)
        case .terminalRetry(let result):
            return try result.get()
        case .conflict(let msg, let activeId):
            throw CoordinatorError.conflict(msg, meetingId: activeId)
        case .waitFinalizing(let fw):
            return try fw.wait()
        case .proceed(let mic, let sysAudio, let tapEpoch, let mixer, let writer, let manifestURL, let currentMeetingId, let fw):
            onStateChanged?()

            var completedWaiter = false
            defer {
                if !completedWaiter {
                    let fallbackErr = CoordinatorError.internalError("会议停止过程中发生意外中止")
                    lock.withLock {
                        lastTerminalStop = (currentMeetingId, .failure(fallbackErr))
                        if finalizationWaiter === fw {
                            finalizationWaiter = nil
                        }
                    }
                    fw.complete(with: .failure(fallbackErr))
                }
            }

            mic?.stop()
            sysAudio?.stop()
            if let tapEpoch {
                PermissionChecker.releaseExclusiveTapForDualSession(epoch: tapEpoch)
            }
            mixer?.finish()
            let finishResult = writer?.finishAll() ?? (chunks: [], failedCount: 0, totalDurationSec: 0)
            manifestIOQueue.sync {}

            let finalState: (manifest: MeetingManifest?, runtimeErr: String?) = lock.withLock {
                var m = activeManifest
                m?.chunks = finishResult.chunks.sorted { $0.index < $1.index }
                m?.failedChunkCount = finishResult.failedCount
                m?.totalDurationSec = (finishResult.totalDurationSec * 1000.0).rounded() / 1000.0
                m?.endedAt = AtomicFileWriter.isoNow()
                let runtimeErr = lastError
                if m != nil {
                    if finishResult.chunks.isEmpty && finishResult.failedCount == 0 && runtimeErr == nil && finishResult.totalDurationSec <= 0.1 {
                        m!.status = "empty"
                    } else if finishResult.failedCount > 0 || runtimeErr != nil {
                        m!.status = "partial"
                        m!.lastError = runtimeErr ?? "部分切片封包失败 (\(finishResult.failedCount))"
                    } else {
                        m!.status = "recorded"
                    }
                }
                return (m, runtimeErr)
            }

            let persistedManifest = finalState.manifest
            if let m = persistedManifest, let url = manifestURL {
                do {
                    try AtomicFileWriter.writeJSON(m, to: url)
                    let commitsDir = url.deletingLastPathComponent().appendingPathComponent(".commits")
                    try? FileManager.default.removeItem(at: commitsDir)
                } catch {
                    let errMsg = "写入最终会议清单失败: \(error.localizedDescription)"
                    let err = CoordinatorError.internalError(errMsg)
                    lock.withLock {
                        lastTerminalStop = (currentMeetingId, .failure(err))
                        resetSessionLocked(newState: "error", errorMsg: errMsg)
                        if finalizationWaiter === fw { finalizationWaiter = nil }
                    }
                    completedWaiter = true
                    fw.complete(with: .failure(err))
                    onStateChanged?()
                    throw err
                }
            }

            let idleSnap: RecorderStateSnapshot = lock.withLock {
                let nextErr = finishResult.failedCount > 0 ? "部分切片封包失败" : finalState.runtimeErr
                resetSessionLocked(newState: "idle", errorMsg: nextErr)
                let snap = buildSnapshotLocked()
                let out = (snapshot: snap, manifest: persistedManifest)
                lastTerminalStop = (currentMeetingId, .success(out))
                if finalizationWaiter === fw { finalizationWaiter = nil }
                return snap
            }

            let outcome = (snapshot: idleSnap, manifest: persistedManifest)
            completedWaiter = true
            fw.complete(with: .success(outcome))
            onStateChanged?()
            return outcome
        }
    }

    func handleSystemWillSleep() {
        waitForFinalizationIfNeeded()
    }

    func waitForFinalizationIfNeeded() {
        while true {
            enum WaitStep {
                case waitStarting(StartAttemptWaiter)
                case stopRecording
                case waitFinalizing(FinalizationWaiter)
                case done
            }

            let step: WaitStep = lock.withLock {
                if let sw = startingWaiter {
                    return .waitStarting(sw)
                }
                if state == "recording" {
                    return .stopRecording
                }
                if let fw = finalizationWaiter {
                    return .waitFinalizing(fw)
                }
                return .done
            }

            switch step {
            case .waitStarting(let sw):
                _ = try? sw.wait()
            case .stopRecording:
                _ = try? stopSession(meetingId: nil)
                return
            case .waitFinalizing(let fw):
                _ = try? fw.wait()
                return
            case .done:
                return
            }
        }
    }

    private func handleFatalCaptureError(meetingId: String, message: String) {
        recordRuntimeError(meetingId: meetingId, message: message)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? self?.stopSession(meetingId: meetingId)
        }
    }

    private func handleSystemAudioDegraded(meetingId: String, message: String) {
        lock.withLock {
            if activeMeetingId == meetingId {
                systemAudioDegraded = true
                remoteLevel = 0.0
            }
        }
        recordRuntimeError(meetingId: meetingId, message: "\(message)（已自动降级继续录制麦克风轨道）")
    }

    private func handleSystemAudioStatusChanged(meetingId: String) {
        let isActive = lock.withLock { activeMeetingId == meetingId }
        if isActive {
            onStateChanged?()
        }
    }

    private func handleChunkCommitted(meetingId: String, record: ChunkRecord) {
        let shouldPersist = lock.withLock { () -> Bool in
            guard activeMeetingId == meetingId, var m = activeManifest else { return false }
            m.chunks.append(record)
            m.chunks.sort { $0.index < $1.index }
            m.totalDurationSec = ChunkWriter.committedCoverageDuration(for: m.chunks)
            activeManifest = m
            return true
        }
        guard shouldPersist else { return }
        scheduleManifestPersist(meetingId: meetingId)
        onStateChanged?()
    }

    private func handleChunkFailed(meetingId: String, message: String) {
        let shouldPersist = lock.withLock { () -> Bool in
            guard activeMeetingId == meetingId else { return false }
            lastError = message
            if var m = activeManifest {
                m.failedChunkCount += 1
                m.lastError = message
                activeManifest = m
                return true
            }
            return false
        }
        if shouldPersist {
            scheduleManifestPersist(meetingId: meetingId)
            onStateChanged?()
        }
    }

    private func updateMeLevel(meetingId: String, level: Double) {
        lock.withLock {
            if activeMeetingId == meetingId {
                meLevel = level
            }
        }
    }

    private func updateRemoteLevel(meetingId: String, level: Double) {
        lock.withLock {
            if activeMeetingId == meetingId, !systemAudioDegraded {
                remoteLevel = level
            }
        }
    }

    private func updateDeviceName(meetingId: String, name: String?) {
        lock.withLock {
            if activeMeetingId == meetingId {
                inputDeviceName = name
            }
        }
    }

    private func updateOutputDeviceName(meetingId: String, name: String?) {
        lock.withLock {
            if activeMeetingId == meetingId {
                outputDeviceName = name
            }
        }
    }

    private func recordHostTimeOrigin(meetingId: String, originNs: UInt64) {
        let shouldPersist = lock.withLock { () -> Bool in
            guard activeMeetingId == meetingId, var m = activeManifest else { return false }
            if m.hostTimeOriginNs == nil {
                m.hostTimeOriginNs = originNs
                activeManifest = m
                return true
            }
            return false
        }
        if shouldPersist {
            scheduleManifestPersist(meetingId: meetingId)
        }
    }

    private func recordGap(meetingId: String, startUptime: Double, endUptime: Double, reason: String) {
        let shouldPersist = lock.withLock { () -> Bool in
            guard activeMeetingId == meetingId, var m = activeManifest else { return false }
            let startSec = max(0.0, ((startUptime - sessionStartUptime) * 1000.0).rounded() / 1000.0)
            let endSec = max(startSec, ((endUptime - sessionStartUptime) * 1000.0).rounded() / 1000.0)
            m.gaps.append(GapRecord(startSec: startSec, endSec: endSec, reason: reason))
            activeManifest = m
            return true
        }
        if shouldPersist {
            scheduleManifestPersist(meetingId: meetingId)
            onStateChanged?()
        }
    }

    private func recordRuntimeError(meetingId: String, message: String) {
        let mutated = lock.withLock { () -> Bool in
            guard activeMeetingId == meetingId else { return false }
            lastError = message
            if var m = activeManifest {
                m.lastError = message
                activeManifest = m
            }
            return true
        }
        guard mutated else { return }
        scheduleManifestPersist(meetingId: meetingId)
        onStateChanged?()
    }

    private func scheduleManifestPersist(meetingId: String) {
        manifestIOQueue.async { [weak self] in
            guard let self else { return }
            let payload: (MeetingManifest, URL)? = self.lock.withLock {
                guard self.activeMeetingId == meetingId,
                      let m = self.activeManifest,
                      let url = self.activeManifestURL
                else {
                    return nil
                }
                return (m, url)
            }
            guard let (manifest, url) = payload else { return }
            do {
                try AtomicFileWriter.writeJSON(manifest, to: url)
            } catch {
                self.lock.withLock {
                    if self.activeMeetingId == meetingId {
                        self.lastError = "写入会议清单失败: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func resetSessionLocked(newState: String, errorMsg: String?) {
        state = newState
        activeMeetingId = nil
        activeTitle = nil
        activeMode = nil
        activeManifest = nil
        activeManifestURL = nil
        activeWriter = nil
        activeMixer = nil
        activeMic = nil
        activeSystemAudio = nil
        activeDualTapEpoch = nil
        sessionStartUptime = 0
        meLevel = 0.0
        remoteLevel = 0.0
        systemAudioDegraded = false
        activeIdempotencyKey = nil
        lastError = errorMsg
    }

    private func buildSnapshotLocked() -> RecorderStateSnapshot {
        let elapsed: Double
        if state == "recording" || state == "finalizing", sessionStartUptime > 0 {
            elapsed = max(0.0, (ProcessInfo.processInfo.systemUptime - sessionStartUptime))
        } else {
            elapsed = 0.0
        }
        let chunks = activeManifest?.chunks ?? []
        let deviceName: String? = (state == "idle" || state == "error")
            ? MicCapture.defaultInputDeviceName()
            : (inputDeviceName ?? MicCapture.defaultInputDeviceName())
        let outDevName: String? = (state == "idle" || state == "error")
            ? SystemAudioCapture.defaultOutputDeviceName()
            : (outputDeviceName ?? SystemAudioCapture.defaultOutputDeviceName())

        return RecorderStateSnapshot(
            state: state,
            meetingId: activeMeetingId,
            title: activeTitle,
            mode: activeMode,
            elapsedSec: (elapsed * 100.0).rounded() / 100.0,
            meLevel: (meLevel * 1000.0).rounded() / 1000.0,
            remoteLevel: (remoteLevel * 1000.0).rounded() / 1000.0,
            committedChunkCount: chunks.count,
            chunks: chunks,
            gaps: activeManifest?.gaps ?? [],
            failedChunkCount: activeManifest?.failedChunkCount ?? 0,
            inputDeviceName: deviceName,
            outputDeviceName: outDevName,
            systemAudioStatus: PermissionChecker.systemAudioStatus(),
            lastError: lastError,
            protocolVersion: 1,
            dataDir: dataDir.path
        )
    }

    private struct FileIdentity: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private enum LStatKind {
        case directory(FileIdentity)
        case regular(FileIdentity)
        case symlink
        case other(FileIdentity)
        case notFound
        case transientError
    }

    private enum PendingCleanupOutcome {
        case removedOrSkipped
        case retryLater
    }

    private enum SafeRegularFileResult {
        case opened(fd: Int32, size: Int64)
        case invalid
        case transientError
    }

    private enum SafeReadDataResult {
        case data(Data)
        case invalid
        case transientError
    }

    private enum LegacyCommitsChildDecision {
        case preserve
        case unlinkable
        case transientError
    }

    private struct LegacyPendingCleanupProbe: Decodable {
        let paths: [String]
    }

    private final class FDReadContext {
        let fd: Int32
        let size: Int64
        var transientReadError: Bool = false
        init(fd: Int32, size: Int64) {
            self.fd = fd
            self.size = size
        }
    }

    private enum NoFollowParentResolution {
        case parent(fd: Int32, ownsFD: Bool, leaf: String)
        case notFoundOrSymlink
        case transientError
    }

    private static func fileIdentity(of url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return FileIdentity(dev: st.st_dev, ino: st.st_ino)
    }

    private static func lstatKind(at url: URL) -> LStatKind {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return (errno == ENOENT || errno == ENOTDIR) ? .notFound : .transientError
        }
        let fid = FileIdentity(dev: st.st_dev, ino: st.st_ino)
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory(fid)
        case S_IFREG:
            return .regular(fid)
        case S_IFLNK:
            return .symlink
        default:
            return .other(fid)
        }
    }

    /// Walks all intermediate path components relative to `rootFD` without following any symlink.
    private static func resolveNoFollowParent(
        rootFD: Int32,
        relPath: String,
        onDirectory: (FileIdentity) -> Void = { _ in }
    ) -> NoFollowParentResolution {
        guard !relPath.isEmpty, !relPath.hasPrefix("/") else {
            return .notFoundOrSymlink
        }
        var norm = relPath
        while norm.hasPrefix("./") { norm.removeFirst(2) }
        let components = norm.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return .notFoundOrSymlink
        }

        var ownedFD: Int32 = -1
        for comp in components.dropLast() {
            let parentFD = (ownedFD >= 0) ? ownedFD : rootFD
            let nextFD = Darwin.openat(parentFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if nextFD < 0 {
                let err = errno
                if ownedFD >= 0 { _ = Darwin.close(ownedFD) }
                if err == ENOENT || err == ELOOP || err == ENOTDIR {
                    return .notFoundOrSymlink
                }
                return .transientError
            }
            if ownedFD >= 0 { _ = Darwin.close(ownedFD) }
            ownedFD = nextFD
            var dirSt = stat()
            if Darwin.fstat(nextFD, &dirSt) != 0 {
                let err = errno
                _ = Darwin.close(ownedFD)
                if err == ENOENT || err == ELOOP || err == ENOTDIR {
                    return .notFoundOrSymlink
                }
                return .transientError
            }
            onDirectory(FileIdentity(dev: dirSt.st_dev, ino: dirSt.st_ino))
        }

        return .parent(
            fd: (ownedFD >= 0) ? ownedFD : rootFD,
            ownsFD: ownedFD >= 0,
            leaf: components[components.count - 1]
        )
    }

    private static func openRegularFileNoFollow(
        rootDir: URL,
        relPath: String,
        requireNonEmpty: Bool = true
    ) -> SafeRegularFileResult {
        let rootFD = Darwin.open(rootDir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if rootFD < 0 {
            let err = errno
            return (err == ENOENT || err == ELOOP || err == ENOTDIR) ? .invalid : .transientError
        }
        defer { _ = Darwin.close(rootFD) }

        let parentFD: Int32
        let ownsParentFD: Bool
        let leaf: String
        switch resolveNoFollowParent(rootFD: rootFD, relPath: relPath) {
        case .parent(let fd, let ownsFD, let l):
            parentFD = fd
            ownsParentFD = ownsFD
            leaf = l
        case .notFoundOrSymlink:
            return .invalid
        case .transientError:
            return .transientError
        }
        defer {
            if ownsParentFD { _ = Darwin.close(parentFD) }
        }

        var preSt = stat()
        if Darwin.fstatat(parentFD, leaf, &preSt, AT_SYMLINK_NOFOLLOW) != 0 {
            let err = errno
            return (err == ENOENT || err == ENOTDIR) ? .invalid : .transientError
        }
        guard (preSt.st_mode & S_IFMT) == S_IFREG else {
            return .invalid
        }

        let fd = Darwin.openat(parentFD, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            let err = errno
            return (err == ENOENT || err == ELOOP || err == ENOTDIR || err == ENXIO) ? .invalid : .transientError
        }
        var st = stat()
        if Darwin.fstat(fd, &st) != 0 {
            let err = errno
            _ = Darwin.close(fd)
            return (err == ENOENT) ? .invalid : .transientError
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, (!requireNonEmpty || st.st_size > 0) else {
            _ = Darwin.close(fd)
            return .invalid
        }
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) != 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        return .opened(fd: fd, size: Int64(st.st_size))
    }

    private static func readRegularFileDataNoFollow(
        rootDir: URL,
        relPath: String,
        requireNonEmpty: Bool = false
    ) -> SafeReadDataResult {
        let openedFD: Int32
        switch openRegularFileNoFollow(rootDir: rootDir, relPath: relPath, requireNonEmpty: requireNonEmpty) {
        case .opened(let fd, _):
            openedFD = fd
        case .invalid:
            return .invalid
        case .transientError:
            return .transientError
        }
        let fh = FileHandle(fileDescriptor: openedFD, closeOnDealloc: true)
        do {
            let data = try fh.readToEnd() ?? Data()
            if requireNonEmpty && data.isEmpty {
                return .invalid
            }
            return .data(data)
        } catch {
            return isNotFoundErrorStatic(error) ? .invalid : .transientError
        }
    }

    private static func normalizedJSONUTF8Data(_ data: Data, stride: Int, bigEndian: Bool) -> Data? {
        if stride == 1 {
            if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
                return Data(data.dropFirst(3))
            }
            return data
        }
        let encoding: String.Encoding
        if stride == 2 {
            encoding = bigEndian ? .utf16BigEndian : .utf16LittleEndian
        } else {
            encoding = bigEndian ? .utf32BigEndian : .utf32LittleEndian
        }
        let hasBOM =
            (stride == 2 && data.count >= 2 &&
             ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF))) ||
            (stride == 4 && data.count >= 4 &&
             ((data[0] == 0x00 && data[1] == 0x00 && data[2] == 0xFE && data[3] == 0xFF) ||
              (data[0] == 0xFF && data[1] == 0xFE && data[2] == 0x00 && data[3] == 0x00)))
        let slice = hasBOM ? data.dropFirst(stride) : data[...]
        guard let text = String(data: slice, encoding: encoding) else { return nil }
        return Data(text.utf8)
    }

    private static func classifyLegacyCommitsChild(
        dirFD: Int32,
        name: String,
        st: stat,
        expectedMeetingId: String
    ) -> LegacyCommitsChildDecision {
        if st.st_nlink > 1 {
            return .preserve
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else {
            return .unlinkable
        }
        let fd = Darwin.openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            let err = errno
            return (err == ENOENT || err == ELOOP || err == ENOTDIR || err == ENXIO) ? .unlinkable : .transientError
        }
        var openSt = stat()
        if Darwin.fstat(fd, &openSt) != 0 {
            let err = errno
            _ = Darwin.close(fd)
            return (err == ENOENT) ? .unlinkable : .transientError
        }
        guard (openSt.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(fd)
            return .unlinkable
        }
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) != 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var data = Data()
        let stride: Int
        let bigEndian: Bool
        var scanPos: Int
        do {
            while data.count < 4 {
                guard let chunk = try fh.read(upToCount: 65_536), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            guard !data.isEmpty else {
                return .unlinkable
            }

            let b0 = data[0]
            let b1 = data.count > 1 ? data[1] : 0
            let b2 = data.count > 2 ? data[2] : 0
            let b3 = data.count > 3 ? data[3] : 0
            if data.count >= 4 && b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF {
                stride = 4; bigEndian = true; scanPos = 4
            } else if data.count >= 4 && b0 == 0xFF && b1 == 0xFE && b2 == 0x00 && b3 == 0x00 {
                stride = 4; bigEndian = false; scanPos = 4
            } else if data.count >= 2 && b0 == 0xFE && b1 == 0xFF {
                stride = 2; bigEndian = true; scanPos = 2
            } else if data.count >= 2 && b0 == 0xFF && b1 == 0xFE {
                stride = 2; bigEndian = false; scanPos = 2
            } else if data.count >= 3 && b0 == 0xEF && b1 == 0xBB && b2 == 0xBF {
                stride = 1; bigEndian = false; scanPos = 3
            } else if data.count >= 4 && b0 == 0x00 && b1 == 0x00 && b2 == 0x00 && b3 != 0x00 {
                stride = 4; bigEndian = true; scanPos = 0
            } else if data.count >= 4 && b0 != 0x00 && b1 == 0x00 && b2 == 0x00 && b3 == 0x00 {
                stride = 4; bigEndian = false; scanPos = 0
            } else if data.count >= 2 && b0 == 0x00 && b1 != 0x00 {
                stride = 2; bigEndian = true; scanPos = 0
            } else if data.count >= 2 && b0 != 0x00 && b1 == 0x00 {
                stride = 2; bigEndian = false; scanPos = 0
            } else {
                stride = 1; bigEndian = false; scanPos = 0
            }

            var foundStart = false
            while true {
                let alignedEnd = data.count - ((data.count - scanPos) % stride)
                var pos = scanPos
                let rejected = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return false
                    }
                    while pos < alignedEnd {
                        let unit: UInt32
                        if stride == 1 {
                            unit = UInt32(base[pos])
                        } else if stride == 2 {
                            unit = bigEndian
                                ? (UInt32(base[pos]) << 8) | UInt32(base[pos + 1])
                                : UInt32(base[pos]) | (UInt32(base[pos + 1]) << 8)
                        } else {
                            unit = bigEndian
                                ? (UInt32(base[pos]) << 24) | (UInt32(base[pos + 1]) << 16) | (UInt32(base[pos + 2]) << 8) | UInt32(base[pos + 3])
                                : UInt32(base[pos]) | (UInt32(base[pos + 1]) << 8) | (UInt32(base[pos + 2]) << 16) | (UInt32(base[pos + 3]) << 24)
                        }
                        if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
                            pos += stride
                            continue
                        }
                        if unit == 0x7B {
                            foundStart = true
                            return false
                        }
                        return true
                    }
                    return false
                }
                scanPos = pos
                if rejected {
                    return .unlinkable
                }
                if foundStart {
                    if let rest = try fh.readToEnd() {
                        data.append(rest)
                    }
                    break
                }
                guard let chunk = try fh.read(upToCount: 65_536), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            if !foundStart {
                return .unlinkable
            }
        } catch {
            return isNotFoundErrorStatic(error) ? .unlinkable : .transientError
        }
        guard let decodeData = normalizedJSONUTF8Data(data, stride: stride, bigEndian: bigEndian) else {
            return .unlinkable
        }
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(MeetingManifest.self, from: decodeData),
           manifest.id == expectedMeetingId {
            return .preserve
        }
        if (try? decoder.decode(LegacyPendingCleanupProbe.self, from: decodeData)) != nil {
            return .preserve
        }
        return .unlinkable
    }

    /// Collects non-symlink ancestor and leaf identities for `relPath`; returns `true` on transient I/O errors.
    private static func collectIdentitiesNoFollow(
        rootFD: Int32,
        relPath: String,
        into idSet: inout Set<FileIdentity>
    ) -> Bool {
        let parentFD: Int32
        let ownsParentFD: Bool
        let leaf: String
        switch resolveNoFollowParent(rootFD: rootFD, relPath: relPath, onDirectory: { idSet.insert($0) }) {
        case .parent(let fd, let ownsFD, let l):
            parentFD = fd
            ownsParentFD = ownsFD
            leaf = l
        case .notFoundOrSymlink:
            return false
        case .transientError:
            return true
        }
        defer {
            if ownsParentFD { _ = Darwin.close(parentFD) }
        }

        var st = stat()
        if Darwin.fstatat(parentFD, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            let err = errno
            return !(err == ENOENT || err == ELOOP || err == ENOTDIR)
        }
        if (st.st_mode & S_IFMT) != S_IFLNK {
            idSet.insert(FileIdentity(dev: st.st_dev, ino: st.st_ino))
        }
        return false
    }

    private static func removeEntryNoFollow(
        rootFD: Int32,
        relPath: String,
        protectedIdentities: Set<FileIdentity>,
        isLegacyJournal: Bool = false,
        expectedMeetingId: String? = nil
    ) -> PendingCleanupOutcome {
        let curFD: Int32
        let ownsCurFD: Bool
        let leaf: String
        switch resolveNoFollowParent(rootFD: rootFD, relPath: relPath) {
        case .parent(let fd, let ownsFD, let l):
            curFD = fd
            ownsCurFD = ownsFD
            leaf = l
        case .notFoundOrSymlink:
            return .removedOrSkipped
        case .transientError:
            return .retryLater
        }
        defer {
            if ownsCurFD { _ = Darwin.close(curFD) }
        }
        let isTopLevel = !ownsCurFD

        var st = stat()
        if Darwin.fstatat(curFD, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            let err = errno
            return (err == ENOENT || err == ENOTDIR) ? .removedOrSkipped : .retryLater
        }
        let fid = FileIdentity(dev: st.st_dev, ino: st.st_ino)
        if protectedIdentities.contains(fid) {
            return .removedOrSkipped
        }

        switch st.st_mode & S_IFMT {
        case S_IFREG:
            if Darwin.unlinkat(curFD, leaf, 0) == 0 || errno == ENOENT {
                return .removedOrSkipped
            }
            return .retryLater
        case S_IFDIR:
            guard isTopLevel && leaf.lowercased() == ".commits" else {
                return .removedOrSkipped
            }
            let commitsFD = Darwin.openat(curFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if commitsFD < 0 {
                let err = errno
                if err == ENOENT || err == ELOOP || err == ENOTDIR {
                    return .removedOrSkipped
                }
                return .retryLater
            }

            var hadRetryableErr = false
            var keptChild = false
            do {
                guard let dirPtr = Darwin.fdopendir(commitsFD) else {
                    let err = errno
                    _ = Darwin.close(commitsFD)
                    return (err == ENOENT || err == ENOTDIR) ? .removedOrSkipped : .retryLater
                }
                defer { _ = Darwin.closedir(dirPtr) }
                let dfd = Darwin.dirfd(dirPtr)
                var childNames: [String] = []
                while true {
                    errno = 0
                    guard let entryPtr = Darwin.readdir(dirPtr) else {
                        if errno != 0 {
                            hadRetryableErr = true
                        }
                        break
                    }
                    let dName = entryPtr.pointee.d_name
                    let namelen = min(Int(entryPtr.pointee.d_namlen), MemoryLayout.size(ofValue: dName))
                    let name = withUnsafeBytes(of: dName) { raw in
                        String(decoding: raw.prefix(namelen), as: UTF8.self)
                    }
                    if name.isEmpty || name == "." || name == ".." {
                        continue
                    }
                    childNames.append(name)
                }

                for child in childNames {
                    var cst = stat()
                    if Darwin.fstatat(dfd, child, &cst, AT_SYMLINK_NOFOLLOW) != 0 {
                        if errno != ENOENT {
                            hadRetryableErr = true
                        }
                        continue
                    }
                    let cid = FileIdentity(dev: cst.st_dev, ino: cst.st_ino)
                    if protectedIdentities.contains(cid) || (cst.st_mode & S_IFMT) != S_IFREG {
                        keptChild = true
                        continue
                    }
                    if isLegacyJournal {
                        switch classifyLegacyCommitsChild(
                            dirFD: dfd,
                            name: child,
                            st: cst,
                            expectedMeetingId: expectedMeetingId ?? ""
                        ) {
                        case .preserve:
                            keptChild = true
                            continue
                        case .transientError:
                            hadRetryableErr = true
                            continue
                        case .unlinkable:
                            break
                        }
                    }
                    if Darwin.unlinkat(dfd, child, 0) != 0 && errno != ENOENT {
                        hadRetryableErr = true
                    }
                }
            }

            if hadRetryableErr {
                return .retryLater
            }
            if keptChild {
                return .removedOrSkipped
            }
            if Darwin.unlinkat(curFD, leaf, AT_REMOVEDIR) != 0 {
                let err = errno
                if err == ENOENT || err == ENOTEMPTY {
                    return .removedOrSkipped
                }
                return .retryLater
            }
            return .removedOrSkipped
        default:
            return .removedOrSkipped
        }
    }

    private static func isDirectory(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func generateMeetingId() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let prefix = fmt.string(from: Date())
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return "\(prefix)_\(suffix)"
    }

    private enum AssetValidationResult: Equatable {
        case valid
        case invalid
        case transientError
    }

    private static func classifyCoreAudioStatus(
        _ status: OSStatus,
        isCodecSetupForAAC: Bool = false
    ) -> AssetValidationResult {
        if isCodecSetupForAAC && (status == kAudioFormatUnsupportedDataFormatError || status == OSStatus(1718449215)) {
            return .transientError
        }

        let explicitInvalid: Set<OSStatus> = [
            -43,  // fnfErr / kAudioFileFileNotFoundError
            -120, // dirNFErr
            -39,  // eofErr / kAudioFileEndOfFileError
            -40,  // kAudioFilePositionError
            kAudioFileInvalidFileError,
            kAudioFileUnsupportedFileTypeError,
            kAudioFileUnsupportedDataFormatError,
            kAudioFileBadPropertySizeError,
            kAudioFileUnspecifiedError,
            kAudioFileInvalidPacketOffsetError,
            kAudioFileInvalidPacketDependencyError,
            kAudioFileInvalidChunkError,
            kAudioFileNotOptimizedError,
            kAudioFileDoesNotAllow64BitDataSizeError,
            kExtAudioFileError_InvalidDataFormat,
            kExtAudioFileError_InvalidChannelMap,
            kExtAudioFileError_InvalidOperationOrder,
            kExtAudioFileError_InvalidSeek,
            kAudioFileStreamError_UnsupportedFileType,
            kAudioFileStreamError_InvalidFile,
            kAudioFileStreamError_NotOptimized,
            kAudioFileStreamError_BadPropertySize,
            kAudioFileStreamError_DataUnavailable,
            kAudioFileStreamError_IllegalOperation,
        ]
        if explicitInvalid.contains(status) {
            return .invalid
        }

        let explicitTransient: Set<OSStatus> = [
            -54,   // permErr / permission denied
            -61,   // wrPermErr
            -47,   // fBsyErr
            -45,   // fLckdErr
            -49,   // opWrErr
            -36,   // ioErr
            -42,   // tmfoErr
            -108,  // memFullErr
            -5000, // afpAccessDenied
            kAudioFilePermissionsError,
            kAudioFileNotOpenError,
            OSStatus(EACCES),
            OSStatus(EPERM),
            OSStatus(EIO),
            OSStatus(EBUSY),
            OSStatus(EAGAIN),
            OSStatus(EMFILE),
            OSStatus(ENFILE),
            OSStatus(ENOMEM),
        ]
        if explicitTransient.contains(status) {
            return .transientError
        }
        // Fail-safe on unexpected OS/codec statuses so valid recordings are never deleted.
        return .transientError
    }

    private static func isNotFoundErrorStatic(_ error: Error) -> Bool {
        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain &&
            (nsErr.code == NSFileNoSuchFileError || nsErr.code == NSFileReadNoSuchFileError) {
            return true
        }
        if nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNotFoundErrorStatic(underlying)
        }
        return false
    }

    private static func defaultMeetingTitle(mode: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MM-dd HH:mm"
        let prefix = (mode == "dual") ? "双轨会议" : "语音记录"
        return "\(prefix) \(fmt.string(from: Date()))"
    }

    // Comprehensive P0-4 crash recovery regression tests:
    // (1) Retains chunks persisted via .commits/ even if manifest.json still shows chunks=[]
    // (2) Rejects unreadable 4-byte corrupted .m4a and mismatched-id timeline JSON, recomputing coverage & failure counts.
    static func runOrphanRecoverySelfTest(tempDir: URL) throws {
        let fm = FileManager.default
        let dataRoot = tempDir.appendingPathComponent("recovery_test_data")
        if fm.fileExists(atPath: dataRoot.path) {
            try fm.removeItem(at: dataRoot)
        }

        // Case 1: Crash immediately after ChunkWriter commit before manifest.json flushed -> .commits/ restores chunk_001.
        let m1Dir = dataRoot.appendingPathComponent("meetings/orphan_commit_marker")
        let w1 = try ChunkWriter(
            chunksDir: m1Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m1Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        let oneSec = [Float](repeating: 0.15, count: 16_000)
        w1.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r1 = w1.finishAll()
        guard r1.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -10, userInfo: [NSLocalizedDescriptionKey: "Fixture 1 write failed"])
        }
        let staleManifest1 = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_commit_marker",
            title: "Crash Right After Commit",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0.0,
            chunks: [], // Not flushed before simulated crash!
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        let m1URL = m1Dir.appendingPathComponent("manifest.json")
        try AtomicFileWriter.writeJSON(staleManifest1, to: m1URL)

        // Case 2: One valid real AAC chunk (chunk_001), one corrupted 4-byte remote chunk (chunk_002),
        // and one mismatched-ID timeline chunk (chunk_003).
        let m2Dir = dataRoot.appendingPathComponent("meetings/orphan_corrupt_dual")
        let w2 = try ChunkWriter(
            chunksDir: m2Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m2Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 2.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        let twoSec = [Float](repeating: 0.15, count: 32_000)
        w2.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec) // chunk_001 [0..2]
        w2.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec) // chunk_002 [2..4]
        w2.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec) // chunk_003 [4..6]
        let r2 = w2.finishAll()
        guard r2.chunks.count == 3 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -11, userInfo: [NSLocalizedDescriptionKey: "Fixture 2 write failed"])
        }
        // Corrupt chunk_002 remote track with 4 unreadable bytes.
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: m2Dir.appendingPathComponent("chunks/remote_002.m4a"))
        // Rewrite chunk_003 timeline with wrong chunkId.
        let wrongTimeline = ChunkTimeline(
            schemaVersion: 1,
            chunkId: "chunk_999",
            chunkIndex: 999,
            audioRangeSec: [3.5, 6.0],
            responsibleRangeSec: [4.0, 6.0],
            windowMs: 250,
            segments: []
        )
        try AtomicFileWriter.writeJSON(wrongTimeline, to: m2Dir.appendingPathComponent("timelines/chunk_003.json"))
        let m2Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_corrupt_dual",
            title: "Corrupt Dual",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 6.0,
            chunks: r2.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        let m2URL = m2Dir.appendingPathComponent("manifest.json")
        try AtomicFileWriter.writeJSON(m2Manifest, to: m2URL)

        let coord = RecorderCoordinator(dataDir: dataRoot)
        coord.recoverOrphanedSessionsOnStartup()

        let rec1 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m1URL))
        guard rec1.chunks.count == 1,
              rec1.chunks[0].id == "chunk_001",
              rec1.totalDurationSec == 1.0,
              rec1.status == "partial",
              fm.fileExists(atPath: m1Dir.appendingPathComponent("chunks/mix_001.m4a").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -12, userInfo: [NSLocalizedDescriptionKey: "Case 1 failed: chunks=\(rec1.chunks.count) status=\(rec1.status) dur=\(rec1.totalDurationSec)"])
        }

        let rec2 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m2URL))
        guard rec2.status == "partial",
              rec2.chunks.count == 1,
              rec2.chunks[0].id == "chunk_001",
              rec2.totalDurationSec == 2.0,
              rec2.failedChunkCount == 2,
              !fm.fileExists(atPath: m2Dir.appendingPathComponent("chunks/remote_002.m4a").path),
              !fm.fileExists(atPath: m2Dir.appendingPathComponent("timelines/chunk_003.json").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -13, userInfo: [NSLocalizedDescriptionKey: "Case 2 failed: chunks=\(rec2.chunks.count) dur=\(rec2.totalDurationSec) failed=\(rec2.failedChunkCount)"])
        }

        // Case 3: Immutable manifest double-recovery preserves .commits/ until write succeeds, then recovers cleanly once writable.
        let m3Dir = dataRoot.appendingPathComponent("meetings/orphan_immutable_manifest")
        let w3 = try ChunkWriter(
            chunksDir: m3Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m3Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w3.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r3 = w3.finishAll()
        guard r3.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -14, userInfo: [NSLocalizedDescriptionKey: "Fixture 3 write failed"])
        }
        let m3URL = m3Dir.appendingPathComponent("manifest.json")
        let staleManifest3 = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_immutable_manifest",
            title: "Immutable Manifest Test",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0.0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(staleManifest3, to: m3URL)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: m3URL.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: m3Dir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: m3Dir.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: m3URL.path)
        }
        coord.recoverOrphanedSessionsOnStartup()
        guard fm.fileExists(atPath: m3Dir.appendingPathComponent(".commits/chunk_001.json").path),
              fm.fileExists(atPath: m3Dir.appendingPathComponent("chunks/mix_001.m4a").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -15, userInfo: [NSLocalizedDescriptionKey: "Immutable manifest failure prematurely deleted .commits/ or audio"])
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: m3Dir.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: m3URL.path)
        coord.recoverOrphanedSessionsOnStartup()
        let rec3 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m3URL))
        guard rec3.status == "partial",
              rec3.chunks.count == 1,
              rec3.chunks[0].id == "chunk_001",
              !fm.fileExists(atPath: m3Dir.appendingPathComponent(".commits").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -16, userInfo: [NSLocalizedDescriptionKey: "Case 3 retry recovery failed: chunks=\(rec3.chunks.count) status=\(rec3.status)"])
        }

        // Case 4: Crash during mid-chunk write leaving only hidden .tmp staged audio file -> counted as failed and removed.
        let m4Dir = dataRoot.appendingPathComponent("meetings/orphan_hidden_tmp")
        let m4Chunks = m4Dir.appendingPathComponent("chunks")
        try fm.createDirectory(at: m4Chunks, withIntermediateDirectories: true)
        let tmpStaged = m4Chunks.appendingPathComponent(".mix_001.ABCD1234.m4a.tmp")
        try Data([0x01, 0x02, 0x03]).write(to: tmpStaged)
        let staleManifest4 = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_hidden_tmp",
            title: "Hidden Tmp Mid-Chunk Crash",
            mode: "mic",
            appTarget: "mic_only",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0.0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        let m4URL = m4Dir.appendingPathComponent("manifest.json")
        try AtomicFileWriter.writeJSON(staleManifest4, to: m4URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec4 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m4URL))
        guard rec4.status == "partial",
              rec4.chunks.isEmpty,
              rec4.failedChunkCount == 1,
              !fm.fileExists(atPath: tmpStaged.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -17, userInfo: [NSLocalizedDescriptionKey: "Case 4 failed: status=\(rec4.status) failed=\(rec4.failedChunkCount)"])
        }

        // Case 5: Truncated valid-header 640-frame remote .m4a (0.04s vs expected 2.0s) rejected on full frame decode.
        let m5Dir = dataRoot.appendingPathComponent("meetings/orphan_truncated_m4a")
        let w5 = try ChunkWriter(
            chunksDir: m5Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m5Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w5.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec)
        let r5 = w5.finishAll()
        guard r5.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -18, userInfo: [NSLocalizedDescriptionKey: "Fixture 5 write failed"])
        }
        let shortStaging = dataRoot.appendingPathComponent("short_640_stage")
        let wShort = try ChunkWriter(
            chunksDir: shortStaging.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        wShort.appendSamples([Float](repeating: 0.1, count: 640))
        let rShort = wShort.finishAll()
        guard let shortRel = rShort.chunks.first?.audioPath else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -19, userInfo: [NSLocalizedDescriptionKey: "Short 640-frame AAC fixture failed"])
        }
        let targetRemote = m5Dir.appendingPathComponent("chunks/remote_001.m4a")
        try? fm.removeItem(at: targetRemote)
        try fm.copyItem(at: shortStaging.appendingPathComponent(shortRel), to: targetRemote)
        let m5URL = m5Dir.appendingPathComponent("manifest.json")
        let m5Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_truncated_m4a",
            title: "Truncated Remote AAC",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 2.0,
            chunks: r5.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m5Manifest, to: m5URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec5 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m5URL))
        guard rec5.status == "partial",
              rec5.chunks.isEmpty,
              rec5.failedChunkCount == 1,
              !fm.fileExists(atPath: targetRemote.path),
              !fm.fileExists(atPath: m5Dir.appendingPathComponent("chunks/mix_001.m4a").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -20, userInfo: [NSLocalizedDescriptionKey: "Case 5 failed: status=\(rec5.status) chunks=\(rec5.chunks.count) failed=\(rec5.failedChunkCount)"])
        }

        // Case 6: Transient .commits/ unreadable permission error (0o000) skips meeting without deleting valid media; retry recovers cleanly.
        let m6Dir = dataRoot.appendingPathComponent("meetings/orphan_transient_commits")
        let w6 = try ChunkWriter(
            chunksDir: m6Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m6Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w6.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r6 = w6.finishAll()
        guard r6.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -21, userInfo: [NSLocalizedDescriptionKey: "Fixture 6 write failed"])
        }
        let m6URL = m6Dir.appendingPathComponent("manifest.json")
        let staleManifest6 = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_transient_commits",
            title: "Transient Unreadable Commits",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0.0,
            chunks: [], // Commit marker only exists in .commits/
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(staleManifest6, to: m6URL)
        let m6CommitsDir = m6Dir.appendingPathComponent(".commits")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: m6CommitsDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: m6CommitsDir.path) }
        coord.recoverOrphanedSessionsOnStartup()
        let duringUnreadable = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m6URL))
        guard duringUnreadable.status == "recording",
              fm.fileExists(atPath: m6Dir.appendingPathComponent("chunks/mix_001.m4a").path),
              fm.fileExists(atPath: m6Dir.appendingPathComponent("chunks/mic_001.m4a").path),
              fm.fileExists(atPath: m6Dir.appendingPathComponent("chunks/remote_001.m4a").path),
              fm.fileExists(atPath: m6Dir.appendingPathComponent("timelines/chunk_001.json").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -22, userInfo: [NSLocalizedDescriptionKey: "Transient .commits/ read failure overwrote manifest or deleted media"])
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: m6CommitsDir.path)
        coord.recoverOrphanedSessionsOnStartup()
        let rec6 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m6URL))
        guard rec6.status == "partial", rec6.chunks.count == 1, rec6.chunks[0].id == "chunk_001" else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -23, userInfo: [NSLocalizedDescriptionKey: "Case 6 retry after .commits/ readable failed: chunks=\(rec6.chunks.count) status=\(rec6.status)"])
        }

        // Case 7: Short 0.20s expected chunk with truncated 640-frame (0.04s = 20%) remote .m4a is rejected.
        let m7Dir = dataRoot.appendingPathComponent("meetings/orphan_short_truncated")
        let w7 = try ChunkWriter(
            chunksDir: m7Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m7Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        let short200ms = [Float](repeating: 0.15, count: 3200)
        w7.appendDualSamples(mix: short200ms, mic: short200ms, remote: short200ms)
        let r7 = w7.finishAll()
        guard r7.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -24, userInfo: [NSLocalizedDescriptionKey: "Fixture 7 write failed"])
        }
        let targetRemote7 = m7Dir.appendingPathComponent("chunks/remote_001.m4a")
        try? fm.removeItem(at: targetRemote7)
        try fm.copyItem(at: shortStaging.appendingPathComponent(shortRel), to: targetRemote7)
        let m7URL = m7Dir.appendingPathComponent("manifest.json")
        let m7Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_short_truncated",
            title: "Short 0.20s Truncated Remote",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0.2,
            chunks: r7.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m7Manifest, to: m7URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec7 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m7URL))
        guard rec7.status == "partial", rec7.chunks.isEmpty, rec7.failedChunkCount == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -25, userInfo: [NSLocalizedDescriptionKey: "Case 7 failed: 0.20s chunk accepted 0.04s truncated remote"])
        }

        // Case 8: .pending_cleanup.json retry drains residual files on already-terminal partial meetings.
        let m8Dir = dataRoot.appendingPathComponent("meetings/orphan_pending_cleanup")
        let m8Chunks = m8Dir.appendingPathComponent("chunks")
        try fm.createDirectory(at: m8Chunks, withIntermediateDirectories: true)
        let strayFile = m8Chunks.appendingPathComponent("stale_002.m4a")
        try Data([0xAA, 0xBB]).write(to: strayFile)
        let pendingCleanupURL = m8Dir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\"chunks/stale_002.m4a\"]}".utf8).write(to: pendingCleanupURL)
        let m8Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_pending_cleanup",
            title: "Pending Cleanup Retry",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 0.0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 1,
            hostTimeOriginNs: nil,
            lastError: "interrupted cleanup"
        )
        try AtomicFileWriter.writeJSON(m8Manifest, to: m8Dir.appendingPathComponent("manifest.json"))
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: strayFile.path), !fm.fileExists(atPath: pendingCleanupURL.path) else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -26, userInfo: [NSLocalizedDescriptionKey: "Case 8 failed: .pending_cleanup.json retry did not drain stray file"])
        }

        // Case 9: CoreAudio -54 (permErr) & restricted AAC codec error (1718449215) classify as transientError (never delete media);
        // 0o000 unreadable audio preserves meeting untouched and recovers once readable.
        guard Self.classifyCoreAudioStatus(-54) == .transientError,
              Self.classifyCoreAudioStatus(OSStatus(1718449215), isCodecSetupForAAC: true) == .transientError,
              Self.classifyCoreAudioStatus(kAudioFileUnspecifiedError) == .invalid
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -27, userInfo: [NSLocalizedDescriptionKey: "CoreAudio OSStatus classification mismatch"])
        }

        let m9Dir = dataRoot.appendingPathComponent("meetings/orphan_late_perm_denial")
        let w9 = try ChunkWriter(
            chunksDir: m9Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m9Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w9.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r9 = w9.finishAll()
        guard r9.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -28, userInfo: [NSLocalizedDescriptionKey: "Fixture 9 write failed"])
        }
        let m9URL = m9Dir.appendingPathComponent("manifest.json")
        let m9Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_late_perm_denial",
            title: "Unreadable Remote Audio",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: r9.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m9Manifest, to: m9URL)
        let m9Remote = m9Dir.appendingPathComponent("chunks/remote_001.m4a")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: m9Remote.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: m9Remote.path) }
        coord.recoverOrphanedSessionsOnStartup()
        let during9 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m9URL))
        guard during9.status == "recording",
              fm.fileExists(atPath: m9Dir.appendingPathComponent("chunks/mix_001.m4a").path),
              fm.fileExists(atPath: m9Remote.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -29, userInfo: [NSLocalizedDescriptionKey: "Unreadable remote audio caused deletion or status mutation"])
        }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: m9Remote.path)
        coord.recoverOrphanedSessionsOnStartup()
        let rec9 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m9URL))
        guard rec9.status == "partial", rec9.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -30, userInfo: [NSLocalizedDescriptionKey: "Case 9 retry recovery failed: chunks=\(rec9.chunks.count)"])
        }

        // Case 10: Stale .pending_cleanup.json listing a file referenced by manifest.json cannot delete it; unreferenced orphan still removed.
        let m10Dir = dataRoot.appendingPathComponent("meetings/orphan_stale_journal_guard")
        let w10 = try ChunkWriter(
            chunksDir: m10Dir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w10.appendSamples(oneSec)
        let r10 = w10.finishAll()
        guard r10.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -31, userInfo: [NSLocalizedDescriptionKey: "Fixture 10 write failed"])
        }
        let m10Orphan = m10Dir.appendingPathComponent("chunks/orphan_002.m4a")
        try Data([0x11, 0x22]).write(to: m10Orphan)
        let m10Pending = m10Dir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\"chunks/mic_001.m4a\",\"chunks/orphan_002.m4a\"]}".utf8).write(to: m10Pending)
        let m10Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_stale_journal_guard",
            title: "Stale Cleanup Journal Guard",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r10.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m10Manifest, to: m10Dir.appendingPathComponent("manifest.json"))
        coord.recoverOrphanedSessionsOnStartup()
        guard fm.fileExists(atPath: m10Dir.appendingPathComponent("chunks/mic_001.m4a").path),
              !fm.fileExists(atPath: m10Orphan.path),
              !fm.fileExists(atPath: m10Pending.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -32, userInfo: [NSLocalizedDescriptionKey: "Case 10 failed: manifest-referenced chunk deleted or orphan survived"])
        }

        // Case 11: Case-insensitive APFS alias (chunks/MIX_001.m4a vs manifest chunks/mix_001.m4a) is NOT treated as an orphan or deleted.
        let m11Dir = dataRoot.appendingPathComponent("meetings/orphan_case_alias")
        let w11 = try ChunkWriter(
            chunksDir: m11Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m11Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w11.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r11 = w11.finishAll()
        guard r11.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -33, userInfo: [NSLocalizedDescriptionKey: "Fixture 11 write failed"])
        }
        let origMix11 = m11Dir.appendingPathComponent("chunks/mix_001.m4a")
        let tmpMix11 = m11Dir.appendingPathComponent("chunks/mix_001_renametmp.m4a")
        let upperMix11 = m11Dir.appendingPathComponent("chunks/MIX_001.m4a")
        try fm.moveItem(at: origMix11, to: tmpMix11)
        try fm.moveItem(at: tmpMix11, to: upperMix11)
        let m11URL = m11Dir.appendingPathComponent("manifest.json")
        let m11Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_case_alias",
            title: "APFS Case Alias Guard",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: r11.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m11Manifest, to: m11URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec11 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m11URL))
        let chunkEntries11 = try fm.contentsOfDirectory(atPath: m11Dir.appendingPathComponent("chunks").path)
        guard rec11.status == "partial",
              rec11.chunks.count == 1,
              rec11.failedChunkCount == 0,
              fm.fileExists(atPath: upperMix11.path),
              chunkEntries11.contains("MIX_001.m4a")
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -34, userInfo: [NSLocalizedDescriptionKey: "Case 11 failed: APFS case alias MIX_001.m4a deleted or failed=\(rec11.failedChunkCount)"])
        }

        // Case 12: 128-byte truncated .m4a (kAudioFileInvalidFileError 1685348671) classifies as .invalid,
        // allowing valid segments 1 & 3 in the same meeting to recover cleanly.
        guard Self.classifyCoreAudioStatus(kAudioFileInvalidFileError) == .invalid else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -35, userInfo: [NSLocalizedDescriptionKey: "kAudioFileInvalidFileError did not classify as .invalid"])
        }
        let m12Dir = dataRoot.appendingPathComponent("meetings/orphan_128b_corrupt_mid")
        let w12 = try ChunkWriter(
            chunksDir: m12Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m12Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 2.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w12.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec) // chunk_001
        w12.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec) // chunk_002
        w12.appendDualSamples(mix: twoSec, mic: twoSec, remote: twoSec) // chunk_003
        let r12 = w12.finishAll()
        guard r12.chunks.count == 3 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -36, userInfo: [NSLocalizedDescriptionKey: "Fixture 12 write failed"])
        }
        let mix2URL = m12Dir.appendingPathComponent("chunks/mix_002.m4a")
        let fullMix2Data = try Data(contentsOf: mix2URL)
        try fullMix2Data.prefix(128).write(to: mix2URL)
        let m12URL = m12Dir.appendingPathComponent("manifest.json")
        let m12Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_128b_corrupt_mid",
            title: "128B Truncated Middle Chunk",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 6.0,
            chunks: r12.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m12Manifest, to: m12URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec12 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m12URL))
        guard rec12.status == "partial",
              rec12.chunks.map(\.id) == ["chunk_001", "chunk_003"],
              rec12.failedChunkCount == 1,
              !fm.fileExists(atPath: mix2URL.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -37, userInfo: [NSLocalizedDescriptionKey: "Case 12 failed: chunks=\(rec12.chunks.map(\.id)) failed=\(rec12.failedChunkCount)"])
        }

        // Case 13: Uppercase .commits/CHUNK_001.JSON commit marker recovers chunk_001 cleanly.
        let m13Dir = dataRoot.appendingPathComponent("meetings/orphan_uppercase_commit_ext")
        let w13 = try ChunkWriter(
            chunksDir: m13Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m13Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w13.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r13 = w13.finishAll()
        guard r13.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -38, userInfo: [NSLocalizedDescriptionKey: "Fixture 13 write failed"])
        }
        let origCommit13 = m13Dir.appendingPathComponent(".commits/chunk_001.json")
        let tmpCommit13 = m13Dir.appendingPathComponent(".commits/chunk_001_renametmp.json")
        let upperCommit13 = m13Dir.appendingPathComponent(".commits/CHUNK_001.JSON")
        try fm.moveItem(at: origCommit13, to: tmpCommit13)
        try fm.moveItem(at: tmpCommit13, to: upperCommit13)
        let m13URL = m13Dir.appendingPathComponent("manifest.json")
        let m13Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_uppercase_commit_ext",
            title: "Uppercase Commit JSON",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0.0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m13Manifest, to: m13URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec13 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m13URL))
        guard rec13.status == "partial",
              rec13.chunks.count == 1,
              rec13.chunks[0].id == "chunk_001",
              fm.fileExists(atPath: m13Dir.appendingPathComponent("chunks/mix_001.m4a").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -39, userInfo: [NSLocalizedDescriptionKey: "Case 13 failed: chunks=\(rec13.chunks.count)"])
        }

        // Case 14: .pending_cleanup.json pointing at parent "chunks" directory cannot delete live chunk assets;
        // unreferenced leaf orphan file still gets cleaned.
        let m14Dir = dataRoot.appendingPathComponent("meetings/orphan_parent_dir_cleanup")
        let w14 = try ChunkWriter(
            chunksDir: m14Dir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w14.appendSamples(oneSec)
        let r14 = w14.finishAll()
        guard r14.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -40, userInfo: [NSLocalizedDescriptionKey: "Fixture 14 write failed"])
        }
        let orphan14 = m14Dir.appendingPathComponent("chunks/orphan_002.m4a")
        try Data([0x33, 0x44]).write(to: orphan14)
        let pending14 = m14Dir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\"chunks\",\"chunks/orphan_002.m4a\"]}".utf8).write(to: pending14)
        let m14Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_parent_dir_cleanup",
            title: "Parent Dir Guard",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r14.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m14Manifest, to: m14Dir.appendingPathComponent("manifest.json"))
        coord.recoverOrphanedSessionsOnStartup()
        guard fm.fileExists(atPath: m14Dir.appendingPathComponent("chunks/mic_001.m4a").path),
              !fm.fileExists(atPath: orphan14.path),
              !fm.fileExists(atPath: pending14.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -41, userInfo: [NSLocalizedDescriptionKey: "Case 14 failed: parent dir 'chunks' deleted live audio or orphan survived"])
        }

        // Case 15a: Symlink traversal in .pending_cleanup.json MUST NOT delete files across symlink into another meeting.
        let extMeeting15a = dataRoot.appendingPathComponent("meetings/external_meeting")
        let extChunks15a = extMeeting15a.appendingPathComponent("chunks")
        try fm.createDirectory(at: extChunks15a, withIntermediateDirectories: true)
        let extKeepURL15a = extChunks15a.appendingPathComponent("keep.m4a")
        let extPayload15a = Data([0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22])
        try extPayload15a.write(to: extKeepURL15a)

        let symMeeting15a = dataRoot.appendingPathComponent("meetings/orphan_symlink_journal")
        try fm.createDirectory(at: symMeeting15a, withIntermediateDirectories: true)
        let symChunks15a = symMeeting15a.appendingPathComponent("chunks")
        guard Darwin.symlink("../external_meeting/chunks", symChunks15a.path) == 0 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -42, userInfo: [NSLocalizedDescriptionKey: "Fixture 15a symlink creation failed (errno=\(errno))"])
        }
        let m15aManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_symlink_journal",
            title: "Symlink Journal Guard",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 0.0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m15aManifest, to: symMeeting15a.appendingPathComponent("manifest.json"))
        let pending15a = symMeeting15a.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\"chunks/keep.m4a\"]}".utf8).write(to: pending15a)
        coord.recoverOrphanedSessionsOnStartup()
        let readBack15a = try? Data(contentsOf: extKeepURL15a)
        guard fm.fileExists(atPath: extKeepURL15a.path),
              readBack15a == extPayload15a,
              !fm.fileExists(atPath: pending15a.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -43, userInfo: [NSLocalizedDescriptionKey: "Case 15a failed: symlink cleanup traversed external meeting or retained journal"])
        }

        // Case 15b: Protected metadata/audio hardlinks inside .commits/ must NOT increment failedChunkCount or get unlinked.
        let m15bDir = dataRoot.appendingPathComponent("meetings/orphan_commits_hardlinks")
        let w15b = try ChunkWriter(
            chunksDir: m15bDir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m15bDir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w15b.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r15b = w15b.finishAll()
        guard r15b.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -44, userInfo: [NSLocalizedDescriptionKey: "Fixture 15b write failed"])
        }
        let m15bURL = m15bDir.appendingPathComponent("manifest.json")
        let m15bManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_commits_hardlinks",
            title: "Commits Hardlink Guard",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: r15b.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m15bManifest, to: m15bURL)
        let link1 = m15bDir.appendingPathComponent(".commits/.chunk_004.json.tmp")
        let link2 = m15bDir.appendingPathComponent(".commits/chunk_005.json.tmp")
        let link3 = m15bDir.appendingPathComponent(".commits/chunk_006.json.tmp")
        let mix1Path15b = m15bDir.appendingPathComponent("chunks/mix_001.m4a").path
        guard Darwin.link(m15bURL.path, link1.path) == 0,
              Darwin.link(mix1Path15b, link2.path) == 0,
              Darwin.link(m15bURL.path, link3.path) == 0
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -45, userInfo: [NSLocalizedDescriptionKey: "Fixture 15b hardlink creation failed (errno=\(errno))"])
        }
        coord.recoverOrphanedSessionsOnStartup()
        let rec15b = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m15bURL))
        guard rec15b.status == "partial",
              rec15b.chunks.count == 1,
              rec15b.failedChunkCount == 0,
              fm.fileExists(atPath: mix1Path15b),
              fm.fileExists(atPath: link1.path),
              fm.fileExists(atPath: link2.path),
              fm.fileExists(atPath: link3.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -46, userInfo: [NSLocalizedDescriptionKey: "Case 15b failed: failed=\(rec15b.failedChunkCount) chunks=\(rec15b.chunks.count)"])
        }

        // Case 16: StartAttemptWaiter isolates failed Attempt 1 from immediate retry Attempt 2 on the same key.
        let coord16 = RecorderCoordinator(dataDir: dataRoot)
        let waiter1 = StartAttemptWaiter()
        let waiter2 = StartAttemptWaiter()
        coord16.lock.withLock {
            coord16.idempotencyMap["retry_same_key"] = "second_attempt_id"
            coord16.state = "starting"
            coord16.activeIdempotencyKey = "retry_same_key"
            coord16.startingWaiter = waiter2
        }
        let waiter1Done = DispatchSemaphore(value: 0)
        final class ErrorBox: @unchecked Sendable {
            var err: Error?
        }
        let errBox16 = ErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try waiter1.wait()
            } catch {
                errBox16.err = error
            }
            waiter1Done.signal()
        }
        waiter1.complete(with: .failure(CoordinatorError.internalError("attempt1_failed")))
        guard waiter1Done.wait(timeout: .now() + .seconds(2)) == .success else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -47, userInfo: [NSLocalizedDescriptionKey: "Case 16 waiter1 timed out"])
        }
        if case .internalError(let msg) = errBox16.err as? CoordinatorError, msg == "attempt1_failed" {
            // Expected Attempt 1 failure surfaced even though Attempt 2 is already in idempotencyMap / starting state.
        } else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -48, userInfo: [NSLocalizedDescriptionKey: "Case 16 failed: waiter1 returned \(String(describing: errBox16.err))"])
        }
        waiter2.complete(with: .failure(CoordinatorError.internalError("cleanup")))

        // Case 17 (P1): Audio & timeline validators MUST reject files accessed via symlinked parent directories.
        let extValid17 = dataRoot.appendingPathComponent("meetings/external_valid_17")
        let w17 = try ChunkWriter(
            chunksDir: extValid17.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: extValid17.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w17.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r17 = w17.finishAll()
        guard r17.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -49, userInfo: [NSLocalizedDescriptionKey: "Fixture 17 write failed"])
        }
        let extManifest17 = MeetingManifest(
            schemaVersion: 1,
            id: "external_valid_17",
            title: "External Valid 17",
            mode: "dual",
            appTarget: "all_system",
            status: "recorded",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r17.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(extManifest17, to: extValid17.appendingPathComponent("manifest.json"))

        let symParent17 = dataRoot.appendingPathComponent("meetings/orphan_symlink_parent_validate")
        try fm.createDirectory(at: symParent17, withIntermediateDirectories: true)
        guard Darwin.symlink("../external_valid_17/chunks", symParent17.appendingPathComponent("chunks").path) == 0,
              Darwin.symlink("../external_valid_17/timelines", symParent17.appendingPathComponent("timelines").path) == 0
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -50, userInfo: [NSLocalizedDescriptionKey: "Fixture 17 symlink creation failed (errno=\(errno))"])
        }
        let m17URL = symParent17.appendingPathComponent("manifest.json")
        let m17Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_symlink_parent_validate",
            title: "Symlinked Parent Validation",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: r17.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m17Manifest, to: m17URL)
        coord.recoverOrphanedSessionsOnStartup()
        let rec17 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m17URL))
        guard rec17.chunks.isEmpty,
              rec17.failedChunkCount == 1,
              fm.fileExists(atPath: extValid17.appendingPathComponent("chunks/mix_001.m4a").path),
              fm.fileExists(atPath: extValid17.appendingPathComponent("chunks/mic_001.m4a").path),
              fm.fileExists(atPath: extValid17.appendingPathComponent("chunks/remote_001.m4a").path),
              fm.fileExists(atPath: extValid17.appendingPathComponent("timelines/chunk_001.json").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -51, userInfo: [NSLocalizedDescriptionKey: "Case 17 failed: symlink parent validated chunk or damaged external meeting: chunks=\(rec17.chunks.count) failed=\(rec17.failedChunkCount)"])
        }

        // Case 18 (P2): Cross-process .pending_cleanup.json replay preserves pre-rewrite manifest.json hardlinks inside .commits/.
        let m18Dir = dataRoot.appendingPathComponent("meetings/orphan_cross_process_commits_replay")
        let w18 = try ChunkWriter(
            chunksDir: m18Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m18Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w18.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r18 = w18.finishAll()
        guard r18.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -52, userInfo: [NSLocalizedDescriptionKey: "Fixture 18 write failed"])
        }
        let m18URL = m18Dir.appendingPathComponent("manifest.json")
        let m18Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_cross_process_commits_replay",
            title: "Cross Process Commits Replay",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: r18.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m18Manifest, to: m18URL)
        let commits18 = m18Dir.appendingPathComponent(".commits")
        let link18a = commits18.appendingPathComponent(".chunk_004.json.tmp")
        let link18b = commits18.appendingPathComponent("chunk_006.json.tmp")
        guard Darwin.link(m18URL.path, link18a.path) == 0,
              Darwin.link(m18URL.path, link18b.path) == 0
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -53, userInfo: [NSLocalizedDescriptionKey: "Fixture 18 hardlink failed (errno=\(errno))"])
        }
        var commitsRestored18 = false
        defer {
            if !commitsRestored18 {
                _ = Darwin.chmod(commits18.path, 0o755)
            }
        }
        guard Darwin.chmod(commits18.path, 0o555) == 0 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -54, userInfo: [NSLocalizedDescriptionKey: "Fixture 18 chmod 0555 failed (errno=\(errno))"])
        }
        coord.recoverOrphanedSessionsOnStartup()
        let pending18 = m18Dir.appendingPathComponent(".pending_cleanup.json")
        let pass1Manifest18 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m18URL))
        guard pass1Manifest18.status == "partial",
              pass1Manifest18.failedChunkCount == 0,
              fm.fileExists(atPath: pending18.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -55, userInfo: [NSLocalizedDescriptionKey: "Case 18 pass 1 failed: status=\(pass1Manifest18.status) pending=\(fm.fileExists(atPath: pending18.path))"])
        }
        guard Darwin.chmod(commits18.path, 0o755) == 0 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -56, userInfo: [NSLocalizedDescriptionKey: "Fixture 18 chmod 0755 failed (errno=\(errno))"])
        }
        commitsRestored18 = true
        let coord18b = RecorderCoordinator(dataDir: dataRoot)
        coord18b.recoverOrphanedSessionsOnStartup()
        let pass2Manifest18 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m18URL))
        guard pass2Manifest18.failedChunkCount == 0,
              !fm.fileExists(atPath: pending18.path),
              !fm.fileExists(atPath: commits18.appendingPathComponent("chunk_001.json").path),
              fm.fileExists(atPath: link18a.path),
              fm.fileExists(atPath: link18b.path),
              fm.fileExists(atPath: m18Dir.appendingPathComponent("chunks/mix_001.m4a").path),
              fm.fileExists(atPath: m18Dir.appendingPathComponent("chunks/mic_001.m4a").path),
              fm.fileExists(atPath: m18Dir.appendingPathComponent("chunks/remote_001.m4a").path),
              fm.fileExists(atPath: m18Dir.appendingPathComponent("timelines/chunk_001.json").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -57, userInfo: [NSLocalizedDescriptionKey: "Case 18 pass 2 failed: protected hardlinks removed or cleanup incomplete"])
        }

        // Case 19 (P1): Named pipe (FIFO) at chunk path MUST NOT block daemon startup recovery.
        let m19Dir = dataRoot.appendingPathComponent("meetings/orphan_fifo_nonblocking")
        try fm.createDirectory(at: m19Dir.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        let fifo19URL = m19Dir.appendingPathComponent("chunks/mic_001.m4a")
        guard Darwin.mkfifo(fifo19URL.path, 0o600) == 0 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -58, userInfo: [NSLocalizedDescriptionKey: "Fixture 19 mkfifo failed (errno=\(errno))"])
        }
        let m19URL = m19Dir.appendingPathComponent("manifest.json")
        let chunk19 = ChunkRecord(
            index: 1,
            id: "chunk_001",
            audioPath: "chunks/mic_001.m4a",
            micPath: "chunks/mic_001.m4a",
            remotePath: nil,
            timelinePath: nil,
            audioRangeSec: [0.0, 1.0],
            responsibleRangeSec: [0.0, 1.0],
            durationSec: 1.0,
            byteSize: 100,
            committedAt: AtomicFileWriter.isoNow()
        )
        let m19Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_fifo_nonblocking",
            title: "FIFO Non-blocking Guard",
            mode: "mic",
            appTarget: "mic_only",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: [chunk19],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m19Manifest, to: m19URL)
        let t0Fifo19 = DispatchTime.now()
        coord.recoverOrphanedSessionsOnStartup()
        let fifoElapsedNs19 = DispatchTime.now().uptimeNanoseconds &- t0Fifo19.uptimeNanoseconds
        let rec19 = try JSONDecoder().decode(MeetingManifest.self, from: Data(contentsOf: m19URL))
        guard fifoElapsedNs19 < 2_000_000_000,
              rec19.chunks.isEmpty,
              rec19.failedChunkCount == 1
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -59, userInfo: [NSLocalizedDescriptionKey: "Case 19 failed: fifo stalled or validated: ns=\(fifoElapsedNs19) chunks=\(rec19.chunks.count) failed=\(rec19.failedChunkCount)"])
        }

        // Case 20 (P2): Legacy journal without protectedIdentities preserves old-manifest/metadata files inside .commits/.
        let m20Dir = dataRoot.appendingPathComponent("meetings/orphan_legacy_upgrade_replay")
        let w20 = try ChunkWriter(
            chunksDir: m20Dir.appendingPathComponent("chunks"),
            mode: .dual,
            timelinesDir: m20Dir.appendingPathComponent("timelines"),
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w20.appendDualSamples(mix: oneSec, mic: oneSec, remote: oneSec)
        let r20 = w20.finishAll()
        guard r20.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -60, userInfo: [NSLocalizedDescriptionKey: "Fixture 20 write failed"])
        }
        let m20URL = m20Dir.appendingPathComponent("manifest.json")
        let m20ManifestOrig = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_legacy_upgrade_replay",
            title: "Legacy Replay",
            mode: "dual",
            appTarget: "all_system",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 1.0,
            chunks: r20.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(m20ManifestOrig, to: m20URL)
        let commits20 = m20Dir.appendingPathComponent(".commits")
        let link20a = commits20.appendingPathComponent(".chunk_004.json.tmp")
        let link20b = commits20.appendingPathComponent("chunk_006.json.tmp")
        let snap20c = commits20.appendingPathComponent("chunk_007.json.tmp")
        guard Darwin.link(m20URL.path, link20a.path) == 0,
              Darwin.link(m20URL.path, link20b.path) == 0
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -61, userInfo: [NSLocalizedDescriptionKey: "Fixture 20 hardlink failed (errno=\(errno))"])
        }
        try Data("{\"paths\":[\".commits\"]}".utf8).write(to: snap20c)
        var m20Updated = m20ManifestOrig
        m20Updated.status = "partial"
        m20Updated.endedAt = AtomicFileWriter.isoNow()
        try AtomicFileWriter.writeJSON(m20Updated, to: m20URL)
        let pending20 = m20Dir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\".commits\"]}".utf8).write(to: pending20)
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: pending20.path),
              !fm.fileExists(atPath: commits20.appendingPathComponent("chunk_001.json").path),
              fm.fileExists(atPath: link20a.path),
              fm.fileExists(atPath: link20b.path),
              fm.fileExists(atPath: snap20c.path),
              fm.fileExists(atPath: m20Dir.appendingPathComponent("chunks/mix_001.m4a").path),
              fm.fileExists(atPath: m20Dir.appendingPathComponent("chunks/mic_001.m4a").path),
              fm.fileExists(atPath: m20Dir.appendingPathComponent("chunks/remote_001.m4a").path),
              fm.fileExists(atPath: m20Dir.appendingPathComponent("timelines/chunk_001.json").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -62, userInfo: [NSLocalizedDescriptionKey: "Case 20 failed: legacy replay deleted metadata hardlinks or failed cleanup"])
        }

        // Case 21 (P2): Malformed out-of-range dev values in .pending_cleanup.json MUST NOT crash startup.
        let m21Dir = dataRoot.appendingPathComponent("meetings/orphan_malformed_dev_replay")
        let w21 = try ChunkWriter(
            chunksDir: m21Dir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w21.appendSamples(oneSec)
        let r21 = w21.finishAll()
        guard r21.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -63, userInfo: [NSLocalizedDescriptionKey: "Fixture 21 write failed"])
        }
        let orphan21 = m21Dir.appendingPathComponent("chunks/orphan_21.m4a")
        try Data([0x12, 0x34]).write(to: orphan21)
        let pending21 = m21Dir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\"chunks/orphan_21.m4a\"],\"protectedIdentities\":[{\"dev\":9223372036854775807,\"ino\":42},{\"dev\":-9223372036854775808,\"ino\":43}]}".utf8).write(to: pending21)
        let m21Manifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_malformed_dev_replay",
            title: "Malformed Dev Replay",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r21.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m21Manifest, to: m21Dir.appendingPathComponent("manifest.json"))
        coord.recoverOrphanedSessionsOnStartup()
        guard fm.fileExists(atPath: m21Dir.appendingPathComponent("chunks/mic_001.m4a").path),
              !fm.fileExists(atPath: orphan21.path),
              !fm.fileExists(atPath: pending21.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -64, userInfo: [NSLocalizedDescriptionKey: "Case 21 failed: orphan survived or live audio deleted"])
        }

        // Case 22a (P2): Legacy replay preserves single-link old manifest > 4 MiB (e.g., 4,194,305 bytes) inside .commits/.
        let m22aDir = dataRoot.appendingPathComponent("meetings/orphan_large_legacy_manifest")
        let w22a = try ChunkWriter(
            chunksDir: m22aDir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w22a.appendSamples(oneSec)
        let r22a = w22a.finishAll()
        guard r22a.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -65, userInfo: [NSLocalizedDescriptionKey: "Fixture 22a write failed"])
        }
        let m22aManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_large_legacy_manifest",
            title: "Large Legacy Manifest",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r22a.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m22aManifest, to: m22aDir.appendingPathComponent("manifest.json"))
        let commits22a = m22aDir.appendingPathComponent(".commits")
        let largeOldManifestURL = commits22a.appendingPathComponent(".chunk_008.json.tmp")
        var largeManifestData = try JSONEncoder().encode(m22aManifest)
        let targetMinSize = (4 * 1024 * 1024) + 1
        if largeManifestData.count < targetMinSize {
            largeManifestData.append(Data(repeating: 0x20, count: targetMinSize - largeManifestData.count))
        }
        try largeManifestData.write(to: largeOldManifestURL)
        let pending22a = m22aDir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\".commits\"]}".utf8).write(to: pending22a)
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: commits22a.appendingPathComponent("chunk_001.json").path),
              !fm.fileExists(atPath: pending22a.path),
              fm.fileExists(atPath: largeOldManifestURL.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -66, userInfo: [NSLocalizedDescriptionKey: "Case 22a failed: >4MiB single-link manifest deleted or journal stuck"])
        }

        // Case 22b (P2): Out-of-range JSON integers (ino=-1, ino=2^64, huge dev) MUST NOT discard pending cleanup or valid protected identities.
        let m22bDir = dataRoot.appendingPathComponent("meetings/orphan_out_of_range_json_ids")
        let w22b = try ChunkWriter(
            chunksDir: m22bDir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w22b.appendSamples(oneSec)
        let r22b = w22b.finishAll()
        guard r22b.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -67, userInfo: [NSLocalizedDescriptionKey: "Fixture 22b write failed"])
        }
        let keepAlias22b = m22bDir.appendingPathComponent("chunks/keep_alias_22.m4a")
        try Data([0x55, 0x66]).write(to: keepAlias22b)
        guard let keepId22b = Self.fileIdentity(of: keepAlias22b) else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -68, userInfo: [NSLocalizedDescriptionKey: "Fixture 22b missing identity"])
        }
        let orphan22b = m22bDir.appendingPathComponent("chunks/orphan_22.m4a")
        try Data([0x77, 0x88]).write(to: orphan22b)
        let pending22b = m22bDir.appendingPathComponent(".pending_cleanup.json")
        let json22b = """
        {"paths":["chunks/orphan_22.m4a","chunks/keep_alias_22.m4a"],"protectedIdentities":[{"dev":99999999999999999999999,"ino":1},{"dev":-99999999999999999999999,"ino":2},{"dev":1,"ino":-1},{"dev":1,"ino":18446744073709551616},{"dev":\(Int64(keepId22b.dev)),"ino":\(UInt64(keepId22b.ino))}]}
        """
        try Data(json22b.utf8).write(to: pending22b)
        let m22bManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_out_of_range_json_ids",
            title: "Out of Range JSON Ids",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r22b.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m22bManifest, to: m22bDir.appendingPathComponent("manifest.json"))
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: orphan22b.path),
              !fm.fileExists(atPath: pending22b.path),
              fm.fileExists(atPath: keepAlias22b.path),
              fm.fileExists(atPath: m22bDir.appendingPathComponent("chunks/mic_001.m4a").path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -69, userInfo: [NSLocalizedDescriptionKey: "Case 22b failed: orphan survived or valid protected alias deleted"])
        }

        // Case 23a (P2): UTF-16LE BOM single-link old manifest inside .commits/ is preserved during legacy replay.
        let m23aDir = dataRoot.appendingPathComponent("meetings/orphan_utf16le_legacy_manifest")
        let w23a = try ChunkWriter(
            chunksDir: m23aDir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w23a.appendSamples(oneSec)
        let r23a = w23a.finishAll()
        guard r23a.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -70, userInfo: [NSLocalizedDescriptionKey: "Fixture 23a write failed"])
        }
        let m23aManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_utf16le_legacy_manifest",
            title: "UTF16LE Legacy Manifest",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r23a.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m23aManifest, to: m23aDir.appendingPathComponent("manifest.json"))
        let commits23a = m23aDir.appendingPathComponent(".commits")
        let utf8Json23a = String(decoding: try JSONEncoder().encode(m23aManifest), as: UTF8.self)
        var utf16Data23a = Data([0xFF, 0xFE])
        utf16Data23a.append(Data(utf8Json23a.data(using: .utf16LittleEndian)!))
        let utf16URL23a = commits23a.appendingPathComponent(".chunk_009.json.tmp")
        try utf16Data23a.write(to: utf16URL23a)
        let pending23a = m23aDir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\".commits\"]}".utf8).write(to: pending23a)
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: commits23a.appendingPathComponent("chunk_001.json").path),
              !fm.fileExists(atPath: pending23a.path),
              fm.fileExists(atPath: utf16URL23a.path),
              (try? Data(contentsOf: utf16URL23a)) == utf16Data23a
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -71, userInfo: [NSLocalizedDescriptionKey: "Case 23a failed: UTF-16LE BOM single-link manifest deleted or journal stuck"])
        }

        // Case 23b (P2): Non-array protectedIdentities (single {dev, ino} object or malformed scalar) keeps protection intact.
        let m23bDir = dataRoot.appendingPathComponent("meetings/orphan_single_obj_protected")
        let w23b = try ChunkWriter(
            chunksDir: m23bDir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w23b.appendSamples(oneSec)
        let r23b = w23b.finishAll()
        guard r23b.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -72, userInfo: [NSLocalizedDescriptionKey: "Fixture 23b write failed"])
        }
        let keep23b = m23bDir.appendingPathComponent("chunks/keep_23b.m4a")
        try Data([0x11, 0x22]).write(to: keep23b)
        let orphan23b = m23bDir.appendingPathComponent("chunks/orphan_23b.m4a")
        try Data([0x33, 0x44]).write(to: orphan23b)
        guard let keepId23b = Self.fileIdentity(of: keep23b) else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -73, userInfo: [NSLocalizedDescriptionKey: "Fixture 23b identity failed"])
        }
        let m23bManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_single_obj_protected",
            title: "Non Array Protected IDs",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r23b.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        let m23bURL = m23bDir.appendingPathComponent("manifest.json")
        try AtomicFileWriter.writeJSON(m23bManifest, to: m23bURL)
        let commits23b = m23bDir.appendingPathComponent(".commits")
        let snap23b = commits23b.appendingPathComponent(".chunk_011.json.tmp")
        try JSONEncoder().encode(m23bManifest).write(to: snap23b)
        let pending23b = m23bDir.appendingPathComponent(".pending_cleanup.json")
        let singleObjJson23b = """
        {"paths":["chunks/orphan_23b.m4a","chunks/keep_23b.m4a"],"protectedIdentities":{"dev":\(Int64(keepId23b.dev)),"ino":\(UInt64(keepId23b.ino))}}
        """
        try Data(singleObjJson23b.utf8).write(to: pending23b)
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: orphan23b.path),
              !fm.fileExists(atPath: pending23b.path),
              fm.fileExists(atPath: keep23b.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -74, userInfo: [NSLocalizedDescriptionKey: "Case 23b single-object protectedIdentities failed"])
        }
        try Data("{\"paths\":[\".commits\"],\"protectedIdentities\":\"bad_not_array\"}".utf8).write(to: pending23b)
        coord.recoverOrphanedSessionsOnStartup()
        guard !fm.fileExists(atPath: commits23b.appendingPathComponent("chunk_001.json").path),
              !fm.fileExists(atPath: pending23b.path),
              fm.fileExists(atPath: snap23b.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -75, userInfo: [NSLocalizedDescriptionKey: "Case 23b malformed protectedIdentities deleted manifest snapshot"])
        }

        // Case 23c (P2): 8 MiB leading-whitespace legacy manifest scans in O(N) well under 2.0s budget.
        let m23cDir = dataRoot.appendingPathComponent("meetings/orphan_8mb_leading_ws")
        let w23c = try ChunkWriter(
            chunksDir: m23cDir.appendingPathComponent("chunks"),
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { _ in },
            onChunkFailed: { _ in }
        )
        w23c.appendSamples(oneSec)
        let r23c = w23c.finishAll()
        guard r23c.chunks.count == 1 else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -76, userInfo: [NSLocalizedDescriptionKey: "Fixture 23c write failed"])
        }
        let m23cManifest = MeetingManifest(
            schemaVersion: 1,
            id: "orphan_8mb_leading_ws",
            title: "8MB Leading WS",
            mode: "mic",
            appTarget: "mic_only",
            status: "partial",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: AtomicFileWriter.isoNow(),
            totalDurationSec: 1.0,
            chunks: r23c.chunks,
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: "partial"
        )
        try AtomicFileWriter.writeJSON(m23cManifest, to: m23cDir.appendingPathComponent("manifest.json"))
        let commits23c = m23cDir.appendingPathComponent(".commits")
        let hugeWSURL = commits23c.appendingPathComponent(".chunk_010.json.tmp")
        var hugeWSData = Data(repeating: 0x20, count: 8 * 1024 * 1024)
        hugeWSData.append(try JSONEncoder().encode(m23cManifest))
        try hugeWSData.write(to: hugeWSURL)
        let pending23c = m23cDir.appendingPathComponent(".pending_cleanup.json")
        try Data("{\"paths\":[\".commits\"]}".utf8).write(to: pending23c)
        let t023c = DispatchTime.now()
        coord.recoverOrphanedSessionsOnStartup()
        let elapsed23cNs = DispatchTime.now().uptimeNanoseconds &- t023c.uptimeNanoseconds
        guard elapsed23cNs < 2_000_000_000,
              !fm.fileExists(atPath: commits23c.appendingPathComponent("chunk_001.json").path),
              !fm.fileExists(atPath: pending23c.path),
              fm.fileExists(atPath: hugeWSURL.path)
        else {
            throw NSError(domain: "OrphanRecoverySelfTest", code: -77, userInfo: [NSLocalizedDescriptionKey: "Case 23c failed: 8MiB leading whitespace took \(elapsed23cNs)ns or lost manifest"])
        }

        try? fm.removeItem(at: dataRoot)
    }

    static func runSnapshotGapSelfTest(tempDir: URL) throws {
        let fm = FileManager.default
        let testRoot = tempDir.appendingPathComponent("snapshot_gap_self_test_\(UUID().uuidString)")
        try? fm.removeItem(at: testRoot)
        let meetingId = "gap_test_001"
        let meetingDir = testRoot.appendingPathComponent("meetings/\(meetingId)")
        try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        let coord = RecorderCoordinator(dataDir: testRoot, defaultChunkDurationSec: 4.0)
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func inc() { lock.withLock { value += 1 } }
            func get() -> Int { lock.withLock { value } }
        }
        let stateChanges = CounterBox()
        coord.onStateChanged = {
            stateChanges.inc()
        }
        let manifestURL = meetingDir.appendingPathComponent("manifest.json")
        let baseUptime = max(10.0, ProcessInfo.processInfo.systemUptime - 5.0)
        let manifest = MeetingManifest(
            schemaVersion: 1,
            id: meetingId,
            title: "Gap Snapshot Self Test",
            mode: "mic",
            appTarget: "mic_only",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        coord.lock.withLock {
            coord.state = "recording"
            coord.activeMeetingId = meetingId
            coord.activeTitle = manifest.title
            coord.activeMode = manifest.mode
            coord.activeManifest = manifest
            coord.activeManifestURL = manifestURL
            coord.sessionStartUptime = baseUptime
        }

        guard coord.snapshot().failedChunkCount == 0 else {
            throw NSError(
                domain: "SnapshotGapSelfTest",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Initial failedChunkCount was not 0"]
            )
        }

        coord.recordGap(
            meetingId: meetingId,
            startUptime: baseUptime + 1.0,
            endUptime: baseUptime + 2.5,
            reason: "audio_device_changed"
        )

        let chunksDir = meetingDir.appendingPathComponent("chunks")
        let timelinesDir = meetingDir.appendingPathComponent("timelines")
        try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: timelinesDir, withIntermediateDirectories: true)
        let faultWriter = try ChunkWriter(
            chunksDir: chunksDir,
            mode: .dual,
            timelinesDir: timelinesDir,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            testFault: ChunkWriter.FaultInjection(role: "remote", afterSamples: 640, chunkIndex: 1),
            onChunkCommitted: { _ in },
            onChunkFailed: { msg in
                coord.handleChunkFailed(meetingId: meetingId, message: msg)
            }
        )
        let block = [Float](repeating: 0.1, count: 640)
        faultWriter.appendDualSamples(mix: block, mic: block, remote: block)
        faultWriter.appendDualSamples(mix: block, mic: block, remote: block)
        let snapBeforeFinish = coord.snapshot()
        _ = faultWriter.finishAll()
        coord.manifestIOQueue.sync {}

        let encoded = try JSONEncoder().encode(snapBeforeFinish)
        let decoded = try JSONDecoder().decode(RecorderStateSnapshot.self, from: encoded)
        guard stateChanges.get() >= 2,
              decoded.gaps.count == 1,
              decoded.gaps[0].reason == "audio_device_changed",
              decoded.gaps[0].endSec > decoded.gaps[0].startSec,
              decoded.failedChunkCount == 1,
              decoded.lastError != nil
        else {
            throw NSError(
                domain: "SnapshotGapSelfTest",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Live snapshot did not preserve gaps or real-time failedChunkCount"]
            )
        }

        let legacyJSON = """
        {"state":"idle","elapsedSec":0,"meLevel":0,"remoteLevel":0,"committedChunkCount":0,"chunks":[],"systemAudioStatus":"unverified","protocolVersion":1,"dataDir":"\(testRoot.path)"}
        """
        let legacyDecoded = try JSONDecoder().decode(RecorderStateSnapshot.self, from: Data(legacyJSON.utf8))
        guard legacyDecoded.gaps.isEmpty, legacyDecoded.failedChunkCount == 0 else {
            throw NSError(
                domain: "SnapshotGapSelfTest",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Backward-compat snapshot decode failed"]
            )
        }

        try? fm.removeItem(at: testRoot)
    }

    static func runSleepGracefulFinalizeSelfTest(tempDir: URL) throws {
        let fm = FileManager.default
        let testRoot = tempDir.appendingPathComponent("sleep_finalize_self_test_\(UUID().uuidString)")
        try? fm.removeItem(at: testRoot)
        let meetingId = "sleep_test_001"
        let meetingDir = testRoot.appendingPathComponent("meetings/\(meetingId)")
        let chunksDir = meetingDir.appendingPathComponent("chunks")
        try fm.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        let coord = RecorderCoordinator(dataDir: testRoot, defaultChunkDurationSec: 4.0)
        let manifestURL = meetingDir.appendingPathComponent("manifest.json")
        let baseUptime = max(10.0, ProcessInfo.processInfo.systemUptime - 2.0)
        let initialManifest = MeetingManifest(
            schemaVersion: 1,
            id: meetingId,
            title: "Sleep Finalize Test",
            mode: "mic",
            appTarget: "mic_only",
            status: "recording",
            createdAt: AtomicFileWriter.isoNow(),
            endedAt: nil,
            totalDurationSec: 0,
            chunks: [],
            gaps: [],
            audioCleaned: false,
            failedChunkCount: 0,
            hostTimeOriginNs: nil,
            lastError: nil
        )
        try AtomicFileWriter.writeJSON(initialManifest, to: manifestURL)

        let sleepWriter = try ChunkWriter(
            chunksDir: chunksDir,
            mode: .mic,
            chunkDurationSec: 4.0,
            expectsRealTime: false,
            onChunkCommitted: { record in
                coord.handleChunkCommitted(meetingId: meetingId, record: record)
            },
            onChunkFailed: { msg in
                coord.handleChunkFailed(meetingId: meetingId, message: msg)
            }
        )

        coord.lock.withLock {
            coord.state = "recording"
            coord.activeMeetingId = meetingId
            coord.activeTitle = initialManifest.title
            coord.activeMode = "mic"
            coord.activeManifest = initialManifest
            coord.activeManifestURL = manifestURL
            coord.activeWriter = sleepWriter
            coord.sessionStartUptime = baseUptime
        }

        let sampleRate = Double(ChunkWriter.sampleRate)
        let sampleCount = Int(1.5 * sampleRate)
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = 0.2 * Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate))
        }
        sleepWriter.appendSamples(samples)

        coord.handleSystemWillSleep()
        // Calling a second time while idle must be a safe idempotent no-op.
        coord.handleSystemWillSleep()

        let snapAfterSleep = coord.snapshot()
        guard !coord.isBusy(), snapAfterSleep.state == "idle" else {
            throw NSError(
                domain: "SleepFinalizeSelfTest",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Coordinator did not settle cleanly into idle after sleep: state=\(snapAfterSleep.state)"]
            )
        }

        let persistedData = try Data(contentsOf: manifestURL)
        let decoded = try JSONDecoder().decode(MeetingManifest.self, from: persistedData)
        guard decoded.status == "recorded",
              decoded.chunks.count == 1,
              decoded.endedAt != nil
        else {
            throw NSError(
                domain: "SleepFinalizeSelfTest",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Persisted manifest invalid after sleep: status=\(decoded.status) chunks=\(decoded.chunks.count)"]
            )
        }

        let audioURL = meetingDir.appendingPathComponent(decoded.chunks[0].audioPath)
        let dirItems = (try? fm.contentsOfDirectory(atPath: chunksDir.path)) ?? []
        let lingeringTmp = dirItems.filter { $0.hasSuffix(".tmp") }
        guard fm.fileExists(atPath: audioURL.path), lingeringTmp.isEmpty else {
            throw NSError(
                domain: "SleepFinalizeSelfTest",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Missing audio chunk or leftover tmp after sleep finalization"]
            )
        }

        guard coord.tryBeginIdleShutdown(idleSeconds: 999, threshold: 600) else {
            throw NSError(
                domain: "SleepFinalizeSelfTest",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Sleep finalization unexpectedly flagged process shutdown"]
            )
        }

        try? fm.removeItem(at: testRoot)
    }
}
