import SwiftUI

/// The full steps list — shown as a sheet from both AI Chef screens.
/// Each row is a checkbox the user can tap to mark/unmark done. Tapping
/// hits the backend `toggle_step` action so the chef's ledger stays in sync.
struct StepsSheet: View {
    @ObservedObject var session: CookingSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: Theme.gap) {
                        ForEach(session.recipe.steps.indices, id: \.self) { index in
                            stepRow(index: index, step: session.recipe.steps[index])
                        }
                    }
                    .padding(.horizontal, Theme.gap)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    // Re-layout smoothly when toggle changes current step
                    .animation(.smooth(duration: 0.25), value: session.currentStep)
                    .animation(.smooth(duration: 0.25), value: session.doneStepIdxs)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Steps")
                    .font(.serif(20))
                    .foregroundStyle(Theme.paper)
                Text(session.recipe.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer()
            // Sheet = X button per the standardized rule.
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
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func stepRow(index: Int, step: String) -> some View {
        let isCurrent = index == session.currentStep && !session.isFinished
        let isDone = session.doneStepIdxs.contains(index) || session.isFinished
        return Button {
            Task { await session.toggleStep(index) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isDone ? Theme.ink : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isDone ? Theme.ink : Theme.hairline, lineWidth: 1.5)
                        )
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.paper)
                    } else {
                        Text("\(index + 1)")
                            .font(.serif(13))
                            .foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 26, height: 26)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    // Ingredient amounts are {{tokens}} scaled to the cook's chosen
                    // servings; times/temps stay as **bold**. Both render bold.
                    Text(Formatting.scaleStepTokens(step, factor: session.effectiveServings / Double(max(1, session.recipe.servings)), bold: true).asInlineMarkdown)
                        .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isDone ? Theme.mutedText : Theme.ink)
                        .strikethrough(isDone, color: Theme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    // Same amber "short" flag as the recipe detail page — keeps
                    // the original step amount but flags what's short (issue c).
                    ForEach(session.recipe.stepShortages(in: step, effective: session.effectiveServings, pantry: session.pantrySnapshot), id: \.name) { s in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                            Text("\(s.name) — short ~\(s.deficit)").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Theme.warmAmber)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.paper)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .stroke(Theme.ink, lineWidth: isCurrent ? 2 : 0)
                    )
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

#Preview {
    StepsSheet(session: CookingSession(recipe: .preview))
}
