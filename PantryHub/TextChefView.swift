import SwiftUI

/// Text Chef — the step-by-step cooking chat window.
struct TextChefView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var session: CookingSession
    @State private var input = ""
    @State private var showVoice = false
    @State private var showSteps = false
    @State private var showTimerSetup = false

    init(recipe: Recipe, servings: Int? = nil, children: Int = 0) {
        _session = StateObject(wrappedValue: CookingSession(recipe: recipe, servings: servings, children: children))
    }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                progressBar
                TimerTray(center: session.timerCenter)
                chat
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showTimerSetup) {
            TimerSetupSheet { label, seconds in
                Task { await session.timerCenter.createManual(label: label, seconds: seconds) }
            }
        }
        .task {
            // Give the session a pantry snapshot so the in-cook steps list shows
            // the same amber "short" flag as the detail page (issue c). The voice
            // chef shares this same session, so it's covered too.
            session.pantrySnapshot = store.pantry
            // Propagate chef ledger edits to the shared store so the recipe
            // detail page + daily feed refresh too.
            session.onRecipeEdited = { [weak store] updated in store?.updateRecipeEverywhere(updated) }
            // When a timer rings in text mode, drop a chef note in the chat.
            session.timerCenter.onTimerFired = { t in
                session.messages.append(ChatMessage(role: .chef, text: "⏰ Your **\(t.label)** timer is done!"))
            }
            await session.start()
        }
        .fullScreenCover(isPresented: $showVoice, onDismiss: {
            // Voice and text share one conversation — pull anything that was
            // said by voice into the text transcript so it's continuous.
            // Also re-claim the timer-fired handler (voice had taken it over).
            session.timerCenter.onTimerFired = { t in
                session.messages.append(ChatMessage(role: .chef, text: "⏰ Your **\(t.label)** timer is done!"))
            }
            Task { await session.reload() }
        }) {
            VoiceChefView(session: session, onFinish: finishCooking)
        }
        .sheet(isPresented: $showSteps) {
            StepsSheet(session: session)
        }
    }

    private func finishCooking() {
        Task {
            _ = await session.finish()
            store.saveCooked(session.recipe)
            await store.loadKitchen()    // reflect cooked tab + new pantry levels next view
            showVoice = false
            dismiss()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // fullScreenCover → back arrow per standardized dismiss rule.
            DismissButton(style: .back) { dismiss() }

            ChefIcon(size: 22, color: Theme.paper)

            VStack(alignment: .leading, spacing: 1) {
                Text("AI Chef")
                    .font(.serif(17))
                    .foregroundStyle(Theme.paper)
                Text(session.recipe.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer()

            circleButton("timer") { showTimerSetup = true }
            circleButton("list.bullet") { showSteps = true }
            circleButton("waveform") { showVoice = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
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

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Theme.paper)
                    .frame(width: max(6, geo.size.width * session.progress))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(session.messages) { message in
                        messageBubble(message)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.gap)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.messages.count) {
                withAnimation(.smooth) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 6) {
                if let step = message.stepNumber {
                    Text("STEP \(step)")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.mutedText)
                }
                // Chef messages use **markdown bold** to emphasise quantities
                // and ingredient names; user messages are plain.
                Text(message.role == .chef ? message.text.asInlineMarkdown : AttributedString(message.text))
                    .font(.system(size: 15))
                    .foregroundStyle(message.role == .chef ? Theme.ink : Theme.paper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(alignment: .leading)
            .background {
                if message.role == .chef {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.paper)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                }
            }

            if message.role == .chef { Spacer(minLength: 48) }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            actionButton
            inputRow
        }
        .padding(.horizontal, Theme.gap)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.stage)
    }

    private var actionButton: some View {
        let pending = session.isThinking
        return Button {
            guard !pending else { return }
            if session.isFinished {
                finishCooking()
            } else {
                // Route "done" through the chef so it respects micro-steps
                // (gives the next part of a multi-action step, or marks the
                // step done when it's truly complete) — same logic as voice.
                Task { await session.signalDone() }
            }
        } label: {
            HStack(spacing: 8) {
                if pending {
                    ProgressView().tint(Theme.ink).controlSize(.small)
                } else {
                    Image(systemName: session.isFinished ? "checkmark" : "checkmark.circle")
                }
                Text(pending ? "Thinking…" : (session.isFinished ? "Finish cooking" : "Done — next step"))
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(pending ? Color.white.opacity(0.75) : Theme.paper, in: Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .disabled(pending)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask the chef anything…", text: $input)
                .font(.system(size: 15))
                .foregroundStyle(Theme.paper)
                .tint(Theme.paper)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1)
                )

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.paper))
            }
            .buttonStyle(.plain)
            .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
    }

    private func send() {
        let text = input
        input = ""
        Task { await session.ask(text) }
    }
}

#Preview {
    TextChefView(recipe: .preview)
        .environmentObject(AppStore())
}
