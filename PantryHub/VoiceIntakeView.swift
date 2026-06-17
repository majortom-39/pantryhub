import SwiftUI
import Speech
import AVFoundation

/// The voice door: the user reads out their groceries and sees the words appear
/// live, like a note. On "Done" the raw transcript goes to the backend, which
/// cleans up spelling, splits it into items and fills in details — then they all
/// land in the same review list, ready to confirm.
struct VoiceIntakeView: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String) -> Void

    @StateObject private var speech = SpeechTranscriber()

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                noteCard
                micControl
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { if !speech.transcript.isEmpty { doneButton } }
        .onAppear { speech.start() }
        .onDisappear { speech.stop() }
    }

    private var topBar: some View {
        HStack {
            DismissButton(style: .back) { dismiss() }
            Spacer()
            Text("Say what you've got").font(.serif(19)).foregroundStyle(Theme.paper)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Split the running transcript into a rough item list (on commas / "and"),
    /// so it reads as a tidy list while speaking rather than one long blob.
    private var dictatedItems: [String] {
        speech.transcript
            .replacingOccurrences(of: " and ", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var noteCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = speech.errorMessage {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.mutedText)
                } else if speech.transcript.isEmpty {
                    Text("Try: “two onions, a litre of milk, half a kilo of rice, a dozen eggs…”")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.mutedText)
                } else {
                    ForEach(dictatedItems.indices, id: \.self) { i in
                        dictatedRow(dictatedItems[i])
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Fill the whole space between the bar and the mic — no more half-screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .whiteCard()
        .padding(.horizontal, Theme.gap)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func dictatedRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Theme.ink.opacity(0.4)).frame(width: 6, height: 6).padding(.top, 9)
            Text(item)
                .font(.serif(19))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var micControl: some View {
        VStack(spacing: 10) {
            Button {
                if speech.isRecording { speech.stop() } else { speech.start() }
            } label: {
                ZStack {
                    Circle()
                        .fill(speech.isRecording ? Theme.alertRed : Theme.paper)
                        .frame(width: 76, height: 76)
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(speech.isRecording ? Theme.paper : Theme.ink)
                }
            }
            .buttonStyle(PressableCardStyle())
            Text(speech.isRecording ? "Listening… tap to pause" : "Tap to talk")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(.bottom, 24)
    }

    private var doneButton: some View {
        Button {
            speech.stop()
            onSubmit(speech.transcript)
        } label: {
            Text("Done — add these")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.paper, in: Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .padding(.horizontal, Theme.gap)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.stage)
    }
}

// MARK: - Live speech-to-text

/// Wraps Apple's on-device speech recognition into a simple observable note.
@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    /// Text committed from earlier recording segments — new partial results are
    /// appended to this so pausing/resuming never loses what was already said.
    private var base = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Allow Speech Recognition in Settings to use voice."
                    return
                }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Voice isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            // Capture the request locally — the audio tap runs off the main
            // actor, and `append` is safe to call from that thread.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            errorMessage = nil
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let live = result.bestTranscription.formattedString
                        self.transcript = self.base.isEmpty ? live : "\(self.base) \(live)"
                    }
                    if error != nil || (result?.isFinal ?? false) { self.stop() }
                }
            }
        } catch {
            errorMessage = "Couldn't start the microphone."
            stop()
        }
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }
        // Commit what we have so a later resume APPENDS instead of overwriting
        // (each new recognition session otherwise replaces the transcript).
        base = transcript
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
