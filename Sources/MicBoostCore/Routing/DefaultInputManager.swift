import CoreAudio
import Foundation

/// Published view of the system default input, relative to MicBoost.
public struct DefaultInputStatus: Codable, Equatable, Sendable {
    /// The current default input is the BlackHole 2ch.
    public var isBlackHole: Bool
    /// The engine is running and the user (or another app) changed the input away from BlackHole.
    public var divergedByUser: Bool
    /// The current default input could not be resolved, so nothing is asserted about it.
    public var unknown: Bool

    public init(isBlackHole: Bool = false, divergedByUser: Bool = false, unknown: Bool = false) {
        self.isBlackHole = isBlackHole
        self.divergedByUser = divergedByUser
        self.unknown = unknown
    }

    /// Nothing could be asserted about the default input.
    public static var unresolved: DefaultInputStatus { DefaultInputStatus(unknown: true) }
}

/// Policy of docs/audio-engine.md "Política de entrada padrão".
///
/// MicBoost only sets the default input to the BlackHole, and only restores the
/// previous device on a voluntary stop. It never sets the default output, never
/// sets a physical device as default outside the restore, and never reverts an
/// external change.
///
/// Not internally synchronized: it must be owned by `EngineController`, whose
/// executor (the `engine` queue) is the only place these methods and `lastStatus`
/// may run. Every async method is `nonisolated(nonsending)`, so it inherits the
/// caller's isolation, stays on the engine actor's executor and resumes there
/// after each `await` to `SettingsStore`; a plain `nonisolated async` method
/// would run on the cooperative pool and touch the HAL adapter off the queue.
/// The class is deliberately not `Sendable`: moving it to another isolation
/// domain is a compile error, and the adapter keeps a single owner on the queue.
/// The manager does not register HAL listeners; `EngineController` calls it when
/// they fire.
public final class DefaultInputManager {
    public enum StopReason: Sendable {
        /// App quit or processing turned off: the restore policy applies.
        case user
        /// The engine failed (`recovering`/`error`): the BlackHole stays as input, so consumers
        /// of the default input do not switch microphones on their own.
        case engineError
    }

    private let hardware: any AudioHardware
    private let settings: SettingsStore
    private var blackHole: AudioDevice?
    private var running = false
    private var status = DefaultInputStatus.unresolved

    public init(hardware: any AudioHardware, settings: SettingsStore) {
        self.hardware = hardware
        self.settings = settings
    }

    /// Last published status.
    public var lastStatus: DefaultInputStatus { status }

    /// Applies the input step when the engine reaches `running`.
    public nonisolated(nonsending) func engineDidStart(blackHole: AudioDevice) async throws {
        self.blackHole = blackHole
        if running {
            try await defaultInputDidChange()
            return
        }
        if await settings.current.manageDefaultInput {
            try await adoptBlackHole()
        } else {
            try await defaultInputDidChange()
        }
        running = true
    }

    /// Handles `kAudioHardwarePropertyDefaultInputDevice` while the engine runs.
    @discardableResult
    public nonisolated(nonsending) func defaultInputDidChange() async throws -> DefaultInputStatus {
        let (currentID, device) = try currentDefaultInput()
        let isBlackHole = isBlackHoleDevice(currentID, device)
        if running, !isBlackHole {
            // The user owns the default input now: stop claiming it and do not revert.
            let stored = await settings.current
            if stored.defaultInputManaged {
                await clearManaged()
            }
        }
        status = DefaultInputStatus(
            isBlackHole: isBlackHole,
            divergedByUser: running && !isBlackHole,
            unknown: blackHole == nil || device == nil)
        return status
    }

    /// "Usar BlackHole" action: repeats the input step of the start.
    public nonisolated(nonsending) func useBlackHole() async throws {
        try await adoptBlackHole()
        if !(await settings.current.manageDefaultInput) { await clearManaged() }
    }

    /// Applies the restore policy when the engine leaves `running`.
    public nonisolated(nonsending) func engineWillStop(reason: StopReason = .user) async throws {
        defer { running = false }
        guard reason == .user, await settings.current.manageDefaultInput, let blackHole else {
            status.divergedByUser = false
            return
        }
        let (currentID, current) = try currentDefaultInput()
        let currentIsBlackHole = currentID == blackHole.id || current?.uid == blackHole.uid
        status = DefaultInputStatus(isBlackHole: currentIsBlackHole, divergedByUser: false, unknown: current == nil)
        let stored = await settings.current
        guard stored.defaultInputManaged else { return }
        guard currentIsBlackHole else {
            // The user changed the input while we ran: nothing to restore.
            await clearManaged()
            return
        }
        let devices = try hardware.devices()
        guard let previousUID = stored.previousDefaultInputUID,
            previousUID != blackHole.uid,
            let previous = devices.first(where: { $0.uid == previousUID }),
            previous.alive
        else {
            await clearManaged()
            return
        }
        try hardware.setDefaultInput(previous.id)
        await clearManaged()
        status = DefaultInputStatus(isBlackHole: false, divergedByUser: false, unknown: false)
    }

    public nonisolated(nonsending) func setManagementEnabled(_ enabled: Bool) async {
        await settings.update { $0.manageDefaultInput = enabled }
        if !enabled { await clearManaged() }
    }

    private nonisolated(nonsending) func adoptBlackHole() async throws {
        guard let blackHole else {
            throw EngineError.invalidArgument("DefaultInputManager used before engineDidStart")
        }
        let (currentID, current) = try currentDefaultInput()
        if currentID == blackHole.id || current?.uid == blackHole.uid {
            // Already the BlackHole: do not touch `previousDefaultInputUID` and keep
            // `defaultInputManaged` as persisted, which covers recovery after a crash.
            status = DefaultInputStatus(isBlackHole: true, divergedByUser: false, unknown: false)
            return
        }
        let previousUID = current?.uid
        // Persist the recovery state before the write, so a crash in between still restores.
        await settings.updateDefaultInput {
            $0.previousDefaultInputUID = previousUID
            $0.defaultInputManaged = true
        }
        do {
            try hardware.setDefaultInput(blackHole.id)
        } catch {
            await settings.updateDefaultInput { $0.defaultInputManaged = false }
            throw error
        }
        status = DefaultInputStatus(isBlackHole: true, divergedByUser: false, unknown: false)
    }

    private nonisolated(nonsending) func clearManaged() async {
        await settings.updateDefaultInput { $0.defaultInputManaged = false }
    }

    private func isBlackHoleDevice(_ id: AudioObjectID, _ device: AudioDevice?) -> Bool {
        guard let blackHole else { return false }
        return id == blackHole.id || device?.uid == blackHole.uid
    }

    private func currentDefaultInput() throws -> (AudioObjectID, AudioDevice?) {
        let id = try hardware.defaultInput()
        return (id, try hardware.devices().first { $0.id == id })
    }
}
