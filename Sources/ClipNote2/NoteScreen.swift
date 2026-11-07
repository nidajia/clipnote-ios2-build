import SwiftUI

/// 我的笔记。独立一页。
///
/// 为什么不放在详情页里直接编辑：详情页已经有简介、AI 摘要、作者备注三段文字，
/// 再加一个可编辑区域就是第四段，滚动条会变得很长，而「读」和「写」是两种状态——
/// 混在一页里，用户既读不干净也写不专注。
struct NoteScreen: View {
    var item: Item

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var text: String
    @State private var saving = false
    @State private var failed = false

    init(item: Item) {
        self.item = item
        _text = State(initialValue: item.note)
    }

    private var dirty: Bool { text != item.note }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("写点什么：这条视频对你有什么用、哪句话值得记、下次要试什么。")
                        .font(.cnBody)
                        .foregroundStyle(Color.cnInk3)
                        .padding(.horizontal, Metric.pagePad)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.cnBody)
                    .foregroundStyle(Color.cnInk)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Metric.pagePad - 5)
                    .padding(.top, 2)
            }

            Divider().overlay(Color.cnHairline)

            HStack {
                Text("\(text.count) 字")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                Spacer()
                if failed {
                    Text("没存上，检查网络")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnRed)
                } else if saving {
                    Text("保存中…")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                }
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.vertical, Metric.space2)
        }
        .background(Color.cnBg)
        .navigationTitle("我的笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // 富文本编辑单独一页：纯文本页负责「快速记一句」，
                // 需要标题/表格/代码块时再进 Markdown 页。
                // 两者写的是同一个字段，不做同步——谁最后保存以谁为准。
                NavigationLink {
                    MarkdownEditorScreen(item: item)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "textformat")
                            .font(.system(size: 11, weight: .semibold))
                        Text("富文本")
                            .font(.cnChip)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { Task { await save() } }
                    .font(.cnChip)
                    .disabled(!dirty || saving)
            }
        }
        .onDisappear {
            // 直接返回也要留下：用户不会记得点保存，而丢一段自己写的字
            // 比任何界面问题都严重。dirty 判断保证不会白写一次。
            if dirty { Task { await save() } }
        }
    }

    private func save() async {
        guard dirty, !saving else { return }
        saving = true
        failed = false
        defer { saving = false }
        let value = text
        let ok = await library.saveNote(id: item.id, note: value)
        if !ok { failed = true }
        logs.info("note.edit", "笔记落盘", meta: [
            "id": item.id, "chars": String(value.count), "ok": ok ? "1" : "0",
        ])
    }
}
