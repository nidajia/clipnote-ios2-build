import SwiftUI

/// 标签库。
///
/// **聚合在本地做，不调 `/api/v2/tags`。** 理由只有一条：标签页上写着「5 条」，
/// 点进去必须正好 5 条。本地数的是同一份 `library.items`，不可能对不上；
/// 走网络则会出现「刚删了一条，标签页还显示旧数字」这类没法解释的偏差。
/// 服务端那个端点留给 Web 与将来分页用，两边规则必须一致：
/// 排除回收站、同一条内去重、按次数倒序、次数相同按名字。
struct TagsScreen: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let tags = TagsScreen.aggregate(library.items)

        ScrollView {
            if tags.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: Metric.space3) {
                    Text(summaryLine(tags))
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)

                    ForEach(tags) { tag in
                        NavigationLink {
                            TagItemsScreen(tag: tag.name)
                        } label: {
                            row(tag)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Metric.pagePad)
            }
        }
        .background(Color.cnBg)
        .navigationTitle("标签")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            Text("还没有标签")
                .font(.cnRowTitle)
                .foregroundStyle(Color.cnInk)
            Text("给几条内容生成摘要之后，分类会自动出现在这里。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metric.pagePad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryLine(_ tags: [TagCount]) -> String {
        TagsScreen.summary(tags: tags, items: library.items)
    }

    /// 顶部那行说明。抽成静态函数是为了能测：
    /// 「各标签次数相加」很容易被写成「覆盖 N 条」，而那个数会大于库里总条数。
    static func summary(tags: [TagCount], items: [Item]) -> String {
        let withLabels = items.filter { !$0.labels.isEmpty }.count
        return "\(tags.count) 个分类 · \(withLabels) 条内容带标签"
    }

    private func row(_ tag: TagCount) -> some View {
        HStack(spacing: Metric.space3) {
            Text(tag.name)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk)

            Spacer(minLength: 0)

            Text("\(tag.count)")
                .font(.custom("Inter-Medium", size: 13, relativeTo: .subheadline))
                .foregroundStyle(Color.cnInk3)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.horizontal, Metric.space4)
        .padding(.vertical, Metric.space3)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    /// 规则就这四行，服务端 `v2_tags_payload` 是同一套。
    static func aggregate(_ items: [Item]) -> [TagCount] {
        var counts: [String: Int] = [:]
        for item in items {
            // 同一条里重复出现只算一次：模型偶尔会给出 ["AI","AI"]
            for label in Set(item.labels) where !label.isEmpty {
                counts[label, default: 0] += 1
            }
        }
        return counts
            .map { TagCount(name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

struct TagCount: Identifiable, Equatable {
    var name: String
    var count: Int
    var id: String { name }
}

/// 某个标签下的条目。
struct TagItemsScreen: View {
    var tag: String
    @EnvironmentObject private var library: LibraryStore

    private var items: [Item] {
        library.items.filter { $0.labels.contains(tag) }
    }

    var body: some View {
        List(items) { item in
            NavigationLink {
                DetailScreen(item: item)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.cnRowTitle)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(2)
                    Text(item.metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.cnCard)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle(tag)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .overlay {
            if items.isEmpty {
                Text("这个分类下的内容都移走了。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }
        }
    }
}
