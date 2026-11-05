import CoreAudio
import Foundation
import os

public enum MonitorBufferPolicy: Sendable, Equatable {
    case request(UInt32)
    case sharedWithSource
}

/// Restores the process-local setting explicitly; disposal alone is not assumed to reset it.
final class MonitorBufferLease {
    private let read: () throws -> UInt32
    private let write: (UInt32) throws -> Void
    private var previous: UInt32?
    private(set) var result: String

    init(policy: MonitorBufferPolicy, read: @escaping () throws -> UInt32, write: @escaping (UInt32) throws -> Void) {
        self.read = read
        self.write = write
        switch policy {
        case .sharedWithSource:
            result = "none (shared with source)"
        case .request(let frames):
            result = String(frames)
            do {
                previous = try read()
                try write(frames)
            } catch {
                if case EngineError.halFailure(let status, _) = error {
                    result = "rejected (\(status))"
                } else {
                    result = "rejected (\(error))"
                }
                Logger(subsystem: "io.github.vittau.MicBoost", category: "engine").warning(
                    "Monitor IO buffer request \(frames) rejected: \(String(describing: error), privacy: .public)")
            }
        }
    }
    func restore() throws {
        if let previous {
            if try read() != previous { try write(previous) }
            guard try read() == previous else {
                throw EngineError.halFailure(kAudioHardwareUnspecifiedError, "Restore monitor IO buffer")
            }
            self.previous = nil
        }
    }
}

extension AudioDevice {
    /// Includes nested aggregates and shared physical leaves; identity never depends on names.
    func sharesDevice(with roots: [AudioDevice], in devices: [AudioDevice]) -> Bool {
        func identities(_ device: AudioDevice, visited: Set<String> = []) -> Set<String> {
            guard !visited.contains(device.uid) else { return [] }
            let seen = visited.union([device.uid])
            return device.subdeviceUIDs.reduce(into: Set([device.uid])) { result, uid in
                result.insert(uid)
                if let child = devices.first(where: { $0.uid == uid }) {
                    result.formUnion(identities(child, visited: seen))
                }
            }
        }
        let outputIDs = identities(self)
        return roots.contains { $0.id == id || !identities($0).isDisjoint(with: outputIDs) }
    }
}
