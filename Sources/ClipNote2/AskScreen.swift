import SwiftUI

/// 问库（3.1）：对着自己存下来的全部内容提问，答案带引用。
///
/// 为什么不做成「搜索框的扩展」：搜索是「找那一条」，问库是「从很多条里总结」。
/// 两者的输入看起来一样，但用户期待的输出完全不同——搜索结果点进去看原文，
/// 问库的答案要能直接读，还得很清楚「这句话是从哪条来的」。
struct AskScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    @State private var question = ""
    @State private var messages: [AskMessage] = []
    @State private var asking = false
    @State private var failed: String?
    @FocusState private var focused: Bool

    struct AskMessage: Identifiable {
        let id = UUID()
        var isUser: Bool
        var text: String
        var grounded: Bool = true
        var citations: [APIAskCitation] = []
    }

    private var examples: [String] {
        [
            "我存的关于 AI 泡沫的内容，主要观点是什么？",
            "代码动画那个工具叫什么？在哪下载？",
            "我最近存的财经类内容有哪些分歧？",
            "什么是向量数据库？",
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            inputBar
        }
        .background(Color.cnBg)
        .navigationTitle("问库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnBrand)
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if messages.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metric.space4) {
                    ForEach(messages) { message in
                        bubble(message)
                    }
                    if asking {
                        HStack(spacing: Metric.space2) {
                            RingSpinner(size: 14, color: .cnBrand)
                            Text("正在翻你的库…")
                                .font(.cnMeta)
                                .foregroundStyle(Color.cnInk3)
                        }
                        .padding(.horizontal, Metric.pagePad)
                    }
                }
                .padding(.vertical, Metric.space3)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.space4) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("问你的库")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.cnInk)
                    Text("答案只来自你自己存的内容，会标出是从哪几条来的。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Metric.space2) {
                    ForEach(examples, id: \.self) { one in
                        Button {
                            question = one
                            Task { await send() }
                        } label: {
                            HStack(spacing: Metric.space2) {
                                Text(one)
                                    .font(.cnChip)
                                    .foregroundStyle(Color.cnInk)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.cnInk3)
                            }
                            .padding(Metric.space3)
                            .background(
                                Color.cnCard,
                                in: RoundedRectangle(cornerRadius: Metric.radiusCard,
                                                     style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let failed {
                    Text(failed)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.top, Metric.space4)
        }
    }

    private func bubble(_ message: AskMessage) -> some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            if message.isUser {
                HStack {
                    Spacer(minLength: 44)
                    Text(message.text)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                        .padding(Metric.space3)
                        .background(
                            Color.cnBrand.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Metric.radiusCard,
                                                 style: .continuous)
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: Metric.space2) {
                    // 来源标签放在答案上方：先告诉用户「这是哪来的」，
                    // 再让他读内容。库外的通用回答必须一眼能看出来。
                    HStack(spacing: 4) {
                        Image(systemName: message.grounded ? "books.vertical" : "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text(message.grounded ? "来自你存的内容" : "通用知识 · 库里没有相关")
                            .font(.cnCaption)
                    }
                    .foregroundStyle(Color.cnInk3)

                    Text(message.text)
                        .font(.cnBody)
                        .foregroundStyle(Color.cnInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if !message.citations.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("来自")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                            ForEach(message.citations) { one in
                                citationRow(one)
                            }
                        }
                    }
                }
                .padding(Metric.space3)
                .background(
                    Color.cnCard,
                    in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                )
            }
        }
        .padding(.horizontal, Metric.pagePad)
    }

    private func citationRow(_ one: APIAskCitation) -> some View {
        NavigationLink {
            if let item = library.items.first(where: { $0.id == one.id }) {
                DetailScreen(item: item)
            } else {
                Text("这条已经不在库里了。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: one.kind == "image" ? "photo" : "play.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cnBrand)
                Text(one.title)
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnBrand)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.cnHairline)

            HStack(alignment: .bottom, spacing: Metric.space2) {
                TextField("问点什么…", text: $question, axis: .vertical)
                    .font(.cnChip)
                    .lineLimit(1 ... 4)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Color.cnCard2,
                        in: RoundedRectangle(cornerRadius: Metric.radiusButton,
                                             style: .continuous)
                    )

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(canSend ? Color.cnBrand : Color.cnInk3)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.vertical, Metric.space2)
        }
        .background(Color.cnCard)
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !asking
    }

    private func send() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        failed = nil
        question = ""
        messages.append(AskMessage(isUser: true, text: text))
        asking = true
        defer { asking = false }

        do {
            let result = try await library.ask(question: text)
            messages.append(AskMessage(isUser: false,
                                       text: result.answer,
                                       grounded: result.grounded,
                                       citations: result.citations))
        } catch let failure as ClipNoteClient.Failure {
            failed = failure.displayMessage
            messages.append(AskMessage(isUser: false,
                                       text: "这次没问成：\(failure.displayMessage)"))
        } catch {
            failed = error.localizedDescription
            messages.append(AskMessage(isUser: false,
                                       text: "这次没问成：\(error.localizedDescription)"))
        }
    }
}
