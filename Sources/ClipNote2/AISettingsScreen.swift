import SwiftUI

/// AI 设置（画布没有这一屏，按现有设计语言补）。
///
/// 为什么要有这一屏：模型调用用的是**用户自己的 key**，服务端不存。
/// key 落在 Keychain 里，只在本机可用、不参与 iCloud 同步。
struct AISettingsScreen: View {
    @State private var preset: AIProviderPreset
    @State private var config: AIConfig
    @State private var status: Status = .idle
    @State private var revealKey = false
    @Environment(\.dismiss) private var dismiss

    enum Status: Equatable {
        case idle
        case testing
        case ok
        case failed(String)
    }

    init() {
        let loaded = AIConfigStore.load()
        _config = State(initialValue: loaded)
        _preset = State(initialValue: AIProviderPreset.match(base: loaded.base))
    }

    var body: some View {
        List {
            Section {
                Picker("服务商", selection: $preset) {
                    ForEach(AIProviderPreset.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .onChange(of: preset) { newValue in
                    // 只填还没填的：别把用户手改过的地址覆盖掉
                    if config.base.isEmpty || AIProviderPreset.match(base: config.base) != .custom {
                        config.base = newValue.base
                    }
                    if config.model.isEmpty || newValue != .custom {
                        config.model = newValue.model
                    }
                }

                row("接口地址", text: $config.base, placeholder: "https://api.example.com/v1")
                row("模型", text: $config.model, placeholder: "gpt-4o-mini")
            } header: {
                Text("服务")
            } footer: {
                Text("填 OpenAI 兼容的地址即可，末尾的 /v1 要带上。")
            }

            Section {
                HStack(spacing: Metric.space2) {
                    if revealKey {
                        row("Key", text: $config.key, placeholder: "sk-…")
                    } else {
                        SecureField("sk-…", text: $config.key)
                            .font(.cnBody)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.cnInk3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealKey ? "隐藏 Key" : "显示 Key")
                }
            } header: {
                Text("密钥")
            } footer: {
                Text("只存在本机的钥匙串里，不上传、不进仓库。换设备要重新填一次。")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack(spacing: Metric.space2) {
                        if status == .testing {
                            RingSpinner(size: 14, color: .cnBrand)
                        }
                        Text("测试连接")
                            .font(.cnBody)
                            .foregroundStyle(Color.cnBrand)
                    }
                }
                .disabled(status == .testing || !config.isConfigured)

                statusLine
            } footer: {
                Text("测试会真的调一次模型，消耗一次额度。")
            }

            Section {
                PrimaryButton(title: "保存", isEnabled: config.isConfigured) {
                    save()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle("AI 摘要")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            label("正在测试…", color: .cnInk3)
        case .ok:
            label("连接正常", color: .cnGreen)
        case .failed(let message):
            label(message, color: .cnRed)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.cnMeta)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 带左标签的输入行。
    ///
    /// 只靠 placeholder 不行：填完之后「哪个是地址、哪个是模型」就看不出来了，
    /// 而这两个值一旦填错，报错信息是模型服务给的（401/404），很难反推。
    private func row(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: Metric.space2) {
            Text(title)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .frame(width: 40, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.cnBody)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .accessibilityElement(children: .combine)
    }

    private func save() {
        guard AIConfigStore.save(config) else {
            status = .failed("保存失败：钥匙串拒绝了写入。")
            return
        }
        // 存完就回去：从「我」进来是返回上一页，从详情页的弹层进来是收起弹层，
        // 两种都对。留一条「已保存」在页面上反而要多按一次返回。
        dismiss()
    }

    private func test() async {
        status = .testing
        do {
            try await Summarizer(config: config).ping()
            status = .ok
        } catch let failure as SummarizeFailure {
            status = .failed(failure.displayMessage)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
