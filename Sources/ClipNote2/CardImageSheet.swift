import SwiftUI

/// 「一图胜千言」的结果页：模型画背景，App 叠文字，最后给一张能分享的竖图。
struct CardImageSheet: View {
    var item: Item
    /// 截图用：直接给一张背景，跳过真实生图（CI 里没有 key、也不该花钱）。
    var previewImage: UIImage?

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case running
        case done(UIImage)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.running, .running): return true
            case (.done(let a), .done(let b)): return a === b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @State private var phase: Phase = .idle

    /// 卡片上要印的几行字。
    /// 没有要点时退到摘要的第一句——空着一大片留给用户自己猜是不行的。
    private var points: [String] {
        if !item.keyPoints.isEmpty { return Array(item.keyPoints.prefix(3)) }
        let summary = item.aiSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return [] }
        let firstSentence = summary
            .split(separator: "。", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? summary
        return [String(firstSentence.prefix(60))]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Metric.space4) {
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.top, Metric.space3)
            .background(Color.cnBg)
            .navigationTitle("一图胜千言")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                // 进来就生成一次：用户点这个入口就是为了要图，
                // 再让他点一次「开始」是多余的一步。
                if let previewImage {
                    phase = .done(renderCard(background: previewImage))
                    return
                }
                if case .idle = phase { await generate() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .running:
            VStack(spacing: Metric.space3) {
                ProgressView()
                Text("正在画背景…大约 10–20 秒")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 80)

        case .failed(let message):
            VStack(alignment: .leading, spacing: Metric.space3) {
                Text(message)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnRed)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "重试") {
                    Task { await generate() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .done(let image):
            VStack(spacing: Metric.space3) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.cnHairline, lineWidth: 0.5)
                    )

                HStack(spacing: Metric.space2) {
                    // 分享就是「导出」——系统面板里自带「存储图像」，
                    // 不必再申请相册权限，也不用维护第二个入口。
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(item.title, image: Image(uiImage: image))) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                            Text("保存 / 分享")
                                .font(.cnChip)
                        }
                        .foregroundStyle(Color.cnBg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.cnInk, in: Capsule())
                    }

                    Button {
                        Task { await generate() }
                    } label: {
                        Text("换一张")
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.cnCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func generate() async {
        phase = .running
        let config = AIConfigStore.load()
        // 提示词用**章节正文**，不是标题：用户原话「这个生图不是根据文本内容来的，
        // 好像是标题？那有什么用」。章节是这条内容里信息密度最高的部分。
        let material: String
        if !item.chapters.isEmpty {
            material = item.chapters.prefix(6)
                .map { "\($0.title)：\($0.detail)" }
                .joined(separator: "。")
        } else {
            material = item.aiSummary
        }
        let prompt = ImageGen.backgroundPrompt(title: item.title,
                                               summary: material,
                                               points: item.keyPoints)
        do {
            let background = try await ImageGen.generate(prompt: prompt, config: config)
            phase = .done(renderCard(background: background))
        } catch {
            phase = .failed((error as? ImageGen.Failure)?.errorDescription
                            ?? error.localizedDescription)
        }
    }

    /// 把背景和文字合成 1080×1440 的竖图。
    ///
    /// 文字用系统字体而不是让模型画：模型写中文经常出错字，
    /// 而这张图的唯一价值就是「能看清标题和要点」。
    @MainActor
    private func renderCard(background: UIImage) -> UIImage {
        let card = ZStack(alignment: .bottomLeading) {
            Image(uiImage: background)
                .resizable()
                .scaledToFill()
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 20) {
                Text("片记 · ClipNote")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(item.title)
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(points, id: \.self) { point in
                            Text("· \(point)")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(2)
                        }
                    }
                }
                Text(item.displayAuthor)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(64)
        }
        .frame(width: 1080, height: 1440)
        .clipped()

        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        return renderer.uiImage ?? background
    }
}
