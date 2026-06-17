import SwiftUI
import UIKit
import VisionKit

/// The barcode door: a live scanner that collects every barcode the user points
/// at. Scanned codes pile up (deduped) with a running count; "Look up" sends
/// them to Open Food Facts. Anything not found comes back to the review list
/// flagged so the user can type it in or try another method.
struct BarcodeIntakeView: View {
    @Environment(\.dismiss) private var dismiss
    /// Hands the collected barcodes to the hub to look up.
    let onSubmit: ([String]) -> Void

    @State private var codes: [String] = []

    private var scannerSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

            if scannerSupported {
                BarcodeScannerRepresentable { code in
                    if !codes.contains(code) {
                        withAnimation(.smooth) { codes.append(code) }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .ignoresSafeArea()
                .overlay(alignment: .center) { reticle }
            } else {
                unsupported
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !codes.isEmpty { countPill }
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { if !codes.isEmpty { lookupButton } }
    }

    private var topBar: some View {
        HStack {
            DismissButton(style: .back) { dismiss() }
            Spacer()
            Text("Scan barcodes").font(.serif(19)).foregroundStyle(Theme.paper)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .background(.black.opacity(0.25))
    }

    private var reticle: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Theme.paper, lineWidth: 3)
            .frame(width: 250, height: 150)
            .overlay(alignment: .bottom) {
                Text("Point at a barcode")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.paper)
                    .padding(.top, 6)
                    .offset(y: 30)
            }
    }

    private var countPill: some View {
        Text("\(codes.count) scanned")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.paper))
            .padding(.bottom, 12)
    }

    private var lookupButton: some View {
        Button { onSubmit(codes) } label: {
            Text("Look up \(codes.count) item\(codes.count == 1 ? "" : "s")")
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

    private var unsupported: some View {
        VStack(spacing: 14) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("Barcode scanning isn't available")
                .font(.serif(20)).foregroundStyle(Theme.paper)
            Text("This device can't scan barcodes. Add items by photo or voice instead.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Go back")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Theme.paper, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(30)
    }
}

// MARK: - VisionKit bridge

/// Wraps the system live barcode scanner. Calls `onFound` with each new payload.
struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(barcode) = item,
                   let payload = barcode.payloadStringValue, !payload.isEmpty {
                    onFound(payload)
                }
            }
        }
    }
}
