import SwiftUI
import UIKit

/// 封面图的内存缓存。
///
/// 之前每张封面都用 `AsyncImage`：它是「按视图实例」的，滚出屏幕再滚回来
/// 就是一次全新的加载与解码，表现是滑动一顿一顿、图还会闪一下。
/// 这里用 NSCache 存已解码的 UIImage，命中时首帧就出图，不再走网络。
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "clipnote-cover-cache")
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        do {
            let (data, _) = try await session.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        } catch {
            return nil
        }
    }
}

/// 带内存缓存的远程图片。外层负责尺寸与裁切，这里只负责「有没有图」。
struct RemoteImage: View {
    var url: URL?
    var mode: ContentMode = .fill
    /// 图还没到时露出的底色；默认透明，由外层占位层负责视觉。
    var placeholder: Color = .clear

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode)
            } else {
                placeholder
            }
        }
        // 用字符串做 id：URL 不是 Hashable 的稳定键，重建时容易重复触发。
        .task(id: url?.absoluteString ?? "") {
            // 列表复用换了 URL：命中缓存就同步出图，没命中先清掉旧图，
            // 避免短暂显示上一条的封面（串图）。
            image = url.flatMap { ImageMemoryCache.shared.cached($0) }
            await load()
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        // 命中缓存同步赋值：滚动回来时第一帧就是图，不会闪。
        if let hit = ImageMemoryCache.shared.cached(url) {
            image = hit
            return
        }
        let loaded = await ImageMemoryCache.shared.load(url)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
