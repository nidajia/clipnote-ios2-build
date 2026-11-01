import SwiftUI
import UIKit

/// 导入面板（画布 04）
///
/// 这一版只有两个入口：粘贴链接、从剪贴板读。
///
/// **「从文件导入视频 / 音频」暂时不显示**——它要么存本机（会让首页变成
/// 云端 + 本地双源），要么上传到服务端（要新端点与存储配额），都不是这一版该背的。
/// 画一个点不动的入口比如不画更糟：用户点了没反应，会以为 App 坏了。
struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    @State private var link = ""
    @State private var phase: Phase = .idle
    @State private var clipboardHasText = false

    private enum Phase: Equatable {
        case idle
        case parsing
        case failed(String)
        /// 服务端说库里已经有这条（created == false）
        case duplicate
    }

    private var trimmed: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmed.isEmpty && phase != .parsing
    }

    private var buttonTitle: String {
        switch phase {
        case .parsing: return "解析中…"
        case .failed: return "重试"
        case .idle, .duplicate: return "解析链接"
        }
    }

    /// 失败/重复都在面板里说，不关面板——关掉就把用户刚粘的链接弄丢了，
    /// 逼他重贴一次，是最让人恼火的一种小气。
    private var hint: (text: String, color: Color)? {
        switch phase {
        case .failed(let message):
            return (message, .cnRed)
        case .duplicate:
            return ("这条已经在库里了，不用再导一次。", .cnInk3)
        case .idle, .parsing:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            Text("导入")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.cnInk)
                .padding(.bottom, Metric.space1)

            TextField("粘贴视频链接，例如 B 站分享链接", text: $link)
                .textFieldStyle(.plain)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    Color.cnCard2,
                    in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                )

            PrimaryButton(
                title: buttonTitle,
                isEnabled: canSubmit,
                isLoading: phase == .parsing,
                action: submit
            )

            if let hint {
                Text(hint.text)
                    .font(.cnMeta)
                    .foregroundStyle(hint.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("或")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
                .frame(maxWidth: .infinity)

            optionRow(
                symbol: "doc.on.clipboard",
                title: "从剪贴板读取链接",
                isEnabled: clipboardHasText,
                action: pasteFromClipboard
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.top, Metric.space2)
        .padding(.bottom, Metric.space6)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        // `.presentationBackground` 要 iOS 16.4。部署目标是 16.0，所以改成
        // 自己铺底色——效果一样，只是不再依赖那个修饰符。
        .background(Color.cnCard)
        .onAppear {
            clipboardHasText = !(UIPasteboard.general.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 输入变了就把上一次的错误清掉，否则红字会挂在一条新链接下面
        .onChange(of: link) { _ in
            if case .failed = phase { phase = .idle }
            if phase == .duplicate { phase = .idle }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let text = trimmed
        phase = .parsing
        Task {
            do {
                let result = try await library.importItem(url: text)
                if result.created {
                    // 列表已在 importItem 里刷新过，关掉面板就能看到新条目
                    dismiss()
                } else {
                    phase = .duplicate
                }
            } catch let failure as ClipNoteClient.Failure {
                phase = .failed(failure.displayMessage)
            } catch {
                phase = .failed("解析失败，请稍后重试。")
            }
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        link = text
    }

    private func optionRow(
        symbol: String,
        title: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Metric.space3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isEnabled ? Color.cnBrand : Color.cnInk3)
                    .frame(width: 20)

                Text(title)
                    .font(.cnChip)
                    .foregroundStyle(isEnabled ? Color.cnInk : Color.cnInk3)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(
                Color.cnCard2,
                in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : "剪贴板里没有文字")
    }
}
