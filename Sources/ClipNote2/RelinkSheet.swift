import SwiftUI

/// 给老条目补原始链接。
///
/// 存在的理由：库里那几条是 Web 端导入的，快照里没有 bvid 和 UP 主 mid，
/// 所以「作者主页」和「原视频」都跳不了。重新导入一次能补，但会多一条重复——
/// 这里让用户粘一次链接就地把字段补齐，不动任何内容。
struct RelinkSheet: View {
    var item: Item
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    @State private var text = ""
    @State private var running = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space4) {
                Text("把这条视频的原始链接粘进来，补上作者主页和原视频地址。")
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("当前的标题：\(item.title)")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(2)

                TextField("粘贴链接或整段分享文案", text: $text, axis: .vertical)
                    .font(.cnBody)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Metric.space3)
                    .background(
                        Color.cnCard3,
                        in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                    )

                if let error {
                    Text(error)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PrimaryButton(
                    title: running ? "补上中…" : "补上",
                    isEnabled: !running && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await submit() }
                }

                Text("会先核对链接里的视频标题和这条是否一致；不一致就不写。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(Metric.pagePad)
            .background(Color.cnBg)
            .navigationTitle("补原始链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .font(.cnChip)
                }
            }
        }
        .presentationDetents([.height(400)])
    }

    private func submit() async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        running = true
        error = nil
        defer { running = false }

        if let failure = await library.relink(id: item.id, url: value) {
            error = failure
            return
        }
        onDone()
        dismiss()
    }
}
