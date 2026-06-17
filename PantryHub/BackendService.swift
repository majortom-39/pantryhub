import Foundation

// MARK: - Backend configuration
// TODO(secrets): move these to Info.plist for production.

enum BackendConfig {
    static let supabaseURL = "https://uipgydhflvxpxfuqzdxm.supabase.co"

    /// Public anon key — safe to ship inside the iOS app.
    static let anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVpcGd5ZGhmbHZ4cHhmdXF6ZHhtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMwMTc1NzgsImV4cCI6MjA4ODU5MzU3OH0.91u223xgIkPPcOVBWOsHmUxpRv7SmesHR8oHdSKl5U0"

    private static var base: String { "\(supabaseURL)/functions/v1" }

    static var dailyFeedEndpoint:    URL { URL(string: "\(base)/get-daily-feed")! }
    static var textChefEndpoint:     URL { URL(string: "\(base)/text-chef")! }
    static var recipeAuthorEndpoint: URL { URL(string: "\(base)/recipe-author")! }
    static var kitchenEndpoint:      URL { URL(string: "\(base)/kitchen")! }
    static var preferencesEndpoint:  URL { URL(string: "\(base)/preferences")! }
    static var feedActionsEndpoint:  URL { URL(string: "\(base)/feed-actions")! }
    static var timersEndpoint:       URL { URL(string: "\(base)/cook-timers")! }
    static var pantryEndpoint:       URL { URL(string: "\(base)/pantry")! }
    static var pantryIntakeEndpoint: URL { URL(string: "\(base)/pantry-intake")! }

    /// WebSocket endpoint for the Voice Chef bridge.
    /// Runs on Cloud Run (keyless Vertex AI Live, billed to GCP credits) — NOT
    /// the Supabase edge function — so long voice calls don't hit edge timeouts.
    /// iOS opens this with the cook_session_id query param.
    static func voiceChefWS(cookSessionID: UUID) -> URL {
        URL(string: "wss://voice-chef-289946863771.us-central1.run.app/?cook_session_id=\(cookSessionID.uuidString.lowercased())")!
    }
}

enum BackendError: LocalizedError {
    case badStatus(Int, String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body): return "Server \(code): \(body.prefix(120))"
        case .decodeFailed(let s): return "Couldn't read server reply: \(s)"
        }
    }
}

// =============================================================================
// MARK: - Shared HTTP helper
// =============================================================================

struct BackendHTTP {
    static func request<T: Decodable>(
        url: URL,
        method: String = "POST",
        body: Encodable? = nil,
        timeout: TimeInterval = 60
    ) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(BackendConfig.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.badStatus(0, "no response")
        }
        guard http.statusCode == 200 else {
            throw BackendError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackendError.decodeFailed(String(describing: error))
        }
    }
}

/// Tiny type-erased Encodable so callers can pass [String: Any]-style dicts.
private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

// =============================================================================
// MARK: - get-daily-feed
// =============================================================================

private struct FeedResponse: Decodable {
    let feed_date: String?
    let recipes: [FeedEntry]
}
private struct FeedEntry: Decodable {
    let id: String
    let slot: String
    let match_score: Int
    let status: String
    let pantry_warning: BackendPantryWarning?
    let recipe: BackendRecipe
}
private struct BackendPantryWarning: Decodable {
    struct CausedBy: Decodable {
        let recipe_name: String
        let slot: String
    }
    struct Short: Decodable {
        let name: String
        let reason: String?
    }
    let caused_by: CausedBy
    let short_ingredients: [Short]

    func toApp() -> PantryWarning {
        PantryWarning(
            causedBy: .init(recipeName: caused_by.recipe_name, slot: caused_by.slot),
            shortIngredients: short_ingredients.map {
                .init(name: $0.name, reason: $0.reason ?? "short")
            }
        )
    }
}

// =============================================================================
// MARK: - Recipe wire format (shared by feed, kitchen, recipe-author)
// =============================================================================

struct BackendRecipe: Decodable {
    let id: String
    let name: String
    let author: String
    let category: String
    let difficulty: String
    let time_text: String
    let budget_text: String
    let servings_base: Int
    let calories_per_serving: Int
    let ingredients: [BackendIngredient]
    let steps: [String]
    let image_url: String?
    let image_style: String?
    let source: String?

    /// `matchScore`, `feedRowID`, `pantryWarning` flow in from the surrounding
    /// FeedEntry. For kitchen recipes there's no feed context so they're nil.
    func toAppRecipe(matchScore: Int? = nil,
                     feedRowID: UUID? = nil,
                     pantryWarning: PantryWarning? = nil) -> Recipe {
        Recipe(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            author: author,
            category: MealCategory(backendSlug: category) ?? .breakfast,
            imageName: "",
            difficulty: Difficulty(backendSlug: difficulty) ?? .easy,
            time: time_text,
            budget: budget_text,
            servings: servings_base,
            calories: calories_per_serving,
            ingredients: ingredients.map { $0.toAppIngredient() },
            steps: steps,
            imageURL: image_url.flatMap(URL.init(string:)),
            matchScore: matchScore,
            feedRowID: feedRowID,
            pantryWarning: pantryWarning,
            source: source
        )
    }
}

struct BackendSubstitute: Codable, Hashable {
    let name: String
    let note: String?
}

struct BackendIngredient: Codable, Hashable {
    let name: String
    let amount: String
    let in_pantry: Bool?
    let substitute: BackendSubstitute?
    /// Phase 2 structured per-serving amount (canonical g|ml|piece). Optional —
    /// legacy recipes won't have it.
    let qty: Double?
    let unit: String?

    func toAppIngredient() -> RecipeIngredient {
        let sub: IngredientSubstitute? = substitute.map {
            IngredientSubstitute(name: $0.name, note: $0.note ?? "")
        }
        return RecipeIngredient(name: name, amount: amount, inPantry: in_pantry, substitute: sub, qty: qty, unit: unit)
    }
}

private extension MealCategory {
    init?(backendSlug: String) {
        switch backendSlug.lowercased() {
        case "breakfast": self = .breakfast
        case "lunch":     self = .lunch
        case "dinner":    self = .dinner
        case "snacks":    self = .snacks
        default: return nil
        }
    }
    var backendSlug: String {
        switch self {
        case .breakfast: return "breakfast"
        case .lunch:     return "lunch"
        case .dinner:    return "dinner"
        case .snacks:    return "snacks"
        }
    }
}
private extension Difficulty {
    init?(backendSlug: String) {
        switch backendSlug.lowercased() {
        case "easy":      self = .easy
        case "medium":    self = .medium
        case "elaborate": self = .elaborate
        default: return nil
        }
    }
}

// =============================================================================
// MARK: - Daily Feed service
// =============================================================================

struct BackendService {
    static let shared = BackendService()

    func fetchDailyFeed() async throws -> [Recipe] {
        let resp: FeedResponse = try await BackendHTTP.request(url: BackendConfig.dailyFeedEndpoint, method: "GET")
        return resp.recipes.map { entry in
            entry.recipe.toAppRecipe(
                matchScore: entry.match_score,
                feedRowID: UUID(uuidString: entry.id),
                pantryWarning: entry.pantry_warning?.toApp()
            )
        }
    }
}

// =============================================================================
// MARK: - Text Chef service
// =============================================================================

struct TextChefStartResponse: Decodable {
    let cook_session_id: String
    let chat_session_id: String
    let current_step: Int
    let total_steps: Int
    let message: String
}
struct TextChefMessageResponse: Decodable {
    let current_step: Int?
    let total_steps: Int?
    let done_step_idxs: [Int]?
    let message: String
    /// Set true when the chef edited the recipe via a ledger tool; the
    /// updated ingredients/steps ride along so the UI can refresh live.
    let ledger_changed: Bool?
    let ingredients: [BackendIngredient]?
    let steps: [String]?
    /// Present when the chef created/cancelled a timer this turn.
    let timers: [BackendTimer]?
}
struct TextChefResumeResponse: Decodable {
    struct ChatMsg: Decodable { let role: String; let text: String? }
    let found: Bool
    let cook_session_id: String?
    let chat_session_id: String?
    let current_step: Int?
    let total_steps: Int?
    let done_step_idxs: [Int]?
    let cooked_servings: Int?
    let cooked_children: Int?
    let is_finished: Bool?
    let messages: [ChatMsg]?
}
struct TextChefToggleResponse: Decodable {
    let current_step: Int
    let total_steps: Int
    let done_step_idxs: [Int]
    let toggled: Int
    let now_done: Bool
}
struct TextChefFinishResponse: Decodable {
    struct Deduction: Decodable {
        let ingredient: String
        let amount: String
        let pantry_item: String?
        let fullness_before: [Double]?
        let fullness_after: [Double]?
        let reduced_by: Double?
        let skipped: Bool?
        let reason: String?
    }
    let deductions: [Deduction]
    let cook_session_id: String?
    let already_finished: Bool?
}

struct TextChefService {
    static let shared = TextChefService()

    private struct StartBody: Encodable { let action = "start"; let recipe_id: String; let servings: Int; let children: Int }
    private struct ResumeBody: Encodable { let action = "resume"; let recipe_id: String }
    private struct SendBody: Encodable { let action = "send"; let cook_session_id: String; let text: String }
    private struct AdvanceBody: Encodable { let action = "advance"; let cook_session_id: String; let direction: String }
    private struct FinishBody: Encodable { let action = "finish"; let cook_session_id: String }
    private struct UpdateServingsBody: Encodable { let action = "update_servings"; let cook_session_id: String; let servings: Int; let children: Int }
    private struct ToggleBody: Encodable { let action = "toggle_step"; let cook_session_id: String; let step_idx: Int }

    func start(recipeID: UUID, servings: Int, children: Int) async throws -> TextChefStartResponse {
        try await BackendHTTP.request(url: BackendConfig.textChefEndpoint,
                                      body: StartBody(recipe_id: recipeID.uuidString.lowercased(),
                                                      servings: servings, children: children),
                                      timeout: 90)
    }

    /// Resume an existing active cook session if one exists for this user+recipe.
    /// Returns `found=false` if there isn't one (caller should call start instead).
    func resume(recipeID: UUID) async throws -> TextChefResumeResponse {
        try await BackendHTTP.request(url: BackendConfig.textChefEndpoint,
                                      body: ResumeBody(recipe_id: recipeID.uuidString.lowercased()),
                                      timeout: 30)
    }

    func toggleStep(cookSessionID: String, stepIdx: Int) async throws -> TextChefToggleResponse {
        try await BackendHTTP.request(url: BackendConfig.textChefEndpoint,
                                      body: ToggleBody(cook_session_id: cookSessionID, step_idx: stepIdx),
                                      timeout: 15)
    }
    func updateServings(cookSessionID: String, servings: Int, children: Int) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await BackendHTTP.request(
            url: BackendConfig.textChefEndpoint,
            body: UpdateServingsBody(cook_session_id: cookSessionID, servings: servings, children: children))
    }
    func send(cookSessionID: String, text: String) async throws -> TextChefMessageResponse {
        try await BackendHTTP.request(url: BackendConfig.textChefEndpoint,
                                      body: SendBody(cook_session_id: cookSessionID, text: text),
                                      timeout: 60)
    }
    func advance(cookSessionID: String, direction: String) async throws -> TextChefMessageResponse {
        try await BackendHTTP.request(url: BackendConfig.textChefEndpoint,
                                      body: AdvanceBody(cook_session_id: cookSessionID, direction: direction),
                                      timeout: 60)
    }
    func finish(cookSessionID: String) async throws -> TextChefFinishResponse {
        try await BackendHTTP.request(url: BackendConfig.textChefEndpoint,
                                      body: FinishBody(cook_session_id: cookSessionID),
                                      timeout: 60)
    }
}

// =============================================================================
// MARK: - Recipe Author service ("Ask Chef" chatbot)
// =============================================================================

struct RecipeAuthorStartResponse: Decodable {
    let chat_session_id: String
    /// Prior conversation for this (24h-persistent) author session, so the chat
    /// reopens where it was left. Each carries an optional suggestion card.
    let messages: [AuthorHistoryMsg]?
}
struct AuthorHistoryMsg: Decodable {
    let role: String
    let text: String
    let recipe: BackendRecipeSuggestion?

    enum CodingKeys: String, CodingKey { case role, text, recipe }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? "model"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        // Lenient: a saved suggestion card that doesn't perfectly match the
        // current shape must NOT break the whole resumed conversation — it just
        // renders as a text message without the card.
        recipe = (try? c.decodeIfPresent(BackendRecipeSuggestion.self, forKey: .recipe)) ?? nil
    }
}
struct RecipeAuthorPreviewResponse: Decodable {
    let recipe_id: String
    let image_url: String?
}
struct RecipeAuthorMessageResponse: Decodable {
    let reply: String
    let recipe: BackendRecipeSuggestion?
}
struct BackendRecipeSuggestion: Codable, Hashable {
    let category: String
    let name: String
    let difficulty: String
    let time_text: String
    let budget_text: String?
    let calories_per_serving: Int
    let servings_base: Int?
    let ingredients: [BackendIngredient]
    let steps: [String]
    /// The recipe's durable vault id, stamped on the card the moment it's
    /// suggested (its "dedicated slot"). Lets preview + add-to-feed reuse the
    /// exact same row and photo instead of re-vaulting/re-painting. Optional —
    /// legacy cards (and brand-new local ones) won't have it.
    let recipe_id: String?
    /// The card's painted image URL, if it's been painted yet (null until then).
    let image_url: String?

    enum CodingKeys: String, CodingKey {
        case category, name, difficulty, time_text, budget_text
        case calories_per_serving, servings_base, ingredients, steps
        case recipe_id, image_url
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = (try? c.decode(String.self, forKey: .category)) ?? "lunch"
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        difficulty = (try? c.decode(String.self, forKey: .difficulty)) ?? "easy"
        time_text = (try? c.decode(String.self, forKey: .time_text)) ?? ""
        budget_text = try? c.decodeIfPresent(String.self, forKey: .budget_text)
        calories_per_serving = (try? c.decode(Int.self, forKey: .calories_per_serving)) ?? 0
        servings_base = try? c.decodeIfPresent(Int.self, forKey: .servings_base)
        ingredients = (try? c.decode([BackendIngredient].self, forKey: .ingredients)) ?? []
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        recipe_id = try? c.decodeIfPresent(String.self, forKey: .recipe_id)
        image_url = try? c.decodeIfPresent(String.self, forKey: .image_url)
    }
}
struct RecipeAuthorAddResponse: Decodable {
    let recipe_id: String
    let slot: String
    let match_score: Int
    let was_new: Bool
}

struct RecipeAuthorService {
    static let shared = RecipeAuthorService()

    private struct StartBody: Encodable { let action = "start" }
    private struct SendBody: Encodable { let action = "send"; let chat_session_id: String; let text: String }
    private struct AddBody: Encodable {
        let action = "add_to_feed"
        let recipe: BackendRecipeSuggestion
        let slot: String?
    }
    private struct PreviewBody: Encodable {
        let action = "preview"
        let recipe: BackendRecipeSuggestion
    }
    private struct RecipeImageBody: Encodable {
        let action = "recipe_image"
        let recipe_id: String
    }

    /// Ensure the suggestion's vaulted row is painting, and return its id right
    /// away. The server reuses the row stamped on the card (no re-vault) and
    /// kicks the paint off in the background, so this returns in well under a
    /// second; the caller polls `recipeImage` until the URL lands.
    func preview(recipe: BackendRecipeSuggestion) async throws -> RecipeAuthorPreviewResponse {
        try await BackendHTTP.request(url: BackendConfig.recipeAuthorEndpoint,
                                      body: PreviewBody(recipe: recipe),
                                      timeout: 30)
    }

    /// Poll a recipe's current image URL (nil until the painter finishes).
    func recipeImage(recipeID: String) async throws -> RecipeAuthorPreviewResponse {
        try await BackendHTTP.request(url: BackendConfig.recipeAuthorEndpoint,
                                      body: RecipeImageBody(recipe_id: recipeID),
                                      timeout: 15)
    }

    func start() async throws -> RecipeAuthorStartResponse {
        try await BackendHTTP.request(url: BackendConfig.recipeAuthorEndpoint, body: StartBody(), timeout: 30)
    }
    func send(chatSessionID: String, text: String) async throws -> RecipeAuthorMessageResponse {
        try await BackendHTTP.request(url: BackendConfig.recipeAuthorEndpoint,
                                      body: SendBody(chat_session_id: chatSessionID, text: text),
                                      timeout: 60)
    }
    func addToFeed(recipe: BackendRecipeSuggestion, slot: MealCategory?) async throws -> RecipeAuthorAddResponse {
        try await BackendHTTP.request(url: BackendConfig.recipeAuthorEndpoint,
                                      body: AddBody(recipe: recipe, slot: slot?.backendSlug),
                                      timeout: 120) // includes paint
    }
}

extension BackendRecipeSuggestion {
    /// Convert to an app-side Recipe for the detail page.
    /// Uses the card's own `image_url` when already painted; the caller may pass
    /// a freshly-polled `imageURL` to override once the paint completes.
    func toAppRecipe(imageURL: URL? = nil) -> Recipe {
        let resolvedImage = imageURL ?? image_url.flatMap(URL.init(string:))
        // Compute a local match score from the supplied in_pantry flags.
        let totalIngs = ingredients.count
        let owned = ingredients.filter { $0.in_pantry == true }.count
        let score = totalIngs > 0 ? Int((100.0 * Double(owned) / Double(totalIngs)).rounded()) : 0
        return Recipe(
            id: UUID(),
            name: name,
            author: "Chef",
            category: MealCategory(backendSlug: category) ?? .lunch,
            imageName: "",
            difficulty: Difficulty(backendSlug: difficulty) ?? .easy,
            time: time_text,
            budget: budget_text ?? "$5",
            servings: servings_base ?? 1,
            calories: calories_per_serving,
            ingredients: ingredients.map { $0.toAppIngredient() },
            steps: steps,
            imageURL: resolvedImage,
            matchScore: score,
            source: "author"
        )
    }
}

// =============================================================================
// MARK: - Kitchen service (Saved + Cooked)
// =============================================================================

struct KitchenResponse: Decodable {
    struct Wrapped: Decodable { let recipe: BackendRecipe }
    let saved: [Wrapped]
    let cooked: [Wrapped]
}

struct KitchenService {
    static let shared = KitchenService()

    private struct SaveBody: Encodable { let action = "save";   let recipe_id: String }
    private struct UnsaveBody: Encodable { let action = "unsave"; let recipe_id: String }

    func list() async throws -> (saved: [Recipe], cooked: [Recipe]) {
        let resp: KitchenResponse = try await BackendHTTP.request(url: BackendConfig.kitchenEndpoint, method: "GET")
        return (resp.saved.map { $0.recipe.toAppRecipe() },
                resp.cooked.map { $0.recipe.toAppRecipe() })
    }
    func save(recipeID: UUID) async throws {
        struct Empty: Decodable { let ok: Bool? }
        let _: Empty = try await BackendHTTP.request(url: BackendConfig.kitchenEndpoint,
                                                     body: SaveBody(recipe_id: recipeID.uuidString.lowercased()))
    }
    func unsave(recipeID: UUID) async throws {
        struct Empty: Decodable { let ok: Bool? }
        let _: Empty = try await BackendHTTP.request(url: BackendConfig.kitchenEndpoint,
                                                     body: UnsaveBody(recipe_id: recipeID.uuidString.lowercased()))
    }
}

// =============================================================================
// MARK: - Preferences service
// =============================================================================

struct BackendPreferences: Codable {
    var cuisines: [String]
    var dietary: [String]
    var allergies: [String]
    var unit_default: String
    /// IANA timezone (e.g. "America/New_York") — drives per-user midnight curation.
    var timezone: String?
}

struct PreferencesService {
    static let shared = PreferencesService()

    func get() async throws -> BackendPreferences {
        try await BackendHTTP.request(url: BackendConfig.preferencesEndpoint, method: "GET")
    }
    func set(_ prefs: BackendPreferences) async throws -> BackendPreferences {
        try await BackendHTTP.request(url: BackendConfig.preferencesEndpoint, body: prefs)
    }
    /// Pushes only the device timezone, without touching other preferences.
    func syncTimezone(_ tz: String) async throws {
        struct Body: Encodable { let timezone: String }
        let _: BackendPreferences = try await BackendHTTP.request(
            url: BackendConfig.preferencesEndpoint, body: Body(timezone: tz))
    }
}

// =============================================================================
// MARK: - Pantry service (cloud is the source of truth)
// =============================================================================

/// One pantry row as the backend stores it.
struct BackendPantryItem: Decodable {
    let id: String
    let name: String
    let brand: String?
    let image_name: String?
    let image_kind: String?
    let category: String?
    let quantity: String?
    let fullness_levels: [Double]?
    let fullness_unit: String?
    let expiry: String?
    let stock_qty: Double?
    let stock_unit: String?

    func toApp() -> PantryItem {
        PantryItem(
            name: name,
            brand: brand ?? "",
            imageName: image_name ?? "",
            imageKind: ItemImageKind(backendSlug: image_kind ?? "generic"),
            category: PantryCategory(backendSlug: category ?? "produce"),
            quantity: quantity ?? "",
            fullnessLevels: (fullness_levels?.isEmpty == false) ? fullness_levels! : [1.0],
            fullnessUnit: fullness_unit ?? "%",
            expiry: PantryDate.parse(expiry),
            backendID: UUID(uuidString: id),
            stockQty: stock_qty,
            stockUnit: stock_unit
        )
    }
}

/// Encodable payload sent to the backend for add/update (stock is derived
/// server-side, so we never send it).
struct PantryItemPayload: Encodable {
    let id: String?
    let name: String
    let brand: String
    let image_name: String
    let image_kind: String
    let category: String
    let quantity: String
    let fullness_levels: [Double]
    let fullness_unit: String
    let expiry: String?

    init(_ item: PantryItem) {
        self.id = item.backendID?.uuidString.lowercased()
        self.name = item.name
        self.brand = item.brand
        self.image_name = item.imageName
        self.image_kind = item.imageKind.backendSlug
        self.category = item.category.backendSlug
        self.quantity = item.quantity
        self.fullness_levels = item.fullnessLevels
        self.fullness_unit = item.fullnessUnit
        self.expiry = PantryDate.format(item.expiry)
    }
}

/// Shared YYYY-MM-DD (UTC) conversion for pantry expiry dates.
enum PantryDate {
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fmt.date(from: String(s.prefix(10)))
    }
    static func format(_ d: Date?) -> String? {
        guard let d else { return nil }
        return fmt.string(from: d)
    }
}

struct PantryService {
    static let shared = PantryService()

    private struct ItemsResponse: Decodable { let items: [BackendPantryItem] }
    private struct ItemResponse: Decodable { let item: BackendPantryItem? }
    private struct AddBody: Encodable { let action = "add"; let items: [PantryItemPayload] }
    private struct UpdateBody: Encodable { let action = "update"; let item: PantryItemPayload }
    private struct DeleteBody: Encodable { let action = "delete"; let id: String }

    /// Load the full pantry from the cloud.
    func list() async throws -> [PantryItem] {
        let resp: ItemsResponse = try await BackendHTTP.request(url: BackendConfig.pantryEndpoint, method: "GET")
        return resp.items.map { $0.toApp() }
    }
    /// Save scanned items; returns the canonical rows (with ids + stock).
    func add(_ items: [PantryItem]) async throws -> [PantryItem] {
        let resp: ItemsResponse = try await BackendHTTP.request(
            url: BackendConfig.pantryEndpoint, body: AddBody(items: items.map(PantryItemPayload.init)))
        return resp.items.map { $0.toApp() }
    }
    /// Update one item; returns the refreshed row (with recomputed stock).
    @discardableResult
    func update(_ item: PantryItem) async throws -> PantryItem? {
        let resp: ItemResponse = try await BackendHTTP.request(
            url: BackendConfig.pantryEndpoint, body: UpdateBody(item: PantryItemPayload(item)))
        return resp.item?.toApp()
    }
    /// Delete one item by its backend id.
    func delete(backendID: UUID) async throws {
        struct Empty: Decodable { let ok: Bool? }
        let _: Empty = try await BackendHTTP.request(
            url: BackendConfig.pantryEndpoint, body: DeleteBody(id: backendID.uuidString.lowercased()))
    }
}

// =============================================================================
// MARK: - Feed actions (regenerate-slot + clear-warning)
// =============================================================================

struct FeedActionsService {
    static let shared = FeedActionsService()

    private struct ClearBody: Encodable { let action = "clear_warning"; let feed_row_id: String }
    private struct RegenBody: Encodable { let action = "regenerate_slot"; let slot: String }
    private struct GenericOK: Decodable {}

    func clearWarning(feedRowID: UUID) async throws {
        let _: GenericOK = try await BackendHTTP.request(
            url: BackendConfig.feedActionsEndpoint,
            body: ClearBody(feed_row_id: feedRowID.uuidString.lowercased()))
    }
    func regenerateSlot(_ slot: MealCategory) async throws {
        let _: GenericOK = try await BackendHTTP.request(
            url: BackendConfig.feedActionsEndpoint,
            body: RegenBody(slot: slot.backendSlug),
            timeout: 180) // includes Gemini gen + paint
    }
}
