import Foundation
import AVFoundation

/// Live-voice client for Voice Chef.
/// Bridges the iOS mic & speaker to the voice-chef WebSocket proxy.
///
/// Flow:
///   - Capture mic at 48kHz Float32 → resample to 16kHz Int16 → base64 → send.
///   - Receive base64 24kHz Int16 → schedule on AVAudioPlayerNode → play.
///   - Transcripts (in & out) update @Published properties for the UI.
///
/// Hard-wired for the demo-user / current cook_session_id flow.
@MainActor
final class VoiceChefClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    enum State: Equatable {
        case idle
        case connecting        // opened client WS, waiting for upstream
        case settingUp         // upstream WS open, sent setup, waiting for setupComplete
        case ready             // upstream ready, audio flowing both ways
        case error(String)
        case closed(String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastUserTranscript = ""
    @Published private(set) var lastChefTranscript = ""
    /// Mic permission result (nil = unknown / not yet checked).
    @Published private(set) var micGranted: Bool? = nil
    @Published private(set) var isUserSpeaking = false   // crude: true while we have recent mic activity
    @Published private(set) var isChefSpeaking = false   // true while we're playing model audio
    /// Smoothed amplitude 0…1, max of chef-out RMS and mic-in RMS. The
    /// Voice Chef waveform is driven by this so it reacts to whoever's
    /// actually making sound. Decays to 0 when silent.
    @Published private(set) var audioLevel: Float = 0

    /// Called when the voice server pushes a `ledger_updated` frame after a
    /// chef tool call (recipe edit, mark-step-done, etc.). The host view
    /// applies it to the shared CookingSession so every screen refreshes.
    /// Any field may be nil — caller passes whatever the server included.
    var onLedgerUpdated: ((_ ingredients: [BackendIngredient]?,
                           _ steps: [String]?,
                           _ currentStep: Int?,
                           _ doneStepIdxs: [Int]?) -> Void)?

    /// Called when the voice chef creates/cancels a timer (server `timers_updated`).
    var onTimersUpdated: (([BackendTimer]) -> Void)?

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var decayTimer: Timer?

    // Audio
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    /// AVAudioPlayerNode is happiest with Float32 non-interleaved buffers.
    /// We convert the int16 PCM Gemini sends into this format.
    private let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                             channels: 1, interleaved: false)!
    private let inputTargetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                  channels: 1, interleaved: true)!
    private var micEnabled = false
    private var lastAudioOutAt: Date?
    private var firstChefAudioLogged = false
    /// True once Apple's voice-processing (echo cancellation) is active. When
    /// on, the mic can stay open while the chef speaks (so the user can
    /// interrupt/barge-in) without the chef hearing itself. When off, we fall
    /// back to half-duplex (mic muted while the chef speaks).
    private var voiceProcessingEnabled = false
    /// Estimated wall-clock time the currently-queued chef audio finishes
    /// playing. Used by half-duplex to mute the mic for the full spoken
    /// duration (audio arrives faster than it plays, so arrival time isn't
    /// enough). nil when the chef isn't speaking.
    private var playbackEndsAt: Date?

    /// Barge-in (talking over the chef) needs real hardware echo cancellation,
    /// which the iOS Simulator can't do — so it's disabled for now. Flip to
    /// `true` once testing on a physical device to allow interruptions.
    private let allowBargeIn = false

    // MARK: Public

    /// Connect to the voice-chef WS and start streaming. Idempotent.
    func connect(cookSessionID: UUID) {
        // Allow connect when idle or after any closed state.
        switch state { case .idle, .closed: break; default: return }
        state = .connecting

        do { try configureSession() } catch {
            state = .error("audio session: \(error.localizedDescription)"); return
        }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session

        var req = URLRequest(url: BackendConfig.voiceChefWS(cookSessionID: cookSessionID))
        req.setValue("Bearer \(BackendConfig.anonKey)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        self.ws = ws
        ws.resume()
        receiveLoop()
    }

    /// Tear everything down.
    func disconnect() {
        sendClientFrame(["type": "close"])
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        stopAudio()
        decayTimer?.invalidate()
        decayTimer = nil
        audioLevel = 0
        state = .closed(nil)
    }

    /// Smoothly fade audioLevel toward 0 when no new audio arrives.
    /// Runs at ~20Hz; cheap.
    private func startDecayLoop() {
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.audioLevel > 0.001 {
                    self.audioLevel *= 0.82
                } else {
                    self.audioLevel = 0
                }
            }
        }
    }

    /// Push a fresh raw amplitude into the smoothed audioLevel.
    private func bumpLevel(_ raw: Float) {
        Task { @MainActor in
            // Take the higher of the new sample and the slow-decayed previous one
            // so peaks pop but silence still fades quickly.
            self.audioLevel = max(self.audioLevel, min(1.0, raw))
        }
    }

    /// RMS amplitude of a chunk of signed 16-bit little-endian PCM samples.
    /// Returns 0…1. Scales up so typical speech sits around 0.4–0.8.
    private static func rmsInt16(_ bytes: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Double = 0
        for i in 0..<count {
            let v = Double(bytes[i]) / 32768.0
            sum += v * v
        }
        let rms = (sum / Double(count)).squareRoot()
        return Float(min(1.0, max(0.0, rms * 5.0)))
    }

    /// RMS for a float32 AVAudioPCMBuffer (mic input lives in float).
    private static func rmsFloat(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Double = 0
        for i in 0..<n {
            let v = Double(ch[0][i])
            sum += v * v
        }
        let rms = (sum / Double(n)).squareRoot()
        return Float(min(1.0, max(0.0, rms * 5.0)))
    }

    // MARK: Audio session

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        // .default mode applies NO signal processing — most reliable for
        // simulator playback. .voiceChat ducks/mutes when it thinks no one
        // is speaking, which on simulator (where mic input is silent or
        // odd) can permanently mute the chef voice output.
        try s.setCategory(.playAndRecord,
                          mode: .default,
                          options: [.defaultToSpeaker])
        try s.setActive(true, options: [])
        let route = s.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        print("[voice-chef] audio session active. sampleRate=\(s.sampleRate) mode=default output=[\(route)]")
    }

    private func startAudio() throws {
        // Output path (always wired so we can hear the chef even if mic fails).
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playerFormat)

        // Input path — best-effort. On simulators without a mic, or when
        // permission isn't granted, just skip it and run output-only.
        let inputNode = engine.inputNode
        // Enable Apple's voice-processing I/O (acoustic echo cancellation +
        // noise suppression) BEFORE reading the input format. With the chef's
        // voice cancelled out of the mic, we can leave the mic open while it
        // speaks, so the user can interrupt it (barge-in) — Gemini's VAD hears
        // the user and stops the model. Must be set before the engine starts.
        // Barge-in is OFF for now (see `allowBargeIn`). Half-duplex everywhere
        // — the mic is muted while the chef speaks, so the chef can't hear
        // itself loop. To enable interruption on a real device later, flip
        // `allowBargeIn = true` and rebuild.
        if allowBargeIn {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
                print("[voice-chef] echo cancellation ON — barge-in enabled")
            } catch {
                voiceProcessingEnabled = false
                print("[voice-chef] voice processing unavailable (\(error.localizedDescription)); half-duplex fallback")
            }
        } else {
            voiceProcessingEnabled = false
            print("[voice-chef] half-duplex mode (no barge-in)")
        }
        let hwFormat = inputNode.outputFormat(forBus: 0)
        if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
            converter = AVAudioConverter(from: hwFormat, to: inputTargetFormat)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
            micEnabled = true
            print("[voice-chef] mic enabled at \(hwFormat.sampleRate)Hz x\(hwFormat.channelCount)ch")
        } else {
            micEnabled = false
            print("[voice-chef] mic unavailable — running playback-only (simulator?)")
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
        startDecayLoop()
        print("[voice-chef] engine running. playerNode=\(playerNode.isPlaying)")
    }

    private func stopAudio() {
        if micEnabled { engine.inputNode.removeTap(onBus: 0) }
        micEnabled = false
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Mic → WS

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let ws = ws, ws.state == .running else { return }

        // Half-duplex echo guard — when echo cancellation isn't in play, mute
        // the mic for the full SPOKEN duration of the chef's queued audio
        // (audio frames arrive from the server far faster than they play out
        // the speaker, so we have to look at when playback actually finishes —
        // not when the last frame arrived).
        if !voiceProcessingEnabled, let ends = playbackEndsAt,
           Date() < ends.addingTimeInterval(0.35) { return }

        // Feed the waveform with the mic's amplitude before we encode it.
        bumpLevel(Self.rmsFloat(buffer))

        let frames = AVAudioFrameCount(
            Double(buffer.frameLength) * inputTargetFormat.sampleRate / buffer.format.sampleRate
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: inputTargetFormat, frameCapacity: max(frames, 320)) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, status in
            // IMPORTANT: signal `.noDataNow` (not `.endOfStream`) when this
            // buffer is exhausted. `.endOfStream` *finalizes* the converter, so
            // only the first buffer would ever convert and every later one came
            // back empty — silencing the mic. `.noDataNow` keeps it alive for
            // continuous streaming.
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let int16 = out.int16ChannelData else { return }

        let byteCount = Int(out.frameLength) * 2
        let data = Data(bytes: int16[0], count: byteCount)
        let b64 = data.base64EncodedString()
        sendClientFrame(["type": "audio", "data": b64])
    }

    // MARK: WS RX

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                Task { @MainActor in self.handleServerMessage(message) }
                self.receiveLoop()
            case .failure(let err):
                Task { @MainActor in
                    self.state = .error(err.localizedDescription)
                }
            }
        }
    }

    private func handleServerMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        switch type {
        case "status":
            // Phase progression from the proxy: "connecting_upstream",
            // "upstream_open_sending_setup". Useful only to keep the user UI
            // showing what's happening.
            let phase = (json["phase"] as? String) ?? ""
            if phase == "upstream_open_sending_setup" {
                state = .settingUp
            }
        case "ready":
            print("[voice-chef] STATE → ready (Gemini setup complete)")
            state = .ready
            do {
                try startAudio()
                print("[voice-chef] startAudio() returned cleanly")
            } catch {
                print("[voice-chef] startAudio() THREW: \(error.localizedDescription)")
                state = .error("audio start failed: \(error.localizedDescription)")
            }
        case "audio":
            if let b64 = json["data"] as? String { playChefAudio(base64: b64) }
        case "transcript_in":
            if let t = json["text"] as? String { lastUserTranscript = t; isUserSpeaking = true }
        case "transcript_out":
            if let t = json["text"] as? String { lastChefTranscript = t }
        case "ledger_updated":
            // Voice server pushed the post-mutation state — could be a recipe
            // edit, a step-nav move, or both. Forward whatever's present.
            let ings: [BackendIngredient]? = {
                guard let raw = json["ingredients"],
                      let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                return try? JSONDecoder().decode([BackendIngredient].self, from: data)
            }()
            let steps = json["steps"] as? [String]
            let cur = json["current_step"] as? Int
            let done = json["done_step_idxs"] as? [Int]
            onLedgerUpdated?(ings, steps, cur, done)
        case "timers_updated":
            if let raw = json["timers"],
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let timers = try? JSONDecoder().decode([BackendTimer].self, from: data) {
                onTimersUpdated?(timers)
            }
        case "turn_complete":
            isUserSpeaking = false
        case "interrupted":
            // User barged in — Gemini cancelled its generation. Drop any
            // queued chef audio immediately so it goes quiet, and reset the
            // playback marker so the mic is unblocked right away.
            playerNode.stop()
            playerNode.play()
            isChefSpeaking = false
            lastAudioOutAt = nil
            playbackEndsAt = nil
        case "error":
            state = .error((json["message"] as? String) ?? "unknown error")
        case "closed":
            let msg = (json["message"] as? String) ?? (json["reason"] as? String)
            state = .closed(msg)
        default: break
        }
    }

    // MARK: Audio out

    private func playChefAudio(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatChannel = buffer.floatChannelData else {
            print("[voice-chef] could not allocate playback buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            // Convert int16 LE (Gemini) → float32 [-1, 1] (AVAudioPlayerNode happy place).
            let dst = floatChannel[0]
            for i in 0..<sampleCount {
                dst[i] = Float(src[i]) / 32768.0
            }
            self.bumpLevel(Self.rmsInt16(src, count: sampleCount))
        }

        // Make sure the engine + player are actually running.
        if !engine.isRunning {
            try? engine.start()
            print("[voice-chef] re-started engine for playback")
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }

        // Log the first audio frame once so we can prove playback is firing.
        if !firstChefAudioLogged {
            firstChefAudioLogged = true
            print("[voice-chef] 🔊 FIRST CHEF AUDIO FRAME — \(sampleCount) samples, engine.running=\(engine.isRunning), player.isPlaying=\(playerNode.isPlaying)")
        }

        isChefSpeaking = true
        lastAudioOutAt = Date()
        // Extend the "chef is speaking" window by this chunk's spoken duration
        // (samples ÷ 24kHz). Half-duplex uses this to keep the mic muted until
        // the chef has actually finished talking — not just finished sending.
        let chunkSeconds = Double(sampleCount) / 24_000.0
        let now = Date()
        let extendFrom = (playbackEndsAt.map { $0 > now ? $0 : now }) ?? now
        playbackEndsAt = extendFrom.addingTimeInterval(chunkSeconds)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let ends = self.playbackEndsAt, Date() >= ends.addingTimeInterval(-0.05) {
                    self.isChefSpeaking = false
                    self.playbackEndsAt = nil
                }
            }
        }
    }

    // MARK: WS TX

    /// Send a UI control event (Done button, checklist) to the live voice chef
    /// so it reacts (advances a micro-action, marks a step done, etc.) and
    /// stays the single driver of progress.
    func sendControl(_ event: String, stepNumber: Int? = nil, done: Bool? = nil, label: String? = nil) {
        var frame: [String: Any] = ["type": "control", "event": event]
        if let s = stepNumber { frame["step_number"] = s }
        if let d = done { frame["done"] = d }
        if let l = label { frame["label"] = l }
        sendClientFrame(frame)
    }

    /// Re-ground the live chef on the authoritative current step after a manual
    /// checklist change (the checklist is the source of truth).
    func sendStepSync(stepNumber: Int, total: Int, text: String) {
        sendClientFrame(["type": "control", "event": "step_sync",
                         "step_number": stepNumber, "total_steps": total, "step_text": text])
    }

    /// Push a live timer snapshot (label + seconds remaining) so the chef knows
    /// exactly how long is left.
    func sendTimerState(_ timers: [(label: String, secondsLeft: Int)]) {
        let arr = timers.map { ["label": $0.label, "seconds_left": $0.secondsLeft] as [String: Any] }
        sendClientFrame(["type": "control", "event": "timers", "timers": arr])
    }

    private func sendClientFrame(_ obj: [String: Any]) {
        guard let ws = ws, ws.state == .running,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(str)) { _ in }
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        // Server will send {type:"ready"} when upstream Gemini is set up.
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in self.state = .closed(nil) }
    }
}
