import SwiftUI

/// 编辑区下方的 AI 动作条。
///
/// 两排而不是一排：七个动作排成一行必然会切边，或者退化成一排横向滚动。
/// 这排只在键盘收起时出现（见 NoteScreen），所以多占的一行不会挤压输入。
struct NoteAIBar: View {
    var configured: Bool
    var running: Bool
    var onAction: (NoteAIAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                chip("整理排版", action: .tidy)
                chip("补充细节", action: .expand(external: false))
                chip("精简要点", action: .outline)
                chip("总结成段", action: .summary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                chip("翻译", action: .translate)
                chip("补全", action: .complete)
                chip("核实", action: .verify)
                chip("按指令改写", action: .custom(""))
                if running {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer(minLength: 0)
            }
            if !configured {
                Text("未配置模型 · 去「我 · AI 设置」填好服务地址、模型和 Key 即可使用")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, 8)
    }

    private func chip(_ label: String, action: NoteAIAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Text(label)
                .font(.cnChip)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.cnBrandSoft)
                .foregroundStyle(Color.cnBrand)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!configured || running)
        .opacity(configured ? 1 : 0.45)
    }
}

/// 预览卡。**采用之前，正文一个字都不会变**——这是这个功能的安全边界。
struct NoteAICard: View {
    var preview: NoteAIPreview
    var onApply: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let warning = preview.warning {
                Text("⚠︎ " + warning)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Text(preview.attributed)
                    .font(.cnMeta)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 176)

            if let basis = preview.basis {
                VStack(alignment: .leading, spacing: 2) {
                    Text("依据").font(.cnMeta).foregroundStyle(Color.cnInk3)
                    Text(basis)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cnCard2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            footer
        }
        .padding(12)
        .background(Color.cnCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.cnHairline, lineWidth: 1)
        )
        .padding(.horizontal, Metric.pagePad)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(preview.action.title)
                .font(.cnChip.weight(.semibold))
                .foregroundStyle(Color.cnInk)
            Text(preview.scope)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
            Spacer(minLength: 0)
            Text(preview.isReport ? "报告 · 不改正文" : preview.legend)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if preview.isReport {
                Button("知道了") { onDiscard() }
                    .font(.cnChip)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.cnBrand)
                    .clipShape(Capsule())
            } else {
                Button("采用") { onApply() }
                    .font(.cnChip)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.cnBrand)
                    .clipShape(Capsule())
                Button("放弃") { onDiscard() }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.cnCard2)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

/// 预览数据。`selection` 记住这段结果是针对哪段文字生成的——
/// 采用时必须用它判断是替换选区还是整篇，不能再读一次当前选区
/// （用户在这期间点了一下正文，选区就没了）。
struct NoteAIPreview: Equatable {
    var action: NoteAIAction
    var scope: String
    var selection: String
    /// 选区范围。`nil` = 整篇。采用时必须按它写回，不能按「当前选区」。
    var range: NoteAIRange?
    var markdown: String
    var diff: [DiffSegment]
    var basis: String?
    var warning: String?

    var isReport: Bool { action.isReport }

    var legend: String {
        diff.contains(where: { $0.kind != .same }) ? "绿=新增 红=删除" : "预览"
    }

    /// 把差异渲染成带底色的富文本。
    /// 绿底＝新增，红底删除线＝删掉，其余原样——一眼能看出动了哪里。
    var attributed: AttributedString {
        var out = AttributedString()
        for segment in diff {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .insert:
                piece.backgroundColor = Color.cnGreenSoft
            case .delete:
                piece.backgroundColor = Color.cnRed.opacity(0.16)
                piece.strikethroughStyle = .single
            }
            out += piece
        }
        return out
    }
}
