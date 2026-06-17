import SwiftUI

/// Voice Chef — a focused voice-mode screen with an animated waveform.
/// The steps list can be toggled open from the top-right icon.
struct VoiceChefView: View {
    @ObservedObject var session: CookingSession
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = VoiceChefClient()
    @State private var showSteps = false
    @State private var showTimerSetup = false

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            // Content is anchored to the TOP, just below the timer tray, with a
            // small constant gap. The tray itself grows downward as more timers
            // are added (pushing the content down) — but the gap between the
            // last timer and the steps stays tight. The flexible space sits
            // BELOW the content, above the Done button.
            VStack(spacing: 0) {
                topBar
                TimerTray(center: session.timerCenter, axis: .vertical)
                center
                    .padding(.top, 22)
                Spacer(minLength: 12)
                doneButton
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTimerSetup) {
            TimerSetupSheet { label, seconds in
                Task { await session.timerCenter.createManual(label: label, seconds: seconds) }
            }
        }
        .task {
            // Voice chef rides on the cook session created by Text Chef.
            // If TextChefView hasn't started yet, start now.
            if session.cookSessionID == nil { await session.start() }
            // Apply voice-driven recipe edits AND step-pointer moves to the
            // shared session, which also propagates the recipe to the store
            // via onRecipeEdited so the detail page + feed refresh too.
            voice.onLedgerUpdated = { ings, steps, cur, done in
                session.applyLedgerEdit(ingredients: ings, steps: steps,
                                        currentStep: cur, doneStepIdxs: done)
            }
            // A manual checklist change while voice is live → re-ground the chef
            // on the AUTHORITATIVE current step (checklist is the source of truth).
            session.onStepToggledExternally = { _, _ in
                voice.sendStepSync(stepNumber: session.currentStep + 1,
                                   total: session.totalSteps,
                                   text: session.currentStepText)
            }
            // Voice chef created/cancelled a timer → reflect on the shared cards.
            voice.onTimersUpdated = { timers in session.timerCenter.apply(timers) }
            // Any timer change → push a live snapshot so the chef knows exactly
            // what's running and how long is left.
            session.timerCenter.onTimersChanged = { timers in
                let now = Date()
                voice.sendTimerState(timers.map { (label: $0.label, secondsLeft: Int($0.remaining(at: now).rounded())) })
            }
            // A timer ringing → have the live chef announce it out loud.
            session.timerCenter.onTimerFired = { t in voice.sendControl("timer_fired", label: t.label) }
            if let cookID = session.cookSessionID, let uuid = UUID(uuidString: cookID) {
                voice.connect(cookSessionID: uuid)
            }
        }
        .onDisappear {
            session.onStepToggledExternally = nil
            session.timerCenter.onTimersChanged = nil
            voice.disconnect()
        }
        .sheet(isPresented: $showSteps) {
            StepsSheet(session: session)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            circleButton("chevron.left") { dismiss() }
            Spacer()
            HStack(spacing: 8) {
                ChefIcon(size: 22, color: Theme.paper)
                Text("AI Chef")
                    .font(.serif(18))
                    .foregroundStyle(Theme.paper)
            }
            Spacer()
            HStack(spacing: 8) {
                circleButton("timer") { showTimerSetup = true }
                circleButton("list.bullet") { showSteps = true }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Center (waveform + current step)

    private var center: some View {
        VStack(spacing: 22) {
            WaveformView(level: Double(voice.audioLevel),
                         active: voice.state == .ready || voice.isChefSpeaking || voice.isUserSpeaking)
                .frame(height: 92)
                .padding(.horizontal, 36)

            Text(voiceStatusLine)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Color.white.opacity(0.5))

            if session.isFinished {
                Text("Your \(session.recipe.name) is ready.")
                    .font(.serif(22))
                    .foregroundStyle(Theme.paper)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            } else {
                stepsStack
                    .padding(.horizontal, 24)
                    // Barrel-roll: spring-driven layout shift + per-row rotation
                    // on insert/remove (see stepLine transition modifier).
                    .animation(.interpolatingSpring(stiffness: 160, damping: 16),
                               value: session.currentStep)
            }

            if !voice.lastUserTranscript.isEmpty {
                Text("\u{201C}\(voice.lastUserTranscript)\u{201D}")
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.top, 4)
                    .padding(.horizontal, 30)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// 5-line stack — up to 2 steps before, the current step (large), up to 2 after.
    /// Rows roll in from below / out to above as the current step advances.
    private var stepsStack: some View {
        let total = session.totalSteps
        let current = session.currentStep
        guard total > 0 else { return AnyView(EmptyView()) }
        let start = max(0, current - 2)
        let end = min(total - 1, current + 2)
        return AnyView(
            VStack(spacing: 18) {
                ForEach(start...end, id: \.self) { idx in
                    stepLine(idx: idx, current: current)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.85, anchor: .center)),
                            removal: .move(edge: .top)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.85, anchor: .center))
                        ))
                        .rotation3DEffect(
                            // Subtle tilt away from the user for non-current rows
                            // — a barrel-roll cue without being garish.
                            .degrees(idx == current ? 0 : (idx < current ? -10 : 10)),
                            axis: (x: 1, y: 0, z: 0),
                            anchor: .center,
                            perspective: 0.6
                        )
                }
            }
        )
    }

    private func stepLine(idx: Int, current: Int) -> some View {
        // Scale {{...}} ingredient-amount tokens to the cook's chosen servings
        // (times/temps stay put), matching the recipe page + steps sheet.
        let rawStep = idx < session.recipe.steps.count ? session.recipe.steps[idx] : ""
        let stepText = Formatting.scaleStepTokens(rawStep, factor: session.effectiveServings / Double(max(1, session.recipe.servings)), bold: true)
        let isCurrent = idx == current
        let offset = abs(idx - current)
        let opacity: Double = isCurrent ? 1.0 : (offset == 1 ? 0.55 : 0.28)
        let bodyFont: Font = isCurrent ? .serif(20) : (offset == 1 ? .system(size: 13) : .system(size: 11))
        let limit: Int? = isCurrent ? nil : (offset == 1 ? 2 : 1)

        return HStack(alignment: .top, spacing: 10) {
            Text("\(idx + 1)")
                .font(.system(size: isCurrent ? 13 : 11, weight: .semibold))
                .foregroundStyle(Theme.paper.opacity(opacity * 0.65))
                .frame(width: 18, alignment: .trailing)
                .padding(.top, isCurrent ? 6 : 2)
            Text(stepText.asInlineMarkdown)
                .font(bodyFont)
                .foregroundStyle(Theme.paper.opacity(opacity))
                .multilineTextAlignment(.leading)
                .lineLimit(limit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var voiceStatusLine: String {
        switch voice.state {
        case .idle:        return "AI CHEF — VOICE"
        case .connecting:  return "CONNECTING…"
        case .settingUp:   return "WAKING UP AI CHEF…"
        case .ready:       return session.isFinished ? "ALL DONE" : "STEP \(session.currentStep + 1) OF \(session.totalSteps)"
        case .error(let m): return "ERROR — \(String(m.prefix(60)))"
        case .closed(let r): return r != nil ? "DISCONNECTED — \(String(r!.prefix(50)))" : "DISCONNECTED"
        }
    }

    // MARK: Done button

    private var doneButton: some View {
        Button {
            if session.isFinished {
                onFinish()
            } else {
                // Tell the LIVE voice chef the user is done — she decides whether
                // there's another micro-action in this step or it's time to mark
                // the step done and move on. Keeps voice as the single driver.
                voice.sendControl("done")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: session.isFinished ? "checkmark" : "checkmark.circle")
                Text(session.isFinished ? "Finish cooking" : "Done — next step")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.paper, in: Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

}

// MARK: - Waveform

/// Voice waveform driven by real audio amplitude.
/// `level` (0…1) is the live RMS coming from the VoiceChefClient — bars
/// scale up with whoever is talking. When silent, they collapse to a thin idle line.
struct WaveformView: View {
    var level: Double = 0
    var active: Bool = true
    private let barCount = 28

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Theme.paper)
                        .frame(width: 5, height: barHeight(index: index, time: t))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.12), value: level)
    }

    private func barHeight(index: Int, time: Double) -> Double {
        let phase = Double(index) * 0.55
        let wave = (sin(time * 3.2 + phase) + 1) / 2 // 0…1
        let envelope = sin(Double(index) / Double(barCount - 1) * .pi)
        // Idle = thin line. Speech = scale with RMS level.
        let amplitude = active ? max(0.08, min(1.0, level * 1.15)) : 0.05
        return 4 + (wave * 0.55 + 0.45) * envelope * 82 * amplitude
    }
}

#Preview {
    VoiceChefView(session: CookingSession(recipe: .preview),
                  onFinish: {})
        .environmentObject(AppStore())
}
