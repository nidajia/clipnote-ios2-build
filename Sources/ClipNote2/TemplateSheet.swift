import SwiftUI

/// 换摘要模板。
///
/// 一个前提必须写在界面上：**换模板只重写摘要，分段/书签/脑图不动。**
/// 用户需要知道这一点的两个原因：
/// 1. 换完发现分段没变，不会以为是坏的；
/// 2. 同样的视频在两种结构下才能比较——四条一起变就说不清差在哪。
struct TemplateSheet: View {
    var onPick: (SummaryTemplate, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: SummaryTemplate
    @State private var custom: String
    @State private var confirmOverwrite = false

    init(onPick: @escaping (SummaryTemplate, String) -> Void) {
        self.onPick = onPick
        _selected = State(initialValue: SummaryTemplateStore.load())
        _custom = State(initialValue: SummaryTemplateStore.loadCustomPrompt())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SummaryTemplate.allCases) { template in
                        Button {
                            selected = template
                        } label: {
                            HStack(alignment: .top, spacing: Metric.space2) {
                                Image(systemName: selected == template
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(selected == template
                                                     ? Color.cnBrand : Color.cnInk3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.title)
                                        .font(.cnChip)
                                        .foregroundStyle(Color.cnInk)
                                    Text(template.hint)
                                        .font(.cnMeta)
                                        .foregroundStyle(Color.cnInk3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("摘要结构")
                } footer: {
                    Text("换模板会重写摘要与要点；分段、书签、脑图保持不动。")
                        .font(.cnMeta)
                }

                if selected == .custom {
                    Section("自定义要求") {
                        TextField("比如：只列出反面证据，不要总结观点",
                                  text: $custom, axis: .vertical)
                            .font(.cnBody)
                            .lineLimit(2...5)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("换模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("应用") {
                        // 重写会覆盖现有摘要——不是不可逆（可以再换回来），
                        // 但要花一次模型调用，先问一句再花。
                        confirmOverwrite = true
                    }
                    .font(.cnChip)
                    .disabled(selected == .custom
                              && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("重写摘要？", isPresented: $confirmOverwrite) {
                Button("取消", role: .cancel) {}
                Button("重写") {
                    SummaryTemplateStore.save(selected)
                    SummaryTemplateStore.saveCustomPrompt(custom)
                    onPick(selected, custom)
                    dismiss()
                }
            } message: {
                Text("会用「\(selected.title)」重新生成摘要与要点，覆盖现在的这一份。")
            }
        }
    }
}
