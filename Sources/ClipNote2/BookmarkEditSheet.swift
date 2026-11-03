import SwiftUI

/// 正在编辑的那个书签。
///
/// 用 `t` 作为查找键而不是数组下标：保存后会 `reload()`，
/// 下标可能在背后被重排过，而「同一秒的那个书签」不会变。
struct BookmarkDraft: Identifiable, Equatable {
    var id = UUID()
    var t: Int
    var note: String
    var by: String
}

/// 书签编辑。能写一句备注、也能删掉。
///
/// 为什么备注是可选的：书签的第一层价值是「这里值得回看」这个判断本身，
/// 逼着写一行字会让大多数人不标。想写的时候再写。
struct BookmarkEditSheet: View {
    var draft: BookmarkDraft
    var onSave: (String) -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(
        draft: BookmarkDraft,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.draft = draft
        self.onSave = onSave
        self.onDelete = onDelete
        _note = State(initialValue: draft.note)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space4) {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(DetailScreen.mmss(draft.t))
                        .font(.cnChip)
                    if draft.by == "ai" {
                        Text("AI 建议")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.cnCard3, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.cnBrand)

                TextField("写一句备注（可留空）", text: $note, axis: .vertical)
                    .font(.cnBody)
                    .lineLimit(1...4)
                    .padding(Metric.space3)
                    .background(
                        Color.cnCard3,
                        in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                    )

                PrimaryButton(title: "保存") {
                    onSave(note)
                    dismiss()
                }

                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Text("删除这个书签")
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
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .font(.cnChip)
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}
