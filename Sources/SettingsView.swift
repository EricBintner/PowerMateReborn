import SwiftUI
import CoreAudio

// MARK: - Section identitier

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case audio = "Audio"
    case knob = "Knob"
    case displays = "Displays"
    case midi = "MIDI"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .audio:   return "speaker.wave.2"
        case .knob:    return "dial.min"
        case .displays: return "display"
        case .midi:    return "pianokeys"
        case .custom:  return "slider.horizontal.3"
        }
    }
}

// MARK: - Root view

struct SettingsView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selectedSection {
                case .general:  GeneralSettingsSection()
                case .audio:    AudioSettingsSection()
                case .knob:     KnobSettingsSection()
                case .displays: DisplaysSettingsSection()
                case .midi:     MIDISettingsSection()
                case .custom:   CustomProfilesSection()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { model.refresh() }
    }
}

// MARK: - Shared form scaffolding

/// Consistent layout for settings sections: titled rows, section spacing.
private struct SettingsForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

/// A control row: icon + title + trailing control, with help text below.
private struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    let help: String?
    let control: Control

    init(icon: String, title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 22)
                Text(title)
                Spacer(minLength: 16)
                control
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 38)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Read-only diagnostic line (device methods, active display, etc.)
private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundColor(.secondary)
        } label: {
            Text(label)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        SettingsForm {
            Text("General").font(.title2).bold().padding(.bottom, 4)
            SettingRow(icon: "power", title: "Launch at Login") {
                Toggle("", isOn: binding(\.launchAtLogin, model.setLaunchAtLogin))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider().padding(.vertical, 12)
            Text("Enabled Modes").font(.headline).padding(.bottom, 8)
            Text("Which modes the knob can switch between (long-press cycles modes).")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
            ForEach(KnobMode.allCases, id: \.self) { mode in
                SettingRow(icon: mode.icon, title: mode.rawValue) {
                    Toggle("", isOn: Binding(
                        get: { model.enabledModes.contains(mode) },
                        set: { model.setModeEnabled(mode, $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, T>, _ setter: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { model[keyPath: keyPath] }, set: setter)
    }
}

// MARK: - Audio

private struct AudioSettingsSection: View {
    @ObservedObject private var model = SettingsModel.shared

    private static let volumeSnapChoices: [(label: String, value: Float)] = [
        ("Mute 0%", 0.0), ("Low 20%", 0.20), ("Medium 50%", 0.50), ("High 80%", 0.80)
    ]

    var body: some View {
        SettingsForm {
            Text("Audio").font(.title2).bold().padding(.bottom, 4)
            SettingRow(icon: "headphones", title: "Output Device",
                       help: "Route the knob's volume control to a specific device.") {
                Picker("", selection: Binding(
                    get: { model.activeDeviceID },
                    set: { model.setActiveDevice($0) }
                )) {
                    ForEach(model.allOutputDevices, id: \.deviceID) { dev in
                        Label(cleanName(dev.name), systemImage: dev.hasVolumeScalar || dev.hasChannelVolume || dev.hasVirtualMaster
                              ? "speaker.wave.2" : "speaker.slash")
                            .tag(dev.deviceID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }
            Divider().padding(.vertical, 12)
            Text("Double-Tap Actions").font(.headline).padding(.bottom, 8)
            SettingRow(icon: "speaker.wave.2", title: "Volume Tap Level",
                       help: "Volume the knob jumps to on a double tap.") {
                Picker("", selection: Binding(
                    get: { nearestSnap(model.volumeSnapValue, Self.volumeSnapChoices.map { $0.value }) },
                    set: { model.setVolumeSnap($0) }
                )) {
                    ForEach(Self.volumeSnapChoices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Divider().padding(.vertical, 12)
            Text("Diagnostics").font(.headline).padding(.bottom, 4)
            DiagnosticRow(label: "Active device", value: model.activeDeviceName)
            DiagnosticRow(label: "Control method", value: model.volumeMethod.rawValue)
        }
    }

    private func cleanName(_ name: String) -> String {
        name.hasSuffix(" Speakers") ? String(name.dropLast(" Speakers".count)) : name
    }

    private func nearestSnap(_ value: Float, _ choices: [Float]) -> Float {
        choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

// MARK: - Knob

private struct KnobSettingsSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var showAdvanced = false

    private static let sensitivityChoices: [(label: String, value: Float)] = [
        ("1%", 0.01), ("3%", 0.03), ("5%", 0.05), ("8%", 0.08)
    ]

    var body: some View {
        SettingsForm {
            Text("Knob").font(.title2).bold().padding(.bottom, 4)
            SettingRow(icon: "dial.min", title: "Sensitivity",
                       help: "How much volume/brightness changes per rotation tick.") {
                Picker("", selection: Binding(
                    get: { nearestSnap(model.stepSize, Self.sensitivityChoices.map { $0.value }) },
                    set: { model.setStepSize($0) }
                )) {
                    ForEach(Self.sensitivityChoices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            Divider().padding(.vertical, 12)
            Text("LED").font(.headline).padding(.bottom, 8)
            SettingRow(icon: "lightbulb", title: "Follow Level",
                       help: "LED brightness tracks the current volume/brightness.") {
                Toggle("", isOn: Binding(
                    get: { model.ledMode == .followLevel },
                    set: { model.setLEDMode($0 ? .followLevel : .dim) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if model.ledMode != .followLevel {
                SettingRow(icon: "lightbulb.fill", title: "Static Brightness") {
                    Picker("", selection: Binding(
                        get: { model.ledMode },
                        set: { model.setLEDMode($0) }
                    )) {
                        Text("Off").tag(LEDMode.off)
                        Text("Dim").tag(LEDMode.dim)
                        BrightnessOptionPicker()
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            Divider().padding(.vertical, 12)
            // Advanced disclosure
            HStack {
                Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Advanced") { withAnimation { showAdvanced.toggle() } }
                    .buttonStyle(.link)
                    .font(.headline)
            }
            .padding(.bottom, 8)
            if showAdvanced {
                SettingRow(icon: "hand.draw", title: "Long Press Threshold",
                           help: "How long the button must be held to count as a long press.") {
                    Stepper(value: Binding(
                        get: { model.longPressThreshold },
                        set: { model.setLongPressThreshold(min(2.0, max(0.1, $0))) }
                    ), in: 0.1...2.0, step: 0.1) {
                        Text(String(format: "%.1f s", model.longPressThreshold))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                SettingRow(icon: "hand.tap", title: "Double Tap Interval",
                           help: "Maximum gap between taps for a double tap.") {
                    Stepper(value: Binding(
                        get: { model.doubleTapInterval },
                        set: { model.setDoubleTapInterval(min(0.8, max(0.05, $0))) }
                    ), in: 0.05...0.8, step: 0.05) {
                        Text(String(format: "%.2f s", model.doubleTapInterval))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func nearestSnap(_ value: Float, _ choices: [Float]) -> Float {
        choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

/// Third segmented option — split out so its tag type matches (LEDMode).
private struct BrightnessOptionPicker: View {
    var body: some View {
        Text("Bright").tag(LEDMode.bright)
    }
}

// MARK: - Displays

private struct DisplaysSettingsSection: View {
    @ObservedObject private var model = SettingsModel.shared

    private static let brightnessSnapChoices: [(label: String, value: Float)] = [
        ("15%", 0.15), ("33%", 0.33), ("50%", 0.50), ("67%", 0.67), ("100%", 1.0)
    ]

    var body: some View {
        SettingsForm {
            Text("Displays").font(.title2).bold().padding(.bottom, 4)
            SettingRow(icon: "display", title: "Hardware Brightness (DDC/CI)",
                       help: "Change the real backlight via the monitor's DDC/CI interface. Disable if a display misbehaves.") {
                Toggle("", isOn: Binding(
                    get: { model.ddcEnabled },
                    set: { model.setDDCEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingRow(icon: "display.2", title: "Sync All Displays",
                       help: "Adjust all displays together. Off: only the display under the mouse.") {
                Toggle("", isOn: Binding(
                    get: { model.syncDisplays },
                    set: { model.setSyncDisplays($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Divider().padding(.vertical, 12)
            Text("Double-Tap Actions").font(.headline).padding(.bottom, 8)
            SettingRow(icon: "sun.max", title: "Brightness Tap Level",
                       help: "Brightness the knob jumps to on a double tap.") {
                Picker("", selection: Binding(
                    get: { nearestSnap(model.brightnessSnapValue, Self.brightnessSnapChoices.map { $0.value }) },
                    set: { model.setBrightnessSnap($0) }
                )) {
                    ForEach(Self.brightnessSnapChoices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Divider().padding(.vertical, 12)
            Text("Diagnostics").font(.headline).padding(.bottom, 4)
            DiagnosticRow(label: "Active display", value: model.activeDisplayName)
            DiagnosticRow(label: "Control method", value: model.brightnessMethod.rawValue)
        }
    }

    private func nearestSnap(_ value: Float, _ choices: [Float]) -> Float {
        choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

// MARK: - MIDI

private struct MIDISettingsSection: View {
    @ObservedObject private var model = SettingsModel.shared

    private static let ccChoices: [(label: String, value: UInt8)] = [
        ("Mod", 1), ("Volume", 7), ("Expr", 11), ("Filter", 74)
    ]

    var body: some View {
        SettingsForm {
            Text("MIDI").font(.title2).bold().padding(.bottom, 4)
            Text("The knob appears to music apps as a virtual MIDI controller named \"PowerMate Knob\".")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 12)
            SettingRow(icon: "pianokeys", title: "CC Number") {
                Picker("", selection: Binding(
                    get: { model.midiCCNumber },
                    set: { model.setMIDICC($0) }
                )) {
                    ForEach(Self.ccChoices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            SettingRow(icon: "waveform", title: "Channel") {
                Picker("", selection: Binding(
                    get: { model.midiChannel + 1 },
                    set: { model.setMIDIChannel($0 - 1) }
                )) {
                    ForEach([1, 2, 10, 16], id: \.self) { ch in
                        Text("Ch \(ch)").tag(ch)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Text("MIDI is only sent while the knob is in MIDI mode (cycle modes with a long press).")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
    }
}

// MARK: - Custom (profiles editor)

struct CustomProfilesSection: View {
    @ObservedObject private var engine = CustomModeEngine.shared
    @State private var selectedProfileID: UUID?
    @State private var showingAddApp = false

    var body: some View {
        HSplitView {
            List(selection: $selectedProfileID) {
                Section(header: Text("Profiles")) {
                    ForEach(engine.profiles) { profile in
                        HStack {
                            Image(systemName: profile.iconName)
                                .foregroundColor(profile.isGlobal ? .blue : .primary)
                                .frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                    .fontWeight(profile.isGlobal ? .medium : .regular)
                                if engine.activeProfileID == profile.id {
                                    Text("Active")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .tag(profile.id)
                        .contextMenu {
                            if !profile.isGlobal {
                                Button("Remove") {
                                    engine.removeProfile(id: profile.id)
                                    if selectedProfileID == profile.id {
                                        selectedProfileID = engine.profiles.first?.id
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button {
                        showingAddApp = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
            }
            .sheet(isPresented: $showingAddApp) {
                AddAppSheet(engine: engine, isPresented: $showingAddApp) { newID in
                    selectedProfileID = newID
                }
            }

            if let selectedProfileID,
               let index = engine.profiles.firstIndex(where: { $0.id == selectedProfileID }) {
                VStack(spacing: 0) {
                    if !engine.inputPermissionGranted {
                        // Custom Mode's scroll/keyboard actions post CGEvents,
                        // which require Accessibility; without it they silently
                        // do nothing on a fresh macOS install.
                        Label(
                            "Scroll and keyboard actions need Accessibility permission (System Settings > Privacy & Security > Accessibility).",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                    }
                    ProfileDetailView(engine: engine, profileIndex: index)
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select an application profile to configure Custom Mode.")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = engine.profiles.first?.id
            }
        }
    }
}