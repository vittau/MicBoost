import AppKit
import CoreAudio
import MicBoostCore
import SwiftUI

/// Settings window. These are plain SwiftUI controls in a normal window, so AppKit backs
/// every one of them: the section cards, switches, pickers, links and buttons are the system
/// components, with no drawing of our own (docs/ui.md "Janela de ajustes").
@MainActor public struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.locale) private var locale
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        Form {
            Section(localized("Audio")) {
                Toggle(isOn: $model.controls.manageDefaultInput) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localized("Use MicBoost as the system input automatically"))
                        Text(
                            localized(
                                "In calling and recording apps, select BlackHole 2ch or the system default input.")
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)

                .onChange(of: model.controls.manageDefaultInput) {
                    let enabled = model.controls.manageDefaultInput
                    Task { await model.engine.setDefaultInputManagement(enabled) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    let buffer = AppModel.bufferPicker(
                        sourceBufferRange: model.status?.source?.bufferRange,
                        current: model.controls.bufferFrames)
                    Picker(
                        localized("Buffer (frames)"),
                        selection: Binding(
                            get: { buffer.selection }, set: { model.controls.bufferFrames = $0 })
                    ) {
                        ForEach(buffer.values, id: \.self) { Text("\($0)").tag($0) }
                    }.onChange(of: model.controls.bufferFrames) {
                        let frames = model.controls.bufferFrames
                        Task {
                            await model.store.update { $0.bufferFrames = frames }
                            model.retry()
                        }
                    }
                    Text(
                        localized(
                            "Smaller buffers reduce latency. Increase this if audio cuts out or crackles; keep the default if audio is stable."
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    let selection =
                        model.controls.channelSelectionByUID[model.controls.selectedInputUID ?? ""]
                        ?? .mono(channel: 1)
                    let channels = AppModel.channelPicker(
                        selection: selection, channelCount: sourceChannelCount)
                    Picker(
                        localized("Channels"),
                        selection: Binding(get: { channels.selection }, set: setChannel)
                    ) {
                        ForEach(channels.values, id: \.self) { value in
                            let title =
                                value == -1
                                ? localized("Mix") : value == -2 ? localized("Stereo") : "Mono \(value)"
                            Text(title).tag(value)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(1...sourceChannelCount, id: \.self) { channel in
                            Text(
                                String.localizedStringWithFormat(
                                    localized("Mono %lld: uses channel %lld on both sides."),
                                    Int64(channel), Int64(channel)))
                        }
                        Text(localized("Mix: combines all channels on both sides."))
                        if sourceChannelCount >= 2 {
                            Text(localized("Stereo: channel 1 on the left, channel 2 on the right."))
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(localized("Diagnostics")) {
                LabeledContent(
                    localized("Sample rate"),
                    value: "\((model.status?.sampleRate ?? 0).formatted(.number.locale(locale))) Hz")
                LabeledContent(localized("Buffer"), value: "\(model.status?.bufferFrames ?? 0) \(localized("frames"))")
                LabeledContent(
                    localized("Reported latency"),
                    value:
                        "\((model.status?.reportedLatencyMs ?? 0).formatted(.number.locale(locale).precision(.fractionLength(1)))) ms"
                )
                LabeledContent(
                    localized("Hear My Voice"),
                    value: model.monitorDescription.isEmpty ? localized("Off") : model.monitorDescription)
                LabeledContent(localized("Audio overloads"), value: "\(model.status?.overloads ?? 0)")
                LabeledContent(localized("Missing input cycles"), value: "\(model.status?.inputMissing ?? 0)")
                LabeledContent(localized("Numerical resets"), value: "\(model.status?.nonfiniteResets ?? 0)")
                HStack {
                    Spacer()
                    Button(localized("Copy report")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.report, forType: .string)
                    }
                }
            }
            Section {
                LabeledContent(
                    localized("Version"),
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
                LabeledContent(localized("Project")) {
                    Link("GitHub", destination: Self.projectURL)
                }
                Button(localized("Support on Buy Me a Coffee")) {
                    NSWorkspace.shared.open(Self.supportURL)
                }
                Text(localized("License: GPL-3.0")).foregroundStyle(.secondary)
            } header: {
                Text(localized("About"))
            }
        }
        .formStyle(.grouped)

        .frame(width: 540)
    }
    static let projectURL = URL(string: "https://github.com/vittau/MicBoost")!
    static let supportURL = URL(string: "https://www.buymeacoffee.com/vittau")!
    private var sourceChannelCount: Int {
        max(1, Int(model.status?.source?.inputChannels ?? 1))
    }
    private func setChannel(_ value: Int) {
        guard let uid = model.controls.selectedInputUID else { return }
        let selection: ChannelSelection =
            value == -1 ? .monoMix : value == -2 ? .stereo(firstChannel: 1) : .mono(channel: value)
        model.controls.channelSelectionByUID[uid] = selection
        Task { await model.engine.setChannelSelection(selection, forUID: uid) }
    }
}
