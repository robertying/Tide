import AppKit
import SwiftUI

/// A standard preferences window: toolbar tabs with icons, one fixed-size pane per tab.
enum SettingsWindow {
    static func make(dimmer: Dimmer, app: AppDelegate) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(pane("Display", "sun.max", DimSettings(dimmer: dimmer).frame(width: 520, height: 430)))
        tabs.addTabViewItem(pane("Soundbar", "hifispeaker", SoundbarSettings(app: app).frame(width: 520, height: 640)))

        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private static func pane<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

// MARK: - Shared row layout

/// Label on the left, controls on the right, all vertically centered.
private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 6) {
        Text(label)
        Spacer()
        content()
    }
}

/// Editable number with a stepper, at a fixed width so the columns line up.
private func number<V: Strideable, F: ParseableFormatStyle>(
    _ value: Binding<V>, format: F, range: ClosedRange<V>, step: V.Stride
) -> some View where F.FormatInput == V, F.FormatOutput == String {
    HStack(spacing: 4) {
        TextField("", value: value, format: format)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
        Stepper("", value: value, in: range, step: step).labelsHidden()
    }
}

/// Unit text in a fixed-width column, so every row ends at the same place.
private func unit(_ text: String) -> some View {
    Text(verbatim: text)
        .foregroundStyle(.secondary)
        .frame(width: 58, alignment: .leading)
}

private func note(_ text: String) -> some View {
    Text(verbatim: text).foregroundStyle(.secondary)
}

// MARK: - Display

struct DimSettings: View {
    let dimmer: Dimmer
    @AppStorage(Key.dimEnabled) private var enabled = true
    @AppStorage(Key.dimAfter) private var after = Defaults.dimAfter
    @AppStorage(Key.dimFactor) private var factor = Defaults.dimFactor
    @AppStorage(Key.dimFadeOut) private var fadeOut = Defaults.dimFadeOut
    @AppStorage(Key.dimFadeIn) private var fadeIn = Defaults.dimFadeIn
    @State private var previewing = false
    @State private var previewError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Dim External Displays When Idle", isOn: $enabled)
            } footer: {
                note("Fades external displays after a period of inactivity and restores them when you return. Skipped during video and calls.")
            }

            Section {
                row("Dim After") {
                    number($after, format: .number, range: 5...3600, step: 15)
                    unit("seconds")
                }
                row("Dimmed Brightness") {
                    // No `step:` on the slider: it would draw tick marks. Round to 5% instead.
                    Slider(value: Binding(get: { factor }, set: { factor = ($0 * 20).rounded() / 20 }), in: 0.05...0.9)
                        .frame(width: 180)
                    unit("\(Int((factor * 100).rounded()))%").monospacedDigit()
                }
                row("Fade Out") {
                    number($fadeOut, format: .number.precision(.fractionLength(0...2)), range: 0...10, step: 0.1)
                    unit("seconds")
                }
                row("Fade In") {
                    number($fadeIn, format: .number.precision(.fractionLength(0...2)), range: 0...10, step: 0.1)
                    unit("seconds")
                }
            } footer: {
                note("Dimmed brightness is relative to the brightness before dimming.")
            }
            .disabled(!enabled)

            Section {
                HStack {
                    Button(previewing ? "Previewing…" : "Preview Dimming") {
                        previewing = true
                        previewError = nil
                        dimmer.preview { err in
                            previewing = false
                            previewError = err
                        }
                    }
                    .disabled(previewing)
                    if let previewError { Text(verbatim: previewError).foregroundStyle(.red) }
                    Spacer()
                    Button("Reset to Defaults") {
                        after = Defaults.dimAfter
                        factor = Defaults.dimFactor
                        fadeOut = Defaults.dimFadeOut
                        fadeIn = Defaults.dimFadeIn
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Soundbar

struct SoundbarSettings: View {
    let app: AppDelegate
    @AppStorage(Key.sbEnabled) private var enabled = true
    @AppStorage(Key.sbURL) private var url = ""
    @AppStorage(Key.sbUser) private var user = ""
    @AppStorage(Key.sbAccessory) private var accessory = Defaults.sbAccessory
    @AppStorage(Key.sbDevice) private var device = Defaults.sbDevice
    @AppStorage(Key.sbStep) private var step = Defaults.sbStep
    @AppStorage(Key.sbMax) private var maxVolume = Defaults.sbMax
    @State private var password = Keychain.get(.password) ?? ""
    @State private var totp = Keychain.get(.totp) ?? ""
    @State private var outputs: [String] = []
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                Toggle("Control the Soundbar with the Volume Keys", isOn: $enabled)
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    row("Accessibility") {
                        if AXIsProcessTrusted() {
                            if Soundbar.shared.tapInstalled {
                                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Relaunch to Apply") { app.relaunch() }
                            }
                        } else {
                            Button("Grant Access…") { app.openAccessibility() }
                        }
                    }
                }
            } footer: {
                note("While the TV is the sound output, the volume keys adjust the soundbar through Homebridge. Hold Shift-Option for finer steps.")
            }

            Section {
                TextField(text: $url, prompt: Text(verbatim: "http://hostname:8581")) { Text("Address") }
                TextField("Username", text: $user)
                SecureField("Password", text: $password)
                    .onChange(of: password) { _, v in Keychain.set(.password, v) }
                SecureField(text: $totp, prompt: Text(verbatim: "Optional")) { Text("Two-Factor Secret") }
                    .onChange(of: totp) { _, v in Keychain.set(.totp, v.trimmingCharacters(in: .whitespaces)) }
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }
                        .disabled(testing || url.isEmpty || user.isEmpty || password.isEmpty)
                    if let r = testResult {
                        Label { Text(verbatim: r.text) } icon: {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        }
                        .foregroundStyle(r.ok ? .green : .red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Homebridge")
            } footer: {
                note("The address of the Homebridge UI, including the port. The two-factor secret is the base32 key or otpauth:// link behind the authenticator QR code.")
            }

            Section {
                Picker("TV Audio Output", selection: $device) {
                    if device.isEmpty { Text("None").tag("") }
                    ForEach(outputChoices, id: \.self) { name in
                        Text(verbatim: outputs.contains(name) ? name : "Name contains “\(name)”").tag(name)
                    }
                }
                TextField(text: $accessory, prompt: Text(verbatim: Defaults.sbAccessory)) { Text("HomeKit Accessory") }
                row("Volume Step") {
                    number($step, format: .number, range: 1...20, step: 1)
                    unit("")
                }
                row("Maximum Volume") {
                    number($maxVolume, format: .number, range: 5...100, step: 5)
                    unit("")
                }
            } header: {
                Text("Soundbar")
            } footer: {
                note("HomeKit Accessory is the name of the soundbar’s volume control in Homebridge.")
            }
        }
        .formStyle(.grouped)
        .onAppear { outputs = outputDeviceNames() }
    }

    /// Current output devices, plus the saved choice if it isn't one of them (unplugged, or a partial name).
    private var outputChoices: [String] {
        outputs.contains(device) || device.isEmpty ? outputs : outputs + [device]
    }

    private func test() {
        testing = true
        testResult = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Homebridge.check()
            DispatchQueue.main.async {
                testing = false
                switch r {
                case .success(let v):
                    testResult = (true, "Connected, volume \(v)")
                case .failure(let e):
                    testResult = (false, "\(e)")
                }
            }
        }
    }
}
