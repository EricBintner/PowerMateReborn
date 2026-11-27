import SwiftUI
import AppKit

// The Custom Mode editor now lives in the Settings window's Custom section
// (SettingsView.swift > CustomProfilesSection). The views below — AddAppSheet,
// ProfileDetailView, ActionConfigRow, IntField — are reused by it.

// MARK: - Add App Sheet

struct AddAppSheet: View {
    @ObservedObject var engine: CustomModeEngine
    @Binding var isPresented: Bool
    var onAdd: (UUID) -> Void

    @State private var runningApps: [(name: String, bundleID: String, icon: NSImage?)] = []
    @State private var selectedBundleID: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(tr("Add Application Profile"))
                .font(.headline)

            List(runningApps, id: \.bundleID) { app in
                HStack {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    Text(app.name)
                    Spacer()
                    if selectedBundleID == app.bundleID {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedBundleID = app.bundleID
                }
            }
            .frame(height: 250)

            HStack {
                Button(tr("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Add")) {
                    guard !selectedBundleID.isEmpty,
                          let app = runningApps.first(where: { $0.bundleID == selectedBundleID }) else { return }
                    engine.addProfile(name: app.name, bundleIdentifier: app.bundleID, iconName: "app")
                    if let newProfile = engine.profiles.last {
                        onAdd(newProfile.id)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBundleID.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear { loadRunningApps() }
    }

    private func loadRunningApps() {
        let existing = Set(engine.profiles.compactMap { $0.bundleIdentifier })
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let bundleID = app.bundleIdentifier,
                      !existing.contains(bundleID) else { return nil }
                return (app.localizedName ?? bundleID, bundleID, app.icon)
            }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
    }
}

// MARK: - Detail View

struct ProfileDetailView: View {
    @ObservedObject var engine: CustomModeEngine
    let profileIndex: Int

    private var profile: CodableAppProfile {
        engine.profiles[profileIndex]
    }

    private func binding<T>(_ keyPath: WritableKeyPath<CodableAppProfile, T>) -> Binding<T> {
        Binding(
            get: { engine.profiles[profileIndex][keyPath: keyPath] },
            set: { newValue in
                engine.profiles[profileIndex][keyPath: keyPath] = newValue
                engine.saveProfiles()
            }
        )
    }

    /// After a profile removal the parent re-renders with a fresh index, but
    /// this view's stored bindings can fire once with the stale index before
    /// that happens — bounds-check in body rather than crashing.
    private var isIndexValid: Bool {
        profileIndex < engine.profiles.count
    }

    var body: some View {
        Group {
            if !isIndexValid {
                // Stale index after a removal — parent will re-render with a
                // valid one; render nothing in the interim.
                EmptyView()
            } else {
                profileDetailBody
            }
        }
    }

    private var profileDetailBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    if profile.isGlobal {
                        Image(systemName: "globe")
                            .font(.system(size: 32))
                            .foregroundColor(.blue)
                    } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == profile.bundleIdentifier }),
                              let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "app")
                            .font(.system(size: 32))
                            .foregroundColor(.primary)
                    }

                    VStack(alignment: .leading) {
                        Text(profile.name)
                            .font(.title2).bold()
                        if profile.isGlobal {
                            Text(tr("Applies when no app-specific profile matches."))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else if let bundle = profile.bundleIdentifier {
                            Text(bundle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.bottom, 20)

                // Rotation
                Text(tr("Rotation"))
                    .font(.headline)
                    .padding(.bottom, 8)
                ActionConfigRow(title: tr("Rotate Left"), icon: "arrow.counterclockwise", config: binding(\.rotateLeft),
                                onRequiresInputPermission: promptInputPermission)
                ActionConfigRow(title: tr("Rotate Right"), icon: "arrow.clockwise", config: binding(\.rotateRight),
                                onRequiresInputPermission: promptInputPermission)

                Divider().padding(.vertical, 12)

                // Button Press
                Text(tr("Button Press"))
                    .font(.headline)
                    .padding(.bottom, 8)
                ActionConfigRow(title: tr("Single Tap"), icon: "hand.tap", config: binding(\.singleClick),
                                onRequiresInputPermission: promptInputPermission)
                ActionConfigRow(title: tr("Double Tap"), icon: "hand.tap.fill", config: binding(\.doubleClick),
                                onRequiresInputPermission: promptInputPermission)

                Divider().padding(.vertical, 12)

                // Long Press Override
                Text(tr("Long Press (Advanced)"))
                    .font(.headline)
                    .padding(.bottom, 8)

                Toggle(tr("Override Global Mode Cycling"), isOn: binding(\.overrideLongPress))
                    .tint(.red)
                    .padding(.bottom, 8)

                if profile.overrideLongPress {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(tr("Assigning a custom action here disables the ability to cycle modes (Volume / Brightness / MIDI / Custom) from the knob while this profile is active."))
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.bottom, 8)

                        Picker(tr("Behavior:"), selection: binding(\.holdBehavior)) {
                            ForEach(CodableHoldBehavior.allCases) { behavior in
                                Text(behavior.displayName).tag(behavior)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .padding(.bottom, 8)

                        if profile.holdBehavior == .extendedPress {
                            Text(tr("The action fires when the button has been held long enough, and stays active until the button is released -- like holding a key on an organ."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 4)
                        }

                        ActionConfigRow(
                            title: profile.holdBehavior == .longPress ? tr("Long Press") : tr("Extended Press"),
                            icon: "hand.draw",
                            config: binding(\.longPressAction),
                            onRequiresInputPermission: promptInputPermission
                        )
                    }
                    .padding()
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                }
            }
            .padding(24)
        }
    }

    private func promptInputPermission() {
        _ = engine.requestInputPermissionIfNeeded(prompt: true)
    }
}

// MARK: - Action Config Row

struct ActionConfigRow: View {
    let title: String
    let icon: String
    @Binding var config: CodableActionConfig
    /// When set, selecting scroll/keyboard triggers the Accessibility TCC prompt
    /// the first time this session (same pattern as Music Automation).
    var onRequiresInputPermission: (() -> Void)? = nil

    @State private var isRecordingShortcut = false
    @State private var shortcutDisplayString = ""
    /// Token of the active keyboard-shortcut recording monitor. Removed when
    /// recording ends — previously every "Record Shortcut" click added a new
    /// permanent monitor, and stale monitors kept rewriting the shortcut long
    /// after the sheet closed.
    @State private var shortcutMonitor: Any?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Label(title, systemImage: icon)
                .frame(width: 130, alignment: .leading)
                .padding(.top, 4)
                .accessibilityHidden(true) // VoiceOver will read the label inside the picker/button instead

            VStack(alignment: .leading, spacing: 8) {
                Picker(title, selection: $config.type) {
                    ForEach(CodableActionType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .accessibilityLabel(tr("%@ Action Type", title))
                .onChange(of: config.type) { newType in
                    if CustomModeEngine.actionRequiresInputPermission(newType) {
                        onRequiresInputPermission?()
                    }
                }

                Group {
                    switch config.type {
                    case .unassigned:
                        EmptyView()

                    case .scroll:
                        Picker(tr("Direction"), selection: $config.scrollDirection) {
                            ForEach(ScrollDirection.allCases, id: \.self) { dir in
                                Text(dir.localizedName).tag(dir)
                            }
                        }
                        .frame(width: 150)

                    case .keyboard:
                        HStack {
                            Text(config.keyboardShortcut.displayString.isEmpty ? tr("None") : config.keyboardShortcut.displayString)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
                                .accessibilityLabel(tr("Current shortcut: %@", config.keyboardShortcut.displayString.isEmpty ? tr("None") : config.keyboardShortcut.displayString))
                            Button(isRecordingShortcut ? tr("Press keys...") : tr("Record Shortcut")) {
                                isRecordingShortcut = true
                                startShortcutRecording()
                            }
                            .buttonStyle(.bordered)
                            .onDisappear {
                                // Sheet closed / row switched while still
                                // recording — remove the abandoned monitor
                                stopShortcutRecording()
                            }
                            .accessibilityHint(tr("Click to start recording a new keyboard shortcut"))
                        }

                    case .media:
                        Picker(tr("Command"), selection: $config.mediaCommand) {
                            ForEach(MediaCommand.allCases, id: \.self) { cmd in
                                Text(cmd.localizedName).tag(cmd)
                            }
                        }
                        .frame(width: 150)
                        .accessibilityLabel(tr("Media Command"))

                    case .midiCC:
                        HStack {
                            IntField(tr("CC#"), value: Binding(
                                get: { Int(config.midiCC.ccNumber) },
                                set: { config.midiCC.ccNumber = UInt8(max(0, min(127, $0))) }
                            ), range: 0...127)
                            .frame(width: 80)
                            IntField(tr("Ch"), value: Binding(
                                get: { Int(config.midiCC.channel) + 1 },
                                set: { config.midiCC.channel = UInt8(max(0, min(15, $0 - 1))) }
                            ), range: 1...16)
                            .frame(width: 70)
                        }

                    case .midiNote:
                        HStack {
                            IntField(tr("Note"), value: Binding(
                                get: { Int(config.midiNote.noteNumber) },
                                set: { config.midiNote.noteNumber = UInt8(max(0, min(127, $0))) }
                            ), range: 0...127)
                            .frame(width: 80)
                            IntField(tr("Vel"), value: Binding(
                                get: { Int(config.midiNote.velocity) },
                                set: { config.midiNote.velocity = UInt8(max(0, min(127, $0))) }
                            ), range: 0...127)
                            .frame(width: 80)
                            IntField(tr("Ch"), value: Binding(
                                get: { Int(config.midiNote.channel) + 1 },
                                set: { config.midiNote.channel = UInt8(max(0, min(15, $0 - 1))) }
                            ), range: 1...16)
                            .frame(width: 70)
                        }

                    case .osc:
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(tr("OSC Path"), text: $config.osc.path)
                            HStack {
                                TextField(tr("Host"), text: $config.osc.host)
                                    .frame(width: 120)
                                IntField(tr("Port"), value: Binding(
                                    get: { Int(config.osc.port) },
                                    set: { config.osc.port = UInt16(max(1, min(65535, $0))) }
                                ), range: 1...65535)
                                .frame(width: 80)
                            }
                        }
                        .frame(width: 260)
                    case .volume:
                        EmptyView()
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func startShortcutRecording() {
        // Remove any monitor left by a previous recording session first
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            config.keyboardShortcut = KeyboardShortcut(
                keyCode: event.keyCode,
                modifiers: UInt64(event.modifierFlags.rawValue),
                displayString: shortcutString(event)
            )
            stopShortcutRecording()
            return nil // consume the event
        }
    }

    private func stopShortcutRecording() {
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
        isRecordingShortcut = false
    }

    private func shortcutString(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option)  { parts.append("Opt") }
        if flags.contains(.shift)   { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Cmd") }

        if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
            parts.append(chars)
        } else {
            parts.append("Key \(event.keyCode)")
        }
        return parts.joined(separator: " + ")
    }
}

// MARK: - Integer TextField Helper

struct IntField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label
        self._value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField("", value: $value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .onSubmit {
                    value = max(range.lowerBound, min(range.upperBound, value))
                }
        }
    }
}
