import SwiftUI

/// 分段总结的完整页。
///
/// 为什么单独一页而不是在详情页里展开：**段数不可控**。
/// 实测一条 10 分钟的视频切出 9 段，更长的会更多；展开会把下载按钮
/// 推到第三四屏，而且一展开页面高度翻倍，滚动位置会跳。
///
/// 这一版只做一件事：把段落读清楚。点时间戳跳播放、按段加书签，
/// 留到接播放器与书签那一步——先让「读」这件事成立。
struct SegmentsScreen: View {
    var item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.space4) {
                header

                if item.segments.isEmpty {
                    Text("这条还没有分段。回到详情页点「按段落读」生成。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Metric.space2)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                            row(index: index + 1, segment: segment)
                            if index < item.segments.count - 1 {
                                Rectangle()
                                    .fill(Color.cnHairlineSoft)
                                    .frame(height: 1)
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
            }
            .padding(Metric.pagePad)
        }
        .background(Color.cnBg)
        .navigationTitle("分段")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            Text(item.title)
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(metaText)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
        }
    }

    private var metaText: String {
        var parts = ["共 \(item.segments.count) 段"]
        if !item.durationText.isEmpty { parts.append(item.durationText) }
        return parts.joined(separator: " · ")
    }

    private func row(index: Int, segment: APISegment) -> some View {
        HStack(alignment: .top, spacing: Metric.space3) {
            // 编号用 Inter：中文数字在 10 以后宽度不一，编号会参差不齐
            Text(String(format: "%02d", index))
                .font(.custom("Inter-SemiBold", size: 13, relativeTo: .subheadline))
                .foregroundStyle(Color.cnBrand)
                .frame(width: 24, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: Metric.space2) {
                    Text(segment.title)
                        .font(.cnRowTitle)
                        .foregroundStyle(Color.cnInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(DetailScreen.mmss(segment.t))
                        .font(.cnDuration)
                        .foregroundStyle(Color.cnInk3)
                }

                if !segment.summary.isEmpty {
                    Text(segment.summary)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, Metric.space3)
    }
}

struct SegmentsScreenPreviews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SegmentsScreen(item: Item(
                id: "p1",
                title: "为什么大多数人的笔记系统最后都会废掉",
                metaLine: "B 站 · 老蒋巨靠谱",
                durationText: "12:34",
                aiSummary: "收藏夹不是知识库。这条视频把「为什么你收藏了却从不回看」拆成三个层次。",
                keyPoints: ["入口太多", "没有回头路", "缺少标记"],
                labels: ["笔记", "方法"],
                segments: [
                    APISegment(title: "提出「收藏≠学习」", t: 0,
                               summary: "开头先给判断：收藏满足的是占有感，不是学习需求。"),
                    APISegment(title: "三组对照实验", t: 200,
                               summary: "用两组对照数据说明，回看率和收藏数量没有关系。"),
                    APISegment(title: "你为什么会反复收藏", t: 465,
                               summary: "把责任从自制力挪到产品结构上，这是全片最重要的一次转场。"),
                ]
            ))
        }
        .preferredColorScheme(.light)
    }
}
