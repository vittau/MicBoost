import CoreAudio
import Foundation

public enum EngineError: Error, CustomStringConvertible, Equatable {
    case blackHoleMissing, microphonePermissionDenied, noSourceSelected
    case sourceUnavailable(String)
    case halFailure(OSStatus, String)
    case formatUnsupported
    case invalidArgument(String)
    public var description: String {
        switch self {
        case .blackHoleMissing: return "BlackHole 2ch missing"
        case .microphonePermissionDenied: return "Microphone permission denied"
        case .noSourceSelected: return "No source selected"
        case .sourceUnavailable(let uid): return "Source unavailable: \(uid)"
        case .halFailure(let status, let operation): return "\(operation): OSStatus \(status)"
        case .formatUnsupported: return "Unsupported audio format"
        case .invalidArgument(let message): return message
        }
    }
}
public func checkHAL(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw EngineError.halFailure(status, operation) }
}
public struct HardwareProperty: Hashable, Sendable {
    public var object: AudioObjectID
    public var selector: AudioObjectPropertySelector
    public var scope: AudioObjectPropertyScope
    public init(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        self.object = object
        self.selector = selector
        self.scope = scope
    }
    var address: AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
public protocol AudioHardware: AnyObject {
    func devices() throws -> [AudioDevice]
    func defaultOutput() throws -> AudioObjectID
    func defaultInput() throws -> AudioObjectID
    func setDefaultInput(_ device: AudioObjectID) throws
    func addListener(_ property: HardwareProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) throws
        -> UUID
    func removeListener(_ token: UUID) throws
}
