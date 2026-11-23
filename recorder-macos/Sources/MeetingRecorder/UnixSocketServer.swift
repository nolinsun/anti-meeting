import Darwin
import Foundation

final class UnixSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let coordinator: RecorderCoordinator
    private let onRequestQuit: @Sendable () -> Void
    private let onActivity: @Sendable () -> Void

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var ownsSocket = false
    private var socketInode: ino_t = 0

    private let acceptQueue = DispatchQueue(label: "com.antigravity.meeting.socket.accept")
    private let clientQueue = DispatchQueue(label: "com.antigravity.meeting.socket.clients", attributes: .concurrent)
    private let clientConcurrencyGate = DispatchSemaphore(value: 16)

    private static let currentBinaryId: String? = {
        let exePath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        guard !exePath.isEmpty else { return nil }
        let resolvedPath = URL(fileURLWithPath: exePath).resolvingSymlinksInPath().path
        let fd = Darwin.open(resolvedPath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }()

    init(
        socketPath: String,
        coordinator: RecorderCoordinator,
        onActivity: @escaping @Sendable () -> Void = {},
        onRequestQuit: @escaping @Sendable () -> Void
    ) {
        self.socketPath = socketPath
        self.coordinator = coordinator
        self.onActivity = onActivity
        self.onRequestQuit = onRequestQuit
    }

    func start() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if socketPath.utf8.count > 103 {
            throw NSError(
                domain: "UnixSocketServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path exceeds macOS sun_path limit (103 bytes): \(socketPath)"]
            )
        }

        var existingStat = stat()
        if Darwin.lstat(socketPath, &existingStat) == 0 {
            let isSocket = (existingStat.st_mode & S_IFMT) == S_IFSOCK
            let ownedByCurrentUser = existingStat.st_uid == Darwin.getuid()
            guard isSocket && ownedByCurrentUser else {
                throw NSError(
                    domain: "UnixSocketServer",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to replace non-socket or foreign path at \(socketPath)"]
                )
            }
            switch Self.probeSocketState(at: socketPath) {
            case .alive:
                throw NSError(
                    domain: "UnixSocketServer",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Another MeetingRecorder daemon is already listening on \(socketPath)"]
                )
            case .stale:
                Darwin.unlink(socketPath)
            case .error(let err):
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(err),
                    userInfo: [NSLocalizedDescriptionKey: "Failed probing existing socket at \(socketPath): errno \(err)"]
                )
            }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed: errno \(errno)"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCString = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
            let limit = min(pathCString.count, sunPathPtr.count)
            pathCString.withUnsafeBytes { src in
                if let dstBase = sunPathPtr.baseAddress, let srcBase = src.baseAddress {
                    memcpy(dstBase, srcBase, limit)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "bind(\(socketPath)) failed: errno \(err)"])
        }

        Darwin.chmod(socketPath, 0o600)

        var boundStat = stat()
        let boundInode: ino_t = (Darwin.lstat(socketPath, &boundStat) == 0) ? boundStat.st_ino : 0

        guard Darwin.listen(fd, 32) == 0 else {
            let err = errno
            Darwin.close(fd)
            if boundInode != 0 {
                Darwin.unlink(socketPath)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "listen() failed: errno \(err)"])
        }

        stateLock.withLock {
            self.listenFD = fd
            self.running = true
            self.ownsSocket = true
            self.socketInode = boundInode
        }

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let (shouldUnlink, expectedInode, fdToClose) = stateLock.withLock { () -> (Bool, ino_t, Int32) in
            running = false
            let fd = listenFD
            listenFD = -1
            let mine = ownsSocket
            let ino = socketInode
            ownsSocket = false
            socketInode = 0
            return (mine, ino, fd)
        }

        if fdToClose >= 0 {
            Darwin.close(fdToClose)
        }
        if shouldUnlink {
            var currentStat = stat()
            if Darwin.lstat(socketPath, &currentStat) == 0,
               (expectedInode == 0 || currentStat.st_ino == expectedInode) {
                Darwin.unlink(socketPath)
            }
        }
    }

    private func acceptLoop() {
        while true {
            let (isRunning, fd) = stateLock.withLock { (running, listenFD) }
            guard isRunning && fd >= 0 else { break }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            var noSigPipe: Int32 = 1
            Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            Darwin.setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            guard clientConcurrencyGate.wait(timeout: .now()) == .success else {
                writeJSONResponse(fd: clientFD, status: 503, reason: "Service Unavailable", body: ["error": "Too many concurrent requests"])
                Darwin.close(clientFD)
                continue
            }

            clientQueue.async { [weak self] in
                defer { self?.clientConcurrencyGate.signal() }
                self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.close(fd) }

        let request: HTTPRequest
        switch readHTTPRequest(fd: fd) {
        case .ok(let req):
            request = req
            onActivity()
        case .error(let status, let message):
            writeJSONResponse(fd: fd, status: status, reason: status == 413 ? "Payload Too Large" : "Bad Request", body: ["error": message])
            return
        }

        let cleanPath = request.path.split(separator: "?").first.map(String.init) ?? request.path

        switch (request.method, cleanPath) {
        case ("GET", "/v1/health"):
            let snap = coordinator.snapshot()
            let health = HealthResponse(
                ok: true,
                protocolVersion: 1,
                appVersion: "0.3.0",
                pid: ProcessInfo.processInfo.processIdentifier,
                dataDir: coordinator.dataDir.path,
                state: snap.state,
                binaryId: Self.currentBinaryId
            )
            writeEncodableResponse(fd: fd, status: 200, reason: "OK", value: health)

        case ("GET", "/v1/permissions"):
            writeEncodableResponse(fd: fd, status: 200, reason: "OK", value: PermissionChecker.snapshot())

        case ("POST", "/v1/permissions/request"):
            let payload = (try? JSONDecoder().decode(PermissionRequestPayload.self, from: request.body))
                ?? PermissionRequestPayload(kind: "mic", openSettings: false)
            let kind = payload.kind ?? "mic"
            if payload.openSettings == true {
                DispatchQueue.main.async {
                    PermissionChecker.openPrivacySettings(kind: kind)
                }
                writeEncodableResponse(
                    fd: fd,
                    status: 200,
                    reason: "OK",
                    value: PermissionRequestResponse(prompting: false, permissions: PermissionChecker.snapshot())
                )
                return
            }

            let current = PermissionChecker.snapshot()
            if kind == "systemAudio" {
                let isBusy = coordinator.isBusy()
                if isBusy || PermissionChecker.isSystemAudioProbeInFlight() {
                    writeEncodableResponse(
                        fd: fd,
                        status: 200,
                        reason: "OK",
                        value: PermissionRequestResponse(
                            prompting: false,
                            permissions: current,
                            probeOutcome: nil
                        )
                    )
                    return
                }
                let outcome = PermissionChecker.probeSystemAudioPermission()
                writeEncodableResponse(
                    fd: fd,
                    status: 200,
                    reason: "OK",
                    value: PermissionRequestResponse(
                        prompting: false,
                        permissions: PermissionChecker.snapshot(),
                        probeOutcome: outcome
                    )
                )
                return
            }

            if current.mic == "not_determined" {
                // Trigger macOS TCC prompt asynchronously without blocking this HTTP request thread.
                Task {
                    _ = await PermissionChecker.requestMicPermission()
                }
                writeEncodableResponse(
                    fd: fd,
                    status: 200,
                    reason: "OK",
                    value: PermissionRequestResponse(prompting: true, permissions: current)
                )
            } else {
                if current.mic == "denied" || current.mic == "restricted" {
                    DispatchQueue.main.async {
                        PermissionChecker.openPrivacySettings(kind: kind)
                    }
                }
                writeEncodableResponse(
                    fd: fd,
                    status: 200,
                    reason: "OK",
                    value: PermissionRequestResponse(prompting: false, permissions: current)
                )
            }

        case ("GET", "/v1/sessions/status"):
            writeEncodableResponse(fd: fd, status: 200, reason: "OK", value: coordinator.snapshot())

        case ("POST", "/v1/sessions/start"):
            let startReq: StartSessionRequest
            if request.body.isEmpty {
                startReq = StartSessionRequest(mode: "mic", title: nil, idempotencyKey: nil, chunkSec: nil, appTarget: nil)
            } else if let decoded = try? JSONDecoder().decode(StartSessionRequest.self, from: request.body) {
                startReq = decoded
            } else {
                writeJSONResponse(fd: fd, status: 400, reason: "Bad Request", body: ["error": "Invalid JSON body"])
                return
            }

            do {
                let snap = try coordinator.startSession(startReq)
                writeEncodableResponse(fd: fd, status: 200, reason: "OK", value: snap)
            } catch let err as CoordinatorError {
                var errBody: [String: String] = ["error": err.localizedDescription]
                if case .conflict(_, let activeId) = err, let activeId {
                    errBody["activeMeetingId"] = activeId
                }
                if case .permissionDenied = err {
                    errBody["code"] = "PERMISSION_DENIED"
                }
                writeJSONResponse(fd: fd, status: err.httpStatus, reason: "Error", body: errBody)
            } catch {
                writeJSONResponse(fd: fd, status: 500, reason: "Internal Server Error", body: ["error": error.localizedDescription])
            }

        case ("POST", "/v1/sessions/stop"):
            let stopReq: StopSessionRequest
            if request.body.isEmpty {
                stopReq = StopSessionRequest(meetingId: nil)
            } else if let decoded = try? JSONDecoder().decode(StopSessionRequest.self, from: request.body) {
                stopReq = decoded
            } else {
                writeJSONResponse(fd: fd, status: 400, reason: "Bad Request", body: ["error": "Invalid JSON body"])
                return
            }

            do {
                let stopped = try coordinator.stopSession(meetingId: stopReq.meetingId)
                struct StopResponse: Codable {
                    let snapshot: RecorderStateSnapshot
                    let manifest: MeetingManifest?
                }
                writeEncodableResponse(
                    fd: fd,
                    status: 200,
                    reason: "OK",
                    value: StopResponse(snapshot: stopped.snapshot, manifest: stopped.manifest)
                )
            } catch let err as CoordinatorError {
                var errBody: [String: String] = ["error": err.localizedDescription]
                if case .conflict(_, let activeId) = err, let activeId {
                    errBody["activeMeetingId"] = activeId
                }
                writeJSONResponse(fd: fd, status: err.httpStatus, reason: "Error", body: errBody)
            } catch {
                writeJSONResponse(fd: fd, status: 500, reason: "Internal Server Error", body: ["error": error.localizedDescription])
            }

        case ("POST", "/v1/app/quit"):
            coordinator.beginShutdown()
            writeJSONResponse(fd: fd, status: 200, reason: "OK", body: ["ok": "true"])
            onRequestQuit()

        default:
            writeJSONResponse(fd: fd, status: 404, reason: "Not Found", body: ["error": "Unknown endpoint \(request.method) \(cleanPath)"])
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private enum HTTPParseResult {
        case ok(HTTPRequest)
        case error(status: Int, message: String)
    }

    private func readHTTPRequest(fd: Int32) -> HTTPParseResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEndRange: Range<Data.Index>?

        while buffer.count < 65_536 {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return .error(status: 400, message: "Socket read error or timeout")
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEndRange = range
                break
            }
        }

        guard let headerEnd = headerEndRange else {
            return .error(status: 400, message: "Malformed or incomplete HTTP headers")
        }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .error(status: 400, message: "Non-UTF8 HTTP headers")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .error(status: 400, message: "Missing HTTP request line")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .error(status: 400, message: "Invalid HTTP request line")
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var parsedContentLength: Int?
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "content-length" {
                    if parsedContentLength != nil {
                        return .error(status: 400, message: "Duplicate Content-Length header")
                    }
                    guard !val.isEmpty, val.allSatisfy({ $0.isASCII && $0.isNumber }), let len = Int(val) else {
                        return .error(status: 400, message: "Invalid Content-Length header")
                    }
                    if len > 1_048_576 {
                        return .error(status: 413, message: "Request body exceeds 1 MiB limit")
                    }
                    parsedContentLength = len
                }
            }
        }

        let contentLength = parsedContentLength ?? 0
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < contentLength {
            let remaining = contentLength - body.count
            let toRead = min(remaining, chunk.count)
            let n = Darwin.read(fd, &chunk, toRead)
            if n < 0 {
                if errno == EINTR { continue }
                return .error(status: 400, message: "Timed out reading HTTP request body")
            }
            if n == 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }

        if body.count < contentLength {
            return .error(status: 400, message: "Incomplete HTTP body: expected \(contentLength) bytes, got \(body.count)")
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        return .ok(HTTPRequest(method: method, path: path, body: body))
    }

    private func writeEncodableResponse<T: Encodable>(fd: Int32, status: Int, reason: String, value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            writeJSONResponse(fd: fd, status: 500, reason: "Internal Server Error", body: ["error": "JSON encoding failed"])
            return
        }
        writeHTTPResponse(fd: fd, status: status, reason: reason, body: data)
    }

    private func writeJSONResponse(fd: Int32, status: Int, reason: String, body: [String: String]) {
        let data = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
        writeHTTPResponse(fd: fd, status: status, reason: reason, body: data)
    }

    private func writeHTTPResponse(fd: Int32, status: Int, reason: String, body: Data) {
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(body)

        full.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            var sent = 0
            while sent < full.count {
                let written = Darwin.write(fd, base.advanced(by: sent), full.count - sent)
                if written <= 0 { break }
                sent += written
            }
        }
    }

    private enum SocketProbe {
        case alive
        case stale
        case error(Int32)
    }

    private static func probeSocketState(at path: String) -> SocketProbe {
        guard path.utf8.count <= 103 else { return .error(ENAMETOOLONG) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .error(errno) }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
            let limit = min(bytes.count, sunPathPtr.count)
            bytes.withUnsafeBytes { src in
                if let dstBase = sunPathPtr.baseAddress, let srcBase = src.baseAddress {
                    memcpy(dstBase, srcBase, limit)
                }
            }
        }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if res == 0 {
            return .alive
        }
        let err = errno
        if err == ECONNREFUSED || err == ENOENT {
            return .stale
        }
        return .error(err)
    }

    // Verifies dual-instance socket protection and strict HTTP 400 / 413 handling.
    static func runSelfTests(tempDir: URL) throws {
        let sockPath = tempDir.appendingPathComponent("test.sock").path
        let coord = RecorderCoordinator(dataDir: tempDir)
        let s1 = UnixSocketServer(socketPath: sockPath, coordinator: coord, onRequestQuit: {})
        try s1.start()
        defer { s1.stop() }

        // Second server on same path must fail and calling s2.stop() must NOT unlink s1's live socket.
        let s2 = UnixSocketServer(socketPath: sockPath, coordinator: coord, onRequestQuit: {})
        var secondFailed = false
        do {
            try s2.start()
        } catch {
            secondFailed = true
        }
        guard secondFailed else {
            throw NSError(domain: "UnixSocketSelfTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Second server unexpectedly bound to live socket"])
        }
        s2.stop()
        guard FileManager.default.fileExists(atPath: sockPath) else {
            throw NSError(domain: "UnixSocketSelfTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed second server unlinked first server's live socket"])
        }

        func rawRequest(_ payload: String) throws -> String {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { Darwin.close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(sockPath.utf8CString)
            withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
                let limit = min(bytes.count, sunPathPtr.count)
                bytes.withUnsafeBytes { src in
                    if let dstBase = sunPathPtr.baseAddress, let srcBase = src.baseAddress {
                        memcpy(dstBase, srcBase, limit)
                    }
                }
            }
            let conn = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard conn == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let data = Data(payload.utf8)
            _ = data.withUnsafeBytes { rawPtr in
                Darwin.write(fd, rawPtr.baseAddress, data.count)
            }
            Darwin.shutdown(fd, SHUT_WR)
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return String(data: out, encoding: .utf8) ?? ""
        }

        let healthResp = try rawRequest("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        guard healthResp.hasPrefix("HTTP/1.1 200 OK") else {
            throw NSError(domain: "UnixSocketSelfTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "Health request failed: \(healthResp)"])
        }

        let partialResp = try rawRequest("POST /v1/sessions/start HTTP/1.1\r\nContent-Length: 50\r\n\r\n{\"mode\":\"mic\"")
        guard partialResp.hasPrefix("HTTP/1.1 400") else {
            throw NSError(domain: "UnixSocketSelfTest", code: -4, userInfo: [NSLocalizedDescriptionKey: "Partial body did not return 400: \(partialResp)"])
        }

        let tooLargeResp = try rawRequest("POST /v1/sessions/start HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n")
        guard tooLargeResp.hasPrefix("HTTP/1.1 413") else {
            throw NSError(domain: "UnixSocketSelfTest", code: -5, userInfo: [NSLocalizedDescriptionKey: "Oversized body did not return 413: \(tooLargeResp)"])
        }
    }
}
