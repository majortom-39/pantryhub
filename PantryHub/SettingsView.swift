import SwiftUI

/// Settings — cuisine and dietary preferences. Opened from the Hero Banner.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let cuisines = [
        "Italian", "Indian", "Mexican", "Chinese", "Japanese", "Thai",
        "French", "Greek", "Spanish", "Korean", "American",
        "Mediterranean", "Middle Eastern", "Vietnamese",
    ]

    private let diets = [
        "Vegetarian", "Vegan", "Low carb", "Gluten free",
        "High protein", "Dairy free",
    ]

    private let allergens = [
        "Peanuts", "Tree nuts", "Milk", "Eggs", "Soy",
        "Wheat", "Fish", "Shellfish", "Sesame",
    ]

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: Theme.gap) {
                        profileCard
                        chipsCard(title: "CUISINES YOU LOVE", options: cuisines,
                                  selection: $store.preferredCuisines)
                        chipsCard(title: "DIETARY PREFERENCES", options: diets,
                                  selection: $store.dietaryPreferences)
                        chipsCard(title: "ALLERGIES", options: allergens,
                                  selection: $store.allergies,
                                  selectedColor: Theme.alertRed)
                    }
                    .padding(.horizontal, Theme.gap)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.loadPreferences() }
        // Push changes to backend whenever any chip toggles.
        .onChange(of: store.preferredCuisines)  { Task { await store.savePreferences() } }
        .onChange(of: store.dietaryPreferences) { Task { await store.savePreferences() } }
        .onChange(of: store.allergies)          { Task { await store.savePreferences() } }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.serif(22))
                .foregroundStyle(Theme.paper)
            Spacer()
            // sheet → X per standardized dismiss rule.
            DismissButton(style: .close) { dismiss() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Profile card

    private var profileCard: some View {
        HStack(spacing: 14) {
            profilePhoto
            VStack(alignment: .leading, spacing: 3) {
                Text("Alex")
                    .font(.serif(20))
                    .foregroundStyle(Theme.ink)
                Text("Home cook")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.mutedText)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .whiteCard()
    }

    private var profilePhoto: some View {
        Group {
            if let image = UIImage.bundled("profile") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Theme.placeholderFill
                    Image(systemName: "person.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.mutedText)
                }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
    }

    // MARK: Chips card

    private func chipsCard(title: String, options: [String],
                           selection: Binding<Set<String>>,
                           selectedColor: Color = Theme.ink) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.mutedText)

            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    chip(option, selection: selection, selectedColor: selectedColor)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whiteCard()
    }

    private func chip(_ label: String,
                      selection: Binding<Set<String>>,
                      selectedColor: Color) -> some View {
        let isOn = selection.wrappedValue.contains(label)
        return Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? Theme.paper : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isOn {
                    Capsule().fill(selectedColor)
                } else {
                    Capsule().stroke(Theme.hairline, lineWidth: 1.2)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.smooth(duration: 0.2)) {
                    if isOn {
                        selection.wrappedValue.remove(label)
                    } else {
                        selection.wrappedValue.insert(label)
                    }
                }
            }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppStore())
}
