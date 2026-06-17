import SwiftUI

/// The masthead — an open black zone at the top of every tab. It is
/// full when the content is at the top and smoothly collapses to a slim
/// greeting bar as the content scrolls (driven by `collapse`, 0...1).
struct HeroBanner: View {
    @EnvironmentObject private var store: AppStore
    @Binding var tab: AppTab
    /// 0 = fully expanded, 1 = fully collapsed.
    var collapse: CGFloat

    @State private var showSettings = false
    @State private var showScanner = false
    @State private var showChat = false
    @State private var showSearch = false

    private let userName = "Alex"
    private let weekLetters = ["M", "T", "W", "T", "F", "S", "S"]

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "GOOD MORNING"
        case 12..<17: return "GOOD AFTERNOON"
        default:      return "GOOD EVENING"
        }
    }

    /// Generous natural height of the collapsible area, per tab.
    private var collapsibleEstimate: CGFloat {
        switch tab {
        case .pantry:  return 245
        case .recipes: return 162
        case .kitchen: return 228
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            greetingRow

            collapsibleArea
                .frame(maxHeight: collapsibleEstimate * (1 - collapse), alignment: .top)
                .clipped()
                .opacity(Double(1 - min(1, collapse * 2)))
                .padding(.top, (1 - collapse) * 16)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.35), value: tab)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSearch) { PantrySearchView() }
        .fullScreenCover(isPresented: $showScanner) { AddPantryView() }
        .fullScreenCover(isPresented: $showChat) { AssistantChatView() }
    }

    // MARK: Greeting (the slim bar when collapsed)

    private var greetingRow: some View {
        HStack(spacing: 12) {
            Button {
                showSettings = true
            } label: {
                profilePhoto
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Color.white.opacity(0.5))
                Text("Hello, \(userName)")
                    .font(.serif(18))
                    .foregroundStyle(Theme.paper)
            }

            Spacer()

            if tab == .pantry {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var profilePhoto: some View {
        Group {
            if let image = UIImage.bundled("profile") {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "person.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    // MARK: Collapsible area

    private var collapsibleArea: some View {
        VStack(alignment: .leading, spacing: 18) {
            headline
            actionElement
            if tab == .pantry {
                pantryStatsStrip
            } else if tab == .kitchen {
                kitchenStatsStrip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: some View {
        Text(headlineText)
            .font(.serif(33))
            .foregroundStyle(Theme.paper)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var headlineText: String {
        switch tab {
        case .pantry:  return "Here's what's\nin your pantry."
        case .recipes: return "What shall we\ncook today?"
        case .kitchen: return "Everything\nyou've cooked."
        }
    }

    // MARK: Primary element

    @ViewBuilder
    private var actionElement: some View {
        switch tab {
        case .pantry:  scanButton
        case .recipes: chefField
        case .kitchen: streakPill
        }
    }

    private var scanButton: some View {
        Button {
            showScanner = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add ingredients")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(Capsule().fill(Theme.paper))
        }
        .buttonStyle(PressableCardStyle())
    }

    private var chefField: some View {
        Button {
            showChat = true
        } label: {
            HStack(spacing: 10) {
                ChefIcon(size: 18, color: Color.white.opacity(0.8))
                Text("Ask AI Chef for a recipe…")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.paper))
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1.5))
        }
        .buttonStyle(PressableCardStyle())
    }

    /// A 7-day week strip — each day highlighted when something was cooked.
    private var streakPill: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { day in
                dayMark(day)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1.5))
    }

    private func dayMark(_ day: Int) -> some View {
        let cooked = store.cookedDaysThisWeek.contains(day)
        return Text(weekLetters[day])
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(cooked ? Theme.ink : Color.white.opacity(0.45))
            .frame(width: 30, height: 30)
            .background {
                if cooked {
                    Circle().fill(Theme.paper)
                } else {
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.2)
                }
            }
    }

    // MARK: Pantry stats (tappable filters)

    private var pantryStatsStrip: some View {
        HStack(spacing: 6) {
            pantryStat("\(store.pantry.count)", "Items", .all,
                       tint: Theme.paper)
            pantryStat("\(store.expiringSoonCount)", "Expiring soon", .expiringSoon,
                       tint: store.expiringSoonCount > 0 ? Theme.alertRed : Theme.paper)
            pantryStat("\(store.runningLowCount)", "Running low", .runningLow,
                       tint: store.runningLowCount > 0 ? Theme.warmAmber : Theme.paper)
        }
    }

    private func pantryStat(_ value: String, _ label: String, _ filter: PantryFilter,
                            tint: Color) -> some View {
        let active = store.pantryFilter == filter
        return Button {
            withAnimation(.smooth(duration: 0.25)) {
                store.pantryFilter = (store.pantryFilter == filter) ? .all : filter
            }
        } label: {
            VStack(spacing: 3) {
                Text(value)
                    .font(.serif(20))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundStyle(Color.white.opacity(active ? 0.95 : 0.62))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(active ? 0.16 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0 : 0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Kitchen stats

    private var kitchenStatsStrip: some View {
        HStack(spacing: 0) {
            kitchenStat("\(store.cookedThisMonth)", "Meals this month")
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1, height: 30)
            kitchenStat("\(store.ingredientsUsed)", "Ingredients used")
        }
    }

    private func kitchenStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.serif(20))
                .foregroundStyle(Theme.paper)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ZStack(alignment: .top) {
        Theme.stage.ignoresSafeArea()
        HeroBanner(tab: .constant(.pantry), collapse: 0)
    }
    .environmentObject(AppStore())
}
