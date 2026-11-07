import SwiftUI

/// 写批注。
///
/// 一次只编辑一句，不是「批注管理页」。理由：批注的触发点永远是
/// 「我正读到这句、有话想说」，脱离了句子的批注列表很难写，也很难找。
struct AnnotationEditor: View {
    var quote: String
    var timeText: String
    /// 已有内容（编辑时传入），新写时为空。
    var existing: String
    var onSave: (String) -> Void
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(quote: String, timeText: String, existing: String,
         onSave: @escaping (String) -> Void, onDelete: (() -> Void)? = nil) {
        self.quote = quote
        self.timeText = timeText
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: existing)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space3) {
                // 原文必须露出来：批注脱离了「当时那句话」就失去意义，
                // 半年后回看只剩自己的评语，根本想不起在说什么。
                HStack(alignment: .top, spacing: 6) {
                    Rectangle()
                        .fill(Color.cnBrand.opacity(0.35))
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(timeText)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnBrand)
                        Text(quote)
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Metric.space2)

                TextEditor(text: $text)
                    .font(.cnBody)
                    .foregroundStyle(Color.cnInk)
                    .scrollContentBackground(.hidden)
                    .background(
                        Color.cnCard2,
                        in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                    )
                    .frame(minHeight: 140)
                    .focused($focused)

                Text("\(trimmed.count) 字")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)

                Spacer(minLength: 0)
            }
            .padding(Metric.pagePad)
            .background(Color.cnBg)
            .navigationTitle("批注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let onDelete, !existing.isEmpty {
                        Button("删除", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                        .font(.cnChip)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onSave(trimmed)
                        dismiss()
                    }
                    .font(.cnChip)
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = existing.isEmpty }
        }
    }
}
