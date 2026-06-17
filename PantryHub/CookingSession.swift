import Foundation
import SwiftUI

/// One message in the cooking chat (text or voice transcript).
struct ChatMessage: Identifiable, Hashable {
    enum Role { case chef, user }
    let id = UUID()
    let role: Role
    let text: String
    var stepNumber: Int? = nil
}

/// Backend-driven cooking session. Wraps the text-chef edge function.
/// Both TextChefView and VoiceChefView observe the same instance so step
/// state stays in sync across screens.
@MainActor
final class CookingSession: ObservableObject {
    /// The recipe being cooked. Published so that when the chef edits the
    /// ledger (ingredients/steps), every screen reading `session.recipe`
    /// — text chef, voice chef, and the steps sheet — refreshes live.
    @Published var recipe: Recipe

    /// Set by the hosting view so ledger edits also propagate to the shared
    /// store (so the recipe detail page + daily feed reflect the change).
    var onRecipeEdited: ((Recipe) -> Void)?

    /// Set by VoiceChefView while the voice chef is live. When the user toggles
    /// a step on the checklist, we notify the live voice chef so it stays in
    /// sync (the text chef sees the change in its context on its next turn).
    /// Params: (stepIndex0Based, nowDone).
    var onStepToggledExternally: ((Int, Bool) -> Void)?
    /// Adults cooking for (each = 1 full portion). Defaults to the recipe base;
    /// the detail page can override before cooking.
    var cookedServings: Int
    /// Children cooking for (each = ½ portion).
    var cookedChildren: Int = 0
    /// Effective portions = adults + ½·children.
    var effectiveServings: Double { Double(cookedServings) + 0.5 * Double(cookedChildren) }

    /// A snapshot of the user's pantry, set by the hosting chef view so the
    /// in-cook steps list can show the SAME amber "short ~X" flag as the recipe
    /// detail page (issue c). Empty when unknown → no flag shown (graceful).
    @Published var pantrySnapshot: [PantryItem] = []

    @Published var messages: [ChatMessage] = []
    @Published var currentStep: Int = 0
    @Published var totalSteps: Int
    @Published var doneStepIdxs: Set<Int> = []
    @Published var isFinished = false
    @Published var isThinking = false
    @Published var errorMessage: String?
    @Published private(set) var didResume = false

    /// Server-side ids returned by the text-chef "start" action.
    @Published private(set) var cookSessionID: String?
    @Published private(set) var chatSessionID: String?

    /// In-app cooking timers for this cook session — shared by the text and
    /// voice screens (both observe this same instance).
    let timerCenter = TimerCenter()

    init(recipe: Recipe, servings: Int? = nil, children: Int = 0) {
        self.recipe = recipe
        self.totalSteps = recipe.steps.count
        self.cookedServings = max(1, servings ?? recipe.servings)
        self.cookedChildren = max(0, children)
    }

    // MARK: Derived

    var isLastStep: Bool { currentStep >= totalSteps - 1 }
    var currentStepText: String {
        guard !recipe.steps.isEmpty, currentStep < recipe.steps.count else { return "" }
        return recipe.steps[currentStep]
    }
    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        if isFinished { return 1 }
        return Double(currentStep + 1) / Double(totalSteps)
    }

    // MARK: Lifecycle

    /// Kick off the cook session on the backend.
    /// First tries to RESUME an existing active session for this user+recipe.
    /// Only creates a fresh session if none exists.
    /// Idempotent — calling twice does nothing after the first start.
    func start() async {
        guard cookSessionID == nil else { return }
        isThinking = true
        errorMessage = nil
        do {
            // 1. Try to resume an in-flight session first.
            let resume = try await TextChefService.shared.resume(recipeID: recipe.id)
            if resume.found, let cookID = resume.cook_session_id {
                cookSessionID = cookID
                chatSessionID = resume.chat_session_id
                currentStep = resume.current_step ?? 0
                totalSteps = resume.total_steps ?? recipe.steps.count
                doneStepIdxs = Set(resume.done_step_idxs ?? [])
                cookedServings = resume.cooked_servings ?? cookedServings
                cookedChildren = resume.cooked_children ?? cookedChildren
                isFinished = resume.is_finished ?? (currentStep >= totalSteps)
                messages = reconstructMessages(from: resume.messages ?? [], welcomeBack: true)
                didResume = true
            } else {
                // 2. No active session — start a fresh one.
                let resp = try await TextChefService.shared.start(recipeID: recipe.id, servings: cookedServings, children: cookedChildren)
                cookSessionID = resp.cook_session_id
                chatSessionID = resp.chat_session_id
                currentStep = resp.current_step
                totalSteps = resp.total_steps
                doneStepIdxs = []
                isFinished = false
                messages = [
                    ChatMessage(role: .chef, text: resp.message, stepNumber: currentStep + 1),
                ]
                didResume = false
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Bind + load any timers already running for this session.
        if let id = cookSessionID {
            timerCenter.bind(cookSessionID: id)
            await timerCenter.refresh()
        }
        isThinking = false
    }

    /// Turn the backend-side chat history into UI messages.
    /// `welcomeBack` prepends a "picking up where you left off" banner (used
    /// when resuming a session); omit it for a silent refresh.
    private func reconstructMessages(from history: [TextChefResumeResponse.ChatMsg],
                                     welcomeBack: Bool) -> [ChatMessage] {
        var out: [ChatMessage] = welcomeBack
            ? [ChatMessage(role: .chef,
                           text: "Welcome back — picking up at step \(currentStep + 1).",
                           stepNumber: currentStep + 1)]
            : []
        for m in history {
            guard let txt = m.text, !txt.isEmpty else { continue }
            let role: ChatMessage.Role = (m.role == "model") ? .chef : .user
            out.append(ChatMessage(role: role, text: txt))
        }
        return out
    }

    /// Re-pull the shared conversation + progress from the backend. Used when
    /// returning from the voice chef so the text transcript shows what was said
    /// by voice (both chefs share one session). Silent — no "welcome back".
    func reload() async {
        do {
            let r = try await TextChefService.shared.resume(recipeID: recipe.id)
            guard r.found else { return }
            if let c = r.current_step { currentStep = c }
            if let t = r.total_steps  { totalSteps = t }
            if let d = r.done_step_idxs { doneStepIdxs = Set(d) }
            isFinished = r.is_finished ?? (currentStep >= totalSteps)
            messages = reconstructMessages(from: r.messages ?? [], welcomeBack: false)
            await timerCenter.refresh()   // pick up timers set during voice
        } catch {
            // Soft-fail: keep what we have.
        }
    }

    /// Toggle a step's done state from the StepsSheet checklist.
    /// Server adjusts current_step accordingly.
    func toggleStep(_ idx: Int) async {
        guard let cookID = cookSessionID else { return }
        // Optimistic UI
        if doneStepIdxs.contains(idx) {
            doneStepIdxs.remove(idx)
            if idx < currentStep { currentStep = idx }
        } else {
            doneStepIdxs.insert(idx)
            if idx == currentStep { currentStep = min(idx + 1, totalSteps) }
        }
        do {
            let resp = try await TextChefService.shared.toggleStep(cookSessionID: cookID, stepIdx: idx)
            currentStep = resp.current_step
            totalSteps = resp.total_steps
            doneStepIdxs = Set(resp.done_step_idxs)
            if currentStep >= totalSteps { isFinished = true }
            // Keep the live voice chef (if any) in sync with the manual toggle.
            onStepToggledExternally?(idx, resp.now_done)
        } catch {
            // Soft-fail; optimistic state stands.
        }
    }

    /// Push a mid-cook servings change to the backend. Cheap, fire-and-forget.
    func updateServings(adults: Int, children: Int) async {
        guard let cookID = cookSessionID else { return }
        cookedServings = max(1, min(20, adults))
        cookedChildren = max(0, min(20, children))
        try? await TextChefService.shared.updateServings(cookSessionID: cookID, servings: cookedServings, children: cookedChildren)
    }

    /// User typed a question or comment.
    func ask(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let cookID = cookSessionID else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true
        do {
            let resp = try await TextChefService.shared.send(cookSessionID: cookID, text: trimmed)
            messages.append(ChatMessage(role: .chef, text: resp.message))
            // Apply WHATEVER state the server returned — recipe edits and/or
            // session-pointer moves. The chef may have called step-nav tools
            // even without editing the recipe.
            applyLedgerEdit(ingredients: resp.ingredients,
                            steps: resp.steps,
                            currentStep: resp.current_step,
                            doneStepIdxs: resp.done_step_idxs)
            if let timers = resp.timers { timerCenter.apply(timers) }
        } catch {
            messages.append(ChatMessage(role: .chef, text: "Sorry, I had trouble responding. Try again?"))
        }
        isThinking = false
    }

    /// The "Done — next step" button (text mode). Routes through the chef so it
    /// decides micro-action-vs-main-step (it calls mark_step_done only when the
    /// whole step is complete) — instead of a blind pointer increment.
    func signalDone() async {
        await ask("Done — what's next?")
    }

    /// Apply a unified post-mutation snapshot from the ledger / chef response
    /// to the live recipe AND the session pointer. Any field is optional —
    /// caller passes whatever the server returned. Refreshes every screen and
    /// propagates the recipe to the shared store so the detail page + feed
    /// also see the change.
    func applyLedgerEdit(
        ingredients: [BackendIngredient]? = nil,
        steps: [String]? = nil,
        currentStep newCurrent: Int? = nil,
        doneStepIdxs newDone: [Int]? = nil
    ) {
        var recipeChanged = false
        if let ings = ingredients {
            recipe.ingredients = ings.map { $0.toAppIngredient() }
            recipeChanged = true
        }
        if let st = steps {
            recipe.steps = st
            totalSteps = st.count
            if currentStep > st.count { currentStep = st.count }
            recipeChanged = true
        }
        // Session pointer: chef-driven step navigation (mark_step_done, etc.)
        // flows in via these fields. Clamp to valid range as a defense.
        if let d = newDone { doneStepIdxs = Set(d) }
        if let c = newCurrent {
            currentStep = max(0, min(c, totalSteps))
            if currentStep >= totalSteps { isFinished = true }
        }
        if recipeChanged { onRecipeEdited?(recipe) }
    }

    /// Advance to next step (or back). Server picks the chef's transition line.
    func advance(direction: String = "next") async {
        guard let cookID = cookSessionID else { return }
        if isFinished, direction == "next" { return }
        isThinking = true
        do {
            let resp = try await TextChefService.shared.advance(cookSessionID: cookID, direction: direction)
            // Single unified apply — handles both recipe edits and the
            // server-authoritative session pointer.
            applyLedgerEdit(ingredients: resp.ingredients,
                            steps: resp.steps,
                            currentStep: resp.current_step,
                            doneStepIdxs: resp.done_step_idxs)
            if let t = resp.total_steps { totalSteps = t }
            if let timers = resp.timers { timerCenter.apply(timers) }
            messages.append(ChatMessage(role: .chef, text: resp.message,
                                        stepNumber: currentStep < totalSteps ? currentStep + 1 : nil))
        } catch {
            messages.append(ChatMessage(role: .chef, text: "Couldn't move on — give it another tap?"))
        }
        isThinking = false
    }

    /// Mark finished. Triggers backend pantry deduction + cooked log.
    /// Returns the deduction summary so the caller can show a sheet if desired.
    @discardableResult
    func finish() async -> TextChefFinishResponse? {
        guard let cookID = cookSessionID else { return nil }
        isThinking = true
        defer { isThinking = false }
        do {
            let resp = try await TextChefService.shared.finish(cookSessionID: cookID)
            isFinished = true
            return resp
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }
}
