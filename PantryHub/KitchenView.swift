import SwiftUI

/// The two sections of Kitchen.
enum KitchenSection: CaseIterable, Identifiable {
    case cooked, saved
    var id: Self { self }
    var title: String { self == .cooked ? "Cooked" : "Saved" }
}

/// Tab 3 — Kitchen.
///
/// Scroll architecture matches PantryView: ONE top-level ScrollView with
/// the section toggle as the first item of the LazyVStack. No `.id(section)`
/// rebuild — section switches just re-filter the same content, animated.
/// This unifies scroll feel across all three tabs AND fixes the horizontal-
/// swipe leakage that the wrapper-VStack pattern was causing under the
/// fullScreenCover transition.
struct KitchenView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var heroCollapse: CGFloat
    @State private var section: KitchenSection = .cooked
    @State private var selectedRecipe: Recipe?

    private var recipes: [Recipe] {
        section == .cooked ? store.cookedRecipes : store.savedRecipes
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.gap) {
                sectionToggle
                    .padding(.top, 4)

                if recipes.isEmpty {
                    emptyCard
                } else {
                    // No per-row transition — keeps scroll smooth on simulator.
                    ForEach(recipes) { recipe in
                        Button {
                            selectedRecipe = recipe
                        } label: {
                            RecipeCard(recipe: recipe)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .tracksHeroCollapse($heroCollapse)
        .refreshable {
            await store.loadKitchen()
        }
        .task {
            await store.loadKitchen()
        }
        .fullScreenCover(item: $selectedRecipe) { recipe in
            RecipeDetailView(recipe: recipe)
        }
    }

    // MARK: Section toggle

    private var sectionToggle: some View {
        HStack(spacing: 4) {
            ForEach(KitchenSection.allCases) { option in
                sectionPill(option)
            }
        }
        .padding(6)
        .whiteCard()
        // Keep the toggle above the recipe cards for hit-testing so a card
        // can never intercept a toggle tap.
        .zIndex(1)
    }

    private func sectionPill(_ option: KitchenSection) -> some View {
        let isSelected = section == option
        // NOTE: no matchedGeometryEffect here — see RecipesView.categoryPill.
        // It corrupted this strip's reported height so the first card overlapped
        // the tabs and stole their taps. Clear Rectangle = full opaque hit shape.
        return Button {
            withAnimation(.smooth(duration: 0.3)) { section = option }
        } label: {
            ZStack {
                Rectangle().fill(Color.clear)
                if isSelected {
                    Capsule().fill(Theme.ink)
                }
                Text(option.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.paper : Theme.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty state

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: section == .cooked ? "frying.pan" : "bookmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.mutedText)
            Text(section == .cooked ? "Nothing cooked yet" : "Nothing saved yet")
                .font(.serif(19))
                .foregroundStyle(Theme.ink)
            Text(section == .cooked
                 ? "Recipes you cook are saved here automatically."
                 : "Recipes you bookmark appear here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 54)
        .whiteCard()
    }
}

#Preview {
    ZStack {
        Theme.stage
        KitchenView(heroCollapse: .constant(0)).padding(8)
    }
    .environmentObject(AppStore())
}
