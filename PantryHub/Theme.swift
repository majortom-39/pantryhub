import SwiftUI
import UIKit

/// Central design system for PantryHub.
/// Black & white base, plus three bold accent colors used only on tags.
enum Theme {

    // MARK: Colors
    static let ink = Color.black                 // primary text, icons, lines
    static let paper = Color.white               // content surfaces (screens + cards)
    static let stage = Color.black               // backdrop for focus screens
    static let mutedText = Color(white: 0.55)    // secondary labels
    static let hairline = Color(white: 0.90)     // thin borders & dividers
    static let placeholderFill = Color(white: 0.93) // photo placeholder boxes

    // MARK: Functional accent colors
    /// Bold, meaningful colors for tags & badges — the only colour in the
    /// UI besides the food photos. Each one means exactly one thing.
    static let matchGreen = Color(red: 0.09, green: 0.64, blue: 0.29) // "you have it" — pantry match, easy
    static let warmAmber  = Color(red: 0.85, green: 0.47, blue: 0.02) // "heads up" — calories, medium
    static let alertRed   = Color(red: 0.86, green: 0.15, blue: 0.15) // "act now" — expiring, elaborate
    static let coolBlue   = Color(red: 0.13, green: 0.42, blue: 0.92) // dairy & frozen category icons

    // MARK: Shape
    static let cardRadius: CGFloat = 22
    static let screenPadding: CGFloat = 20

    /// The thin black sliver between cards and the screen edges.
    /// Used everywhere so card widths and gaps stay consistent.
    static let gap: CGFloat = 5

    /// How far the user scrolls (points) to fully collapse the hero.
    static let heroCollapseDistance: CGFloat = 150
}

// MARK: - Difficulty color
extension Difficulty {
    /// The bold accent color used for this difficulty level.
    var tint: Color {
        switch self {
        case .easy:      return Theme.matchGreen
        case .medium:    return Theme.warmAmber
        case .elaborate: return Theme.alertRed
        }
    }
}

// MARK: - Fonts (built-in: "New York" serif + "SF Pro" sans)
extension Font {
    /// Elegant serif (New York) for titles.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Card surface
struct CardSurface: ViewModifier {
    var bordered: Bool = true
    func body(content: Content) -> some View {
        content
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: bordered ? 1 : 0)
            )
    }
}

extension View {
    /// Wraps a view as a white, rounded, hairline-bordered card.
    func cardSurface(bordered: Bool = true) -> some View {
        modifier(CardSurface(bordered: bordered))
    }

    /// White rounded card that floats on the app's black background.
    func whiteCard(_ radius: CGFloat = Theme.cardRadius) -> some View {
        self
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Reports a scroll view's offset as a 0...1 hero-collapse progress.
    func tracksHeroCollapse(_ collapse: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offsetY in
            collapse.wrappedValue = min(1, max(0, offsetY / Theme.heroCollapseDistance))
        }
    }
}

// MARK: - Photo placeholder
/// Neutral gray box used until real food photos are added.
struct PhotoPlaceholder: View {
    var label: String = ""
    var body: some View {
        ZStack {
            Theme.placeholderFill
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .light))
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(Theme.mutedText)
        }
    }
}

/// Animated "image is loading" state — a soft shimmer sweeping across the
/// placeholder fill, with a fork-knife glyph. Used in the recipe hero while a
/// painted image is downloading (or being generated).
struct LoadingPhotoPlaceholder: View {
    var label: String = "Plating your dish…"
    @State private var animate = false
    var body: some View {
        ZStack {
            Theme.placeholderFill
            // Sheen sweep done by animating the gradient's start/end POINTS —
            // the gradient always fills the frame, so unlike an offset child it
            // can never widen the layout or make the page scroll sideways.
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.30), .clear],
                startPoint: animate ? UnitPoint(x: 1.0, y: 0.5) : UnitPoint(x: -1.0, y: 0.5),
                endPoint:   animate ? UnitPoint(x: 2.0, y: 0.5) : UnitPoint(x: 0.0, y: 0.5)
            )
            VStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 26, weight: .light))
                Text(label).font(.system(size: 12))
            }
            .foregroundStyle(Theme.mutedText)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

// MARK: - Markdown rendering
/// Renders a string with simple **bold** / *italic* markdown — what both
/// chefs and the curator emit to emphasise quantities and ingredient names
/// inside steps and chat replies. Inline-only: ignores headings/lists/code
/// so we never end up with weird block formatting in a tight chat bubble.
/// Falls back to plain text if the markdown is malformed.
extension String {
    var asInlineMarkdown: AttributedString {
        (try? AttributedString(
            markdown: self,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(self)
    }
}

// MARK: - Image loading
extension UIImage {
    /// Loads an image file by name from the app bundle (the FoodImages folder).
    /// Tries common photo formats so any of them work.
    static func bundled(_ name: String) -> UIImage? {
        // An empty name makes Bundle.main.url(forResource:) return the FIRST file
        // with that extension — a random bundled photo. Guard it out.
        guard !name.isEmpty else { return nil }
        for ext in ["jpg", "jpeg", "png", "webp", "heic"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }
        return nil
    }
}

// MARK: - Food image
/// Loads a photo by name from the FoodImages folder.
/// Falls back to a gray placeholder until the real photo is added.
struct FoodImage: View {
    let name: String

    var body: some View {
        if let image = UIImage.bundled(name) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            PhotoPlaceholder()
        }
    }
}
