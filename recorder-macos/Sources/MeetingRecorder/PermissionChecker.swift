import AppKit
import AVFoundation
import Foundation

enum PermissionChecker {
    private static let lock = NSLock()
    private static let validSystemStates: Set<String> = [
        "unverified",
        "granted",
        "silent_or_denied",
        "tap_failed",
    ]
    nonisolated(unsafe) private static var cachedSystemAudioStatus: String = "unverified"
    nonisolated(unsafe) private static var cachedTapReady: Bool? = nil
    nonisolated(unsafe) private static var probeInFlight = false
    nonisolated(unsafe) private static var tapSessionEpoch: UInt64 = 0
    nonisolated(unsafe) private static var activeDualSessionEpoch: UInt64?
    nonisolated(unsafe) private static var dualAcquisitionPending = false
    nonisolated(unsafe) private static var activeProbeCancelSem: DispatchSemaphore?
    nonisolated(unsafe) private static var probeTeardownGroup: DispatchGroup?

    static func micStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "granted"
        case .denied:
            return "denied"
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        @unknown default:
            return "not_determined"
        }
    }

    static func systemAudioStatus() -> String {
        lock.withLock { cachedSystemAudioStatus }
    }

    static func tapReady() -> Bool? {
        lock.withLock { cachedTapReady }
    }

    static func updateSystemAudioStatus(_ status: String, expectedEpoch: UInt64? = nil) {
        guard validSystemStates.contains(status) else { return }
        lock.withLock {
            if let expectedEpoch, tapSessionEpoch != expectedEpoch {
                return
            }
            cachedSystemAudioStatus = status
            if status == "granted" || status == "silent_or_denied" {
                cachedTapReady = true
            } else if status == "tap_failed" {
                cachedTapReady = false
            }
        }
    }

    static func currentTapSessionEpoch() -> UInt64 {
        lock.withLock { tapSessionEpoch }
    }

    /// Bumps tap session epoch, cancels any in-flight permission probe, and waits up to `timeoutMs`
    /// for actual HAL teardown completion before granting exclusive ownership (returns nil on busy timeout) (P1-2).
    static func acquireExclusiveTapForDualSession(timeoutMs: Int = 250) -> UInt64? {
        let clampedMs = max(1, timeoutMs)
        let budgetNs = UInt64(clampedMs) * 1_000_000
        let headroomNs = min(UInt64(15_000_000), budgetNs / 5)
        let deadline = DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ (budgetNs - headroomNs))

        let (epoch, cancelSem, waitGroup): (UInt64, DispatchSemaphore?, DispatchGroup?) = lock.withLock {
            dualAcquisitionPending = true
            tapSessionEpoch &+= 1
            return (tapSessionEpoch, activeProbeCancelSem, probeTeardownGroup)
        }

        cancelSem?.signal()
        let waitResult: DispatchTimeoutResult
        if let waitGroup {
            waitResult = waitGroup.wait(timeout: deadline)
        } else {
            waitResult = .success
        }

        // Flush any retired HAL objects within the SAME remaining deadline budget (P1-2 #4).
        let halCleared = (waitResult == .success) ? SystemAudioCapture.tryFlushRetiredHALObjects(deadline: deadline) : false

        return lock.withLock {
            dualAcquisitionPending = false
            guard waitResult == .success, halCleared, !probeInFlight, activeDualSessionEpoch == nil else {
                return nil
            }
            activeDualSessionEpoch = epoch
            return epoch
        }
    }

    static func releaseExclusiveTapForDualSession(epoch: UInt64) {
        lock.withLock {
            if activeDualSessionEpoch == epoch {
                activeDualSessionEpoch = nil
            }
        }
    }

    static func isSystemAudioProbeInFlight() -> Bool {
        lock.withLock { probeInFlight }
    }

    @discardableResult
    static func probeSystemAudioPermission() -> String? {
        let totalDeadline = DispatchTime.now() + .milliseconds(650)

        guard SystemAudioCapture.tryFlushRetiredHALObjects(deadline: totalDeadline) else {
            return nil
        }

        guard totalDeadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds + 15_000_000 else {
            return nil
        }

        let acquisition: (epochBefore: UInt64, cancelSem: DispatchSemaphore)? = lock.withLock {
            if probeInFlight || dualAcquisitionPending || activeDualSessionEpoch != nil {
                return nil
            }
            probeInFlight = true
            let sem = DispatchSemaphore(value: 0)
            activeProbeCancelSem = sem
            let group = DispatchGroup()
            group.enter()
            probeTeardownGroup = group
            return (tapSessionEpoch, sem)
        }

        guard let acquired = acquisition else {
            return nil
        }

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        let detail = SystemAudioCapture.probePermissionDetailed(
            deadline: totalDeadline,
            cancelSemaphore: acquired.cancelSem,
            onTeardownComplete: {
                let doneGroup: DispatchGroup? = lock.withLock {
                    probeInFlight = false
                    activeProbeCancelSem = nil
                    let g = probeTeardownGroup
                    probeTeardownGroup = nil
                    return g
                }
                doneGroup?.leave()
            }
        )

        if detail.status == "unverified" && !detail.tapStarted {
            lock.withLock {
                if tapSessionEpoch == acquired.epochBefore,
                   activeDualSessionEpoch == nil,
                   !dualAcquisitionPending
                {
                    cachedTapReady = false
                }
            }
            return "timeout"
        }

        _ = applySystemAudioProbeResult(detail.status, expectedEpoch: acquired.epochBefore)
        return detail.status
    }

    @discardableResult
    static func applySystemAudioProbeResult(_ probed: String, expectedEpoch: UInt64) -> String {
        lock.withLock {
            guard validSystemStates.contains(probed),
                  tapSessionEpoch == expectedEpoch,
                  activeDualSessionEpoch == nil,
                  !dualAcquisitionPending
            else {
                return cachedSystemAudioStatus
            }
            if probed == "granted" || probed == "tap_failed" || probed == "silent_or_denied" {
                cachedSystemAudioStatus = probed
                cachedTapReady = (probed != "tap_failed")
                return probed
            }
            cachedTapReady = true
            if cachedSystemAudioStatus != "granted" {
                cachedSystemAudioStatus = probed
            }
            return cachedSystemAudioStatus
        }
    }

    static func runProbeTransitionSelfTest() throws {
        let saved = systemAudioStatus()
        let savedTapReady = tapReady()
        defer {
            updateSystemAudioStatus(saved)
            lock.withLock { cachedTapReady = savedTapReady }
        }

        let epoch = currentTapSessionEpoch()
        updateSystemAudioStatus("tap_failed")
        let afterTapReset = applySystemAudioProbeResult("unverified", expectedEpoch: epoch)
        guard afterTapReset == "unverified", systemAudioStatus() == "unverified", tapReady() == true else {
            throw NSError(
                domain: "PermissionCheckerSelfTest",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Expected quiet 'unverified' probe to clear stale 'tap_failed', got '\(afterTapReset)'"]
            )
        }

        updateSystemAudioStatus("silent_or_denied")
        let afterSilentReset = applySystemAudioProbeResult("unverified", expectedEpoch: epoch)
        guard afterSilentReset == "unverified", systemAudioStatus() == "unverified" else {
            throw NSError(
                domain: "PermissionCheckerSelfTest",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Expected quiet 'unverified' probe to clear stale 'silent_or_denied', got '\(afterSilentReset)'"]
            )
        }

        updateSystemAudioStatus("granted")
        let keepGranted = applySystemAudioProbeResult("unverified", expectedEpoch: epoch)
        guard keepGranted == "granted", systemAudioStatus() == "granted" else {
            throw NSError(
                domain: "PermissionCheckerSelfTest",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Expected quiet 'unverified' probe to preserve 'granted', got '\(keepGranted)'"]
            )
        }

        let ignoreStaleEpoch = applySystemAudioProbeResult("tap_failed", expectedEpoch: epoch &+ 99)
        guard ignoreStaleEpoch == "granted", systemAudioStatus() == "granted" else {
            throw NSError(
                domain: "PermissionCheckerSelfTest",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Expected stale epoch probe result to be ignored, got '\(ignoreStaleEpoch)'"]
            )
        }

        let afterGrantedToSilent = applySystemAudioProbeResult("silent_or_denied", expectedEpoch: epoch)
        guard afterGrantedToSilent == "silent_or_denied", systemAudioStatus() == "silent_or_denied" else {
            throw NSError(
                domain: "PermissionCheckerSelfTest",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Expected 'silent_or_denied' probe to update 'granted' when denied/muted, got '\(afterGrantedToSilent)'"]
            )
        }
    }

    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            mic: micStatus(),
            systemAudio: systemAudioStatus(),
            otherAudioPlaying: SystemAudioCapture.hasOtherProcessRunningOutput(),
            tapReady: tapReady()
        )
    }

    static func requestMicPermission() async -> String {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .authorized {
            return "granted"
        }
        if current == .notDetermined {
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? "granted" : "denied"
        }
        return micStatus()
    }

    @MainActor
    static func openPrivacySettings(kind: String) {
        let primaryURLString: String
        if kind == "systemAudio" {
            primaryURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        } else {
            primaryURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let url = URL(string: primaryURLString), NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(fallback)
        }
    }
}
