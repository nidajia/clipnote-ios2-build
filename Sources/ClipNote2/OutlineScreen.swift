import SwiftUI
import UIKit

/// 脑图页。缩进大纲 + 可折叠 + 可导出 Markdown。
///
/// 为什么是缩进树而不是节点连线图：手机宽度放不下一棵可读的连线树。
/// 三个分支各带四个叶子，画出来要么字小到看不清，要么得无限横向滚动——
/// 而「能不能一眼看懂层级」比「长得像不像脑图」重要。
/// 真要图形化，应该放到 iPad 或导出到别的工具里做，不是在这块屏幕上硬塞。
struct OutlineScreen: View {
    var item: Item

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var nodes: [OutlineNode]
    @State private var generating = false
    @State private var failed: String?
    @State private var collapsed = Set<String>()
    @State private var copied = false

    init(item: Item) {
        self.item = item
        _nodes = State(initialValue: item.outline)
    }

    private struct Row: Identifiable {
        let id: String
        let node: OutlineNode
        let depth: Int
        let hasChildren: Bool
        let expanded: Bool
        /// 是否为同级最后一个。连接线据此在末项处收口，避免竖线一路悬空到页脚。
        let isLast: Bool
    }

    private var rows: [Row] {
        OutlineScreen.flatten(nodes, parent: "", depth: 0, collapsed: collapsed)
    }

    private static func flatten(
        _ nodes: [OutlineNode], parent: String, depth: Int, collapsed: Set<String>
    ) -> [Row] {
        var out: [Row] = []
        for (index, node) in nodes.enumerated() {
            let path = parent.isEmpty ? "\(index)" : "\(parent).\(index)"
            out.append(Row(id: path, node: node, depth: depth,
                           hasChildren: !node.children.isEmpty,
                           expanded: !collapsed.contains(path),
                           isLast: index == nodes.count - 1))
            if !collapsed.contains(path) {
                out += flatten(node.children, parent: path, depth: depth + 1,
                               collapsed: collapsed)
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if generating {
                    HStack(spacing: Metric.space2) {
                        RingSpinner(size: 14, color: .cnBrand)
                        Text("正在把内容整理成结构…")
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk3)
                    }
                    .padding(Metric.pagePad)
                } else if let failed {
                    VStack(alignment: .leading, spacing: Metric.space3) {
                        Text(failed)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnRed)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("再试一次") { Task { await generate() } }
                            .font(.cnChip)
                            .foregroundStyle(Color.cnBrand)
                            .buttonStyle(.plain)
                    }
                    .padding(Metric.pagePad)
                } else if nodes.isEmpty {
                    VStack(alignment: .leading, spacing: Metric.space3) {
                        Text("还没有脑图。")
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk3)
                        PrimaryButton(title: "生成脑图") { Task { await generate() } }
                    }
                    .padding(Metric.pagePad)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(Metric.pagePad)
                }
            }
        }
        .background(Color.cnBg)
        .navigationTitle("AI 脑图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !nodes.isEmpty && !generating {
                    Menu {
                        Button("重新生成") { Task { await generate() } }
                        Button(copied ? "已复制" : "复制为 Markdown") { copyMarkdown() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
        .task {
            // 进这一页就是「我要看脑图」，没有就顺手生成，
            // 不让人再点一次按钮——那一步没有决策价值。
            if nodes.isEmpty && !generating { await generate() }
        }
    }

    /// 每层缩进。16pt 时父子只靠字号区分，"从属"不是视觉事实而要靠读；
    /// 22pt 才让缩进本身成立。
    private let indentStep: CGFloat = 22
    /// 折叠箭头宽 14pt，连接线落在它的中心列上，于是竖线能从父项直贯子项。
    private let markerWidth: CGFloat = 14

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if row.hasChildren {
                Button {
                    if collapsed.contains(row.id) {
                        collapsed.remove(row.id)
                    } else {
                        collapsed.insert(row.id)
                    }
                } label: {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.cnBrand)
                        .frame(width: markerWidth, height: 18)
                }
                .buttonStyle(.plain)
            } else {
                Circle()
                    .fill(Color.cnHairline)
                    .frame(width: 4, height: 4)
                    .frame(width: markerWidth, height: 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(row.node.title)
                    .font(row.depth == 0 ? .cnChip : .cnCaption)
                    .foregroundStyle(row.depth == 0 ? Color.cnInk : Color.cnInk2)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.node.note.isEmpty {
                    Text(row.node.note)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * indentStep)
        .padding(.vertical, row.depth == 0 ? 8 : 5)
        // 连接线画在背景层：它拿到的正是整行高度（含上下内边距），
        // 相邻兄弟行首尾相接就成了一条连续的竖脊，不会断成虚线。
        .background(alignment: .topLeading) {
            if row.depth > 0 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.cnInk3.opacity(0.30))
                        .frame(width: 1,
                               height: row.isLast ? geo.size.height * 0.52 : geo.size.height)
                        .offset(x: CGFloat(row.depth - 1) * indentStep + markerWidth / 2)
                }
            }
        }
    }

    private func copyMarkdown() {
        let text = nodes.map { $0.markdown() }.joined()
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
    }

    private func generate() async {
        guard !library.isOffline, !generating else { return }
        let config = AIConfigStore.load()
        guard config.isConfigured else {
            failed = "还没配置 AI 服务。"
            return
        }
        generating = true
        failed = nil
        defer { generating = false }

        do {
            let result = try await Outliner(config: config).outline(
                title: item.title,
                summary: item.aiSummary.isEmpty ? item.summary : item.aiSummary,
                segments: item.segments,
                labels: item.labels
            )
            nodes = result
            collapsed = []
            await library.saveOutline(id: item.id, outline: result)
            logs.info("outline.built", "脑图生成完成", meta: [
                "id": item.id, "top": String(result.count),
            ])
        } catch let failure as SummarizeFailure {
            failed = failure.displayMessage
            logs.error("outline.failed", failure.displayMessage, meta: ["id": item.id])
        } catch {
            failed = "生成失败：\(error.localizedDescription)"
        }
    }
}
