import SwiftUI

/// 一次 AI 动作的「先选择，再干活」。
///
/// 为什么要有这一步：以前点一下就直接发请求，用户不知道它到底处理了多大范围、
/// 补充细节会不会查外部资料、这条指令到底怎么发的。等结果出来才发现不对，
/// 只能重来。把选择摊在开工之前，一次点清楚。
struct NoteAIPreflight: Identifiable, Equatable {
    var action: NoteAIAction
    var text: String
    var range: NoteAIRange?
    /// `live` / `saved` / `doc`。`saved` 表示焦点已离开编辑器、用的是记住的选区。
    var kind: String

    var id: String { "\(action.title)-\(range?.from ?? -1)-\(text.count)" }

    var isWholeDoc: Bool { range == nil }

    var scopeText: String {
        let where_ = isWholeDoc ? "全文" : "选区"
        var text = "\(where_) · \(self.text.count) 字"
        if kind == "saved" {
            text += "（用的是你刚才选中的那段）"
        }
        return text
    }
}

struct NoteAIPreflightSheet: View {
    var preflight: NoteAIPreflight
    @Binding var external: Bool
    @Binding var instruction: String
    var onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var instructionFocused: Bool

    private var needsInstruction: Bool {
        if case .custom = preflight.action { return true }
        return false
    }

    private var canStart: Bool {
        !needsInstruction || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.space4) {
                    header
                    scopeCard
                    if case .expand = preflight.action { modeCard }
                    if needsInstruction { instructionCard }
                    riskCard
                    backgroundCard
                }
                .padding(.horizontal, Metric.pagePad)
                .padding(.vertical, Metric.space3)
            }
            .background(Color.cnBg)
            .navigationTitle("确认这次怎么改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        onStart()
                    }
                    .disabled(!canStart)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: Metric.space2) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cnBrand)
            Text(preflight.action.title)
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)
        }
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这次处理")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
            Text(preflight.scopeText)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk)
                .fixedSize(horizontal: false, vertical: true)
            if preflight.isWholeDoc {
                Text("没有选中文字，所以整条笔记都会被交给模型。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metric.space3)
        .background(Color.cnCard2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("补充细节的来源")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
            Picker("来源", selection: $external) {
                Text("只用原文").tag(false)
                Text("允许查资料").tag(true)
            }
            .pickerStyle(.segmented)
            Text(external
                 ? "模型可以引入外部知识，但每一处补充后面必须标「（外部）」，方便你识别和删除。"
                 : "只把原文已有的信息展开，不引入外部事实。碎片式笔记可能没什么可展开的。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metric.space3)
        .background(Color.cnCard2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("要它怎么改")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
            TextField("例如：把这些条目按主题归成三组", text: $instruction, axis: .vertical)
                .font(.cnBody)
                .focused($instructionFocused)
                .lineLimit(2...4)
                .padding(10)
                .background(Color.cnCard3)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(Metric.space3)
        .background(Color.cnCard2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { instructionFocused = true }
    }

    private var riskCard: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.cnInk3)
            Text(riskText)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var riskText: String {
        switch preflight.action {
        case .tidy:
            return "只调结构、一个字都不改。要是它改了字，预览卡会标红。"
        case .expand(external: true):
            return "会加入原文没有的内容，采用前请过一遍；每处外部补充都标了「（外部）」。"
        case .expand(external: false):
            return "只用原文信息，不会编造。碎片式的笔记可能改不动，那就换「按指令改写」。"
        case .outline, .summary:
            return "会删掉细节。原条目还在，采用后按一次撤销就能回到改之前。"
        case .translate:
            return "只换语言，不增删内容；标题、列表、高亮结构都会保留。"
        case .complete:
            return "会补出原文没有的字。没把握时模型会在「依据」里说明出处，采用前请核对。"
        case .verify:
            return "只出一份核对报告，不会改你的正文。"
        case .custom:
            return "只按你这条指令改，不会顺手改别的。"
        }
    }

    private var backgroundCard: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.cnBrand)
            Text("开始之后可以切出 App，任务在服务端跑；回来看结果就行。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metric.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cnBrandSoft)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
