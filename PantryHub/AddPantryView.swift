import SwiftUI

/// The "Add to pantry" hub — three doors into the SAME review list:
///   • Photo  — camera + gallery, read by the vision AI
///   • Barcode — live scanner → Open Food Facts
///   • Voice  — speak your groceries, cleaned up by the AI
/// Whichever door is used, the captured items are scanned/looked-up and shown
/// in IntakeReviewView for the user to confirm before they hit the pantry.
struct AddPantryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Door: Int, Identifiable { case photo, barcode, voice; var id: Int { rawValue } }

    @State private var activeDoor: Door?
    // The review items are owned HERE (not inside the review screen's @State) so
    // per-item edits in the review list survive re-renders and don't get wiped.
    @State private var reviewItems: [PantryItem] = []
    @State private var showReview = false
    @State private var processing = false
    @State private var errorText: String?

    // Payload captured from a door, processed when its cover dismisses.
    @State private var pendingPhotos: [Data] = []
    @State private var pendingCodes: [String] = []
    @State private var pendingVoice: String = ""

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            chooser
            if processing { processingOverlay }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $activeDoor, onDismiss: processPending) { door in
            switch door {
            case .photo:
                PhotoIntakeView { data in pendingPhotos = data; activeDoor = nil }
            case .barcode:
                BarcodeIntakeView { codes in pendingCodes = codes; activeDoor = nil }
            case .voice:
                VoiceIntakeView { text in pendingVoice = text; activeDoor = nil }
            }
        }
        .fullScreenCover(isPresented: $showReview) {
            IntakeReviewView(items: $reviewItems) { dismiss() }
                .environmentObject(store)
        }
        .alert("Nothing to add", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(spacing: 0) {
            topBar
            VStack(alignment: .leading, spacing: 6) {
                Text("Add to pantry")
                    .font(.serif(28))
                    .foregroundStyle(Theme.paper)
                Text("Pick a way to add your ingredients.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 22)

            VStack(spacing: 12) {
                doorCard(.photo, icon: "camera.viewfinder", title: "Scan a photo",
                         subtitle: "Snap or upload shelves, products, or a receipt")
                doorCard(.barcode, icon: "barcode.viewfinder", title: "Scan a barcode",
                         subtitle: "Point at packaged products to pull their details")
                doorCard(.voice, icon: "mic.fill", title: "Say it out loud",
                         subtitle: "Read out your groceries and we'll list them")
            }
            .padding(.horizontal, 18)

            Spacer()
        }
    }

    private var topBar: some View {
        HStack {
            DismissButton(style: .close) { dismiss() }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func doorCard(_ door: Door, icon: String, title: String, subtitle: String) -> some View {
        Button { activeDoor = door } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.placeholderFill))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.serif(19)).foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.mutedText)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .whiteCard()
        }
        .buttonStyle(PressableCardStyle())
    }

    private var processingOverlay: some View { ScanningOverlay() }

    /// A friendlier "reading your groceries" screen: a softly pulsing scanner
    /// glyph with a sweeping highlight, plus status lines that cycle so the wait
    /// feels alive rather than a bare spinner.
    private struct ScanningOverlay: View {
        private let messages = [
            "Looking at your photos…",
            "Reading the labels…",
            "Finding brands & sizes…",
            "Tidying up your list…",
        ]
        @State private var idx = 0
        @State private var pulse = false
        @State private var sweep = false

        var body: some View {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 96, height: 96)
                            .scaleEffect(pulse ? 1.12 : 0.9)
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(Theme.paper)
                        // sweeping scan line
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.5), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: 96, height: 3)
                            .offset(y: sweep ? 34 : -34)
                            .mask(Circle().frame(width: 96, height: 96))
                    }
                    Text(messages[idx])
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.paper)
                        .id(idx)
                        .transition(.opacity)
                }
                .padding(36)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeInOut(duration: 0.4)) { idx = (idx + 1) % messages.count }
                }
            }
        }
    }

    // MARK: Processing

    private func processPending() {
        if !pendingPhotos.isEmpty {
            let photos = pendingPhotos; pendingPhotos = []
            run { try await PantryIntakeService.shared.scanImages(photos) }
        } else if !pendingCodes.isEmpty {
            let codes = pendingCodes; pendingCodes = []
            run { try await PantryIntakeService.shared.lookupBarcodes(codes) }
        } else if !pendingVoice.trimmingCharacters(in: .whitespaces).isEmpty {
            let text = pendingVoice; pendingVoice = ""
            run { try await PantryIntakeService.shared.parseVoice(text) }
        }
    }

    private func run(_ work: @escaping () async throws -> [PantryItem]) {
        processing = true
        Task {
            do {
                let items = try await work()
                await MainActor.run {
                    processing = false
                    if items.isEmpty {
                        errorText = "We couldn't pick anything out. Try again or use another method."
                    } else {
                        reviewItems = items
                        showReview = true
                    }
                }
            } catch {
                await MainActor.run {
                    processing = false
                    errorText = "Something went wrong reading your items. Please try again."
                }
            }
        }
    }
}
