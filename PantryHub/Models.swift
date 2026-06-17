import Foundation

/// A recipe category shown on the Recipes page.
enum MealCategory: String, CaseIterable, Identifiable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snacks = "Snacks"

    var id: String { rawValue }
}

/// How hard a recipe is to cook.
enum Difficulty: String, CaseIterable, Hashable {
    case easy = "Easy"
    case medium = "Medium"
    case elaborate = "Elaborate"
}

/// A pantry-based substitute the Curator picked for a missing ingredient.
struct IngredientSubstitute: Hashable {
    var name: String
    var note: String
}

/// Set by the backend after a cook when this feed slot is now short ingredients.
struct PantryWarning: Hashable {
    struct CausedBy: Hashable {
        var recipeName: String
        var slot: String
    }
    struct ShortItem: Hashable, Identifiable {
        let id = UUID()
        var name: String
        var reason: String
    }
    var causedBy: CausedBy
    var shortIngredients: [ShortItem]
}

/// One ingredient line inside a recipe.
struct RecipeIngredient: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var amount: String
    /// Whether the user has this ingredient in their pantry.
    /// nil for hardcoded sample recipes; true/false for backend recipes.
    var inPantry: Bool?
    /// When the ingredient is missing, an optional pantry-based alternative
    /// chosen by the Curator (shown in orange under the missing line).
    var substitute: IngredientSubstitute?
    /// Phase 2 structured amount for ONE base serving — `qty` in canonical
    /// `unit` ("g" | "ml" | "piece"). nil for legacy recipes (then the app
    /// falls back to scaling the `amount` string). Enables precise scaling and
    /// pantry-shortfall arithmetic.
    var qty: Double?
    var unit: String?

    init(name: String, amount: String, inPantry: Bool? = nil, substitute: IngredientSubstitute? = nil,
         qty: Double? = nil, unit: String? = nil) {
        self.name = name
        self.amount = amount
        self.inPantry = inPantry
        self.substitute = substitute
        self.qty = qty
        self.unit = unit
    }

    /// The display amount scaled to `effective` servings (base = `base`).
    /// Uses the structured qty×factor when present; otherwise scales the
    /// leading number in the `amount` string; otherwise returns it unchanged.
    func scaledAmount(effective: Double, base: Double) -> String {
        let factor = base > 0 ? effective / base : 1
        if let q = qty, let u = unit, q > 0 {
            let num = Formatting.tidy(q * factor)
            // "piece" is implied by the ingredient name — show just the number.
            return u == "piece" ? num : "\(num) \(u)"
        }
        return Formatting.scaleAmountString(amount, factor: factor)
    }

    /// Per-base-serving need scaled to `effective` servings, in canonical unit.
    /// nil when this ingredient has no structured quantity.
    func need(effective: Double, base: Double) -> (qty: Double, unit: String)? {
        guard let q = qty, let u = unit, q > 0 else { return nil }
        let factor = base > 0 ? effective / base : 1
        return (q * factor, u)
    }

    /// Shortfall deficit vs the user's pantry stock at the chosen servings,
    /// as a short "Xg"/"Xml"/"X" string — nil when not short or not comparable.
    /// Shared by the recipe detail page AND the cooking steps so the amber
    /// "short ~X" flag is portrayed identically everywhere (issue c).
    func shortfallDeficit(effective: Double, base: Double, pantry: [PantryItem]) -> String? {
        guard let need = need(effective: effective, base: base) else { return nil }
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty,
              let item = pantry.first(where: {
                  let a = $0.name.lowercased().trimmingCharacters(in: .whitespaces)
                  return a.contains(n) || n.contains(a)
              }),
              let stock = item.stockQty, let su = item.stockUnit, su == need.unit else { return nil }
        let deficit = need.qty - stock
        guard deficit > 0.05 else { return nil }
        let label = need.unit == "piece" ? "" : need.unit
        return label.isEmpty ? Formatting.tidy(deficit) : "\(Formatting.tidy(deficit)) \(label)"
    }
}

extension Recipe {
    /// Ingredients USED in `step` that the pantry is short on at `effective`
    /// servings — returned as (name, "short ~X") so the cooking steps can show
    /// the SAME amber flag as the ingredient list. Matches an ingredient to a
    /// step by name (case-insensitive substring), the same loose rule used
    /// elsewhere. Original step amounts are never changed — we only annotate.
    func stepShortages(in step: String, effective: Double, pantry: [PantryItem]) -> [(name: String, deficit: String)] {
        let base = Double(max(1, servings))
        let lower = step.lowercased()
        var out: [(name: String, deficit: String)] = []
        for ing in ingredients {
            let nm = ing.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !nm.isEmpty, lower.contains(nm) else { continue }
            if let d = ing.shortfallDeficit(effective: effective, base: base, pantry: pantry) {
                out.append((ing.name, d))
            }
        }
        return out
    }
}

/// Small shared number/amount formatting helpers (Phase 2 scaling).
enum Formatting {
    /// Whole number when near-integer, else up to 2dp.
    static func tidy(_ n: Double) -> String {
        if abs(n - n.rounded()) < 0.01 { return String(Int(n.rounded())) }
        return String(format: "%g", (n * 100).rounded() / 100)
    }

    /// Scale the leading number of a free-text amount ("200 g", "1 1/2 tbsp").
    /// Non-numeric amounts ("to taste") pass through unchanged.
    static func scaleAmountString(_ amount: String, factor: Double) -> String {
        guard factor != 1, !amount.isEmpty else { return amount }
        let trimmed = amount.trimmingCharacters(in: .whitespaces)
        // Match: mixed fraction "1 1/2", simple fraction "1/2", or decimal "200".
        guard let m = trimmed.range(of: #"^(\d+\s+\d+/\d+|\d+/\d+|\d*\.?\d+)"#, options: .regularExpression) else {
            return amount
        }
        let numStr = String(trimmed[m])
        let rest = String(trimmed[m.upperBound...]).trimmingCharacters(in: .whitespaces)
        let value = parseNumber(numStr)
        guard value.isFinite else { return amount }
        let scaled = tidy(value * factor)
        return rest.isEmpty ? scaled : "\(scaled) \(rest)"
    }

    /// Parse "1 1/2", "3/4", or "200" into a Double.
    static func parseNumber(_ s: String) -> Double {
        if s.contains("/") {
            let parts = s.split(separator: " ")
            if parts.count == 2 {
                let frac = parts[1].split(separator: "/").compactMap { Double($0) }
                let whole = Double(parts[0]) ?? 0
                return frac.count == 2 && frac[1] != 0 ? whole + frac[0] / frac[1] : whole
            }
            let frac = s.split(separator: "/").compactMap { Double($0) }
            return frac.count == 2 && frac[1] != 0 ? frac[0] / frac[1] : 0
        }
        return Double(s) ?? .nan
    }

    /// Replace {{...}} ingredient-amount tokens in step text with the scaled
    /// amount, leaving everything else (incl. **bold** times/temps) untouched.
    /// When `bold` is true the scaled amount is wrapped in **markdown bold** so
    /// it pops on screen (matching how times/temps are already emphasised).
    static func scaleStepTokens(_ text: String, factor: Double, bold: Bool = false) -> String {
        guard text.contains("{{") else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{" {
                var j = i + 2
                var inner = ""
                var closed = false
                while j + 1 < chars.count {
                    if chars[j] == "}", chars[j + 1] == "}" { closed = true; break }
                    inner.append(chars[j]); j += 1
                }
                if closed {
                    let scaled = scaleAmountString(inner.trimmingCharacters(in: .whitespaces), factor: factor)
                    out += bold ? "**\(scaled)**" : scaled
                    i = j + 2
                    continue
                }
            }
            out.append(chars[i]); i += 1
        }
        return out
    }
}

/// A full recipe.
struct Recipe: Identifiable, Hashable {
    let id: UUID
    var name: String
    var author: String
    var category: MealCategory
    var imageName: String
    var difficulty: Difficulty
    var time: String
    var budget: String
    var servings: Int
    /// Estimated calories per serving.
    var calories: Int
    var ingredients: [RecipeIngredient]
    var steps: [String]
    /// Set when the recipe was loaded from the backend (Painter-generated).
    /// nil for hardcoded/bundled recipes — those fall back to `imageName`.
    var imageURL: URL?
    /// Backend-computed pantry match score (0–100). Carried through from
    /// daily_feed.match_score. nil for sample/kitchen recipes — UI then
    /// falls back to AppStore.matchScore(for:) against the local pantry.
    var matchScore: Int?
    /// daily_feed.id — used by clear_warning / regenerate_slot calls.
    /// nil for kitchen recipes (which aren't tied to a feed row).
    var feedRowID: UUID?
    /// Set when an earlier cook left this slot short on ingredients.
    var pantryWarning: PantryWarning?

    /// How it entered the feed: "curator" (nightly) or "author" (user added it
    /// from the AI Chef). Drives the small chef-hat badge.
    var source: String?

    /// True when the user added this recipe via the AI Chef author.
    var isAuthorMade: Bool { source == "author" }

    init(
        id: UUID = UUID(),
        name: String,
        author: String,
        category: MealCategory,
        imageName: String,
        difficulty: Difficulty,
        time: String,
        budget: String,
        servings: Int,
        calories: Int,
        ingredients: [RecipeIngredient],
        steps: [String],
        imageURL: URL? = nil,
        matchScore: Int? = nil,
        feedRowID: UUID? = nil,
        pantryWarning: PantryWarning? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.category = category
        self.imageName = imageName
        self.difficulty = difficulty
        self.time = time
        self.budget = budget
        self.servings = servings
        self.calories = calories
        self.ingredients = ingredients
        self.steps = steps
        self.imageURL = imageURL
        self.matchScore = matchScore
        self.feedRowID = feedRowID
        self.pantryWarning = pantryWarning
        self.source = source
    }

    static func == (lhs: Recipe, rhs: Recipe) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A short word describing a 0...1 fullness level.
func fullnessText(_ level: Double) -> String {
    switch level {
    case ..<0.13: return "Almost out"
    case ..<0.38: return "Running low"
    case ..<0.63: return "Half full"
    case ..<0.88: return "Mostly full"
    default:      return "Full"
    }
}

/// Universal pantry categories — the same fixed set for every user.
enum PantryCategory: String, CaseIterable, Identifiable {
    case produce    = "Fruits & Veg"
    case meat       = "Meat & Seafood"
    case dairy      = "Dairy & Eggs"
    case grains     = "Grains & Bread"
    case condiments = "Condiments & Spices"
    case snacks     = "Snacks & Sweets"
    case drinks     = "Drinks"
    case frozen     = "Frozen & Canned"

    var id: String { rawValue }

    /// The backend enum slug (matches Postgres `pantry_category`).
    var backendSlug: String {
        switch self {
        case .produce: return "produce"
        case .meat: return "meat"
        case .dairy: return "dairy"
        case .grains: return "grains"
        case .condiments: return "condiments"
        case .snacks: return "snacks"
        case .drinks: return "drinks"
        case .frozen: return "frozen"
        }
    }
    init(backendSlug: String) {
        switch backendSlug.lowercased() {
        case "produce": self = .produce
        case "meat": self = .meat
        case "dairy": self = .dairy
        case "grains": self = .grains
        case "condiments": self = .condiments
        case "snacks": self = .snacks
        case "drinks": self = .drinks
        case "frozen": self = .frozen
        default: self = .produce
        }
    }
}

/// How a pantry item is pictured.
/// - `generic`: a staple / whole food (eggs, milk, tomatoes) — shown with
///   a clean built-in mark. Never needs the internet.
/// - `product`: a branded packaged good (cereal, a named pasta) — shown
///   with its real packaging photo, fetched online by the backend.
enum ItemImageKind: Hashable {
    case generic
    case product

    var backendSlug: String { self == .product ? "product" : "generic" }
    init(backendSlug: String) { self = (backendSlug.lowercased() == "product") ? .product : .generic }
}

/// One product stored in the user's pantry.
struct PantryItem: Identifiable, Hashable {
    let id = UUID()
    /// The cloud `pantry_items.id` once this item is synced. nil for a brand-new
    /// local item not yet saved to the backend.
    var backendID: UUID?
    var name: String
    var brand: String
    var imageName: String
    /// Whether this item shows a generic mark or a real product photo.
    var imageKind: ItemImageKind
    var category: PantryCategory
    var quantity: String
    /// One fullness value (0…1) per container the user owns.
    var fullnessLevels: [Double]
    /// The unit the fullness is measured in ("%", "g", "oz", …).
    var fullnessUnit: String
    var expiry: Date?
    /// Phase 2 canonical stock available NOW (package size × fullness), in
    /// `stockUnit` ("g" | "ml" | "piece"). nil = unknown (no shortfall math).
    var stockQty: Double?
    var stockUnit: String?

    // ── Intake review flags (transient — never sent to / stored in the cloud) ──
    /// True when an item came in from scan/barcode but the AI/lookup couldn't be
    /// sure what it is. The review list flags it so the user types in a name.
    var needsReview: Bool = false
    /// True when the expiry date is an AI estimate, not a printed/known date —
    /// the review list nudges the user to confirm it.
    var expiryEstimated: Bool = false
    /// A short human reason carried from intake (e.g. why an item is unidentified).
    var intakeNote: String = ""

    init(name: String,
         brand: String = "",
         imageName: String = "",
         imageKind: ItemImageKind = .generic,
         category: PantryCategory = .produce,
         quantity: String = "",
         fullnessLevels: [Double] = [1.0],
         fullnessUnit: String = "%",
         expiry: Date? = nil,
         backendID: UUID? = nil,
         stockQty: Double? = nil,
         stockUnit: String? = nil,
         needsReview: Bool = false,
         expiryEstimated: Bool = false,
         intakeNote: String = "") {
        self.name = name
        self.brand = brand
        self.imageName = imageName
        self.imageKind = imageKind
        self.category = category
        self.quantity = quantity
        self.fullnessLevels = fullnessLevels.isEmpty ? [1.0] : fullnessLevels
        self.fullnessUnit = fullnessUnit
        self.expiry = expiry
        self.backendID = backendID
        self.stockQty = stockQty
        self.stockUnit = stockUnit
        self.needsReview = needsReview
        self.expiryEstimated = expiryEstimated
        self.intakeNote = intakeNote
    }

    /// A sensible fullness metaphor for this product, so the editor shows a
    /// draggable jar for liquids/jars but a piece counter for eggs, fruit, cans.
    enum FillStyle { case level, count }
    var fillStyle: FillStyle {
        switch fullnessUnit.lowercased() {
        case "pieces", "servings": return .count
        case "%", "g", "kg", "oz", "ml", "l", "cups": return .level
        default: return .level
        }
    }

    /// How many containers of this product the user has.
    var count: Int { fullnessLevels.count }

    /// The average fill across all containers (0…1).
    var averageFullness: Double {
        guard !fullnessLevels.isEmpty else { return 0 }
        return fullnessLevels.reduce(0, +) / Double(fullnessLevels.count)
    }

    /// A short word for the overall fullness.
    var fullnessLabel: String { fullnessText(averageFullness) }

    static func == (lhs: PantryItem, rhs: PantryItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
