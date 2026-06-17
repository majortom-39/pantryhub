import SwiftUI

/// Tab 2 — curated recipes, filtered by a category selector.
///
/// Scroll architecture matches PantryView: ONE top-level ScrollView with
/// the category selector as the first item of the LazyVStack, so it
/// scrolls away with the content (instead of being pinned outside).
/// No `.id(selectedCategory)` — the content stays in the same scroll
/// identity, just changes its rendered rows.
struct RecipesView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var heroCollapse: CGFloat
    @State private var selectedCategory: MealCategory = .breakfast
    @State private var selectedRecipe: Recipe?
    @State private var warningRecipe: Recipe?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.gap) {
                categorySelector
                    .padding(.top, 4)

                recipeList
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .tracksHeroCollapse($heroCollapse)
        .refreshable {
            await store.loadDailyFeed()
        }
        .fullScreenCover(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
        .sheet(item: $warningRecipe) { recipe in
            if let warning = recipe.pantryWarning {
                PantryWarningSheet(
                    recipe: recipe,
                    warning: warning,
                    onRegenerated: { Task { await store.loadDailyFeed() } },
                    onKept:        { Task { await store.loadDailyFeed() } }
                )
            }
        }
    }

    @ViewBuilder
    private var recipeList: some View {
        let items = store.recipes(in: selectedCategory)

        if !items.isEmpty {
            // No per-row transition — would fire 5–10 simultaneously on every
            // category switch and tank scroll performance. The pill animation
            // is enough visual feedback.
            ForEach(items) { recipe in
                Button {
                    selectedRecipe = recipe
                } label: {
                    RecipeCard(recipe: recipe, onWarningTap: { _ in
                        warningRecipe = recipe
                    })
                }
                .buttonStyle(PressableCardStyle())
            }
        } else {
            switch store.feedLoadState {
            case .loading, .idle:
                loadingPlaceholder
            case .failed(let message):
                errorPlaceholder(message)
            case .loaded:
                emptyPlaceholder
            }
        }
    }

    // MARK: Category selector (white card with a black-pill segment)

    private var categorySelector: some View {
        HStack(spacing: 4) {
            ForEach(MealCategory.allCases) { category in
                categoryPill(category)
            }
        }
        .padding(6)
        .whiteCard()
        // Keep the tab strip above the recipe cards for hit-testing so a card
        // can never intercept a tab tap.
        .zIndex(1)
    }

    private func categoryPill(_ category: MealCategory) -> some View {
        let isSelected = selectedCategory == category
        // NOTE: do NOT use matchedGeometryEffect on the selected capsule here.
        // It corrupts the height this strip reports to the LazyVStack, which
        // then lays the first recipe card on top of the lower part of the tabs
        // — so card taps win and only the top edge of the tabs stays tappable.
        // The clear Rectangle gives the Button a full opaque hit shape.
        return Button {
            withAnimation(.smooth(duration: 0.3)) {
                selectedCategory = category
            }
        } label: {
            ZStack {
                Rectangle().fill(Color.clear)
                if isSelected {
                    Capsule().fill(Theme.ink)
                }
                Text(category.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.paper : Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Theme.ink)
                .padding(.top, 60)
            Text("Loading today's recipes…")
                .font(.system(size: 14))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .whiteCard()
    }

    private func errorPlaceholder(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.alertRed)
            Text("Couldn't load recipes")
                .font(.serif(18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Try again") {
                Task { await store.loadDailyFeed() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.ink))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .whiteCard()
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "fork.knife")
                .font(.system(size: 24))
                .foregroundStyle(Theme.mutedText)
            Text("No \(selectedCategory.rawValue.lowercased()) recipe today")
                .font(.system(size: 14))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .whiteCard()
    }
}

#Preview {
    ZStack {
        Theme.stage
        RecipesView(heroCollapse: .constant(0)).padding(8)
    }
    .environmentObject(AppStore())
}
