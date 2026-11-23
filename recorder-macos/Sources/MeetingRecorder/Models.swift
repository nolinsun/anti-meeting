import Foundation

struct ChunkRecord: Codable, Sendable {
    let index: Int
    let id: String
    let audioPath: String
    let micPath: String?
    let remotePath: String?
    let timelinePath: String?
    let audioRangeSec: [Double]
    let responsibleRangeSec: [Double]
    let durationSec: Double
    let byteSize: Int64
    let committedAt: String
}

struct GapRecord: Codable, Sendable {
    let startSec: Double
    let endSec: Double
    let reason: String
}

struct MeetingManifest: Codable, Sendable {
    var schemaVersion: Int
    var id: String
    var title: String
    var mode: String
    var appTarget: String
    var status: String
    var createdAt: String
    var endedAt: String?
    var totalDurationSec: Double
    var chunks: [ChunkRecord]
    var gaps: [GapRecord]
    var audioCleaned: Bool
    var failedChunkCount: Int
    var hostTimeOriginNs: UInt64?
    var lastError: String?

    init(
        schemaVersion: Int,
        id: String,
        title: String,
        mode: String,
        appTarget: String,
        status: String,
        createdAt: String,
        endedAt: String?,
        totalDurationSec: Double,
        chunks: [ChunkRecord],
        gaps: [GapRecord],
        audioCleaned: Bool,
        failedChunkCount: Int = 0,
        hostTimeOriginNs: UInt64? = nil,
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.mode = mode
        self.appTarget = appTarget
        self.status = status
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.totalDurationSec = totalDurationSec
        self.chunks = chunks
        self.gaps = gaps
        self.audioCleaned = audioCleaned
        self.failedChunkCount = failedChunkCount
        self.hostTimeOriginNs = hostTimeOriginNs
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        mode = try c.decode(String.self, forKey: .mode)
        appTarget = try c.decodeIfPresent(String.self, forKey: .appTarget) ?? "mic_only"
        status = try c.decode(String.self, forKey: .status)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        totalDurationSec = try c.decodeIfPresent(Double.self, forKey: .totalDurationSec) ?? 0
        chunks = try c.decodeIfPresent([ChunkRecord].self, forKey: .chunks) ?? []
        gaps = try c.decodeIfPresent([GapRecord].self, forKey: .gaps) ?? []
        audioCleaned = try c.decodeIfPresent(Bool.self, forKey: .audioCleaned) ?? false
        failedChunkCount = try c.decodeIfPresent(Int.self, forKey: .failedChunkCount) ?? 0
        hostTimeOriginNs = try c.decodeIfPresent(UInt64.self, forKey: .hostTimeOriginNs)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

struct RecorderStateSnapshot: Codable, Sendable {
    let state: String
    let meetingId: String?
    let title: String?
    let mode: String?
    let elapsedSec: Double
    let meLevel: Double
    let remoteLevel: Double
    let committedChunkCount: Int
    let chunks: [ChunkRecord]
    let gaps: [GapRecord]
    let failedChunkCount: Int
    let inputDeviceName: String?
    let outputDeviceName: String?
    let systemAudioStatus: String
    let lastError: String?
    let protocolVersion: Int
    let dataDir: String

    enum CodingKeys: String, CodingKey {
        case state
        case meetingId
        case title
        case mode
        case elapsedSec
        case meLevel
        case remoteLevel
        case committedChunkCount
        case chunks
        case gaps
        case failedChunkCount
        case inputDeviceName
        case outputDeviceName
        case systemAudioStatus
        case lastError
        case protocolVersion
        case dataDir
    }

    init(
        state: String,
        meetingId: String?,
        title: String?,
        mode: String?,
        elapsedSec: Double,
        meLevel: Double,
        remoteLevel: Double,
        committedChunkCount: Int,
        chunks: [ChunkRecord],
        gaps: [GapRecord] = [],
        failedChunkCount: Int = 0,
        inputDeviceName: String?,
        outputDeviceName: String?,
        systemAudioStatus: String,
        lastError: String?,
        protocolVersion: Int,
        dataDir: String
    ) {
        self.state = state
        self.meetingId = meetingId
        self.title = title
        self.mode = mode
        self.elapsedSec = elapsedSec
        self.meLevel = meLevel
        self.remoteLevel = remoteLevel
        self.committedChunkCount = committedChunkCount
        self.chunks = chunks
        self.gaps = gaps
        self.failedChunkCount = failedChunkCount
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.systemAudioStatus = systemAudioStatus
        self.lastError = lastError
        self.protocolVersion = protocolVersion
        self.dataDir = dataDir
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        meetingId = try c.decodeIfPresent(String.self, forKey: .meetingId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        elapsedSec = try c.decodeIfPresent(Double.self, forKey: .elapsedSec) ?? 0
        meLevel = try c.decodeIfPresent(Double.self, forKey: .meLevel) ?? 0
        remoteLevel = try c.decodeIfPresent(Double.self, forKey: .remoteLevel) ?? 0
        committedChunkCount = try c.decodeIfPresent(Int.self, forKey: .committedChunkCount) ?? 0
        chunks = try c.decodeIfPresent([ChunkRecord].self, forKey: .chunks) ?? []
        gaps = try c.decodeIfPresent([GapRecord].self, forKey: .gaps) ?? []
        failedChunkCount = try c.decodeIfPresent(Int.self, forKey: .failedChunkCount) ?? 0
        inputDeviceName = try c.decodeIfPresent(String.self, forKey: .inputDeviceName)
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName)
        systemAudioStatus = try c.decodeIfPresent(String.self, forKey: .systemAudioStatus) ?? "unverified"
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        dataDir = try c.decode(String.self, forKey: .dataDir)
    }
}

struct SpeakerSegment: Codable, Sendable {
    let startSec: Double
    let endSec: Double
    let speaker: String
    let micDb: Double
    let remoteDb: Double
}

struct ChunkTimeline: Codable, Sendable {
    let schemaVersion: Int
    let chunkId: String
    let chunkIndex: Int
    let audioRangeSec: [Double]
    let responsibleRangeSec: [Double]
    let windowMs: Int
    let segments: [SpeakerSegment]
}

struct PermissionSnapshot: Codable, Sendable {
    let mic: String
    let systemAudio: String
    let otherAudioPlaying: Bool?
    let tapReady: Bool?

    init(
        mic: String,
        systemAudio: String,
        otherAudioPlaying: Bool? = nil,
        tapReady: Bool? = nil
    ) {
        self.mic = mic
        self.systemAudio = systemAudio
        self.otherAudioPlaying = otherAudioPlaying
        self.tapReady = tapReady
    }
}

struct PermissionRequestResponse: Codable, Sendable {
    let prompting: Bool
    let permissions: PermissionSnapshot
    let probeOutcome: String?

    init(
        prompting: Bool,
        permissions: PermissionSnapshot,
        probeOutcome: String? = nil
    ) {
        self.prompting = prompting
        self.permissions = permissions
        self.probeOutcome = probeOutcome
    }
}

struct HealthResponse: Codable, Sendable {
    let ok: Bool
    let protocolVersion: Int
    let appVersion: String
    let pid: Int32
    let dataDir: String
    let state: String
    let binaryId: String?

    init(
        ok: Bool,
        protocolVersion: Int,
        appVersion: String,
        pid: Int32,
        dataDir: String,
        state: String,
        binaryId: String? = nil
    ) {
        self.ok = ok
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.pid = pid
        self.dataDir = dataDir
        self.state = state
        self.binaryId = binaryId
    }
}

struct StartSessionRequest: Codable, Sendable {
    let mode: String?
    let title: String?
    let idempotencyKey: String?
    let chunkSec: Double?
    let appTarget: String?
}

struct StopSessionRequest: Codable, Sendable {
    let meetingId: String?
}

struct PermissionRequestPayload: Codable, Sendable {
    let kind: String?
    let openSettings: Bool?
}

enum AtomicFileWriter {
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmpURL, options: .atomic)
        let rc = Darwin.rename(tmpURL.path, url.path)
        if rc != 0 {
            let err = errno
            try? fm.removeItem(at: tmpURL)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "Failed to atomically rename \(tmpURL.lastPathComponent): errno \(err)"]
            )
        }
    }

    static func isoNow() -> String {
        Date.now.ISO8601Format()
    }
}
