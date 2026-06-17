import SwiftUI

/// Edit a pantry product. One white identity card, then the fullness —
/// pick how many containers and set each one's level on a single jar —
/// and a short details list, all on the dark background.
struct IngredientDetailView: View {
    @Environment(\.dismiss) private var dismiss

    private let original: PantryItem
    private let onSave: (PantryItem) -> Void

    @State private var name: String
    @State private var brand: String
    @State private var category: PantryCategory
    @State private var quantity: String
    @State private var fullnessLevels: [Double]
    @State private var fullnessUnit: String
    @State private var expiry: Date
    @State private var selected = 0

    private let maxContainers = 6
    private let units = ["%", "g", "kg", "oz", "ml", "L", "cups", "pieces", "servings"]

    init(item: PantryItem, onSave: @escaping (PantryItem) -> Void) {
        self.original = item
        self.onSave = onSave
        _name = State(initialValue: item.name)
        _brand = State(initialValue: item.brand)
        _category = State(initialValue: item.category)
        _quantity = State(initialValue: item.quantity)
        _fullnessLevels = State(initialValue: item.fullnessLevels)
        _fullnessUnit = State(initialValue: item.fullnessUnit)
        _expiry = State(initialValue: item.expiry
            ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
    }

    private var currentLevel: Double {
        fullnessLevels.indices.contains(selected) ? fullnessLevels[selected] : 0
    }

    private var readoutText: String {
        let u = fullnessUnit.lowercased()
        if fullnessUnit == "%" {
            return "\(Int((currentLevel * 100).rounded()))%"
        }
        if u == "pieces" || u == "servings" {
            return "\(pieceCount) \(fullnessUnit)"
        }
        // Real measure (g, ml, oz, …): show the ACTUAL amount = level × the full
        // container size parsed from the Quantity field, so the ceiling tracks
        // whatever the user enters (a full "750 ml" jar reads "750 ml", half
        // reads "375 ml") instead of the old level×100.
        if let ceiling = quantityCeiling {
            let amt = currentLevel * ceiling
            let s = abs(amt - amt.rounded()) < 0.05 ? String(Int(amt.rounded())) : String(format: "%.1f", amt)
            return "\(s) \(fullnessUnit)"
        }
        return "\(Int((currentLevel * 100).rounded()))%"
    }

    /// The full-container amount parsed from the Quantity text ("750 ml" → 750),
    /// used as the ceiling for the fill readout.
    private var quantityCeiling: Double? {
        let first = quantity.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " ×x")).first ?? ""
        let n = Formatting.parseNumber(first)
        return n.isFinite && n > 0 ? n : nil
    }

    private var jarBinding: Binding<Double> {
        Binding(
            get: { fullnessLevels.indices.contains(selected) ? fullnessLevels[selected] : 0 },
            set: { if fullnessLevels.indices.contains(selected) { fullnessLevels[selected] = $0 } }
        )
    }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 30) {
                        identityCard
                        fullnessSection
                        detailsSection
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { saveButton }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Edit product")
                .font(.serif(20))
                .foregroundStyle(Theme.paper)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: Identity card

    private var identityCard: some View {
        HStack(spacing: 16) {
            PantryItemImage(item: original)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                categoryMenu
                TextField("Name", text: $name)
                    .font(.serif(22))
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.ink)
                TextField("Brand (optional)", text: $brand)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.mutedText)
                    .tint(Theme.ink)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .environment(\.colorScheme, .light)
        .padding(.horizontal, Theme.gap)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(PantryCategory.allCases) { option in
                Button(option.rawValue) { category = option }
            }
        } label: {
            HStack(spacing: 4) {
                Text(category.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.mutedText)
        }
    }

    // MARK: Fullness

    private var fullnessSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Fullness")
                .font(.serif(22))
                .foregroundStyle(Theme.paper)

            HStack {
                Text("How many containers?")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
                containerStepper
            }

            if fullnessLevels.count > 1 {
                containerSelector
            }

            if fillStyle == .count {
                pieceControl
            } else {
                HStack(alignment: .center, spacing: 24) {
                    FullnessJar(level: jarBinding)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(readoutText)
                            .font(.serif(46))
                            .foregroundStyle(Theme.paper)
                            .contentTransition(.numericText())
                        Text(fullnessLevels.count > 1
                             ? "Drag the jar to fill container \(selected + 1)."
                             : "Drag the jar up or down to fill it.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.screenPadding)
    }

    // MARK: Piece counter (for eggs, fruit, cans — a jar makes no sense there)

    /// Which fill metaphor to show, following the *current* unit so it updates
    /// live if the user switches "Measured in" to/from pieces.
    private var fillStyle: PantryItem.FillStyle {
        switch fullnessUnit.lowercased() {
        case "pieces", "servings": return .count
        default: return .level
        }
    }

    /// Total pieces in a full container, parsed from the quantity ("12 ct" → 12).
    private var pieceTotal: Int {
        let first = quantity.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: " ×x")).first ?? ""
        let n = Formatting.parseNumber(first)
        if n.isFinite, n >= 1 { return min(99, Int(n.rounded())) }
        return 12
    }

    private var pieceCount: Int { Int((currentLevel * Double(pieceTotal)).rounded()) }

    private func setPieces(_ n: Int) {
        let clamped = max(0, min(pieceTotal, n))
        jarBinding.wrappedValue = pieceTotal > 0 ? Double(clamped) / Double(pieceTotal) : 0
    }

    private var pieceControl: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text("\(pieceCount)")
                    .font(.serif(46))
                    .foregroundStyle(Theme.paper)
                    .contentTransition(.numericText())
                Text("of \(pieceTotal) left")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                HStack(spacing: 14) {
                    stepButton("minus") { setPieces(pieceCount - 1) }
                    stepButton("plus") { setPieces(pieceCount + 1) }
                }
            }
            if pieceTotal <= 24 {
                FlowLayout(spacing: 7) {
                    ForEach(0..<pieceTotal, id: \.self) { index in
                        Circle()
                            .fill(index < pieceCount ? Theme.paper : Color.white.opacity(0.15))
                            .frame(width: 18, height: 18)
                    }
                }
            }
            Text(fullnessLevels.count > 1
                 ? "How many are left in container \(selected + 1)?"
                 : "Tap − / + for how many you have left.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private var containerStepper: some View {
        HStack(spacing: 14) {
            stepButton("minus") {
                guard fullnessLevels.count > 1 else { return }
                fullnessLevels.removeLast()
                if selected >= fullnessLevels.count {
                    selected = fullnessLevels.count - 1
                }
            }
            Text("\(fullnessLevels.count)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.paper)
                .frame(minWidth: 20)
                .contentTransition(.numericText())
            stepButton("plus") {
                guard fullnessLevels.count < maxContainers else { return }
                fullnessLevels.append(1.0)
                selected = fullnessLevels.count - 1
            }
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.paper)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.3))
        }
        .buttonStyle(.plain)
    }

    private var containerSelector: some View {
        HStack(spacing: 8) {
            ForEach(0..<fullnessLevels.count, id: \.self) { index in
                Button {
                    withAnimation(.smooth(duration: 0.3)) { selected = index }
                } label: {
                    Text("\(index + 1)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(index == selected ? Theme.ink : Theme.paper)
                        .frame(width: 42, height: 38)
                        .background {
                            if index == selected {
                                Capsule().fill(Theme.paper)
                            } else {
                                Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1.3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DETAILS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.bottom, 4)

            detailRow("Quantity") {
                TextField("e.g. 750 g tub", text: $quantity)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.paper)
                    .tint(Theme.paper)
            }
            if quantity.trimmingCharacters(in: .whitespaces).isEmpty {
                confirmHint("Add the amount so we can track how much you have.")
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            detailRow("Expires") {
                DatePicker("", selection: $expiry, displayedComponents: .date)
                    .labelsHidden()
                    .tint(Theme.paper)
            }
            if original.expiryEstimated {
                confirmHint("This date is our best guess — set the real one if you can.")
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            detailRow("Measured in") {
                Menu {
                    ForEach(units, id: \.self) { unit in
                        Button(unit == "%" ? "Percentage (%)" : unit) {
                            fullnessUnit = unit
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(fullnessUnit)
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.paper)
                }
            }
        }
        .padding(.horizontal, Theme.screenPadding)
    }

    private func detailRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.paper)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: 54)
    }

    /// A small amber line nudging the user to confirm something we guessed.
    private func confirmHint(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.warmAmber)
        .padding(.bottom, 8)
    }

    // MARK: Save

    private var saveButton: some View {
        Button {
            var updated = original
            updated.name = name.trimmingCharacters(in: .whitespaces)
            updated.brand = brand.trimmingCharacters(in: .whitespaces)
            updated.category = category
            updated.quantity = quantity.trimmingCharacters(in: .whitespaces)
            updated.fullnessLevels = fullnessLevels
            updated.fullnessUnit = fullnessUnit
            updated.expiry = expiry
            // The user has now reviewed this item, so retire the intake nudges.
            updated.needsReview = false
            updated.expiryEstimated = false
            onSave(updated)
            dismiss()
        } label: {
            Text("Save")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.paper, in: Capsule())
        }
        .buttonStyle(PressableCardStyle())
        .padding(.horizontal, Theme.gap)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.stage)
    }
}

#Preview {
    IngredientDetailView(item: SampleData.pantry[0]) { _ in }
}
