import CoreAudio
import Foundation

public enum EngineError: Error, CustomStringConvertible {
    case halFailure(OSStatus, String)
    case formatUnsupported
    case invalidArgument(String)
    public var description: String {
        switch self {
        case let .halFailure(status, operation): return "\(operation): OSStatus \(status)"
        case .formatUnsupported: return "Unsupported audio format"
        case let .invalidArgument(message): return message
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
    public init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.object = object; self.selector = selector; self.scope = scope
    }
    var address: AudioObjectPropertyAddress { .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain) }
}
public protocol AudioHardware: AnyObject {
    func devices() throws -> [AudioDevice]
    func defaultInput() throws -> AudioObjectID
    func setDefaultInput(_ device: AudioObjectID) throws
    func addListener(_ property: HardwareProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) throws -> UUID
    func removeListener(_ token: UUID) throws
}
