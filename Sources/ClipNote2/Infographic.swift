import SwiftUI
import UIKit

/// 一页「摘要 + 分段」的长图（信息图）。
///
/// 为什么做成一张图而不是一页可滚动的界面：这一段内容用户**想带走**。
/// 想贴到群里、发给没装 App 的人、存进笔记软件。界面截图要么带上状态栏，
/// 要么只截到半屏；而这里画的是一份完整、没有交互、可以独立存在的纸张。
///
/// 版式取舍：
/// - 固定宽 390pt（和详情页同一套栅格），高度由内容自己决定——
///   3 段和 9 段都会得到一张「刚好装下」的图，不会留大片空白。
/// - 只用文字和细线，不用卡片和阴影：长图会被缩放看图，
///   卡片边框缩小后只剩噪点，细线反而更稳。
/// - 强制浅色。分享出去的图不跟随查看者的外观，深色海报在聊天窗口里
///   容易糊成一块；同一份内容任何时候生成都应该是同一个样子。
struct InfographicCard: View {
    var item: Item
    /// 生成日期。做成参数是为了截图可复现，不是为了给用户改。
    var generatedAt: Date = Date()

    /// 与 `SnapshotSupport.phone` 一致的画布宽度
    static let width: CGFloat = 390

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Spacer().frame(height: 18)

            Text(item.title)
                .font(.custom("PingFangSC-Semibold", size: 22, relativeTo: .title2))
                .foregroundStyle(Color.cnInk)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if !metaText.isEmpty {
                Spacer().frame(height: 8)
                Text(metaText)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }

            if !item.aiSummary.isEmpty {
                rule
                sectionLabel("摘要")

                Text(item.aiSummary)
                    .font(.custom("PingFangSC-Regular", size: 14, relativeTo: .body))
                    .foregroundStyle(Color.cnInk2)
                    .lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.keyPoints.isEmpty {
                    Spacer().frame(height: 14)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.cnBrand)
                                    .frame(width: 4, height: 4)
                                    // 圆点和首行文字的中线对齐：中文行高 20，
                                    // 4pt 的点放在 8pt 处正好压在字腰上
                                    .padding(.top, 8)
                                Text(point)
                                    .font(.custom("PingFangSC-Regular", size: 13, relativeTo: .subheadline))
                                    .foregroundStyle(Color.cnInk2)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !item.labels.isEmpty {
                    Spacer().frame(height: 16)
                    HStack(spacing: 6) {
                        ForEach(item.labels, id: \.self) { label in
                            Text(label)
                                .font(.custom("PingFangSC-Medium", size: 11, relativeTo: .caption))
                                .foregroundStyle(Color.cnBrand)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.cnBrandSoft, in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if !item.segments.isEmpty {
                rule
                sectionLabel("分段 · \(item.segments.count)")

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                        segmentRow(index: index + 1, segment: segment)
                        if index < item.segments.count - 1 {
                            Rectangle()
                                .fill(Color.cnHairlineSoft)
                                .frame(height: 1)
                                .padding(.leading, 26)
                        }
                    }
                }
            }

            Spacer().frame(height: 22)

            Rectangle()
                .fill(Color.cnHairline)
                .frame(height: 1)

            Spacer().frame(height: 12)

            HStack(spacing: 6) {
                Text("片记 · 一页读完一条片子")
                    .font(.custom("PingFangSC-Medium", size: 10, relativeTo: .caption2))
                    .foregroundStyle(Color.cnInk3)
                Spacer(minLength: 0)
                Text("摘要由 AI 提炼，可能与原片有出入")
                    .font(.custom("PingFangSC-Regular", size: 10, relativeTo: .caption2))
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.cnBg)
    }

    // MARK: - 零件

    /// 顶部眉标：一条品牌色短杠 + 产品名 + 生成日期。
    /// 短杠而不是整条横线：整条横线会和下面的分隔线抢层级。
    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.cnBrand)
                .frame(width: 16, height: 3)
            Text("片记 CLIPNOTE")
                .font(.custom("PingFangSC-Medium", size: 10, relativeTo: .caption2))
                .tracking(1.4)
                .foregroundStyle(Color.cnInk3)
            Spacer(minLength: 0)
            Text(Self.dateFormatter.string(from: generatedAt))
                .font(.custom("Inter-Medium", size: 10, relativeTo: .caption2))
                .foregroundStyle(Color.cnInk3)
        }
    }

    private var rule: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)
            Rectangle()
                .fill(Color.cnHairline)
                .frame(height: 1)
            Spacer().frame(height: 16)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("PingFangSC-Semibold", size: 11, relativeTo: .caption))
            .tracking(0.8)
            .foregroundStyle(Color.cnBrand)
            .padding(.bottom, 8)
    }

    private func segmentRow(index: Int, segment: APISegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", index))
                .font(.custom("Inter-SemiBold", size: 10, relativeTo: .caption2))
                .foregroundStyle(Color.cnBrand)
                .frame(width: 16, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(segment.title)
                        .font(.custom("PingFangSC-Semibold", size: 13, relativeTo: .subheadline))
                        .foregroundStyle(Color.cnInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(Self.mmss(segment.t))
                        .font(.custom("Inter-Medium", size: 10, relativeTo: .caption2))
                        .foregroundStyle(Color.cnInk3)
                }

                if !segment.summary.isEmpty {
                    Text(segment.summary)
                        .font(.custom("PingFangSC-Regular", size: 12, relativeTo: .footnote))
                        .foregroundStyle(Color.cnInk2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 9)
    }

    /// 「平台 · 作者 · 时长」。作者为空时整段跳过，不写一个孤零零的分隔点。
    private var metaText: String {
        var parts: [String] = []
        if !item.author.isEmpty { parts.append(item.author) }
        let platform = item.metaLine
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != item.author }
        parts.append(contentsOf: platform)
        if !item.durationText.isEmpty { parts.append(item.durationText) }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    static func mmss(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

// MARK: - 渲染

/// 把 `InfographicCard` 画成位图 / 落地成文件。
///
/// 用 `ImageRenderer` 而不是 `UIGraphicsImageRenderer`：版式是 SwiftUI 写的，
/// 再抄一遍 UIKit 绘制等于养两份代码，改一处忘一处。
///
/// 只在这里定死 scale：长图会被缩放浏览，1x 会明显发虚，而 3x 对
/// 一张 1000–3000pt 高的图约 30MB 内存，仍在安全区内。
@MainActor
enum InfographicRenderer {
    static let scale: CGFloat = 3

    static func makeImage(_ item: Item, generatedAt: Date = Date()) -> UIImage? {
        let content = InfographicCard(item: item, generatedAt: generatedAt)
            .frame(width: InfographicCard.width)
            // 强制浅色：分享出去的图不跟随设备外观（见 `InfographicCard` 注释）
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// 落到临时目录并返回文件地址。
    /// 分享面板吃一个文件比吃一个 `UIImage` 稳：存到相册、存到文件、
    /// 发微信都走同一条路径，而且失败时能明确说「没写出来」。
    static func makeFile(_ item: Item, generatedAt: Date = Date()) -> URL? {
        guard let image = makeImage(item, generatedAt: generatedAt),
              let data = image.pngData() else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infographic", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("片记-\(fileNameSafe(item.title)).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 标题里可能有 `/` `?` 这类文件名非法字符——不处理会得到一个写不出去的路径。
    static func fileNameSafe(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "长图" : String(trimmed.prefix(24))
    }
}

// MARK: - 预览页

/// 点「长图」后看到的那一页：先看，再决定发不发。
///
/// 不做成「点了直接弹分享面板」：用户没法确认这张图长什么样，
/// 而且分享面板一取消就什么都拿不到，还得再点一次。
struct InfographicSheet: View {
    var item: Item

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var logs: LogStore
    @State private var image: UIImage?
    @State private var fileURL: URL?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cnBg.ignoresSafeArea()

                if let image = image {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal, Metric.pagePad)
                            .padding(.vertical, Metric.space4)
                    }
                } else if let failure = failure {
                    VStack(spacing: Metric.space2) {
                        Text("长图没能生成")
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk)
                        Text(failure)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnInk3)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Metric.pagePad)
                } else {
                    VStack(spacing: Metric.space3) {
                        ActivitySpinner(style: .medium)
                        Text("正在排版…")
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnInk3)
                    }
                }
            }
            .navigationTitle("信息图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.cnChip)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let fileURL = fileURL {
                    shareBar(fileURL)
                } else if image != nil {
                    Text("长图没能存成文件，这一版暂时分享不了。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .frame(maxWidth: .infinity)
                        .padding(Metric.space3)
                        .background(Color.cnBg)
                }
            }
        }
        .task {
            guard image == nil else { return }
            await render()
        }
    }

    private func shareBar(_ url: URL) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.cnHairlineSoft)
                .frame(height: 1)

            // 预览标题不传：默认就是文件名（`片记-标题.png`），
            // 少一层泛型推断，也少一个版本差异的坑。
            ShareLink(item: url) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                    Text("分享 / 存为图片")
                        .font(.cnButton)
                }
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    Color.cnBrand,
                    in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                )
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.top, Metric.space3)
        }
        .background(Color.cnBg)
    }

    /// 深色下 brand 被提亮，白字对比不足——和 `PrimaryButton` 同一条规则
    private var labelColor: Color { scheme == .dark ? .cnBg : .white }

    private func render() async {
        let started = Date()
        guard let image = await InfographicRenderer.makeImage(item) else {
            failure = "排版没有产出图像，换个页面再试一次。"
            logs.error("infographic.render_failed", "长图没有产出图像", meta: ["id": item.id])
            return
        }
        self.image = image
        fileURL = await InfographicRenderer.makeFile(item)
        if fileURL == nil {
            // 图能看、但存不成文件：分享按钮不出现，得说清是「存不下来」而不是「没反应」
            logs.error("infographic.write_failed", "长图没写出来", meta: ["id": item.id])
        }
        logs.info("infographic.rendered", "生成信息图", meta: [
            "id": item.id,
            "segments": String(item.segments.count),
            "px": "\(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))",
            "ms": String(Int(Date().timeIntervalSince(started) * 1000)),
        ])
    }
}
