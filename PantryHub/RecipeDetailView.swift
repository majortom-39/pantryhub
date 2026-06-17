import SwiftUI

/// The full recipe — black background with white cards: a recipe card
/// (photo + title + stats), an ingredients card and a steps card.
/// A "Cook with Chef" button is pinned at the bottom.
struct RecipeDetailView: View {
    /// What the bottom button does.
    /// - `.cook`: normal feed recipe → "Cook with AI Chef" opens the chef.
    /// - `.addToToday`: an AI-Chef *suggestion* being previewed → "Add to
    ///   today's recipe" calls the closure (the author chat handles the add).
    enum PrimaryAction {
        case cook
        case addToToday(() -> Void)
    }

    /// The recipe as it was when this page opened. We prefer the live copy from
    /// the store (so chef edits show up), falling back to this if it's not in
    /// any store list.
    private let initialRecipe: Recipe
    private let primaryAction: PrimaryAction

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var adults: Int
    @State private var children = 0
    @State private var showChef = false

    init(recipe: Recipe, primaryAction: PrimaryAction = .cook) {
        self.initialRecipe = recipe
        self.primaryAction = primaryAction
        _adults = State(initialValue: max(1, recipe.servings))
    }

    /// Effective portions: each adult = 1, each child = ½.
    private var effectiveServings: Double { Double(adults) + 0.5 * Double(children) }

    /// Live recipe — reflects any edits the chef made (ingredients/steps),
    /// because the store is the source of truth. A previewed suggestion isn't
    /// in the store, so it falls back to the initial copy.
    private var recipe: Recipe {
        store.recipe(withID: initialRecipe.id) ?? initialRecipe
    }

    private var isAuthorPreview: Bool {
        if case .addToToday = primaryAction { return true }
        return false
    }

    private var ratio: Double { effectiveServings / Double(max(1, recipe.servings)) }

    /// Estimated calories for the chosen number of effective servings.
    private var totalCalories: Int { Int((Double(recipe.calories) * effectiveServings).rounded()) }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .background(Theme.stage.ignoresSafeArea(edges: .top))

                ScrollView {
                    VStack(spacing: Theme.gap) {
                        recipeCard
                        ingredientsCard
                        stepsSection
                    }
                    .padding(.horizontal, Theme.gap)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fullScreenCover(isPresented: $showChef) {
            TextChefView(recipe: recipe, servings: adults, children: children)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.paper)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.smooth) { store.toggleSaved(recipe) }
            } label: {
                Image(systemName: store.isSaved(recipe) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.paper)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: Recipe card

    private var recipeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecipeHeroImage(recipe: recipe, showsLoadingState: isAuthorPreview)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipped()   // bound the scaledToFill image so it can't widen the scroll
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topLeading) {
                    MatchTag(score: recipe.matchScore ?? store.matchScore(for: recipe))
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    if recipe.isAuthorMade { AuthorBadge().padding(12) }
                }

            VStack(alignment: .leading, spacing: 14) {
                Text(recipe.category.rawValue.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.mutedText)

                Text(recipe.name)
                    .font(.serif(28))
                    .italic()
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                difficultyTags

                statRow
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .padding(3)
        .whiteCard(24)
    }

    /// Three difficulty chips — the recipe's own level is filled in.
    private var difficultyTags: some View {
        HStack(spacing: 6) {
            ForEach(Difficulty.allCases, id: \.self) { level in
                let active = recipe.difficulty == level
                Text(level.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Theme.paper : Theme.mutedText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if active {
                            Capsule().fill(level.tint)
                        } else {
                            Capsule().stroke(Theme.hairline, lineWidth: 1)
                        }
                    }
            }
        }
    }

    private var statRow: some View {
        HStack(spacing: 0) {
            statCell(recipe.time, "Time")
            statDivider
            statCell(servingsText, "Serves")
            statDivider
            statCell("\(totalCalories)", "Calories")
        }
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 28)
    }

    // MARK: Ingredients card

    private var ingredientsCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ingredients")
                    .font(.serif(20))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("≈ \(servingsText) \(effectiveServings == 1 ? "serving" : "servings")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.mutedText)
                    .contentTransition(.numericText())
            }
            .padding(.bottom, 10)

            servingsControl
                .padding(.bottom, 14)

            ForEach(recipe.ingredients) { ingredient in
                let isMissing = ingredient.inPantry == false
                let sub = ingredient.substitute
                // Dot language: green = you have it; red = missing with no
                // pantry stand-in; for a substitutable miss the colored dot
                // moves to the alternative line (yellow), so the original line
                // gets a clear spacer dot to keep names aligned. nil = sample.
                let primaryDot: Color = {
                    guard let inPantry = ingredient.inPantry else { return .clear }
                    if inPantry { return Theme.matchGreen }
                    return sub != nil ? .clear : Theme.alertRed
                }()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(primaryDot)
                            .frame(width: 7, height: 7)
                        Text(ingredient.name)
                            .font(.system(size: 14))
                            .strikethrough(isMissing, color: Theme.mutedText)
                            .foregroundStyle(isMissing ? Theme.mutedText : Theme.ink)
                        DottedLine()
                        Text(ingredient.scaledAmount(effective: effectiveServings, base: Double(max(1, recipe.servings))))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.mutedText)
                            .contentTransition(.numericText())
                    }
                    // Phase 2: amber "short" flag when the chosen servings need
                    // more than the pantry holds. Only shows when we have both a
                    // structured recipe qty and a canonical pantry stock.
                    if let short = shortfall(for: ingredient) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("short ~\(short)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.warmAmber)
                        .padding(.leading, 15)
                    }
                    // Substitute line — missing ingredient with a pantry stand-in.
                    // Yellow dot = "you can still make this with what you have".
                    if isMissing, let sub {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Theme.warmAmber)
                                    .frame(width: 7, height: 7)
                                (Text(sub.name).foregroundStyle(Theme.ink).fontWeight(.medium)
                                    + Text(" — from your pantry").foregroundStyle(Theme.mutedText))
                                    .font(.system(size: 14))
                            }
                            if !sub.note.isEmpty {
                                Text(sub.note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.mutedText)
                                    .padding(.leading, 15)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 9)
            }
        }
        .padding(20)
        .whiteCard(24)
    }

    /// Effective servings as a short string (e.g. "2", "2.5").
    private var servingsText: String {
        effectiveServings == effectiveServings.rounded()
            ? String(Int(effectiveServings))
            : String(format: "%.1f", effectiveServings)
    }

    /// Two counters: Adults (full portions) + Kids (½ portion each).
    private var servingsControl: some View {
        HStack(spacing: 10) {
            counterChip(title: "Adults", value: adults, canDecrement: adults > 1,
                        onMinus: { adults -= 1 }, onPlus: { if adults < 20 { adults += 1 } })
            counterChip(title: "Kids", subtitle: "½ each", value: children, canDecrement: children > 0,
                        onMinus: { if children > 0 { children -= 1 } }, onPlus: { if children < 20 { children += 1 } })
        }
    }

    private func counterChip(title: String, subtitle: String? = nil, value: Int,
                             canDecrement: Bool,
                             onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.mutedText) }
            }
            HStack(spacing: 12) {
                stepButton("minus", action: onMinus)
                    .opacity(canDecrement ? 1 : 0.3).disabled(!canDecrement)
                Text("\(value)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(minWidth: 16).contentTransition(.numericText())
                stepButton("plus", action: onPlus)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Steps (plain on the black background)

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Steps")
                    .font(.serif(22))
                    .foregroundStyle(Theme.paper)
                Spacer()
                Text("\(recipe.steps.count) steps")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            ForEach(recipe.steps.indices, id: \.self) { index in
                let step = recipe.steps[index]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.serif(15))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.paper))
                        // Ingredient amounts are {{tokens}} that scale with the
                        // servings; times/temps stay as plain **bold**. Both render
                        // bold so they pop while cooking.
                        Text(Formatting.scaleStepTokens(step, factor: ratio, bold: true).asInlineMarkdown)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.paper)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    // Same amber "short" flag as the ingredient list — keeps the
                    // original step amount but flags what's short (issue c).
                    ForEach(recipe.stepShortages(in: step, effective: effectiveServings, pantry: store.pantry), id: \.name) { s in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                            Text("\(s.name) — short ~\(s.deficit)").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.warmAmber)
                        .padding(.leading, 42)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bottom button

    @ViewBuilder
    private var bottomBar: some View {
        switch primaryAction {
        case .cook:
            bottomButton(icon: true, title: "Cook with AI Chef") { showChef = true }
        case .addToToday(let onAdd):
            bottomButton(icon: false, title: "Add to today's recipe") { onAdd() }
        }
    }

    private func bottomButton(icon: Bool, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if icon { ChefIcon(size: 22, color: Theme.ink) }
                else { Image(systemName: "plus.circle.fill").font(.system(size: 20)) }
                Text(title)
            }
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

    // MARK: Helpers

    /// Phase 2 shortfall: does the pantry hold enough of this ingredient for the
    /// chosen servings? Returns a short "Xg" / "Xml" / "X" string when short,
    /// else nil. Needs BOTH a structured recipe qty and a canonical pantry stock
    /// in the same unit — otherwise we can't compare, so we show nothing.
    private func shortfall(for ingredient: RecipeIngredient) -> String? {
        ingredient.shortfallDeficit(effective: effectiveServings,
                                    base: Double(max(1, recipe.servings)),
                                    pantry: store.pantry)
    }
}

#Preview {
    RecipeDetailView(recipe: .preview)
        .environmentObject(AppStore())
}
