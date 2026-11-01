import SwiftUI

/// 同步阶段。截图的 `previewPhase` 与真实运行共用这一套状态。
enum SyncPhase: Equatable {
    case welcome
    case syncing(SyncStep)
    case done(count: Int, milliseconds: Int)
    case failed(message: String, step: SyncStep)
}

enum StepStatus {
    case pending
    case running
    case done
    case failed
}

/// 某一步在某个阶段下是什么状态。
///
/// 纯函数，单独拎出来是为了能测：如果它错了，界面会显示「三步全绿但同步还没成功」
/// 这种自相矛盾的东西，而这种错在截图里看着完全正常。
func stepStatus(_ step: SyncStep, in phase: SyncPhase) -> StepStatus {
    switch phase {
    case .welcome:
        return .pending
    case .syncing(let current):
        if step.rawValue < current.rawValue { return .done }
        return step == current ? .running : .pending
    case .done:
        return .done
    case .failed(_, let failedStep):
        if step.rawValue < failedStep.rawValue { return .done }
        return step == failedStep ? .failed : .pending
    }
}

extension SyncStep {
    /// 给用户看的名字。store 里只存事件，文案在界面层——
    /// 换一种说法不该动到同步逻辑。
    var title: String {
        switch self {
        case .connecting: return "连接服务端"
        case .fetched: return "读取收藏列表"
        case .ready: return "准备就绪"
        }
    }
}

/// 引导（画布 01 / 02）。
///
/// 01 欢迎 → 02 首次同步 → 进首页。
///
/// 02 的三步是**真的**：每一步都由 `LibraryStore.reload` 里的事件点亮。
/// 后两步通常在同一帧完成、会一起打勾——那是事实，不是动画没调好。
/// 也正因为如此，这里**不显示每步耗时**：那两步只有几毫秒，写出来会是
/// 两个「0.0s」，看着像坏了；凑个好看的数字又是编。只报一个总耗时。
struct OnboardingFlow: View {
    /// 截图用：直接指定停在哪一帧。真机传 nil。
    var previewPhase: SyncPhase?
    var onFinish: () -> Void = {}

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var phase: SyncPhase
    @State private var running = false

    init(previewPhase: SyncPhase? = nil, onFinish: @escaping () -> Void = {}) {
        self.previewPhase = previewPhase
        self.onFinish = onFinish
        _phase = State(initialValue: previewPhase ?? .welcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: Metric.space6)

            if case .welcome = phase {
                welcome
            } else {
                syncPage
            }

            Spacer(minLength: Metric.space6)

            actions
        }
        .padding(Metric.pagePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.cnBg)
    }

    // MARK: - 01 欢迎

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Metric.space4) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cnBrandSoft)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.cnBrand)
                }
                .padding(.bottom, Metric.space2)

            Text("片记")
                .font(.cnLargeTitle)
                .foregroundStyle(Color.cnInk)

            Text("收藏的视频、看过的笔记，都在这里。\n同步一次，换台设备也能接着看。")
                .font(.cnBody)
                .foregroundStyle(Color.cnInk3)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 02 首次同步

    private var syncPage: some View {
        VStack(alignment: .leading, spacing: Metric.space4) {
            Text(syncTitle)
                .font(.cnLargeTitle)
                .foregroundStyle(Color.cnInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(syncSubtitle)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(SyncStep.allCases, id: \.rawValue) { step in
                    stepRow(step)
                    // 用序号判断「不是最后一行」，而不是 `step != allCases.last`
                    // ——后者拿非可选去比可选，语法上能过，读着别扭，加一步还会错。
                    if step.rawValue < SyncStep.allCases.count - 1 {
                        Rectangle()
                            .fill(Color.cnHairline)
                            .frame(height: 1)
                            .padding(.leading, 30)
                    }
                }
            }
            .padding(.horizontal, Metric.space3)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                    .strokeBorder(Color.cnHairline, lineWidth: 1)
            )
            .padding(.top, Metric.space2)
        }
    }

    private var syncTitle: String {
        switch phase {
        case .welcome: return ""
        case .syncing: return "正在同步"
        case .done: return "同步完成"
        case .failed: return "没能连上服务端"
        }
    }

    private var syncSubtitle: String {
        switch phase {
        case .welcome:
            return ""
        case .syncing:
            return "第一次打开要拉一次云端目录，通常一秒内。"
        case .done(let count, let milliseconds):
            let seconds = String(format: "%.1f", Double(milliseconds) / 1000)
            return count > 0
                ? "\(count) 条内容已就绪，用时 \(seconds) 秒。"
                : "云端还没有内容，用时 \(seconds) 秒。可以先去导入一条。"
        case .failed(let message, _):
            return message
        }
    }

    private func stepRow(_ step: SyncStep) -> some View {
        let status = stepStatus(step, in: phase)
        return HStack(spacing: Metric.space3) {
            indicator(status)
                .frame(width: 18, height: 18)

            Text(step.title)
                .font(.cnBody)
                .foregroundStyle(status == .pending ? Color.cnInk3 : Color.cnInk)

            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func indicator(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .strokeBorder(Color.cnCard3, lineWidth: 1.5)
                .frame(width: 13, height: 13)
        case .running:
            RingSpinner(size: 14, color: .cnBrand)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.cnGreen)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.cnRed)
        }
    }

    // MARK: - 按钮

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .welcome:
            PrimaryButton(title: "开始使用") { start() }

        case .syncing:
            PrimaryButton(title: "正在同步…", isEnabled: false, isLoading: true) {}

        case .done:
            PrimaryButton(title: "进入片记") { finish() }

        case .failed:
            VStack(spacing: Metric.space3) {
                PrimaryButton(title: running ? "正在重试…" : "重试", isLoading: running) {
                    start()
                }
                // 没网时就等于装了个不能用的 App，所以必须给出口
                Button("先离线进入") { finish() }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnInk3)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
        }
    }

    // MARK: - 流程

    private func start() {
        guard !running else { return }
        running = true
        Task {
            await runSync()
            running = false
        }
    }

    private func runSync() async {
        let started = Date()
        phase = .syncing(.connecting)

        await library.reload { step in
            phase = .syncing(step)
        }

        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        switch library.phase {
        case .loaded:
            phase = .done(count: library.items.count, milliseconds: milliseconds)
            logs.info("onboarding.synced", "首次同步完成", meta: [
                "count": "\(library.items.count)",
                "ms": "\(milliseconds)",
            ])
        case .failed(let message):
            // 失败落在哪一步，从当前 phase 反推——不用在闭包里另存一个变量，
            // 那种「闭包改外部局部变量」的写法在并发下很容易读到旧值。
            phase = .failed(message: message, step: currentStep)
            logs.error("onboarding.failed", message, meta: [
                "step": "\(currentStep.rawValue)",
                "ms": "\(milliseconds)",
            ])
        default:
            phase = .failed(message: "同步没有完成，请重试。", step: currentStep)
        }
    }

    /// 正在进行的最后一步。同步失败时它就是出错的那一步。
    private var currentStep: SyncStep {
        if case .syncing(let step) = phase { return step }
        return .connecting
    }

    private func finish() {
        // 离线进入也算「引导过」：否则下次启动又回到欢迎页，
        // 而用户会觉得「我明明点过开始了」。
        if case .failed = phase {
            logs.info("onboarding.skipped", "没连上服务端，先离线进入")
        }
        onFinish()
    }
}
