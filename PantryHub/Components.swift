import SwiftUI

// MARK: - Info pill
/// A small rounded chip for recipe meta (difficulty, time).
struct InfoPill: View {
    let text: String
    var icon: String? = nil
    var filled: Bool = false
    /// When set, the pill is filled with this bold color and white text.
    var tint: Color? = nil

    private var fillColor: Color {
        if let tint { return tint }
        return filled ? Theme.ink : Theme.paper
    }
    private var textColor: Color {
        (tint != nil || filled) ? Theme.paper : Theme.ink
    }
    private var strokeWidth: CGFloat {
        (tint != nil || filled) ? 0 : 1
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(fillColor))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: strokeWidth))
    }
}

// MARK: - Match tag
/// A small badge showing how much of a recipe the user can already make
/// from their own pantry. Sits on top of the recipe photo.
struct MatchTag: View {
    let score: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.paper)
                .frame(width: 5, height: 5)
            Text("\(score)% match")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Theme.paper)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.matchGreen))
        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Calorie label
/// A small flame + number showing a recipe's estimated calories.
struct CalorieLabel: View {
    let calories: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("\(calories) cal")
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.numericText())
        }
        .foregroundStyle(Theme.warmAmber)
    }
}

// MARK: - Recipe card
/// A large editorial card — big photo, name, meta pills.
/// Used on the Recipes feed and on Kitchen.
struct RecipeCard: View {
    @EnvironmentObject private var store: AppStore
    let recipe: Recipe
    /// Tapped when the user hits the warning icon (when one is shown).
    /// The outer card tap still opens the detail page as usual.
    var onWarningTap: ((PantryWarning) -> Void)? = nil

    /// Estimated calories for the whole dish at its default serving count.
    private var totalCalories: Int { recipe.calories * recipe.servings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecipeHeroImage(recipe: recipe)
                .frame(maxWidth: .infinity)
                .frame(height: 208)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topLeading) {
                    // Prefer the backend-computed match score; fall back to a
                    // local recompute against AppStore.pantry for legacy recipes.
                    MatchTag(score: recipe.matchScore ?? store.matchScore(for: recipe))
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        if recipe.isAuthorMade { AuthorBadge() }
                        if let warning = recipe.pantryWarning, let onTap = onWarningTap {
                            Button { onTap(warning) } label: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Theme.paper, Theme.warmAmber)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Circle())
                        }
                    }
                    .padding(8)
                }

            VStack(alignment: .leading, spacing: 12) {
                Text(recipe.name)
                    .font(.serif(22))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    InfoPill(text: recipe.difficulty.rawValue, tint: recipe.difficulty.tint)
                    InfoPill(text: recipe.time, icon: "clock")
                    Spacer(minLength: 8)
                    CalorieLabel(calories: totalCalories)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(3)
        .whiteCard()
    }
}

// MARK: - Dismiss button (standardized)
/// One source of truth for dismiss controls across the app.
///   .back  — for full-screen pages (fullScreenCover)
///   .close — for sheets sliding up from the bottom
/// `tone` defaults to light (paper) for dark backgrounds; pass `.dark`
/// for white-card backgrounds.
struct DismissButton: View {
    enum Style { case back, close }
    enum Tone { case light, dark }

    let style: Style
    var tone: Tone = .light
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: style == .back ? "chevron.left" : "xmark")
                .font(.system(size: style == .back ? 16 : 14, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 38, height: 38)
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        tone == .light ? Theme.paper : Theme.ink
    }
    private var background: Color {
        tone == .light ? Color.white.opacity(0.14) : Color.black.opacity(0.05)
    }
}

// MARK: - Author badge
/// A small frosted "Custom request" pill marking a recipe the user created via
/// the AI Chef. Sits in a photo corner — clearer than an icon at telling the
/// user this dish came from their own request rather than the daily curation.
struct AuthorBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            ChefIcon(size: 13, color: Theme.paper)
            Text("Custom request")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.paper)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// A chef's hat (toque) — drawn as vectors so it's just the HAT (no head/face),
/// tints to any color, and stays crisp at any size. Used everywhere a chef mark
/// appears (nav, chat headers, loader, author-recipe badge).
struct ChefIcon: View {
    var size: CGFloat = 24
    var color: Color = Theme.ink

    var body: some View {
        let s = size
        ZStack {
            // The band (bottom of the toque).
            RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                .frame(width: s * 0.54, height: s * 0.26)
                .offset(y: s * 0.22)
            // Puffy cloud top — three overlapping circles merge into the toque.
            Circle().frame(width: s * 0.40, height: s * 0.40).offset(y: -s * 0.10)
            Circle().frame(width: s * 0.30, height: s * 0.30).offset(x: -s * 0.18, y: -s * 0.02)
            Circle().frame(width: s * 0.30, height: s * 0.30).offset(x:  s * 0.18, y: -s * 0.02)
        }
        .frame(width: s, height: s)
        .foregroundStyle(color)
    }
}

// MARK: - Recipe hero image
/// Loads a recipe's hero photo from its backend URL when present,
/// or from the bundled FoodImages folder otherwise. Shows a soft
/// skeleton while a remote image downloads.
struct RecipeHeroImage: View {
    let recipe: Recipe
    /// When true, an empty/missing image shows the animated "plating…" loader
    /// instead of a static placeholder — used in the detail page where a fresh
    /// image may still be on its way.
    var showsLoadingState: Bool = false

    var body: some View {
        Group {
            if let url = recipe.imageURL {
                // Painted image — memory+disk cached, so it's instant after the
                // first load. Loading shimmer shows only on the very first fetch.
                CachedImage(url: url) { LoadingPhotoPlaceholder() }
            } else if !recipe.imageName.isEmpty, UIImage.bundled(recipe.imageName) != nil {
                // A real bundled photo (sample recipes only).
                FoodImage(name: recipe.imageName)
            } else if showsLoadingState {
                // No image yet (e.g. a chef suggestion not painted yet) — show
                // the animated loading state rather than a wrong/blank image.
                LoadingPhotoPlaceholder()
            } else {
                PhotoPlaceholder()
            }
        }
        // Never let scaledToFill push the layout wider than its frame — that
        // overflow is what made the page rubber-band horizontally.
        .clipped()
    }
}

// MARK: - Pantry item icon
/// Picks the icon for a pantry item — a distinct illustrated icon per
/// ingredient (a PNG in FoodImages), with a coloured SF Symbol per food
/// category as the final fallback.
enum PantryIcon {
    /// The illustrated-icon file name for an ingredient, e.g. "icon-tomato".
    /// Returns nil when nothing specific matches.
    static func iconName(for item: PantryItem) -> String? {
        let name = item.name.lowercased()
        for (key, icon) in lookup where name.contains(key) {
            return "icon-\(icon)"
        }
        return nil
    }

    /// Scanned in order — more specific keys must come first.
    private static let lookup: [(String, String)] = [
        ("bell pepper", "bellpepper"), ("black pepper", "jar"),
        ("chilli", "chilli"), ("chili", "chilli"), ("paprika", "chilli"),
        ("olive oil", "olive"),
        // Fruits & veg
        ("tomato", "tomato"), ("onion", "onion"), ("garlic", "garlic"),
        ("spinach", "leafygreen"), ("lettuce", "leafygreen"),
        ("lemon", "lemon"), ("carrot", "carrot"), ("potato", "potato"),
        ("broccoli", "broccoli"), ("mushroom", "mushroom"), ("avocado", "avocado"),
        // Herbs
        ("basil", "herb"), ("oregano", "herb"), ("thyme", "herb"),
        ("rosemary", "herb"), ("parsley", "herb"), ("mint", "herb"),
        ("bay leaves", "leaf"), ("bay leaf", "leaf"),
        // Dairy & eggs
        ("egg", "egg"), ("milk", "milk"), ("butter", "butter"),
        ("cheese", "cheese"), ("parmesan", "cheese"), ("mozzarella", "cheese"),
        ("yogurt", "milk"), ("yoghurt", "milk"), ("cream", "milk"),
        // Meat & seafood
        ("chicken", "chicken"), ("beef", "beef"), ("steak", "beef"),
        ("bacon", "bacon"), ("pork", "pork"), ("ham", "pork"), ("lamb", "pork"),
        ("salmon", "fish"), ("tuna", "fish"), ("fish", "fish"),
        ("shrimp", "shrimp"), ("prawn", "shrimp"),
        // Grains & bread
        ("bread", "bread"), ("loaf", "bread"), ("toast", "bread"),
        ("flour", "wheat"), ("oat", "wheat"), ("rice", "bowl"),
        ("pasta", "pasta"), ("spaghetti", "pasta"), ("noodle", "pasta"),
        ("flakes", "bowl"), ("cereal", "bowl"),
        // Condiments, spices, staples
        ("salt", "salt"), ("sugar", "sugar"), ("honey", "honey"),
        ("oil", "olive"), ("nutmeg", "nutmeg"),
        ("cinnamon", "jar"), ("cumin", "jar"), ("turmeric", "jar"),
        ("coriander", "jar"), ("garam masala", "jar"), ("pepper", "jar"),
        ("chickpea", "beans"), ("lentil", "beans"), ("bean", "beans"),
    ]

    static func symbol(for category: PantryCategory) -> String {
        switch category {
        case .produce:    return "carrot.fill"
        case .meat:       return "fish.fill"
        case .dairy:      return "drop.fill"
        case .grains:     return "basket.fill"
        case .condiments: return "leaf.fill"
        case .snacks:     return "birthday.cake.fill"
        case .drinks:     return "cup.and.saucer.fill"
        case .frozen:     return "snowflake"
        }
    }

    static func color(for category: PantryCategory) -> Color {
        switch category {
        case .produce:    return Theme.matchGreen
        case .meat:       return Theme.alertRed
        case .dairy:      return Theme.coolBlue
        case .grains:     return Theme.warmAmber
        case .condiments: return Theme.warmAmber
        case .snacks:     return Theme.alertRed
        case .drinks:     return Theme.coolBlue
        case .frozen:     return Theme.coolBlue
        }
    }
}

// MARK: - Pantry item image
/// The picture for a pantry item: the real product photo when available,
/// then a distinct illustrated ingredient icon, and finally a coloured
/// category symbol — so there is always something tidy to show.
struct PantryItemImage: View {
    let item: PantryItem

    var body: some View {
        if item.imageKind == .product, !item.imageName.isEmpty, let photo = UIImage.bundled(item.imageName) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
        } else if let iconName = PantryIcon.iconName(for: item),
                  let icon = UIImage.bundled(iconName) {
            GeometryReader { geo in
                ZStack {
                    Theme.placeholderFill
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(geo.size.width * 0.14)
                }
            }
        } else {
            GeometryReader { geo in
                ZStack {
                    Theme.placeholderFill
                    Image(systemName: PantryIcon.symbol(for: item.category))
                        .font(.system(size: geo.size.width * 0.4, weight: .semibold))
                        .foregroundStyle(PantryIcon.color(for: item.category))
                }
            }
        }
    }
}

// MARK: - Pressable card button style
/// Gently scales a card down while it is being tapped.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.smooth(duration: 0.25), value: configuration.isPressed)
    }
}

// MARK: - Dotted leader line
/// The horizontal dotted line used between an ingredient name and its amount.
struct DottedLine: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [1, 3]))
            .foregroundStyle(Theme.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Fullness jar
/// The contents of the jar — a filled column with a gently domed
/// (liquid-surface) top.
struct JarFill: Shape {
    var level: Double          // 0...1
    var dome: CGFloat = 16

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(1, max(0, level))
        let topY = rect.height - rect.height * clamped
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: topY))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: topY),
            control: CGPoint(x: rect.width / 2, y: topY - dome))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// A clean, draggable jar showing how full one container is.
/// Drag up or down to set the level.
struct FullnessJar: View {
    @Binding var level: Double
    var width: CGFloat = 122
    var height: CGFloat = 210

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.white.opacity(0.06))

            JarFill(level: level)
                .fill(Theme.paper)

            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Theme.paper, lineWidth: 2)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let y = min(max(0, value.location.y), height)
                    level = 1 - Double(y / height)
                }
        )
    }
}

// MARK: - Flow layout
/// Lays subviews left-to-right, wrapping onto new rows — used for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
