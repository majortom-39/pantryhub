import SwiftUI

/// App frame: a black background with the Hero masthead on top (which
/// collapses as the tab content scrolls), and a black Nav Bar at the bottom.
struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab: AppTab = .recipes
    @State private var heroCollapse: CGFloat = 0

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                HeroBanner(tab: $selectedTab, collapse: heroCollapse)
                    .padding(.bottom, Theme.gap)

                Group {
                    switch selectedTab {
                    case .pantry:  PantryView(heroCollapse: $heroCollapse)
                    case .recipes: RecipesView(heroCollapse: $heroCollapse)
                    case .kitchen: KitchenView(heroCollapse: $heroCollapse)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selectedTab)
                .transition(.opacity)
                .padding(.horizontal, Theme.gap)

                NavBar(selection: $selectedTab)
            }
            .padding(.top, Theme.gap)
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) {
            heroCollapse = 0
        }
        .task {
            // One-time fetch of the Daily Feed when the app launches.
            // Pull-to-refresh on the Recipes tab can reload manually.
            await store.syncTimezone()
            if store.feedRecipes.isEmpty {
                await store.loadDailyFeed()
            }
            // Cloud is the source of truth for the pantry — load it once.
            await store.loadPantry()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppStore())
}
