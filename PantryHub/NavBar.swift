import SwiftUI

/// The three main sections of the app.
enum AppTab: CaseIterable {
    case pantry, recipes, kitchen

    var title: String {
        switch self {
        case .pantry:  return "Pantry"
        case .recipes: return "Recipes"
        case .kitchen: return "Kitchen"
        }
    }

    var icon: String {
        switch self {
        case .pantry:  return "basket"
        case .recipes: return "book"
        case .kitchen: return "frying.pan"
        }
    }
}

/// Bottom navigation — a full-width black bar with a hairline top edge,
/// the active tab in white and the others dimmed.
struct NavBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = selection == tab
                Button {
                    withAnimation(.smooth(duration: 0.32)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19))
                            .symbolVariant(isSelected ? .fill : .none)
                            .scaleEffect(isSelected ? 1.08 : 1.0)
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? Theme.paper : Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.stage)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }
}

#Preview {
    ZStack {
        Theme.stage.ignoresSafeArea()
        VStack {
            Spacer()
            NavBar(selection: .constant(.recipes))
        }
    }
}
