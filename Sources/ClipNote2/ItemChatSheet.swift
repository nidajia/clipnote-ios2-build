import SwiftUI

/// 「继续问」：围绕**这一条**内容的对话。
///
/// 和「问库」的区别：问库是跨条目的（拿整库当上下文），这里是单条——
/// 上下文只有这条的概述、章节和分段标题。混在一起会让回答变糊，
/// 而用户点「继续问」时想追问的正是这条里的细节。
struct ItemChatSheet: View {
    var item: Item

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    private struct Turn: Identifiable {
        let id = UUID()
        var role: String   // "user" / "assistant"
        var text: String
    }

    @State private var turns: [Turn] = []
    @State private var input = ""
    @State private var sending = false
    @State private var errorText = ""
    @FocusState private var focused: Bool

    private let suggestions = [
        "这条最值得看的结论是什么？",
        "用三句话讲清它的做法",
        "哪些地方是有争议的？",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metric.space3) {
                            head
                            if turns.isEmpty {
                                emptyState
                            } else {
                                ForEach(turns) { turn in
                                    bubble(turn).id(turn.id)
                                }
                            }
                            if sending {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("正在想…")
                                        .font(.cnCaption)
                                        .foregroundStyle(Color.cnInk3)
                                }
                                .padding(.horizontal, Metric.space3)
                                .id("thinking")
                            }
                            if !errorText.isEmpty {
                                Text(errorText)
                                    .font(.cnCaption)
                                    .foregroundStyle(Color.cnRed)
                                    .padding(.horizontal, Metric.space3)
                            }
                        }
                        .padding(.vertical, Metric.space3)
                    }
                    .onChange(of: turns.count) { _ in
                        if let last = turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                inputBar
            }
            .background(Color.cnBg)
            .navigationTitle("继续问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.cnRowTitle)
                .foregroundStyle(Color.cnInk)
                .lineLimit(2)
            Text("回答只依据这条内容的总结与章节")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.horizontal, Metric.pagePad)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            ForEach(suggestions, id: \.self) { text in
                Button {
                    input = text
                    Task { await send() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .semibold))
                        Text(text)
                            .font(.cnChip)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.cnInk2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.cnCard,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.top, Metric.space2)
    }

    private func bubble(_ turn: Turn) -> some View {
        HStack {
            if turn.role == "user" { Spacer(minLength: 40) }
            Text(turn.text)
                .font(.cnBody)
                .foregroundStyle(turn.role == "user" ? Color.cnBg : Color.cnInk)
                .lineSpacing(4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    turn.role == "user" ? Color.cnInk : Color.cnCard,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            if turn.role != "user" { Spacer(minLength: 40) }
        }
        .padding(.horizontal, Metric.pagePad)
    }

    private var inputBar: some View {
        HStack(spacing: Metric.space2) {
            TextField("想问这条内容的什么？", text: $input, axis: .vertical)
                .font(.cnBody)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.cnCard,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canSend ? Color.cnBrand : Color.cnInk3)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, Metric.space2)
        .background(Color.cnBg)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cnHairlineSoft).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !sending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        errorText = ""
        input = ""
        turns.append(Turn(role: "user", text: text))
        sending = true
        defer { sending = false }

        // 只带最近三轮：服务端也会截断，这里是省流量。
        var history: [[String: String]] = []
        for turn in turns.suffix(6) {
            history.append(["role": turn.role, "text": turn.text])
        }
        let result = await library.ask(itemId: item.id, question: text, history: history)
        if let failure = result.failure {
            errorText = failure
            return
        }
        if let answer = result.answer {
            turns.append(Turn(role: "assistant", text: answer))
        }
    }
}
