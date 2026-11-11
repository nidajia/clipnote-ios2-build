import Photos
import UIKit
import SwiftUI

/// 图文作品（抖音图集）的图片区。
///
/// 为什么单独一块而不是复用播放器那块：图文**没有视频流**，用 16:9 的播放器
/// 外壳装竖图会把两侧裁掉一大半，而且那个播放键点了必然失败。图集该有自己
/// 的形状：竖版、可翻页、一眼能看出「第几张 / 共几张」。
struct ImagePostSurface: View {
    var item: Item
    /// 点开大图时带上当前页码，全屏从同一张开始看。
    var onOpen: (Int) -> Void

    @State private var index = 0

    /// 没有图集字段时退回封面：老条目只存了 cover，至少还能看一张，
    /// 而不是给用户一块占位渐变。
    private var urls: [URL] {
        if !item.images.isEmpty { return item.images }
        return [item.coverURL].compactMap { $0 }
    }

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                ZStack(alignment: .topLeading) {
                    if urls.isEmpty {
                        LinearGradient(
                            colors: [item.coverTop, item.coverBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        TabView(selection: $index) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { pair in
                                AsyncImage(url: pair.element,
                                           transaction: Transaction(animation: nil)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    case .failure:
                                        Image(systemName: "photo")
                                            .font(.system(size: 28, weight: .regular))
                                            .foregroundStyle(.white.opacity(0.5))
                                    default:
                                        Color.black.opacity(0.04)
                                    }
                                }
                                .tag(pair.offset)
                                .clipped()
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }

                    ImageBadge(text: "图文", systemImage: "photo.on.rectangle.angled")
                        .padding(12)

                    if urls.count > 1 {
                        counter
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomTrailing)
                            .padding(12)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onOpen(index) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("图文作品，共 \(urls.count) 张")
            .accessibilityAddTraits(.isButton)
    }

    private var counter: some View {
        Text("\(index + 1) / \(urls.count)")
            .font(.cnCaption)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.5), in: Capsule())
            .monospacedDigit()
    }
}

/// 图片角标。和 `noStreamBadge` 同一套视觉：半透明黑底 + 白字。
struct ImageBadge: View {
    var text: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.cnCaption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.5), in: Capsule())
    }
}

/// 全屏看图：横滑翻页、点一下收起控件。
///
/// 不做缩放：图集的用法是「快速看完这几张」，双指缩放要接管手势、
/// 还要处理与翻页的冲突，收益不抵这一轮的复杂度和崩溃风险。
struct ImageGalleryScreen: View {
    var item: Item
    var startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true
    /// 正在写相册。批量保存时这一屏不能退出，否则会中断。
    @State private var saving = false
    @State private var saveNote: String?

    private var urls: [URL] {
        if !item.images.isEmpty { return item.images }
        return [item.coverURL].compactMap { $0 }
    }

    init(item: Item, startIndex: Int) {
        self.item = item
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { pair in
                    AsyncImage(url: pair.element,
                               transaction: Transaction(animation: nil)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            VStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .font(.system(size: 32, weight: .regular))
                                Text("这张没加载出来")
                                    .font(.cnCaption)
                            }
                            .foregroundStyle(.white.opacity(0.55))
                        default:
                            ProgressView().tint(.white)
                        }
                    }
                    .tag(pair.offset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { chromeVisible.toggle() }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if let saveNote {
                        Text(saveNote)
                            .font(.cnCaption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(.horizontal, 24)
                            .padding(.bottom, 10)
                            .transition(.opacity)
                    }
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.18), value: chromeVisible)
        .animation(.easeInOut(duration: 0.18), value: saveNote)
    }

    /// 底部：页码 + 保存。图集的用法就是「看完想留下」，
    /// 「保存」必须在这一屏里，让用户退回详情页再找入口等于没做。
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if urls.count > 1 {
                Text("\(index + 1) / \(urls.count)")
                    .font(.cnCaption)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45), in: Capsule())
            }

            Spacer(minLength: 0)

            if saving {
                HStack(spacing: 6) {
                    RingSpinner(size: 12, color: .white)
                    Text("保存中…")
                        .font(.cnCaption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.45), in: Capsule())
            } else {
                saveButton("保存这张") {
                    Task { await saveCurrent() }
                }
                if urls.count > 1 {
                    saveButton("全部保存") {
                        Task { await saveAll() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func saveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.cnCaption)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func saveCurrent() async {
        guard !saving, index < urls.count else { return }
        saving = true
        let outcome = await ImageSaver.save(url: urls[index])
        saving = false
        switch outcome {
        case .saved:
            flash("已保存到相册")
        case .denied:
            flash("没有相册权限。到「设置 → 片记 → 照片」里允许「添加照片」后再试。")
        case .failed(let message):
            flash(message)
        }
    }

    private func saveAll() async {
        guard !saving else { return }
        saving = true
        var saved = 0
        for (offset, url) in urls.enumerated() {
            let outcome = await ImageSaver.save(url: url)
            switch outcome {
            case .saved:
                saved += 1
            case .denied:
                saving = false
                flash("没有相册权限。到「设置 → 片记 → 照片」里允许「添加照片」后再试。")
                return
            case .failed:
                // 单张失败不该中断整批：用户要的是「能存几张存几张」
                continue
            }
            if urls.count > 1 {
                saveNote = "正在保存 \(offset + 1)/\(urls.count)…"
            }
        }
        saving = false
        flash(saved > 0 ? "已保存 \(saved) 张到相册" : "没有保存成功，稍后再试")
    }

    /// 提示 2.2 秒后自己消失，不留一条永久横在图片上
    private func flash(_ text: String) {
        saveNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [self] in
            if saveNote == text { saveNote = nil }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !item.displayAuthor.isEmpty {
                    Text(item.displayAuthor)
                        .font(.cnCaption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - 播放地址的最后一道闸

extension APIPlaybackPayload {
    /// 这个地址能不能交给 `AVPlayer`。
    ///
    /// 必须挡住的是「图片」：图文作品的封面曾被服务端误判成视频直链，
    /// `mimeType` 还写着 video/mp4。`AVPlayerItem(url:)` 加载一张 webp
    /// 不会老老实实报错——AVKit 会直接崩。所以这层校验不是防御性冗余，
    /// 它是最后一道闸。
    var isPlayableMedia: Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            return false
        }

        let imageExts = [".webp", ".jpg", ".jpeg", ".png", ".gif", ".avif", ".heic", ".bmp"]
        func looksLikeImage(_ raw: String) -> Bool {
            let low = raw.lowercased()
            let path = URL(string: low)?.path ?? low
            if imageExts.contains(where: { path.hasSuffix($0) }) { return true }
            // 图片 CDN 即使没有扩展名也不能当视频
            return ["douyinpic", "xhscdn", "sns-img", "aweme-avatar", "byteimg"]
                .contains(where: { low.contains($0) })
        }

        if looksLikeImage(url) { return false }

        // 走本服务代理的地址：真身在被编码的 u 参数里
        if let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
           let target = comps.queryItems?.first(where: { $0.name == "u" })?.value,
           looksLikeImage(target) {
            return false
        }
        return true
    }
}

// MARK: - 保存到相册

/// 把图片写进相册。
///
/// 只要 `.addOnly` 权限：保存一张图不该要求「读取你的全部照片」。
/// 权限被拒时给一句人话，不反复弹系统框——系统只让问一次，
/// 再弹也弹不出来，只会让按钮看起来是坏的。
enum ImageSaver {
    enum Outcome {
        case saved
        case denied
        case failed(String)
    }

    static func save(url: URL) async -> Outcome {
        guard let fetched = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: fetched.0) else {
            return .failed("这张没下载下来")
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .denied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return .saved
        } catch {
            return .failed("写相册失败：\(error.localizedDescription)")
        }
    }
}
