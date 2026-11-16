import Combine
import Foundation
import Network

/// 真实网络状态。
///
/// 别和 `LibraryStore.isOffline` 混在一起：那个指的是「这个进程没配网络层」
/// （截图 / 预览态），飞行模式下它是 **false**——client 照样存在，只是请求会超时。
/// 之前只有那个判断，所以没网时点播放会先转 30 秒再报错，
/// 用户看到的是「这条打不开」，而不是「你没网 / 这条没下载」。
final class NetworkMonitor: ObservableObject {
    /// 没网（含飞行模式、Wi-Fi 断但有蜂窝 / 反过来）。
    @Published private(set) var isDown = false
    /// 是否已经收到过第一次判定。首帧不确定时不要急着弹「离线」提示。
    @Published private(set) var settled = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "clipnote.network.monitor")

    init(startImmediately: Bool = true) {
        guard startImmediately else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let down = path.status != .satisfied
            DispatchQueue.main.async {
                self?.isDown = down
                self?.settled = true
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// 截图用：直接钉住一个状态，不依赖模拟器网络。
    func override(down: Bool) {
        isDown = down
        settled = true
    }
}
