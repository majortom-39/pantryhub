import SwiftUI
import CryptoKit

/// Two-tier image cache for recipe photos.
///
/// Recipe images live in Supabase Storage (cloud) — the URL is stable per
/// recipe (`<user_id>/<recipe_id>.png`). SwiftUI's `AsyncImage` re-downloads
/// every time a view reappears (no disk cache), which is why cards flashed a
/// placeholder for ~1s each time. This caches them:
///   • Memory (NSCache) — instant within a session, auto-evicts under pressure.
///   • Disk (Caches dir) — survives app launches; the OS can reclaim it.
/// First view downloads once; every view after is instant.
actor ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("recipe-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    /// Stable filename for a URL (SHA256 — deterministic across launches, unlike
    /// String.hashValue which is randomized per process).
    private func diskKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func image(for url: URL) async -> UIImage? {
        let key = diskKey(url) as NSString
        if let hit = memory.object(forKey: key) { return hit }

        let file = dir.appendingPathComponent(key as String)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key)
            return img
        }

        // De-dupe concurrent requests for the same URL (e.g. card + detail).
        if let existing = inflight[url] { return await existing.value }
        let task = Task<UIImage?, Never> {
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            memory.setObject(img, forKey: key)
            return img
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        return result
    }
}

/// Drop-in cached image view. Shows `placeholder` until the (cached) image
/// loads, then cross-fades the photo in. Use instead of `AsyncImage` for
/// recipe photos so they load instantly after the first fetch.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()        // contain fill overflow to the frame
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            // Don't blank the current photo while (re)loading — that caused the
            // "image showed then vanished" flicker when the view re-rendered or
            // was recreated. Cached loads are instant; only swap once we have a
            // new image, and keep the old one if a load fails.
            if let loaded = await ImageCache.shared.image(for: url) {
                withAnimation(.smooth(duration: 0.25)) { image = loaded }
            }
        }
    }
}
