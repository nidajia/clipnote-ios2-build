import Combine
import Foundation
import SwiftUI

/// 一条内容的进度状态。
///
/// 4.1 原本想做「笔记本 + 状态流转」，但笔记本已经由 6.1 的分区承担了
/// （见 2026-11-11 的决定：分区就是笔记本，不再造第二套分组）。
/// 所以这里只补状态——它是分区里的一条横轴，两者正交：
/// 「学习」里可以有未开始的、也可以有已完成的。
enum ItemStatus: String, CaseIterable, Codable, Identifiable {
    case todo
    case doing
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todo: return "未开始"
        case .doing: return "进行中"
        case .done: return "已完成"
        }
    }

    /// SF Symbol。列表行里只有 12pt 的位置，图标比文字更快扫读。
    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .doing: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// 「这条现在到哪一步了」的本地存储。
///
/// 和分区一样**只在本机**：服务端没有这个字段。换设备、重装会丢。
/// 但它是用户随手标的，丢了可以重标；笔记正文和分区归属才是不可再生的。
final class StatusStore: ObservableObject {
    /// itemID → 状态。没有键 = 没标过。
    @Published private(set) var map: [String: ItemStatus] = [:]

    private let fileURL: URL
    private weak var log: LogStore?

    init(directory: URL? = nil, log: LogStore? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("statuses.json")
        self.log = log
        load()
    }

    // MARK: - 查询

    func status(for itemID: String) -> ItemStatus? { map[itemID] }

    func count(_ status: ItemStatus, items: [Item]) -> Int {
        items.filter { map[$0.id] == status }.count
    }

    var assignedCount: Int { map.count }

    // MARK: - 动作

    /// 设置状态。`nil` = 清除标记。
    /// 返回是否真的变了——界面据此决定要不要弹提示，避免「点了个一样的状态也弹一下」。
    @discardableResult
    func set(_ status: ItemStatus?, for ids: [String]) -> Int {
        var changed = 0
        for id in ids where map[id] != status {
            if let status { map[id] = status } else { map.removeValue(forKey: id) }
            changed += 1
        }
        guard changed > 0 else { return 0 }
        save()
        let name = status?.title ?? "未标记"
        let logger = log
        Task { @MainActor in
            logger?.info("status.assigned", "状态已更新", meta: [
                "status": name, "count": String(changed),
            ])
        }
        return changed
    }

    /// 条目被删掉时清掉标记。不清的话这张表会越滚越长，
    /// 而且换一台设备重新同步、id 复用时会出现「明明没标过却显示已完成」。
    func forget(_ id: String) {
        guard map.removeValue(forKey: id) != nil else { return }
        save()
    }

    func forget(_ ids: [String]) {
        var changed = false
        for id in ids where map.removeValue(forKey: id) != nil { changed = true }
        if changed { save() }
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            // 文件坏了不要清空：先留一份备份，下次保存会覆盖它。
            // 这条数据不致命，但「静默清零」会让用户以为自己标错了。
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return
        }
        map = decoded.compactMapValues(ItemStatus.init(rawValue:))
    }

    private func save() {
        let raw = map.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 列表行里的状态标记。只有标过才画——未标记不该占一个「无」字的位置。
struct StatusBadge: View {
    var status: ItemStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(status.title)
                .font(.cnCaption)
                .lineLimit(1)
        }
        .foregroundStyle(status == .done ? Color.cnBrand : Color.cnInk2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.cnCard2, in: Capsule())
    }
}
