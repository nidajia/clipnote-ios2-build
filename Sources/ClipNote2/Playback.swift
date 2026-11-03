import AVFoundation
import Foundation

/// 全局唯一的「谁在响」。
///
/// 为什么需要它：详情页里 `@State var player` 在页面被关掉之后不一定立刻释放，
/// 而 `AVPlayer` 只要还活着就会继续出声。结果是「返回首页 → 打开另一条 →
/// 两个视频的声音同时播」，用户只能杀进程。
///
/// 只靠 `onDisappear` 里 pause 不可靠：onDisappear 不保证执行（快速返回、
/// 手势取消），而且管不到「上一次那个实例」。
/// 这里用一个弱引用记着当前在响的那一个，换人时先掐掉旧的。
final class AudioFocus {
    static let shared = AudioFocus()

    private weak var current: AVPlayer?

    private init() {}

    /// 认领播放权。调用方创建或拿到播放器后必须调一次。
    func adopt(_ player: AVPlayer?) {
        if let current, current !== player {
            current.pause()
        }
        current = player
    }

    /// 主动收声。详情页消失时调用。
    func resign(_ player: AVPlayer?) {
        guard let player else { return }
        player.pause()
        if current === player { current = nil }
    }

    func stopAll() {
        current?.pause()
        current = nil
    }
}

/// 每条内容看到哪儿了。
///
/// 存本地而不是服务端：播放进度是高频写、低价值的数据（几秒一条），
/// 同步上去的收益是「换个设备接着看」，但代价是每次拖动进度条都可能打一次网络。
/// 先本地，等真正有跨端需求再往上抬。
final class PlaybackMemory {
    static let shared = PlaybackMemory()

    private let defaults = UserDefaults.standard
    private let key = "clipnote.playback.positions"

    private init() {}

    private func all() -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    func position(for id: String) -> Double? {
        let value = all()[id] ?? 0
        // 小于 5 秒等于没看，别让用户「点进去还停在片头」困惑
        return value >= 5 ? value : nil
    }

    func remember(_ seconds: Double, for id: String) {
        guard seconds.isFinite, seconds > 0 else { return }
        var table = all()
        table[id] = seconds
        defaults.set(table, forKey: key)
    }

    func forget(_ id: String) {
        var table = all()
        table.removeValue(forKey: id)
        defaults.set(table, forKey: key)
    }
}
