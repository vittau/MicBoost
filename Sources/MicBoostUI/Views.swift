import AppKit
import CoreAudio
import MicBoostCore
import SwiftUI

@MainActor public struct PanelView: View {
    @Bindable var model: AppModel
    @State private var editing = false
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    if model.error == .microphonePermissionDenied {
                        Link(
                            localized("Open Privacy Settings"),
                            destination: URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    } else if model.error == .blackHoleMissing {
                        Link(
                            localized("How to install"),
                            destination: URL(string: "https://github.com/vittau/MicBoost#requirements")!)
                    } else {
                        Button(localized("Try again"), action: model.retry)
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
                Slider(
                    value: Binding(get: { model.controls.gainDB }, set: model.gain), in: Settings.gainRange
                )
                .accessibilityLabel(localized("Gain")).accessibilityValue(AppModel.gainLabel(model.controls.gainDB))
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let direction = press.key == .leftArrow || press.key == .downArrow ? -1.0 : 1.0
                    model.gain(
                        model.controls.gainDB + direction * AppModel.gainStep(option: press.modifiers.contains(.option))
                    )
                    return .handled
                }
            }
            HStack {
                if editing {
                    TextField(
                        localized("Gain"), value: Binding(get: { model.controls.gainDB }, set: model.gain),
                        format: .number
                    )
                    .onSubmit { editing = false }
                } else {
                    Button(AppModel.gainLabel(model.controls.gainDB)) { editing = true }.buttonStyle(.plain)
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
        }.padding(16).frame(width: 320).fixedSize(horizontal: false, vertical: true)
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
                    gain.wrappedValue.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " dB"
                )
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(
                value: Binding(get: { gain.wrappedValue }, set: { gain.wrappedValue = ($0 * 2).rounded() / 2 }),
                in: EQSettings.gainRange
            )
            .accessibilityLabel("\(localized(title)), \(localized("Gain"))").accessibilityValue(
                "\(gain.wrappedValue) dB"
            )
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let direction = press.key == .leftArrow || press.key == .downArrow ? -1.0 : 1.0
                gain.wrappedValue = min(
                    12,
                    max(
                        -12,
                        gain.wrappedValue + direction * AppModel.gainStep(option: press.modifiers.contains(.option))))
                model.eq()
                return .handled
            }
            .onChange(of: gain.wrappedValue) { model.eq() }
            HStack {
                Text(localized("Frequency"))
                Spacer()
                TextField("Hz", value: frequency, format: .number)
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
                Slider(value: q, in: EQSettings.midQRange)
                    .accessibilityLabel(localized("Width"))
                    .accessibilityValue(String(format: "Q %.1f", q.wrappedValue))
                    .onChange(of: q.wrappedValue) { model.eq() }
            }
        }.padding(.vertical, 6)
    }
}

@MainActor public struct SettingsView: View {
    @Bindable var model: AppModel
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
                Picker(localized("Buffer"), selection: $model.controls.bufferFrames) {
                    ForEach(
                        Settings.allowedBufferFrames.filter { frames in
                            guard let source = model.status?.source else { return true }
                            return Double(frames) >= source.bufferRange.minimum
                                && Double(frames) <= source.bufferRange.maximum
                        }, id: \.self
                    ) { Text("\($0)").tag($0) }
                }.onChange(of: model.controls.bufferFrames) {
                    let frames = model.controls.bufferFrames
                    Task {
                        await model.store.update { $0.bufferFrames = frames }
                        model.retry()
                    }
                }
                Picker(localized("Channels"), selection: Binding(get: { channel }, set: setChannel)) {
                    Text(localized("Automatic")).tag(0)
                    Text(localized("Mono mix")).tag(-1)
                    ForEach(1...max(1, Int(model.status?.source?.inputChannels ?? 1)), id: \.self) {
                        Text("Mono \($0)").tag($0)
                    }
                    if (model.status?.source?.inputChannels ?? 0) >= 2 { Text("Stereo 1–2").tag(-2) }
                }
            }
            Section(localized("Diagnostics")) {
                LabeledContent(localized("Sample rate"), value: "\((model.status?.sampleRate ?? 0).formatted()) Hz")
                LabeledContent(localized("Buffer"), value: "\(model.status?.bufferFrames ?? 0) \(localized("frames"))")
                LabeledContent(
                    localized("Reported latency"),
                    value:
                        "\((model.status?.reportedLatencyMs ?? 0).formatted(.number.precision(.fractionLength(1)))) ms")
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
                Text(localized("License: to be defined")).foregroundStyle(.secondary)
            } header: {
                Text(localized("About"))
            } footer: {
                Text(localized("This app is not notarized."))
            }
        }
        .formStyle(.grouped)

        .frame(width: 540)
    }
    private var channel: Int {
        switch model.controls.channelSelectionByUID[model.controls.selectedInputUID ?? ""] ?? .auto {
        case .auto: 0
        case .monoMix: -1
        case .mono(let n): n
        case .stereo: -2
        }
    }
    private func setChannel(_ value: Int) {
        guard let uid = model.controls.selectedInputUID else { return }
        let selection: ChannelSelection =
            value == 0 ? .auto : value == -1 ? .monoMix : value == -2 ? .stereo(firstChannel: 1) : .mono(channel: value)
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
            .padding(.horizontal, 6)
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
