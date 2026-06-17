import Foundation
import SwiftUI

/// How the Pantry list is currently filtered.
enum PantryFilter {
    case all, expiringSoon, runningLow
}

/// State of the latest backend recipe fetch.
enum FeedLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// The shared data for the whole app — the pantry, cooked & saved
/// recipes, cuisine preferences and a few cooking stats. One instance
/// is created at launch and passed to every screen.
@MainActor
final class AppStore: ObservableObject {

    /// Products currently in the user's pantry.
    @Published var pantry: [PantryItem] = SampleData.pantry

    /// Recipes the user has actually cooked (via the chef).
    @Published var cookedRecipes: [Recipe]

    /// Recipes the user bookmarked with the save button.
    @Published var savedRecipes: [Recipe]

    /// The 4 curated recipes from the backend Daily Feed (one per slot).
    /// Populated by `loadDailyFeed()`.
    @Published var feedRecipes: [Recipe] = []
    @Published var feedLoadState: FeedLoadState = .idle

    /// Cuisines the user picked in Settings.
    @Published var preferredCuisines: Set<String> = []

    /// Dietary preferences the user picked in Settings.
    @Published var dietaryPreferences: Set<String> = []

    /// Allergies the user set — ingredients to keep out of suggestions.
    @Published var allergies: Set<String> = []

    /// Default unit system for newly scanned items (per-item overrides exist on each PantryItem).
    @Published var unitDefault: String = "metric"

    /// The active filter on the Pantry list.
    @Published var pantryFilter: PantryFilter = .all

    // Cooking stats — sample values for the design phase.
    @Published var cookedThisMonth = 6

    /// Weekday indices (0 = Mon … 6 = Sun) the user cooked something this week.
    @Published var cookedDaysThisWeek: Set<Int> = [0, 1, 2, 3]

    init() {
        // No more hardcoded recipes — feed, saved and cooked all come from the
        // backend now. They populate via loadDailyFeed() and loadKitchen().
        cookedRecipes = []
        savedRecipes = []
    }

    // MARK: Recipes

    /// Recipes shown on the Recipes tab — now pulled from the backend Daily Feed.
    func recipes(in category: MealCategory) -> [Recipe] {
        feedRecipes.filter { $0.category == category }
    }

    /// The current copy of a recipe from whichever list holds it (feed, saved,
    /// or cooked). Used by the detail page so it reflects live chef edits.
    func recipe(withID id: UUID) -> Recipe? {
        feedRecipes.first { $0.id == id }
            ?? savedRecipes.first { $0.id == id }
            ?? cookedRecipes.first { $0.id == id }
    }

    /// Replace a recipe everywhere it appears after the chef edits it, so the
    /// detail page, daily feed, and kitchen all show the updated version.
    func updateRecipeEverywhere(_ r: Recipe) {
        if let i = feedRecipes.firstIndex(where: { $0.id == r.id })   { feedRecipes[i] = r }
        if let i = savedRecipes.firstIndex(where: { $0.id == r.id })  { savedRecipes[i] = r }
        if let i = cookedRecipes.firstIndex(where: { $0.id == r.id }) { cookedRecipes[i] = r }
    }

    /// Fetches today's Daily Feed from the backend.
    /// Call once on app launch; safe to retry.
    func loadDailyFeed() async {
        feedLoadState = .loading
        do {
            let fresh = try await BackendService.shared.fetchDailyFeed()
            feedRecipes = fresh
            feedLoadState = .loaded
        } catch {
            feedLoadState = .failed(error.localizedDescription)
        }
    }

    /// Loads Saved + Cooked from the backend, replacing local arrays.
    func loadKitchen() async {
        do {
            let (saved, cooked) = try await KitchenService.shared.list()
            savedRecipes = saved
            cookedRecipes = cooked
        } catch {
            // Soft-fail: keep whatever we have. Surface later if needed.
        }
    }

    /// Reports the device's current timezone to the backend so the nightly
    /// curator runs at THIS user's local midnight. Cheap, fire-and-forget.
    func syncTimezone() async {
        try? await PreferencesService.shared.syncTimezone(TimeZone.current.identifier)
    }

    /// Loads preferences from the backend into the local sets.
    func loadPreferences() async {
        do {
            let p = try await PreferencesService.shared.get()
            preferredCuisines = Set(p.cuisines)
            dietaryPreferences = Set(p.dietary)
            allergies = Set(p.allergies)
            unitDefault = p.unit_default
        } catch {
            // Soft-fail: defaults stay empty
        }
    }

    /// Pushes the current preferences to the backend.
    func savePreferences() async {
        let payload = BackendPreferences(
            cuisines: Array(preferredCuisines).sorted(),
            dietary: Array(dietaryPreferences).sorted(),
            allergies: Array(allergies).sorted(),
            unit_default: unitDefault
        )
        _ = try? await PreferencesService.shared.set(payload)
    }

    /// How much of a recipe the user can already make from their own
    /// pantry — the share of its ingredients they have, as 0–100%.
    func matchScore(for recipe: Recipe) -> Int {
        guard !recipe.ingredients.isEmpty else { return 0 }
        let owned = recipe.ingredients.filter { ingredient in
            pantry.contains { pantryHas($0.name, ingredient.name) }
        }.count
        return Int((Double(owned) / Double(recipe.ingredients.count) * 100).rounded())
    }

    /// A loose name match between a pantry product and a recipe ingredient.
    private func pantryHas(_ pantryName: String, _ recipeName: String) -> Bool {
        let a = pantryName.lowercased()
        let b = recipeName.lowercased()
        return a.contains(b) || b.contains(a)
    }

    // MARK: Pantry

    /// Whether the pantry has been loaded from the cloud at least once.
    /// Until then the UI shows the sample pantry as a placeholder.
    @Published private(set) var pantryLoaded = false

    /// Load the pantry from the cloud (the source of truth). Soft-fails: on
    /// error we keep whatever is on screen so the page is never empty.
    func loadPantry() async {
        do {
            pantry = try await PantryService.shared.list()
            pantryLoaded = true
        } catch {
            // Keep current (sample) pantry; surface later if needed.
        }
    }

    /// Add scanned items: show them immediately, save to the cloud, then refresh
    /// from the cloud so they carry their real ids + computed stock.
    func addToPantry(_ items: [PantryItem]) {
        pantry.insert(contentsOf: items, at: 0)   // optimistic
        Task {
            do {
                _ = try await PantryService.shared.add(items)
                await loadPantry()                // canonical refresh
            } catch {
                // Keep optimistic local copies (no backend id) if the save failed.
            }
        }
    }

    /// Update an item locally, then persist. The server recomputes stock, which
    /// we copy back onto the existing row (preserving its local identity).
    func update(_ item: PantryItem) {
        if let index = pantry.firstIndex(where: { $0.id == item.id }) {
            pantry[index] = item
        }
        guard item.backendID != nil else { return }   // not yet synced
        Task {
            if let refreshed = (try? await PantryService.shared.update(item)) ?? nil,
               let i = pantry.firstIndex(where: { $0.id == item.id }) {
                pantry[i].stockQty = refreshed.stockQty
                pantry[i].stockUnit = refreshed.stockUnit
            }
        }
    }

    func removeFromPantry(_ item: PantryItem) {
        pantry.removeAll { $0.id == item.id }
        if let bid = item.backendID {
            Task { try? await PantryService.shared.delete(backendID: bid) }
        }
    }

    /// Pantry items expiring within a week.
    var expiringSoonCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return pantry.filter { item in
            guard let expiry = item.expiry else { return false }
            let days = calendar.dateComponents(
                [.day], from: today, to: calendar.startOfDay(for: expiry)
            ).day ?? 99
            return days <= 7
        }.count
    }

    /// Pantry items that are running low (low average fill).
    var runningLowCount: Int {
        pantry.filter { $0.averageFullness < 0.35 }.count
    }

    // MARK: Kitchen

    /// Total ingredients across every recipe the user has cooked.
    var ingredientsUsed: Int {
        cookedRecipes.reduce(0) { $0 + $1.ingredients.count }
    }

    /// Whether a recipe is bookmarked.
    func isSaved(_ recipe: Recipe) -> Bool {
        savedRecipes.contains { $0.id == recipe.id }
    }

    /// Toggles the save (bookmark) state of a recipe. Syncs to backend.
    func toggleSaved(_ recipe: Recipe) {
        let nowSaved: Bool
        if isSaved(recipe) {
            savedRecipes.removeAll { $0.id == recipe.id }
            nowSaved = false
        } else {
            savedRecipes.insert(recipe, at: 0)
            nowSaved = true
        }
        Task {
            do {
                if nowSaved { try await KitchenService.shared.save(recipeID: recipe.id) }
                else        { try await KitchenService.shared.unsave(recipeID: recipe.id) }
            } catch {
                // Soft-fail: optimistic UI keeps the local toggle.
            }
        }
    }

    /// Called when a recipe is finished in the cooking chef.
    /// Pantry deduction + cooked_recipes write happen on the backend via text-chef finish.
    /// This just reflects the result locally.
    func saveCooked(_ recipe: Recipe) {
        if !cookedRecipes.contains(where: { $0.id == recipe.id }) {
            cookedRecipes.insert(recipe, at: 0)
        }
        cookedThisMonth += 1
        let weekday = Calendar.current.component(.weekday, from: Date())
        cookedDaysThisWeek.insert((weekday + 5) % 7)
    }
}
