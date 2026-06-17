import SwiftUI
import PhotosUI
import UIKit

/// The photo door: take one or more pictures with the camera and/or pick
/// several from the gallery, then send them all to the vision scanner together.
/// A receipt or a clear product shot reads best — the hint says so.
struct PhotoIntakeView: View {
    @Environment(\.dismiss) private var dismiss
    /// Hands the captured photos (already JPEG-compressed) to the hub to scan.
    let onSubmit: ([Data]) -> Void

    @State private var images: [UIImage] = []
    @State private var showCamera = false
    @State private var galleryPicks: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if images.isEmpty { emptyState } else { thumbnails }
                Spacer(minLength: 0)
                sourceButtons
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) { if !images.isEmpty { scanButton } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in if let image { images.append(image) } }
                .ignoresSafeArea()
        }
        .onChange(of: galleryPicks) { _, picks in
            Task { await loadGallery(picks) }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack {
            DismissButton(style: .back) { dismiss() }
            Spacer()
            Text("Add by photo").font(.serif(19)).foregroundStyle(Theme.paper)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("Snap your groceries")
                .font(.serif(20))
                .foregroundStyle(Theme.paper)
            Text("Got a receipt? Scan that for the best results.\nYou can add several photos at once.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 30)
    }

    private var thumbnails: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(images.indices, id: \.self) { index in
                    thumbnailCell(index)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
    }

    // Extracted so the grid body stays simple enough for the type-checker
    // (a deeply-chained inline cell was making ScrollView's init ambiguous).
    private func thumbnailCell(_ index: Int) -> some View {
        Image(uiImage: images[index])
            .resizable()
            .scaledToFill()
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    removeImage(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.paper))
                }
                .buttonStyle(.plain)
                .padding(5)
            }
    }

    /// Remove a chosen photo with a smooth animation. `Array.remove(at:)` returns
    /// the removed element, which we intentionally discard — the deletion is the
    /// only intent. Pulling this out of the view body also keeps `withAnimation`'s
    /// generic return type unambiguous.
    private func removeImage(at index: Int) {
        withAnimation(.smooth) { _ = images.remove(at: index) }
    }

    private var sourceButtons: some View {
        HStack(spacing: 12) {
            Button { showCamera = true } label: {
                sourceLabel("Take photo", icon: "camera.fill")
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $galleryPicks, maxSelectionCount: 8, matching: .images) {
                sourceLabel("Gallery", icon: "photo.on.rectangle")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, images.isEmpty ? 30 : 8)
    }

    private func sourceLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(Theme.paper)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1.3))
    }

    private var scanButton: some View {
        Button {
            let data = images.compactMap { $0.jpegCompressed() }
            onSubmit(data)
        } label: {
            Text("Scan \(images.count) photo\(images.count == 1 ? "" : "s")")
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

    // MARK: Gallery loading

    private func loadGallery(_ picks: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for pick in picks {
            if let data = try? await pick.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                loaded.append(image)
            }
        }
        await MainActor.run {
            images.append(contentsOf: loaded)
            galleryPicks = []
        }
    }
}

// MARK: - Camera picker (UIKit bridge)

/// A thin wrapper over the system camera. Returns one captured photo; the photo
/// door lets the user keep taking more.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) { self.onCapture(image) }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.onCapture(nil) }
        }
    }
}

extension UIImage {
    /// Downscale to a sensible max dimension and JPEG-compress, so a batch of
    /// photos stays small enough to upload quickly.
    func jpegCompressed(maxDimension: CGFloat = 1280, quality: CGFloat = 0.5) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
