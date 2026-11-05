import ServiceManagement

/// Registration status of the app as a login item (docs/architecture.md "Item de início").
public enum LoginItemStatus: Equatable, Sendable {
    /// Registered and eligible to run at login.
    case enabled
    /// Registered, but the user must allow it in System Settings before it runs.
    case requiresApproval
    /// Not registered, or unregistered by the user.
    case notRegistered
    /// The system could not find the service.
    case notFound

    /// Whether the settings toggle is on for this state (docs/ui.md "Janela de ajustes").
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        }
    }
}

/// The login item behind `AppModel`, so tests never touch the real `SMAppService`
/// (docs/architecture.md "Item de início").
public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Real login item of the running app.
///
/// `SMAppService` requires a code-signed bundle, which `scripts/build-app.sh` provides with the
/// ad hoc signature (docs/distribution.md). Nothing calls `register` unless the user asks or the
/// one-time default applies from an Applications folder, so a development build never enters the
/// maintainer's login items.
public struct SystemLoginItemService: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }

    public func unregister() throws { try SMAppService.mainApp.unregister() }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
