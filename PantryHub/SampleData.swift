import Foundation

/// Built-in sample content used during the design phase.
/// Recipes are no longer kept here — the Recipes tab and Kitchen are
/// fully backend-driven. What remains is only what the iOS UI still
/// needs locally:
///   - `pantry`   → mirrors the demo user's pantry rows in Supabase
///                   (used by the local AppStore.pantry until Pantry
///                    CRUD is wired to the backend)
enum SampleData {

    // MARK: - Pantry (matches the seeded pantry_items rows for the demo user)

    static let pantry: [PantryItem] = [
        // Grains & Bread
        PantryItem(name: "Corn Flakes", brand: "Kellogg's", imageName: "prod-cornflakes",
                   imageKind: .product, category: .grains, quantity: "500 g box",
                   fullnessLevels: [0.4, 0.15], fullnessUnit: "g", expiry: daysFromNow(40)),
        PantryItem(name: "Spaghetti", brand: "Barilla", imageName: "prod-spaghetti",
                   imageKind: .product, category: .grains, quantity: "500 g box",
                   fullnessLevels: [1.0], expiry: daysFromNow(200)),
        PantryItem(name: "Whole Wheat Bread", brand: "Harvest Gold", imageName: "prod-bread",
                   imageKind: .product, category: .grains, quantity: "400 g loaf",
                   fullnessLevels: [0.6], expiry: daysFromNow(3)),
        PantryItem(name: "All-Purpose Flour", brand: "Gold Medal", imageName: "prod-flour",
                   imageKind: .product, category: .grains, quantity: "1 kg bag",
                   fullnessLevels: [0.8], fullnessUnit: "g", expiry: daysFromNow(150)),

        // Dairy & Eggs
        PantryItem(name: "Eggs", category: .dairy, quantity: "6 pcs",
                   fullnessLevels: [0.66], expiry: daysFromNow(9)),
        PantryItem(name: "Milk", brand: "Amul", category: .dairy, quantity: "1 L carton",
                   fullnessLevels: [0.5], fullnessUnit: "ml", expiry: daysFromNow(4)),
        PantryItem(name: "Butter", brand: "Amul", category: .dairy, quantity: "200 g",
                   fullnessLevels: [0.3], expiry: daysFromNow(25)),
        PantryItem(name: "Greek Yogurt", brand: "Chobani", imageName: "prod-yogurt",
                   imageKind: .product, category: .dairy, quantity: "750 g tub",
                   fullnessLevels: [0.8], expiry: daysFromNow(6)),
        PantryItem(name: "Cheddar Cheese", brand: "Cabot", imageName: "prod-cheddar",
                   imageKind: .product, category: .dairy, quantity: "250 g block",
                   fullnessLevels: [0.5], expiry: daysFromNow(18)),
        PantryItem(name: "Parmesan", category: .dairy, quantity: "100 g wedge",
                   fullnessLevels: [0.3], expiry: daysFromNow(14)),

        // Fruits & Veg
        PantryItem(name: "Tomatoes", category: .produce, quantity: "6 pcs",
                   fullnessLevels: [0.7], expiry: daysFromNow(10)),
        PantryItem(name: "Onion", category: .produce, quantity: "4 pcs",
                   fullnessLevels: [0.6], expiry: daysFromNow(30)),
        PantryItem(name: "Garlic", category: .produce, quantity: "1 bulb",
                   fullnessLevels: [0.55], expiry: daysFromNow(45)),
        PantryItem(name: "Spinach", category: .produce, quantity: "1 bunch",
                   fullnessLevels: [0.45], expiry: daysFromNow(2)),
        PantryItem(name: "Lemon", category: .produce, quantity: "3 pcs",
                   fullnessLevels: [0.8], expiry: daysFromNow(12)),
        PantryItem(name: "Carrots", category: .produce, quantity: "500 g",
                   fullnessLevels: [0.7], expiry: daysFromNow(20)),
        PantryItem(name: "Potatoes", category: .produce, quantity: "1 kg",
                   fullnessLevels: [0.8], expiry: daysFromNow(35)),
        PantryItem(name: "Bell Pepper", category: .produce, quantity: "3 pcs",
                   fullnessLevels: [0.6], expiry: daysFromNow(14)),
        PantryItem(name: "Broccoli", category: .produce, quantity: "1 head",
                   fullnessLevels: [0.5], expiry: daysFromNow(9)),
        PantryItem(name: "Mushrooms", category: .produce, quantity: "250 g",
                   fullnessLevels: [0.65], expiry: daysFromNow(5)),
        PantryItem(name: "Avocado", category: .produce, quantity: "2 pcs",
                   fullnessLevels: [1.0], expiry: daysFromNow(4)),

        // Meat & Seafood
        PantryItem(name: "Chicken Breast", category: .meat, quantity: "400 g",
                   fullnessLevels: [1.0], expiry: daysFromNow(9)),
        PantryItem(name: "Ground Beef", category: .meat, quantity: "500 g",
                   fullnessLevels: [1.0], expiry: daysFromNow(8)),
        PantryItem(name: "Bacon", category: .meat, quantity: "250 g pack",
                   fullnessLevels: [0.8], expiry: daysFromNow(12)),
        PantryItem(name: "Salmon Fillet", category: .meat, quantity: "2 fillets",
                   fullnessLevels: [1.0], expiry: daysFromNow(5)),
        PantryItem(name: "Shrimp", category: .meat, quantity: "300 g",
                   fullnessLevels: [1.0], expiry: daysFromNow(8)),
        PantryItem(name: "Pork Chops", category: .meat, quantity: "4 pcs",
                   fullnessLevels: [1.0], expiry: daysFromNow(6)),

        // Condiments & Spices
        PantryItem(name: "Olive Oil", brand: "Bertolli", imageName: "prod-oliveoil",
                   imageKind: .product, category: .condiments, quantity: "500 ml",
                   fullnessLevels: [0.65], fullnessUnit: "ml", expiry: daysFromNow(120)),
        PantryItem(name: "Honey", brand: "Nature Nate's", imageName: "prod-honey",
                   imageKind: .product, category: .condiments, quantity: "340 g jar",
                   fullnessLevels: [0.9], expiry: daysFromNow(300)),
        PantryItem(name: "Cinnamon", brand: "McCormick", imageName: "prod-cinnamon",
                   imageKind: .product, category: .condiments, quantity: "50 g jar",
                   fullnessLevels: [0.7], expiry: daysFromNow(220)),
        PantryItem(name: "Salt", category: .condiments, quantity: "1 kg",
                   fullnessLevels: [0.85], fullnessUnit: "g", expiry: daysFromNow(365)),
        PantryItem(name: "Sugar", category: .condiments, quantity: "1 kg",
                   fullnessLevels: [0.6], fullnessUnit: "g", expiry: daysFromNow(300)),
        PantryItem(name: "Black Pepper", category: .condiments, quantity: "100 g",
                   fullnessLevels: [0.6], expiry: daysFromNow(240)),
        PantryItem(name: "Paprika", category: .condiments, quantity: "50 g",
                   fullnessLevels: [0.45], expiry: daysFromNow(200)),
        PantryItem(name: "Cumin", category: .condiments, quantity: "50 g",
                   fullnessLevels: [0.7], expiry: daysFromNow(220)),
        PantryItem(name: "Turmeric", category: .condiments, quantity: "50 g",
                   fullnessLevels: [0.55], expiry: daysFromNow(210)),
        PantryItem(name: "Chilli Flakes", category: .condiments, quantity: "40 g",
                   fullnessLevels: [0.3], expiry: daysFromNow(180)),
        PantryItem(name: "Oregano", category: .condiments, quantity: "30 g",
                   fullnessLevels: [0.5], expiry: daysFromNow(160)),
        PantryItem(name: "Bay Leaves", category: .condiments, quantity: "20 g",
                   fullnessLevels: [0.8], expiry: daysFromNow(300)),
        PantryItem(name: "Garam Masala", category: .condiments, quantity: "50 g",
                   fullnessLevels: [0.25], expiry: daysFromNow(190)),
        PantryItem(name: "Coriander Powder", category: .condiments, quantity: "50 g",
                   fullnessLevels: [0.65], expiry: daysFromNow(230)),
        PantryItem(name: "Nutmeg", category: .condiments, quantity: "30 g",
                   fullnessLevels: [0.7], expiry: daysFromNow(280)),

        // Frozen & Canned
        PantryItem(name: "Canned Chickpeas", brand: "Goya", imageName: "prod-chickpeas",
                   imageKind: .product, category: .frozen, quantity: "400 g can",
                   fullnessLevels: [1.0], expiry: daysFromNow(240)),
    ]

    private static func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }
}

// MARK: - Preview-only Recipe
// Lightweight stand-in used by SwiftUI #Previews. Not for runtime — at runtime
// every recipe comes from the backend Daily Feed or Kitchen.
extension Recipe {
    static var preview: Recipe {
        Recipe(
            name: "Preview Recipe",
            author: "Preview Chef",
            category: .breakfast,
            imageName: "",
            difficulty: .easy,
            time: "10 min",
            budget: "$2",
            servings: 1,
            calories: 320,
            ingredients: [
                RecipeIngredient(name: "Eggs", amount: "2", inPantry: true),
                RecipeIngredient(name: "Spinach", amount: "1 cup", inPantry: true),
                RecipeIngredient(name: "Parmesan", amount: "30 g", inPantry: false,
                                 substitute: IngredientSubstitute(name: "Cheddar",
                                                                  note: "sharper but melts well")),
            ],
            steps: [
                "Beat the eggs in a bowl until uniformly pale yellow.",
                "Wilt the spinach in a hot pan with a tiny knob of butter for 30 seconds.",
                "Pour eggs over, swirl, cook 2 minutes, fold and serve.",
            ],
            matchScore: 67
        )
    }
}
