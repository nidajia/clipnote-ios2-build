import SwiftUI

/// 从服务商读模型列表。
///
/// 为什么需要这一屏：模型名是一串 `Qwen/Qwen2.5-7B-Instruct`，
/// 用户不可能凭记忆填对；填错了报的是「404 model not found」，
/// 而那句话看起来像是地址错了。
///
/// 备注是**本地按名字猜的**（接口只返回 id，不返回能力）。所以这里
/// 只写「对话模型 / 向量模型」这种粗分类，不写参数量、不写上下文长度——
/// 猜错一个分类，后果只是列表里藏错一项；写错参数，后果是用户以为能用。
struct ModelPickerSheet: View {
    var base: String
    var key: String
    @Binding var selected: String

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState
    @State private var showAll = false
    @State private var keyword = ""

    /// `initialModels` 只给截图用：真机上一定要先点「读取模型列表」，
    /// 因为这一屏的价值就在于「列表是从服务商那里真拿到的」。
    init(base: String, key: String, selected: Binding<String>, initialModels: [AIModel]? = nil) {
        self.base = base
        self.key = key
        _selected = selected
        _state = State(initialValue: initialModels.map { LoadState.loaded($0) } ?? .idle)
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([AIModel])
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                idleView
            case .loading:
                loadingView
            case .loaded(let models):
                listView(models)
            case .failed(let message):
                failedView(message)
            }
        }
        .background(Color.cnBg)
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                // 只有读到列表之后，这个开关才有意义
                if case .loaded = state {
                    Button(showAll ? "只看对话" : "显示全部") {
                        showAll.toggle()
                    }
                    .font(.cnCaption)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("关闭") { dismiss() }
                    .font(.cnChip)
            }
        }
    }

    // MARK: - 三态

    private var idleView: some View {
        VStack(alignment: .leading, spacing: Metric.space4) {
            Text("让服务商把可用的模型发过来，再挑一个。")
                .font(.cnBody)
                .foregroundStyle(Color.cnInk2)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(title: "读取模型列表") {
                Task { await load() }
            }

            Text("这一步只读列表，不调用模型、不消耗额度。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)

            Spacer(minLength: 0)
        }
        .padding(Metric.pagePad)
    }

    private var loadingView: some View {
        VStack(spacing: Metric.space3) {
            ActivitySpinner(style: .medium)
            Text("正在读取…")
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            Text("没能读到列表")
                .font(.cnRowTitle)
                .foregroundStyle(Color.cnInk)
            Text(message)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "重试") {
                Task { await load() }
            }
            Text("有些网关不提供 /models 接口，这种情况直接在上面手填模型名就行。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Metric.pagePad)
    }

    // MARK: - 列表

    private func listView(_ models: [AIModel]) -> some View {
        let visible = filtered(models)
        return VStack(spacing: 0) {
            if visible.isEmpty {
                VStack(spacing: Metric.space2) {
                    Text(keyword.isEmpty ? "列表里没有能聊天的模型" : "没有匹配「\(keyword)」的模型")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk3)
                    if keyword.isEmpty {
                        Button("显示全部（含向量、语音、图片模型）") {
                            showAll = true
                        }
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnBrand)
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(visible) { model in
                            Button {
                                selected = model.id
                                dismiss()
                            } label: {
                                row(model)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text(showAll
                             ? "备注是按模型名猜的用途，不是服务商给的能力说明。"
                             : "默认只显示能对话的模型；向量、重排、语音、图片模型已隐藏。")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $keyword, prompt: "搜索模型名")
    }

    private func row(_ model: AIModel) -> some View {
        HStack(alignment: .top, spacing: Metric.space2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.id)
                    .font(.custom("Menlo", size: 13, relativeTo: .subheadline))
                    .foregroundStyle(model.chattable ? Color.cnInk : Color.cnInk3)
                    .lineLimit(2)
                Text(model.note)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }
            Spacer(minLength: 0)
            if model.id == selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.cnBrand)
                    .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
    }

    private func filtered(_ models: [AIModel]) -> [AIModel] {
        var list = showAll ? models : models.filter(\.chattable)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            list = list.filter { $0.id.localizedCaseInsensitiveContains(trimmed) }
        }
        return list
    }

    private func load() async {
        state = .loading
        do {
            let models = try await ModelCatalog.fetch(base: base, key: key)
            state = .loaded(models)
        } catch let failure as SummarizeFailure {
            state = .failed(failure.displayMessage)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
