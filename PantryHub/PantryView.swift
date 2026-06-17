import SwiftUI

/// Tab 1 — the user's pantry, grouped into collapsible categories.
/// The list responds to the filter set by the hero stats.
struct PantryView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var heroCollapse: CGFloat
    @State private var editingItem: PantryItem?
    @State private var collapsed: Set<PantryCategory> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.gap) {
                if store.pantry.isEmpty {
                    emptyCard
                } else if filteredPantry.isEmpty {
                    noMatchCard
                } else {
                    controlRow

                    ForEach(activeCategories) { category in
                        sectionHeader(category)

                        if !collapsed.contains(category) {
                            ForEach(items(in: category)) { item in
                                Button {
                                    editingItem = item
                                } label: {
                                    pantryRow(item)
                                }
                                .buttonStyle(PressableCardStyle())
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .tracksHeroCollapse($heroCollapse)
        .sheet(item: $editingItem) { item in
            IngredientDetailView(item: item) { updated in
                store.update(updated)
            }
        }
    }

    // MARK: Filtering

    private var filteredPantry: [PantryItem] {
        switch store.pantryFilter {
        case .all:
            return store.pantry
        case .expiringSoon:
            return store.pantry.filter { expiryInfo($0.expiry).urgent }
        case .runningLow:
            return store.pantry.filter { $0.averageFullness < 0.35 }
        }
    }

    private var activeCategories: [PantryCategory] {
        PantryCategory.allCases.filter { category in
            filteredPantry.contains { $0.category == category }
        }
    }

    private func items(in category: PantryCategory) -> [PantryItem] {
        filteredPantry.filter { $0.category == category }
    }

    private var allCollapsed: Bool {
        !activeCategories.isEmpty && activeCategories.allSatisfy { collapsed.contains($0) }
    }

    // MARK: Control row

    private var controlRow: some View {
        HStack {
            Text("\(filteredPantry.count) items")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))

            Spacer()

            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    if allCollapsed {
                        collapsed.removeAll()
                    } else {
                        collapsed = Set(activeCategories)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: allCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                    Text(allCollapsed ? "Expand all" : "Collapse all")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.paper)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.gap)
        .padding(.top, 20)
    }

    // MARK: Section header

    private func sectionHeader(_ category: PantryCategory) -> some View {
        let isCollapsed = collapsed.contains(category)
        return Button {
            withAnimation(.smooth(duration: 0.3)) {
                if isCollapsed {
                    collapsed.remove(category)
                } else {
                    collapsed.insert(category)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(category.rawValue)
                    .font(.serif(18))
                    .foregroundStyle(Theme.paper)
                Spacer()
                Text("\(items(in: category).count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }
            .padding(.horizontal, Theme.gap)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Pantry row

    private func pantryRow(_ item: PantryItem) -> some View {
        HStack(spacing: 14) {
            PantryItemImage(item: item)
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if item.count > 1 {
                        Text("×\(item.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.paper)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.ink))
                            .overlay(Capsule().stroke(Theme.paper, lineWidth: 1.5))
                            .offset(x: 6, y: -6)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.serif(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            expiryView(item.expiry)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .whiteCard()
    }

    private func subtitle(for item: PantryItem) -> String {
        let amount = item.quantity.isEmpty ? "No amount" : item.quantity
        return item.brand.isEmpty ? amount : "\(item.brand)  ·  \(amount)"
    }

    // MARK: Expiry

    @ViewBuilder
    private func expiryView(_ date: Date?) -> some View {
        let info = expiryInfo(date)
        if info.urgent {
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(info.text)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.alertRed))
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text("EXPIRES")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.mutedText)
                Text(info.text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private func expiryInfo(_ date: Date?) -> (text: String, urgent: Bool) {
        guard let date else { return ("Not set", false) }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        switch days {
        case ..<0:  return ("Expired", true)
        case 0:     return ("Today", true)
        case 1:     return ("1 day left", true)
        case 2...7: return ("\(days) days left", true)
        default:
            return (date.formatted(.dateTime.day().month(.abbreviated).year()), false)
        }
    }

    // MARK: Empty states

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "basket")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.mutedText)
            Text("Your pantry is empty")
                .font(.serif(18))
                .foregroundStyle(Theme.ink)
            Text("Add some ingredients to get started.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .whiteCard()
        .padding(.top, 20)
    }

    private var noMatchCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.mutedText)
            Text("Nothing matches this filter")
                .font(.serif(18))
                .foregroundStyle(Theme.ink)
            Text("Tap the active stat in the header to clear it.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .whiteCard()
        .padding(.top, 20)
    }
}

#Preview {
    ZStack {
        Theme.stage
        PantryView(heroCollapse: .constant(0)).padding(8)
    }
    .environmentObject(AppStore())
}
