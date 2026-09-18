import Foundation
import AVFoundation
import Speech

@MainActor
final class WakeWordManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    static let shared = WakeWordManager()

    enum Sensitivity: String, CaseIterable, Identifiable {
        case strict
        case balanced
        case high
        case maximum

        var id: String { rawValue }

        var title: String {
            switch self {
            case .strict: return "Strict"
            case .balanced: return "Balanced"
            case .high: return "High"
            case .maximum: return "Max"
            }
        }

        var threshold: Double {
            switch self {
            case .strict: return 0.95
            case .balanced: return 0.88
            case .high: return 0.78
            case .maximum: return 0.65
            }
        }

        var explanation: String {
            switch self {
            case .strict: return "Fewest false wakes"
            case .balanced: return "Good default"
            case .high: return "Catches more misheard words"
            case .maximum: return "Most aggressive; may wake by mistake"
            }
        }
    }

    @Published private(set) var enabled: Bool = UserDefaults.standard.bool(forKey: "jarvis.wake.enabled")
    @Published private(set) var isListening = false
    @Published private(set) var status = "Wake word is off"
    @Published private(set) var liveText = ""
    @Published private(set) var inputRoute = "Not listening"
    @Published private(set) var lastDetected = "Never"
    @Published private(set) var lastMatch = "No match yet"
    @Published private(set) var lastMatchScore: Double = 0

    @Published private(set) var wakePhrase: String = {
        let saved = UserDefaults.standard.string(forKey: "jarvis.wake.phrase")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved?.isEmpty == false) ? saved! : "Hey Jarvis"
    }()

    @Published private(set) var aliasesText: String = {
        if let saved = UserDefaults.standard.string(forKey: "jarvis.wake.aliases") { return saved }
        return "Hey Jervis, Hey Jarvus, A Jarvis"
    }()

    @Published private(set) var sensitivity: Sensitivity = {
        let raw = UserDefaults.standard.string(forKey: "jarvis.wake.sensitivity") ?? Sensitivity.high.rawValue
        return Sensitivity(rawValue: raw) ?? .high
    }()

    @Published private(set) var onDeviceOnly: Bool = UserDefaults.standard.object(forKey: "jarvis.wake.onDeviceOnly") as? Bool ?? false

    var onWake: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var configurationRestartTask: Task<Void, Never>?
    private var lastWakeDate = Date.distantPast
    private var intentionalStop = false

    override private init() {
        super.init()
        recognizer?.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioInterrupted),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: "jarvis.wake.enabled")

        if newValue {
            intentionalStop = false
            Task { await startWithPermissions() }
        } else {
            intentionalStop = true
            stop(deactivateAudio: true)
            status = "Wake word is off"
        }
    }

    func setWakePhrase(_ value: String) {
        let oldNormalized = normalize(wakePhrase)
        let defaultAliases = "Hey Jervis, Hey Jarvus, A Jarvis"

        wakePhrase = value
        UserDefaults.standard.set(value, forKey: "jarvis.wake.phrase")

        // If the user changes away from the default Jarvis phrase, do not leave
        // Jarvis-specific aliases active and accidentally wake on the old name.
        if oldNormalized == "hey jarvis", normalize(value) != "hey jarvis", aliasesText == defaultAliases {
            aliasesText = ""
            UserDefaults.standard.set("", forKey: "jarvis.wake.aliases")
        }

        scheduleConfigurationRestart()
    }

    func setAliasesText(_ value: String) {
        aliasesText = value
        UserDefaults.standard.set(value, forKey: "jarvis.wake.aliases")
        scheduleConfigurationRestart()
    }

    func setSensitivity(_ value: Sensitivity) {
        sensitivity = value
        UserDefaults.standard.set(value.rawValue, forKey: "jarvis.wake.sensitivity")
        status = enabled ? "Sensitivity: \(value.title)" : "Wake word is off"
    }

    func setOnDeviceOnly(_ value: Bool) {
        onDeviceOnly = value
        UserDefaults.standard.set(value, forKey: "jarvis.wake.onDeviceOnly")
        scheduleConfigurationRestart()
    }

    func resetWakeSettings() {
        setWakePhrase("Hey Jarvis")
        setAliasesText("Hey Jervis, Hey Jarvus, A Jarvis")
        setSensitivity(.high)
        setOnDeviceOnly(false)
    }

    func resumeIfNeeded() {
        guard enabled, !isListening else { return }
        intentionalStop = false
        Task { await startWithPermissions() }
    }

    private var effectiveWakePhrase: String {
        let clean = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Hey Jarvis" : clean
    }

    private var configuredPhrases: [String] {
        var phrases = [effectiveWakePhrase]
        let aliases = aliasesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        phrases.append(contentsOf: aliases)

        var seen = Set<String>()
        return phrases.filter { phrase in
            let key = normalize(phrase)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func startWithPermissions() async {
        guard enabled else { return }

        status = "Requesting microphone permission..."
        let micAllowed = await requestMicrophonePermission()
        guard micAllowed else {
            status = "Microphone permission denied"
            isListening = false
            return
        }

        status = "Requesting speech permission..."
        let speechAllowed = await requestSpeechPermission()
        guard speechAllowed else {
            status = "Speech recognition permission denied"
            isListening = false
            return
        }

        startRecognition()
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechPermission() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in
                continuation.resume(returning: result == .authorized)
            }
        }
    }

    private func startRecognition() {
        guard enabled, !intentionalStop else { return }

        stopRecognitionOnly()

        guard let recognizer, recognizer.isAvailable else {
            status = "Speech recognition is unavailable"
            scheduleRestart(after: 1.5)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            try? session.setPreferredIOBufferDuration(0.012)
            try session.setActive(true, options: [])
            preferGlassesMicrophone(session)
            updateInputRoute(session)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = false

            // Bias Apple's recognizer heavily toward the selected phrase and aliases.
            var context: [String] = []
            for phrase in configuredPhrases {
                context.append(phrase)
                context.append(phrase)
            }
            if normalize(effectiveWakePhrase).contains("jarvis") {
                context.append(contentsOf: ["Jarvis", "Hey Jarvis", "Jervis", "Jarvus"])
            }
            request.contextualStrings = context
            request.taskHint = .search

            if onDeviceOnly && recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            } else {
                request.requiresOnDeviceRecognition = false
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                status = "Microphone audio format is unavailable"
                scheduleRestart(after: 1.0)
                return
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    self?.handleRecognition(result: result, error: error)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()

            isListening = true
            liveText = ""
            status = "Listening for “\(effectiveWakePhrase)” · \(sensitivity.title)"
            scheduleHealthyRotation()
        } catch {
            isListening = false
            status = "Listener error: \(error.localizedDescription)"
            scheduleRestart(after: 1.0)
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            liveText = text

            let match = bestWakeMatch(in: text)
            if match.score > 0 {
                lastMatchScore = match.score
                lastMatch = "\(Int((match.score * 100).rounded()))% · \(match.window)"
            }

            if match.score >= sensitivity.threshold {
                let now = Date()
                if now.timeIntervalSince(lastWakeDate) > 2.2 {
                    lastWakeDate = now
                    lastDetected = Self.timeFormatter.string(from: now)
                    status = "“\(effectiveWakePhrase)” detected ✓"
                    onWake?()

                    // Start fresh quickly so old transcript text cannot fire again.
                    restartRecognition(after: 0.22)
                    return
                }
            }

            if result.isFinal {
                restartRecognition(after: 0.18)
                return
            }
        }

        if error != nil, enabled, !intentionalStop {
            restartRecognition(after: 0.45)
        }
    }

    // MARK: - Better wake phrase matching

    private func bestWakeMatch(in transcript: String) -> (score: Double, window: String) {
        let cleanTranscript = normalize(transcript)
        guard !cleanTranscript.isEmpty else { return (0, "") }

        let transcriptWords = cleanTranscript.split(separator: " ").map(String.init)
        var bestScore = 0.0
        var bestWindow = cleanTranscript

        for rawPhrase in configuredPhrases {
            let phrase = normalize(rawPhrase)
            guard !phrase.isEmpty else { continue }

            if cleanTranscript.contains(phrase) {
                return (1.0, phrase)
            }

            let phraseWords = phrase.split(separator: " ").map(String.init)
            guard !phraseWords.isEmpty else { continue }

            // Compare the phrase with nearby word windows. This catches things like
            // "hey jervis", "a jarvis", or a tiny transcription error.
            let minWindow = max(1, phraseWords.count - 1)
            let maxWindow = min(transcriptWords.count, phraseWords.count + 1)
            if minWindow <= maxWindow {
                for count in minWindow...maxWindow {
                    guard transcriptWords.count >= count else { continue }
                    for start in 0...(transcriptWords.count - count) {
                        let window = transcriptWords[start..<(start + count)].joined(separator: " ")
                        var score = similarity(window, phrase)

                        // Matching every word except a short lead-in like "hey" is useful
                        // when Speech drops the first syllable. Only Max mode gets the full boost.
                        if sensitivity == .maximum,
                           phraseWords.count >= 2,
                           count == phraseWords.count - 1 {
                            let tail = phraseWords.dropFirst().joined(separator: " ")
                            let tailScore = similarity(window, tail)
                            if tailScore >= 0.88 { score = max(score, 0.64 + (tailScore - 0.88)) }
                        }

                        if score > bestScore {
                            bestScore = score
                            bestWindow = window
                        }
                    }
                }
            }

            // On Max, also allow a very clean match on the assistant name by itself.
            // This is deliberately capped so lower sensitivities never trigger from one word.
            if sensitivity == .maximum, phraseWords.count == 2, let keyword = phraseWords.last {
                for word in transcriptWords.suffix(3) {
                    let wordScore = similarity(word, keyword)
                    if wordScore >= 0.92 {
                        let boosted = min(0.66, 0.58 + ((wordScore - 0.92) * 2.0))
                        if boosted > bestScore {
                            bestScore = boosted
                            bestWindow = word
                        }
                    }
                }
            }
        }

        return (bestScore, bestWindow)
    }

    private func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en-US"))
            .lowercased()

        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }

        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1.0 }
        let a = Array(lhs)
        let b = Array(rhs)
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1.0 }
        let distance = levenshtein(a, b)
        return max(0, 1.0 - (Double(distance) / Double(longest)))
    }

    private func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i + 1
            for (j, cb) in b.enumerated() {
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let substitution = previous[j] + (ca == cb ? 0 : 1)
                current[j + 1] = min(insertion, deletion, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Audio / restart reliability

    private func preferGlassesMicrophone(_ session: AVAudioSession) {
        guard let inputs = session.availableInputs else { return }

        let preferred = inputs.first { input in
            let name = input.portName.lowercased()
            return input.portType == .bluetoothHFP && (
                name.contains("m02") ||
                name.contains("m01") ||
                name.contains("cyan") ||
                name.contains("glasses")
            )
        } ?? inputs.first(where: { $0.portType == .bluetoothHFP })

        if let preferred {
            try? session.setPreferredInput(preferred)
        }
    }

    private func updateInputRoute(_ session: AVAudioSession = .sharedInstance()) {
        if let input = session.currentRoute.inputs.first {
            inputRoute = "\(input.portName) · \(input.portType.rawValue)"
        } else {
            inputRoute = "No audio input"
        }
    }

    private func restartRecognition(after delay: TimeInterval) {
        stopRecognitionOnly()
        scheduleRestart(after: delay)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartTask?.cancel()
        guard enabled, !intentionalStop else { return }

        restartTask = Task { [weak self] in
            let nanos = UInt64(max(delay, 0.08) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.enabled, !self.intentionalStop else { return }
                self.startRecognition()
            }
        }
    }

    private func scheduleHealthyRotation() {
        rotationTask?.cancel()
        guard enabled, !intentionalStop else { return }

        // Speech recognition sessions can become stale during long runs. Rotating before
        // the common one-minute boundary makes background detection more consistent.
        rotationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 48_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.enabled, !self.intentionalStop else { return }
                self.restartRecognition(after: 0.12)
            }
        }
    }

    private func scheduleConfigurationRestart() {
        configurationRestartTask?.cancel()
        guard enabled else { return }
        configurationRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.enabled, !self.intentionalStop else { return }
                self.status = "Applying wake-word settings..."
                self.restartRecognition(after: 0.08)
            }
        }
    }

    private func stopRecognitionOnly() {
        restartTask?.cancel()
        restartTask = nil
        rotationTask?.cancel()
        rotationTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    func stop(deactivateAudio: Bool) {
        configurationRestartTask?.cancel()
        stopRecognitionOnly()
        liveText = ""
        inputRoute = "Not listening"

        if deactivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    @objc private func audioRouteChanged() {
        let session = AVAudioSession.sharedInstance()
        preferGlassesMicrophone(session)
        updateInputRoute(session)

        if enabled, !intentionalStop, !isListening {
            status = "Audio route changed · recovering listener"
            scheduleRestart(after: 0.18)
        }
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            status = "Audio interrupted"
            stopRecognitionOnly()
        case .ended:
            if enabled, !intentionalStop {
                status = "Restarting wake listener..."
                scheduleRestart(after: 0.25)
            }
        @unknown default:
            break
        }
    }

    @objc private func mediaServicesReset() {
        if enabled, !intentionalStop {
            status = "Audio system reset · recovering..."
            scheduleRestart(after: 0.4)
        }
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if available {
                if self.enabled && !self.isListening { self.scheduleRestart(after: 0.15) }
            } else {
                self.status = "Speech recognizer temporarily unavailable"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}
