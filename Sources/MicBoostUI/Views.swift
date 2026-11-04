import AppKit
import CoreAudio
import MicBoostCore
import SwiftUI

@MainActor public struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.locale) private var locale
    @State private var editing = false
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MicBoost").font(.headline)
                Spacer()
                Toggle(
                    localized("Processing"),
                    isOn: Binding(get: { model.controls.processingEnabled }, set: model.processing)
                )
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(
                    localized("Processing"))
            }
            if let message = model.message {
                VStack(alignment: .leading) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                    switch model.statusMessage?.action ?? .noAction {
                    case .privacySettings:
                        Link(
                            localized("Open Privacy Settings"),
                            destination: URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    case .install:
                        Link(
                            localized("How to install"),
                            destination: URL(string: "https://github.com/vittau/MicBoost#requirements")!)
                    case .retry:
                        Button(localized("Try again"), action: model.retry)
                    case .noAction:
                        EmptyView()
                    }
                }.font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button(action: model.mute) {
                    Image(systemName: model.controls.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(localized("Mute"))
                .accessibilityValue(localized(model.controls.muted ? "On" : "Off"))
                .help(localized("Mute"))
                .keyboardShortcut("m", modifiers: [])
                MenuSlider(
                    value: model.controls.gainDB, range: Settings.gainRange,
                    step: AppModel.gainStep(option: false), optionStep: AppModel.gainStep(option: true),
                    label: localized("Gain"),
                    valueText: AppModel.gainLabel(model.controls.gainDB, locale: locale), onEdit: model.gain)
            }
            HStack {
                if editing {
                    TextField(
                        localized("Gain"), value: Binding(get: { model.controls.gainDB }, set: model.gain),
                        format: .number.locale(locale)
                    )
                    .onSubmit { editing = false }
                } else {
                    Button(AppModel.gainLabel(model.controls.gainDB, locale: locale)) { editing = true }.buttonStyle(
                        .plain
                    )
                    .monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(localized("Limiter active"))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
                    .opacity(model.limitingUntil > Date() ? 1 : 0)
                    .accessibilityHidden(model.limitingUntil <= Date())
            }.frame(minHeight: 24)
            meter("Input", model.inputDB)
            meter("Output", model.outputDB)
            Divider()
            if model.status?.defaultInput.isBlackHole == true {
                Label(localized("System input: MicBoost"), systemImage: "checkmark.circle.fill").font(.caption)
            } else {
                Text("\(localized("System input")): \(model.status?.defaultInputName ?? localized("Unknown"))").font(
                    .caption)
                Button(localized("Use MicBoost"), action: model.useBlackHole).disabled(model.status?.state != .running)
            }
            Text(localized("Microphone")).font(.headline)
            VStack(spacing: 0) {
                ForEach(model.sources, id: \.uid) { device in
                    Button {
                        model.select(device)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sourceSymbol(device)).frame(width: 18)
                            Text(device.name).lineLimit(2)
                            Spacer()
                            if model.controls.selectedInputUID == device.uid { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityLabel(device.name)
                    .accessibilityValue(model.controls.selectedInputUID == device.uid ? localized("Selected") : "")
                }
            }.buttonStyle(PanelMenuItemStyle())
            if let uid = model.controls.selectedInputUID, !model.sources.contains(where: { $0.uid == uid }) {
                Text("\(uid) (\(localized("Disconnected")))").font(.caption)
            }
            Divider()
            DisclosureGroup(isExpanded: $model.expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    band(
                        "Bass", gain: $model.controls.eq.low.gainDB, frequency: $model.controls.eq.low.frequency,
                        range: EQSettings.lowFrequencyRange)
                    Divider()
                    band(
                        "Mid", gain: $model.controls.eq.mid.gainDB, frequency: $model.controls.eq.mid.frequency,
                        range: EQSettings.midFrequencyRange, q: $model.controls.eq.mid.q)
                    Divider()
                    band(
                        "Treble", gain: $model.controls.eq.high.gainDB, frequency: $model.controls.eq.high.frequency,
                        range: EQSettings.highFrequencyRange)
                    HStack {
                        Button(localized("Voice preset"), action: model.voicePreset)
                        Spacer()
                        Button(localized("Reset EQ"), action: model.reset)
                    }.buttonStyle(.borderless)
                }.padding(.top, 8)
            } label: {
                HStack {
                    Text(localized("Equalizer"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { model.expanded.toggle() }
                    Toggle(localized("Enable EQ"), isOn: $model.controls.eq.enabled)
                        .labelsHidden()
                        .accessibilityLabel(localized("Enable EQ"))
                        .toggleStyle(.switch)
                        .onChange(of: model.controls.eq.enabled) { model.eq() }
                }
            }
            Divider()
            VStack(spacing: 0) {
                Button(localized("Settings…"), action: model.onSettings)
                    .keyboardShortcut(",")
                    .accessibilityLabel(localized("Settings…"))
                Button(localized("Quit MicBoost"), action: model.onQuit)
                    .accessibilityLabel(localized("Quit MicBoost"))
            }.buttonStyle(PanelMenuItemStyle())
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .animation(nil, value: model.expanded)
    }
    private func sourceSymbol(_ device: AudioDevice) -> String {
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeUSB: "mic.fill"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            "iphone"
        default: "mic"
        }
    }
    private func meter(_ title: String, _ db: Double) -> some View {
        HStack {
            Text(localized(title)).font(.caption).frame(width: 42, alignment: .leading)
            LevelMeterView(fraction: AppModel.meterFraction(db)).frame(maxWidth: .infinity)
                .accessibilityLabel(localized(title)).accessibilityValue("\(Int(db)) dBFS")
        }
    }
    private func band(
        _ title: String, gain: Binding<Double>, frequency: Binding<Double>, range: ClosedRange<Double>,
        q: Binding<Double>? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localized(title)).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(
                    gain.wrappedValue.formatted(
                        .number.locale(locale).precision(.fractionLength(1)).sign(strategy: .always())) + " dB"
                )
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            MenuSlider(
                value: gain.wrappedValue, range: EQSettings.gainRange,
                step: AppModel.gainStep(option: false), optionStep: AppModel.gainStep(option: true),
                label: "\(localized(title)), \(localized("Gain"))", valueText: "\(gain.wrappedValue) dB",
                onEdit: { gain.wrappedValue = ($0 * 2).rounded() / 2 }
            )
            .onChange(of: gain.wrappedValue) { model.eq() }
            HStack {
                Text(localized("Frequency"))
                Spacer()
                TextField("Hz", value: frequency, format: .number.locale(locale))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityLabel("\(localized(title)), Hz")
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        let direction = press.key == .upArrow ? 1.0 : -1.0
                        let maximum = min(range.upperBound, (model.status?.sampleRate ?? 48000) * 0.45)
                        frequency.wrappedValue = min(
                            maximum, max(range.lowerBound, frequency.wrappedValue * pow(2, direction / 12)))
                        model.eq()
                        return .handled
                    }
                    .onSubmit {
                        frequency.wrappedValue = min(
                            max(frequency.wrappedValue, range.lowerBound),
                            min(range.upperBound, (model.status?.sampleRate ?? 48000) * 0.45))
                        model.eq()
                    }
                Text("Hz")
            }.font(.caption)
            if let q {
                HStack {
                    Text(localized("Width"))
                    Spacer()
                    Text(String(format: "Q %.1f", q.wrappedValue)).foregroundStyle(.secondary)
                }.font(.caption)
                MenuSlider(
                    value: q.wrappedValue, range: EQSettings.midQRange, step: 0.1, optionStep: 0.5,
                    label: localized("Width"), valueText: String(format: "Q %.1f", q.wrappedValue),
                    onEdit: { q.wrappedValue = $0 }
                ).onChange(of: q.wrappedValue) { model.eq() }
            }
        }.padding(.vertical, 6)
    }
}

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
                    Link("GitHub", destination: URL(string: "https://github.com/vittau/MicBoost")!)
                }
                Text(localized("License: GPL-3.0")).foregroundStyle(.secondary)
            } header: {
                Text(localized("About"))
            }
        }
        .formStyle(.grouped)

        .frame(width: 540)
    }
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

/// Text-only rows matching the actions at the bottom of system menu bar panels.
private struct PanelMenuItemStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = hovered || configuration.isPressed
        configuration.label
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .foregroundStyle(
                highlighted ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary
            )
            .background(
                highlighted ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}
