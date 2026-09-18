import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bluetooth: BLEController
    @EnvironmentObject var wakeWord: WakeWordManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    connectionCard
                    wakeWordCard
                    devicesCard
                    notesCard
                }
                .padding()
            }
            .navigationTitle("Jarvis")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: wakeWord.isListening ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 76))
                .symbolEffect(.pulse, isActive: wakeWord.isListening)

            Text("Jarvis Glasses")
                .font(.largeTitle.bold())

            Text("Say “\(wakeWord.wakePhrase.isEmpty ? "Hey Jarvis" : wakeWord.wakePhrase)” → wake M02S")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Glasses", systemImage: "eyeglasses")
                .font(.headline)

            infoRow("Selected", bluetooth.selectedName)
            infoRow("Connection", bluetooth.isConnected ? "Connected" : "Not connected")
            infoRow("Last wake", bluetooth.lastWakeText)

            Text(bluetooth.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Auto reconnect", isOn: Binding(
                get: { bluetooth.autoReconnect },
                set: { bluetooth.setAutoReconnect($0) }
            ))

            HStack {
                Button(bluetooth.isScanning ? "Stop Scan" : "Scan") {
                    bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.startScan()
                }
                .buttonStyle(.borderedProminent)

                Button("Test Glasses") {
                    bluetooth.testWake()
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var wakeWordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Custom Background Wake Word", systemImage: "mic.badge.plus")
                .font(.headline)

            Toggle("Wake-word listening", isOn: Binding(
                get: { wakeWord.enabled },
                set: { wakeWord.setEnabled($0) }
            ))

            VStack(alignment: .leading, spacing: 5) {
                Text("Wake phrase")
                    .font(.caption.bold())
                TextField("Hey Jarvis", text: Binding(
                    get: { wakeWord.wakePhrase },
                    set: { wakeWord.setWakePhrase($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Recognition aliases")
                    .font(.caption.bold())
                TextField("Hey Jervis, Hey Jarvus", text: Binding(
                    get: { wakeWord.aliasesText },
                    set: { wakeWord.setAliasesText($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                Text("Comma separated. Add anything your iPhone usually hears instead of your wake phrase.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Sensitivity")
                Spacer()
                Picker("Sensitivity", selection: Binding(
                    get: { wakeWord.sensitivity },
                    set: { wakeWord.setSensitivity($0) }
                )) {
                    ForEach(WakeWordManager.Sensitivity.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.menu)
            }

            Text(wakeWord.sensitivity.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("On-device recognition only", isOn: Binding(
                get: { wakeWord.onDeviceOnly },
                set: { wakeWord.setOnDeviceOnly($0) }
            ))

            infoRow("Listener", wakeWord.isListening ? "Listening" : "Stopped")
            infoRow("Microphone", wakeWord.inputRoute)
            infoRow("Last detected", wakeWord.lastDetected)
            infoRow("Best match", wakeWord.lastMatch)

            Text(wakeWord.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !wakeWord.liveText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live speech")
                        .font(.caption.bold())
                    Text(wakeWord.liveText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

            Button("Reset Wake Settings") {
                wakeWord.resetWakeSettings()
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bluetooth devices")
                .font(.headline)

            if bluetooth.devices.isEmpty {
                Text("Tap Scan. Your M02S should move near the top of the list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bluetooth.devices.prefix(12)) { device in
                    Button {
                        bluetooth.select(device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(device.id.uuidString)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(device.rssi)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Better detection in V3", systemImage: "waveform.badge.magnifyingglass")
                .font(.headline)
            Text("V3 does not require an exact speech transcript anymore. It uses live partial speech, phrase biasing, recognition aliases, fuzzy matching, and automatically refreshes long speech sessions.")
            Text("Start with High sensitivity. If it still misses you, use Max. If it wakes by accident, move down to Balanced or Strict.")
            Text("For a misheard phrase, look at Live speech and add that wording under Recognition aliases. Example: if iOS hears ‘Hey Jervis,’ add it as an alias.")
            Text("Keep Wake-word listening on before locking the phone. Do not swipe-force-close the app.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .cardStyle()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
