import SwiftUI

/// 编辑区下方的 AI 动作条。
///
/// 三个固定动作 + 自由指令。做成标签而不是下拉菜单：
/// 这个功能的价值在于「随手就能用」，多一层展开就少一半使用率。
struct NoteAIBar: View {
    var configured: Bool
    var running: Bool
    var onAction: (NoteAIAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("整理排版", action: .tidy)
                    chip("补充细节", action: .expand)
                    chip("精简成要点", action: .outline)
                    chip("按指令改写", action: .custom(""))
                    if running {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, Metric.pagePad)
                .padding(.vertical, 8)
            }
            if !configured {
                Text("未配置模型 · 去「我 · AI 设置」填好服务地址、模型和 Key 即可使用")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.bottom, 6)
            }
        }
    }

    /// 不带图标：四个胶囊在 390pt 上刚好排满一行。
    /// 每加一个 ✨ 就要宽出 14pt，四个就是 56pt——正好把第四个挤出屏幕。
    private func chip(_ title: String, action: NoteAIAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Text(title)
                .font(.cnChip)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
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
            HStack(spacing: 6) {
                Text(preview.action.title)
                    .font(.cnChip.weight(.semibold))
                    .foregroundStyle(Color.cnInk)
                Text(preview.scope)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                Spacer(minLength: 0)
                Text("预览")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }

            if let warning = preview.warning {
                Text("⚠︎ " + warning)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Text(preview.markdown)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 172)

            HStack(spacing: 10) {
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
                Spacer(minLength: 0)
            }
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
}

/// 预览数据。`selection` 记住这段结果是针对哪段文字生成的——
/// 采用时必须用它判断是替换选区还是整篇，不能再读一次当前选区
/// （用户在这期间点了一下正文，选区就没了）。
struct NoteAIPreview: Equatable {
    var action: NoteAIAction
    var scope: String
    var selection: String
    var markdown: String
    var warning: String?
}
