import SwiftUI

/// The single review-and-confirm list every intake method funnels into —
/// photos, gallery, barcode, and voice all land here. Each row shows what was
/// captured and gently nudges the user toward the things we can't know for sure:
/// a name (when AI/lookup wasn't certain), an amount, and the expiry date.
/// Tap a row to edit it on the shared IngredientDetailView; "Add all" saves the
/// whole list to the pantry.
struct IntakeReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    /// The items being reviewed — OWNED BY THE PARENT (AddPantryView) and passed
    /// as a binding. Keeping the source of truth in the parent means per-item
    /// edits survive any re-render of the presenting view (the previous @State
    /// here was getting reset, which is why edits "disappeared").
    @Binding var items: [PantryItem]

    /// Closes the entire add-to-pantry flow once items are accepted.
    let onAccept: () -> Void

    @State private var editingItem: PantryItem?

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: Theme.gap) {
                            ForEach(items) { item in
                                Button { editingItem = item } label: { itemRow(item) }
                                    .buttonStyle(PressableCardStyle())
                            }
                        }
                        .padding(.horizontal, Theme.gap)
                        .padding(.bottom, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { if !items.isEmpty { acceptButton } }
        .sheet(item: $editingItem) { item in
            IngredientDetailView(item: item) { updated in
                if let i = items.firstIndex(where: { $0.id == updated.id }) {
                    withAnimation(.smooth) { items[i] = updated }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(items.isEmpty ? "Nothing found" : "\(items.count) item\(items.count == 1 ? "" : "s") found")
                    .font(.serif(22))
                    .foregroundStyle(Theme.paper)
                Text(items.isEmpty
                     ? "Try again, or add the items another way."
                     : "Check each one, fill in the amount and date, then add them all.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            // Cancel — leave the review without adding anything to the pantry.
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: Row

    private func itemRow(_ item: PantryItem) -> some View {
        HStack(spacing: 14) {
            PantryItemImage(item: item)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if item.needsReview {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.paper, Theme.warmAmber)
                            .offset(x: 5, y: -5)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.needsReview ? "Couldn't identify" : item.name)
                    .font(.serif(17))
                    .foregroundStyle(item.needsReview ? Theme.warmAmber : Theme.ink)
                    .lineLimit(1)
                // Show the vision model's description of what it saw but couldn't
                // name, so the user knows exactly which product to type in.
                if !item.intakeNote.isEmpty {
                    Text(item.intakeNote)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mutedText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Brand is the key signal for enrichment — always surface it when
                // we have one (it used to hide behind the amber nudge chips).
                if !item.brand.isEmpty {
                    Text(item.brand)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.7))
                        .lineLimit(1)
                }
                nudges(for: item)
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.smooth) { items.removeAll { $0.id == item.id } }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.mutedText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.placeholderFill))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .whiteCard()
    }

    /// The little amber prompts that pull the user's eye to what still needs them.
    @ViewBuilder
    private func nudges(for item: PantryItem) -> some View {
        let chips = nudgeChips(for: item)
        if chips.isEmpty {
            Text(subtitle(for: item))
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedText)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 8, weight: .bold))
                        Text(chip)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.warmAmber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.warmAmber.opacity(0.12)))
                }
            }
        }
    }

    private func nudgeChips(for item: PantryItem) -> [String] {
        var out: [String] = []
        if item.needsReview { out.append("Tap to name it") }
        if item.quantity.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Add amount") }
        if item.expiry == nil { out.append("Set expiry") }
        else if item.expiryEstimated { out.append("Confirm date") }
        return out
    }

    private func subtitle(for item: PantryItem) -> String {
        item.quantity.isEmpty ? "Full" : item.quantity
    }

    // MARK: Empty / Accept

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.white.opacity(0.4))
            Text("No items to add")
                .font(.serif(18))
                .foregroundStyle(Theme.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var acceptButton: some View {
        Button {
            store.addToPantry(items)
            onAccept()
        } label: {
            Text(items.count == 1 ? "Add to pantry" : "Add all \(items.count) to pantry")
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
