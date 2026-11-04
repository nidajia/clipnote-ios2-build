import SwiftUI

/// 给作者写一句备注。
///
/// 和书签备注分开一个视图，是因为这里多了一个「从摘要生成草稿」的动作，
/// 而那个动作只对作者备注成立。
struct AuthorNoteSheet: View {
    var author: String
    var original: String
    /// 草稿来源。传空就不显示「生成草稿」按钮（比如还没跑过摘要）。
    var draftSource: String
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(
        author: String,
        original: String,
        draftSource: String,
        onSave: @escaping (String) -> Void
    ) {
        self.author = author
        self.original = original
        self.draftSource = draftSource
        self.onSave = onSave
        _note = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space4) {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(author.isEmpty ? "这位作者" : author)
                        .font(.cnChip)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.cnBrand)

                TextField("比如：讲存储很扎实，适合看架构", text: $note, axis: .vertical)
                    .font(.cnBody)
                    .lineLimit(2...5)
                    .padding(Metric.space3)
                    .background(
                        Color.cnCard3,
                        in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                    )

                if !draftSource.isEmpty {
                    Button {
                        // 覆盖而不是追加：草稿是「一句话起点」，
                        // 追加会变成两段互不相干的话
                        note = draftSource
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10, weight: .semibold))
                            Text("从摘要生成草稿")
                                .font(.cnCaption)
                        }
                        .foregroundStyle(Color.cnBrand)
                    }
                    .buttonStyle(.plain)
                }

                PrimaryButton(title: "保存") {
                    onSave(note.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }

                Button(role: .destructive) {
                    note = ""
                    onSave("")
                    dismiss()
                } label: {
                    Text("清空备注")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(Metric.pagePad)
            .background(Color.cnBg)
            .navigationTitle("作者备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .font(.cnChip)
                }
            }
        }
        .presentationDetents([.height(380)])
    }
}
