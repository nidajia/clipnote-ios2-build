import Combine
import Foundation

/// 一个分区。
///
/// **和标签不是一回事**（见产品路线 6.1）：
/// - 标签是内容属性，由 AI 打，一条可以有多个；
/// - 分区是「我为什么存它」，只能有一个，由用户选。
///
/// 所以这里是独立类型、独立存储，不复用 `Item.labels`。
/// 一旦复用，「AI 说这是知识科普」就会覆盖「我把它放进娱乐」。
struct LibrarySection: Identifiable, Hashable, Codable {
    /// 稳定标识。内置的写死，自定义的由名字派生 + 去重后缀——
    /// 用 UUID 的话，两条同名的子分区在筛选条上会长得完全一样。
    let id: String
    var name: String
    /// SF Symbol。名字可能是任意汉字，图标是唯一能快速扫读的线索。
    var symbol: String
    /// 内置分区不能删：删掉之后「学习」这条意图就没有归处了。
    var isBuiltin: Bool

    init(id: String, name: String, symbol: String, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isBuiltin = isBuiltin
    }
}

extension LibrarySection {
    /// 产品路线 6.1 点名的四个。第四个后面的「…」由用户自己加。
    static let builtins: [LibrarySection] = [
        .init(id: "study", name: "学习", symbol: "book.fill", isBuiltin: true),
        .init(id: "info", name: "信息", symbol: "newspaper.fill", isBuiltin: true),
        .init(id: "fun", name: "娱乐", symbol: "gamecontroller.fill", isBuiltin: true),
        .init(id: "know", name: "知识科普", symbol: "lightbulb.fill", isBuiltin: true),
    ]
}

/// 新建/删除分区时会撞到的几种情况。
///
/// 用枚举而不是字符串：这些分支都要在界面上给出不同的说法，
/// 而字符串比较写错不会报错，只会「静默没反应」。
enum SectionEditError: Error, Equatable {
    case emptyName
    case tooLong
    case duplicate
    case tooMany
    case builtin

    var message: String {
        switch self {
        case .emptyName: return "名字不能为空"
        case .tooLong: return "名字最多 \(SectionStore.maxNameLength) 个字"
        case .duplicate: return "已经有同名分区了"
        case .tooMany: return "自定义分区最多 \(SectionStore.maxCustomCount) 个"
        case .builtin: return "内置分区不能删除"
        }
    }
}

/// 分区与「这条属于哪个分区」的本地存储。
///
/// **只在本机**：服务端没有这个字段，`/api/v2` 也没有通用的条目字段写入接口。
/// 换设备、重装会丢——这一条写在选择器的脚注里，不藏起来。
///
/// 键用服务端 id（不是下标、不是 UUID）：它是稳定的，重新同步之后仍然对得上。
/// 上一版下载记录用过 UUID，结果重装后已下载状态全部失效，同一个坑不踩第二次。
final class SectionStore: ObservableObject {
    @Published private(set) var custom: [LibrarySection] = []
    /// itemID → sectionID
    @Published private(set) var assignment: [String: String] = [:]

    static let maxNameLength = 8
    static let maxCustomCount = 12

    private let fileURL: URL
    private weak var log: LogStore?

    /// 落盘结构。两个字典放一个文件，避免「分区表更新了、归属没更新」的半截状态。
    private struct Archive: Codable {
        var custom: [LibrarySection]
        var assignment: [String: String]
    }

    init(directory: URL? = nil, log: LogStore? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("sections.json")
        self.log = log
        load()
    }

    // MARK: - 查询

    var allSections: [LibrarySection] { LibrarySection.builtins + custom }

    func section(id: String) -> LibrarySection? {
        allSections.first { $0.id == id }
    }

    /// 这条属于哪个分区。`nil` 有两种情况：没分过，或者指向一个已被删掉的分区。
    /// 后者必须当成「未分区」，否则会出现一个点进去永远是空的幽灵筛选。
    func sectionID(for itemID: String) -> String? {
        guard let id = assignment[itemID], section(id: id) != nil else { return nil }
        return id
    }

    func section(for itemID: String) -> LibrarySection? {
        sectionID(for: itemID).flatMap { section(id: $0) }
    }

    func count(in sectionID: String?, items: [Item]) -> Int {
        items.filter { self.sectionID(for: $0.id) == sectionID }.count
    }

    var assignedCount: Int { assignment.count }

    // MARK: - 动作

    /// 把若干条移进某个分区。`nil` = 移出分区（回到未分区）。
    /// 返回真正被改动的条数，供界面说「已移入 3 条」。
    @discardableResult
    func assign(_ sectionID: String?, to itemIDs: [String]) -> Int {
        if let sectionID, section(id: sectionID) == nil { return 0 }
        var changed = 0
        for id in itemIDs where sectionID(for: id) != sectionID {
            // 移出分区要真删键，而不是写一个空串——
            // 空串会让 `assignment.count` 越滚越大，也无法区分「没分过」。
            if let sectionID { assignment[id] = sectionID } else { assignment.removeValue(forKey: id) }
            changed += 1
        }
        guard changed > 0 else { return 0 }
        save()
        let name = sectionID.flatMap { section(id: $0)?.name } ?? "未分区"
        let logger = log
        Task { @MainActor in
            logger?.info("section.assigned", "移入分区", meta: [
                "section": name, "count": String(changed),
            ])
        }
        return changed
    }

    /// 新建自定义分区。名字去首尾空白后查重。
    func addSection(name rawName: String) -> Result<LibrarySection, SectionEditError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard name.count <= Self.maxNameLength else { return .failure(.tooLong) }
        guard !allSections.contains(where: { $0.name == name }) else { return .failure(.duplicate) }
        guard custom.count < Self.maxCustomCount else { return .failure(.tooMany) }

        let section = LibrarySection(
            id: Self.makeID(from: name, taken: Set(allSections.map(\.id))),
            name: name,
            symbol: "folder.fill"
        )
        custom.append(section)
        save()
        let logger = log
        Task { @MainActor in
            logger?.info("section.created", "新建分区", meta: ["name": name])
        }
        return .success(section)
    }

    /// 删除自定义分区。它的归属一起清掉——留着会让这些条目
    /// 指向一个不存在的分区，在筛选条上表现为「凭空少了几条」。
    func deleteSection(_ id: String) -> Bool {
        guard let target = section(id: id), !target.isBuiltin else { return false }
        custom.removeAll { $0.id == id }
        assignment = assignment.filter { $0.value != id }
        save()
        let logger = log
        Task { @MainActor in
            logger?.info("section.deleted", "删除分区", meta: ["name": target.name])
        }
        return true
    }

    /// 条目被删除/进回收站时调用，别让归属表无限长下去。
    func forget(_ itemIDs: [String]) {
        let before = assignment.count
        for id in itemIDs { assignment.removeValue(forKey: id) }
        guard assignment.count != before else { return }
        save()
    }

    /// 把名字变成 id：保留 ASCII 字母数字，其余（含汉字）用稳定哈希尾巴区分。
    /// 纯汉字名字用拼音需要一张表，不划算；哈希足够避免撞车。
    static func makeID(from name: String, taken: Set<String>) -> String {
        var hash: UInt64 = 0x811c9dc5
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let base = String(format: "s-%08x", UInt32(truncatingIfNeeded: hash))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else { return }
        let builtinIDs = Set(LibrarySection.builtins.map(\.id))
        // 手改过 JSON 也不该让界面出现两个「学习」
        custom = archive.custom.filter { !builtinIDs.contains($0.id) }
        assignment = archive.assignment
    }

    private func save() {
        let archive = Archive(custom: custom, assignment: assignment)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 截图与测试用

    func seed(custom: [LibrarySection] = [], assignment: [String: String]) {
        self.custom = custom
        self.assignment = assignment
        save()
    }
}
