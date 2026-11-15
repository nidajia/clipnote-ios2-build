import Foundation

/// 合集剧集的排列方式。
///
/// 原来只有「按集数 / 按时间」两个选项，而「按时间」只有一个方向（旧→新），
/// 追更的人想先看最新一集就必须滑到底。现在「按时间」本身带方向，
/// 再点一次就翻过来；选择存在 `AppStorage` 里，下次打开还是上次那个。
enum SeasonOrder: String, CaseIterable {
    /// 按集数（服务端给的顺序，就是作品的正常观看顺序）。
    case index
    /// 时间倒序：新 → 旧。
    case newest
    /// 时间正序：旧 → 新。
    case oldest

    /// 主标签。方向只在「按时间」时出现，避免三个按钮挤在一起。
    var label: String {
        switch self {
        case .index: return "按集数"
        case .newest: return "按时间 新→旧"
        case .oldest: return "按时间 旧→新"
        }
    }

    var isTime: Bool { self != .index }

    /// 点「按时间」之后落在哪个方向/翻到哪一边。
    /// 从「按集数」切过去先看最新的（追更的人更多）；已经在按时间则翻面。
    var toggledTime: SeasonOrder {
        switch self {
        case .index: return .newest
        case .newest: return .oldest
        case .oldest: return .newest
        }
    }

    /// 排序。没有发布时间的永远排在最后——
    /// 正序时把它当 1970 会跑到最前面，看起来像「排序坏了」。
    func sorted(_ episodes: [APISeasonEpisode]) -> [APISeasonEpisode] {
        guard isTime else { return episodes }
        let known = episodes.filter { $0.created > 0 }
        let unknown = episodes.filter { $0.created <= 0 }
        let ordered = known.sorted {
            self == .newest ? $0.created > $1.created : $0.created < $1.created
        }
        return ordered + unknown
    }

    static let storageKey = "clipnote.seasonOrder"

    /// 读存储。非法值回落到「按集数」——旧版本存的是 "time"，
    /// 直接丢弃不会有副作用。
    static func stored(_ raw: String) -> SeasonOrder {
        SeasonOrder(rawValue: raw) ?? .index
    }
}
