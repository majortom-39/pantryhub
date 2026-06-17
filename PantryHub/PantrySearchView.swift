import SwiftUI

/// A search window for the pantry — opened from the magnifying-glass in
/// the hero. Type a product name and the matching items show up.
struct PantrySearchView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var editingItem: PantryItem?
    @FocusState private var focused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var results: [PantryItem] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return [] }
        return store.pantry.filter {
            $0.name.lowercased().contains(q) || $0.brand.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                content
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $editingItem) { item in
            IngredientDetailView(item: item) { updated in
                store.update(updated)
            }
        }
        .onAppear { focused = true }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                TextField("Search your pantry", text: $query)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.paper)
                    .tint(Theme.paper)
                    .focused($focused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))

            // sheet → X per standardized dismiss rule.
            DismissButton(style: .close) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            hint("Start typing to find a product in your pantry.")
        } else if results.isEmpty {
            hint("No products match “\(trimmedQuery)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.gap) {
                    ForEach(results) { item in
                        Button {
                            editingItem = item
                        } label: {
                            resultRow(item)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, Theme.gap)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private func resultRow(_ item: PantryItem) -> some View {
        HStack(spacing: 14) {
            FoodImage(name: item.imageName)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.serif(17))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.mutedText)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .whiteCard()
    }

    private func subtitle(for item: PantryItem) -> String {
        let amount = item.quantity.isEmpty ? "No amount" : item.quantity
        return item.brand.isEmpty ? amount : "\(item.brand)  ·  \(amount)"
    }
}

#Preview {
    PantrySearchView()
        .environmentObject(AppStore())
}
