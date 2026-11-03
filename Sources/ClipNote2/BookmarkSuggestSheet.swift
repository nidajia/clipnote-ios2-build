import SwiftUI

/// AI 建议的回看点。
///
/// 关键设计：**AI 只提议，不落库**。用户勾了才算数。
/// 自动塞进书签的后果是，那个旗子从此不代表「我看重这里」，
/// 而代表「模型觉得这里重要」——两者混在一起，时间轴就失去意义了。
struct BookmarkSuggestSheet: View {
    var suggestions: [APIBookmark]
    var onConfirm: ([APIBookmark]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int>

    init(suggestions: [APIBookmark], onConfirm: @escaping ([APIBookmark]) -> Void) {
        self.suggestions = suggestions
        self.onConfirm = onConfirm
        // 默认全选：用户点这个按钮本来就是想要建议，
        // 让他一条条勾是多余的动作；不想要的取消掉就行。
        _picked = State(initialValue: Set(suggestions.map(\.t)))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space3) {
                Text("模型从字幕里挑的，勾上才会加进你的书签。")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.top, Metric.space3)

                List {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, item in
                        Button {
                            if picked.contains(item.t) {
                                picked.remove(item.t)
                            } else {
                                picked.insert(item.t)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: Metric.space3) {
                                Image(systemName: picked.contains(item.t)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(picked.contains(item.t)
                                                     ? Color.cnBrand : Color.cnInk3)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(DetailScreen.mmss(item.t))
                                        .font(.cnDuration)
                                        .foregroundStyle(Color.cnBrand)
                                    Text(item.note)
                                        .font(.cnChip)
                                        .foregroundStyle(Color.cnInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.cnCard)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                PrimaryButton(title: picked.isEmpty ? "一条都没选" : "加入 \(picked.count) 条书签",
                              isEnabled: !picked.isEmpty) {
                    onConfirm(suggestions.filter { picked.contains($0.t) })
                    dismiss()
                }
                .padding(.horizontal, Metric.pagePad)
                .padding(.bottom, Metric.space3)
            }
            .background(Color.cnBg)
            .navigationTitle("AI 建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .font(.cnChip)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
