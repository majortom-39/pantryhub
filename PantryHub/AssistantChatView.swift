import SwiftUI

/// General "Ask Chef for a recipe" — opened from the Recipes hero.
/// Backed by the recipe-author edge function. Can render an inline
/// recipe-card suggestion that the user taps "Add to today" on.
struct AssistantChatView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var chatSessionID: String?
    @State private var messages: [AuthorMessage] = [
        AuthorMessage(role: .chef,
                      text: "Hi! Tell me what you're in the mood for and I'll suggest a recipe — or ask for swaps and tips.",
                      suggestion: nil),
    ]
    @State private var input = ""
    @State private var isThinking = false
    /// True while the persistent session + its history is being resumed.
    @State private var sessionLoading = true
    /// The suggestion currently being previewed in the detail page (if any).
    @State private var preview: SuggestionPreview?
    /// Recipe-suggestion IDs currently being added — disables the "Add to today" button
    /// and shows a spinner so a slow Gemini+paint round-trip doesn't get double-tapped.
    @State private var addingSuggestionIDs: Set<UUID> = []
    /// Painted image URLs resolved this session, keyed by the card's recipe_id.
    /// Lets reopening a preview show its photo INSTANTLY instead of re-fetching
    /// (the card's own suggestion carries no URL until the next chat resume).
    @State private var paintedURLs: [String: URL] = [:]

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                chat
            }
            if sessionLoading { ChefLoader() }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { inputBar }
        .task {
            // Resume the user's persistent author session (kept until the next
            // midnight curation). Rehydrate the conversation if it has history.
            if chatSessionID == nil {
                if let resp = try? await RecipeAuthorService.shared.start() {
                    chatSessionID = resp.chat_session_id
                    if let hist = resp.messages, !hist.isEmpty {
                        var rebuilt = hist.map {
                            AuthorMessage(role: $0.role == "model" ? .chef : .user,
                                          text: $0.text, suggestion: $0.recipe)
                        }
                        // Collapse duplicate cards for the same dish: keep the
                        // card only on the LAST message that suggested it, so a
                        // dish refined across turns shows a single (latest) card.
                        var lastIndexByDish: [String: Int] = [:]
                        for (i, m) in rebuilt.enumerated() {
                            if let name = m.suggestion?.name { lastIndexByDish[normalizedDishName(name)] = i }
                        }
                        for i in rebuilt.indices {
                            if let name = rebuilt[i].suggestion?.name,
                               lastIndexByDish[normalizedDishName(name)] != i {
                                rebuilt[i].suggestion = nil
                            }
                        }
                        messages = rebuilt
                    }
                }
            }
            withAnimation(.smooth) { sessionLoading = false }
        }
        .fullScreenCover(item: $preview) { item in
            // The preview kicks off server-side painting on appear (finishes
            // even if the user backs out) and shows the image as soon as ready.
            SuggestionPreviewView(
                suggestion: item.suggestion,
                cachedImageURL: item.suggestion.recipe_id.flatMap { paintedURLs[$0] },
                onImageResolved: { rid, url in paintedURLs[rid] = url },
                onAddToToday: {
                    preview = nil
                    Task { await addToFeed(item.suggestion, messageID: item.messageID) }
                })
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
                Text("Suggests recipes from your pantry")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        bubble(message)
                    }
                    if isThinking { typingIndicator }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.gap)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: messages.count) {
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: isThinking) {
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.ink.opacity(0.45)).frame(width: 6, height: 6)
                        .scaleEffect(1)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15),
                                   value: isThinking)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.paper))
            Spacer(minLength: 48)
        }
    }

    private func bubble(_ message: AuthorMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 10) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(message.role == .chef ? Theme.ink : Theme.paper)
                    .fixedSize(horizontal: false, vertical: true)

                if let suggestion = message.suggestion {
                    suggestionCard(suggestion, messageID: message.id)
                }
            }
            .padding(14)
            .background {
                if message.role == .chef {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.paper)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                }
            }
            if message.role == .chef { Spacer(minLength: 48) }
        }
    }

    private func suggestionCard(_ s: BackendRecipeSuggestion, messageID: UUID) -> some View {
        let isAdding = addingSuggestionIDs.contains(messageID)
        // How much of this dish the user can already make from their pantry.
        let total = s.ingredients.count
        let owned = s.ingredients.filter { $0.in_pantry == true }.count
        let match = total > 0 ? Int((100.0 * Double(owned) / Double(total)).rounded()) : 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(s.name)
                .font(.serif(18))
                .italic()
                .foregroundStyle(Theme.ink)

            HStack(spacing: 6) {
                InfoPill(text: s.category.capitalized, filled: true)
                InfoPill(text: s.time_text, icon: "clock")
                Spacer()
                Text("\(s.calories_per_serving) cal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warmAmber)
            }

            // Pantry match — how much they already have for this recipe.
            HStack(spacing: 5) {
                Circle().fill(Theme.matchGreen).frame(width: 5, height: 5)
                Text("\(match)% match — from your pantry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedText)
            }

            HStack(spacing: 8) {
                Button {
                    preview = SuggestionPreview(suggestion: s, messageID: messageID)
                } label: {
                    Text("View")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(Capsule().stroke(Theme.ink, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isAdding)

                Button {
                    Task { await addToFeed(s, messageID: messageID) }
                } label: {
                    HStack(spacing: 6) {
                        if isAdding {
                            ProgressView()
                                .tint(Theme.paper)
                                .controlSize(.mini)
                        }
                        Text(isAdding ? "Adding…" : "Add to today")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(isAdding ? Theme.mutedText : Theme.ink))
                }
                .buttonStyle(.plain)
                .disabled(isAdding)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.96)))
    }

    private func addToFeed(_ s: BackendRecipeSuggestion, messageID: UUID) async {
        // Guard against double-tap while the async round-trip is in flight.
        guard !addingSuggestionIDs.contains(messageID) else { return }
        addingSuggestionIDs.insert(messageID)
        defer { addingSuggestionIDs.remove(messageID) }

        do {
            _ = try await RecipeAuthorService.shared.addToFeed(recipe: s, slot: nil)
            // Refresh feed so the Recipes tab shows it.
            await store.loadDailyFeed()
            messages.append(AuthorMessage(
                role: .chef,
                text: "Added \(s.name) to your \(s.category) for today. Enjoy!",
                suggestion: nil))
        } catch {
            messages.append(AuthorMessage(
                role: .chef,
                text: "Couldn't add that — \(error.localizedDescription). Try again?",
                suggestion: nil))
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask for a recipe…", text: $input)
                .font(.system(size: 15))
                .foregroundStyle(Theme.paper)
                .tint(Theme.paper)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))

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
        .padding(.horizontal, Theme.gap)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.stage)
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let chatID = chatSessionID else { return }
        messages.append(AuthorMessage(role: .user, text: trimmed, suggestion: nil))
        input = ""
        isThinking = true
        Task {
            do {
                let resp = try await RecipeAuthorService.shared.send(chatSessionID: chatID, text: trimmed)
                if let rec = resp.recipe,
                   let idx = messages.lastIndex(where: { $0.suggestion.map { normalizedDishName($0.name) == normalizedDishName(rec.name) } ?? false }) {
                    // Same dish as a card already in the chat → update THAT card
                    // in place (the chef refined it), and add the reply as words.
                    // No duplicate card.
                    messages[idx].suggestion = rec
                    messages.append(AuthorMessage(role: .chef, text: resp.reply, suggestion: nil))
                } else {
                    messages.append(AuthorMessage(role: .chef, text: resp.reply, suggestion: resp.recipe))
                }
            } catch {
                messages.append(AuthorMessage(role: .chef,
                                              text: "Hmm, that didn't go through. Try again?",
                                              suggestion: nil))
            }
            isThinking = false
        }
    }
}

/// Full-screen chef-hat loader shown over the black stage while a chat session
/// resumes. A gently pulsing chef icon.
struct ChefLoader: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            ChefIcon(size: 44, color: Theme.paper)
                .scaleEffect(pulse ? 1.12 : 0.88)
                .opacity(pulse ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
        }
        .transition(.opacity)
        .onAppear { pulse = true }
    }
}

/// A suggestion being previewed full-screen. Wraps the suggestion with a stable
/// id (for `.fullScreenCover(item:)`) and the source message id (so "Add to
/// today" can disable the right card + show its spinner).
struct SuggestionPreview: Identifiable {
    let id = UUID()
    let suggestion: BackendRecipeSuggestion
    let messageID: UUID
}

/// Wraps RecipeDetailView for an AI-Chef suggestion. The moment it appears it
/// asks the backend to vault + paint the recipe (which finishes server-side
/// even if the user leaves this page), then shows the image as soon as it's
/// ready. Until then the hero shows the animated loading state.
private struct SuggestionPreviewView: View {
    let suggestion: BackendRecipeSuggestion
    /// A URL already resolved for this card earlier this session (instant show).
    let cachedImageURL: URL?
    /// Report a freshly-resolved URL back so reopening is instant next time.
    let onImageResolved: (String, URL) -> Void
    let onAddToToday: () -> Void
    @State private var recipe: Recipe

    init(suggestion: BackendRecipeSuggestion,
         cachedImageURL: URL?,
         onImageResolved: @escaping (String, URL) -> Void,
         onAddToToday: @escaping () -> Void) {
        self.suggestion = suggestion
        self.cachedImageURL = cachedImageURL
        self.onImageResolved = onImageResolved
        self.onAddToToday = onAddToToday
        // Seed with the session-cached URL (or the card's own, if already painted)
        // so the photo shows immediately on reopen — no placeholder flash.
        _recipe = State(initialValue: suggestion.toAppRecipe(imageURL: cachedImageURL))
    }

    var body: some View {
        RecipeDetailView(recipe: recipe, primaryAction: .addToToday(onAddToToday))
            .task {
                // Already have the photo (cached or painted earlier) — nothing to do.
                guard recipe.imageURL == nil else { return }
                // Ask the server to (re)start painting this card's vaulted row.
                // Returns fast with the recipe id; the URL may already be ready.
                guard let resp = try? await RecipeAuthorService.shared.preview(recipe: suggestion) else { return }
                let rid = resp.recipe_id
                if let url = resp.image_url.flatMap(URL.init(string:)) {
                    recipe.imageURL = url; onImageResolved(rid, url); return
                }
                // Poll for the image as it lands. The paint finishes server-side
                // even if we leave here. Paint can take up to ~2 min, so allow
                // headroom (60 × 2.5s = 150s).
                for _ in 0..<60 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if Task.isCancelled { return }
                    if let r = try? await RecipeAuthorService.shared.recipeImage(recipeID: rid),
                       let url = r.image_url.flatMap(URL.init(string:)) {
                        recipe.imageURL = url; onImageResolved(rid, url); return
                    }
                }
            }
    }
}

/// One message in the Recipe Author chat. May carry an inline recipe-card
/// suggestion. `suggestion` is mutable so a follow-up that updates the SAME
/// dish edits the existing card in place instead of spawning a duplicate.
struct AuthorMessage: Identifiable {
    enum Role { case chef, user }
    let id = UUID()
    let role: Role
    let text: String
    var suggestion: BackendRecipeSuggestion?
}

/// Normalized dish name for matching "same dish" across re-suggestions
/// (drops parentheticals, punctuation, and filler words like "style"/"inspired").
func normalizedDishName(_ s: String) -> String {
    let filler: Set<String> = ["style", "inspired", "classic", "homemade", "easy",
                               "simple", "quick", "the", "a", "an", "with", "and",
                               "of", "spiced", "authentic"]
    let cleaned = s.lowercased()
        .replacingOccurrences(of: #"\(.*?\)"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
    return cleaned.split(separator: " ").map(String.init)
        .filter { !$0.isEmpty && !filler.contains($0) }
        .sorted().joined(separator: " ")
}

#Preview {
    AssistantChatView()
        .environmentObject(AppStore())
}
