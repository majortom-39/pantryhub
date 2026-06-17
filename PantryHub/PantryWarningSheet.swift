import SwiftUI

/// Sheet shown when the user taps the orange alert icon on a Recipe card.
/// Explains what happened (an earlier cook used up shared ingredients) and
/// offers two actions: Regenerate this slot, or keep the recipe as is.
struct PantryWarningSheet: View {
    let recipe: Recipe
    let warning: PantryWarning
    /// Called after Regenerate completes — typically reloads the feed.
    var onRegenerated: () -> Void = {}
    /// Called after Keep is tapped — clears the warning on the backend.
    var onKept: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var working: Action? = nil

    private enum Action { case regen, keep }

    var body: some View {
        VStack(spacing: 0) {
            handle
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headline
                    explanation
                    shortIngredientsList
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            actions
        }
        .background(Theme.paper)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    // MARK: Sections

    private var handle: some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(width: 36, height: 4)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
    }

    private var headline: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.warmAmber)
            Text("Heads up")
                .font(.serif(22))
                .foregroundStyle(Theme.ink)
        }
    }

    private var explanation: some View {
        let causedBy = warning.causedBy
        let count = warning.shortIngredients.count
        let things = count == 1 ? "an ingredient" : "\(count) ingredients"
        return Text("When you cooked **\(causedBy.recipeName)** for \(causedBy.slot), you used up \(things) that **\(recipe.name)** also needs.")
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var shortIngredientsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RUNNING SHORT")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.mutedText)
                .padding(.top, 4)
            ForEach(warning.shortIngredients) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.warmAmber)
                        .frame(width: 7, height: 7)
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if !item.reason.isEmpty {
                        Text("· \(item.reason)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.mutedText)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.warmAmber.opacity(0.08)))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                runKeep()
            } label: {
                Text("Keep it")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 1.4))
            }
            .buttonStyle(.plain)
            .disabled(working != nil)

            Button {
                runRegenerate()
            } label: {
                HStack(spacing: 6) {
                    if working == .regen {
                        ProgressView().tint(Theme.paper).scaleEffect(0.85)
                    }
                    Text(working == .regen ? "Regenerating…" : "Regenerate recipe")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Theme.warmAmber))
            }
            .buttonStyle(.plain)
            .disabled(working != nil)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(Theme.paper)
    }

    // MARK: Actions

    private func runKeep() {
        guard let id = recipe.feedRowID else { dismiss(); return }
        working = .keep
        Task {
            try? await FeedActionsService.shared.clearWarning(feedRowID: id)
            onKept()
            dismiss()
        }
    }

    private func runRegenerate() {
        working = .regen
        Task {
            try? await FeedActionsService.shared.regenerateSlot(recipe.category)
            onRegenerated()
            dismiss()
        }
    }
}

#Preview {
    PantryWarningSheet(
        recipe: .preview,
        warning: PantryWarning(
            causedBy: .init(recipeName: "Spinach & Mushroom Omelette", slot: "breakfast"),
            shortIngredients: [
                .init(name: "Eggs", reason: "running low"),
                .init(name: "Spinach", reason: "running low"),
            ]
        )
    )
}
