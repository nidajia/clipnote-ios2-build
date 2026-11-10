import SwiftUI

/// 分区标记。列表行上用，紧凑到不抢标题的位置。
///
/// 只显示**已分区**的：未分区不画一个「无」字，那会让每一行都多一块噪声。
/// 找不到分区就看「未分区」这个筛选，这是它的用途。
struct SectionBadge: View {
    var section: LibrarySection

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: section.symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(section.name)
                .font(.cnCaption)
                .lineLimit(1)
        }
        .foregroundStyle(Color.cnInk2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.cnCard2, in: Capsule())
    }
}

/// 选分区。
///
/// 三种入口共用这一个面板：详情页（一条）、列表长按（一条）、多选底栏（一批）。
/// 分开画三套的话，「新建分区」这种后续改动就会只落在其中一个入口上。
struct SectionPickerSheet: View {
    @ObservedObject var store: SectionStore
    /// 当前归属。多选时传 nil（多个可能不同）。
    var current: String?
    /// 一次处理几条。>1 时标题里写明，避免「以为只改了当前这条」。
    var count: Int = 1
    var onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var newName = ""
    @State private var errorText: String?
    @State private var pendingDelete: LibrarySection?

    var body: some View {
        List {
            if let errorText {
                Text(errorText)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnRed)
                    .listRowBackground(Color.cnBg)
                    .listRowSeparator(.hidden)
            }

            Section {
                row(title: "未分区", symbol: "tray", selected: current == nil) {
                    onPick(nil)
                }
            }

            Section {
                ForEach(store.allSections) { item in
                    row(title: item.name, symbol: item.symbol, selected: current == item.id) {
                        onPick(item.id)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 内置分区不给删除：删掉之后「学习」这条意图就没有归处，
                        // 而它并不占什么空间，留着没有代价。
                        if !item.isBuiltin {
                            Button(role: .destructive) {
                                pendingDelete = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                // 脚注挂在分区这一组下面，不是挂在「未分区」下面：
                // 它说的是分区是什么、存在哪，属于这一组。
                Text("分区只存在这台设备上。换设备或重装不会带过去——服务端没有这个字段。")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.cnBg)
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
                    .font(.cnChip)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newName = ""
                    errorText = nil
                    showNew = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .font(.cnChip)
            }
        }
        .alert("新建分区", isPresented: $showNew) {
            TextField("名字（最多 \(SectionStore.maxNameLength) 个字）", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { create() }
        } message: {
            Text("分区是「我为什么存它」，和 AI 打的标签不是一回事。")
        }
        .alert("删除分区？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { confirmDelete() }
        } message: {
            Text(deleteMessage)
        }
    }

    private var titleText: String {
        count > 1 ? "移到分区（\(count) 条）" : "移到分区"
    }

    private var deleteMessage: String {
        guard let target = pendingDelete else { return "" }
        let affected = store.assignment.values.filter { $0 == target.id }.count
        return "「\(target.name)」里的 \(affected) 条会回到未分区，条目本身不会删。"
    }

    private func row(
        title: String,
        symbol: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: Metric.space3) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? Color.cnBrand : Color.cnInk3)
                    .frame(width: 20)
                Text(title)
                    .font(.cnBody)
                    .foregroundStyle(Color.cnInk)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.cnBrand)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.cnCard)
    }

    /// 新建失败要说原因：静默什么都不发生，会让人以为按钮坏了。
    private func create() {
        switch store.addSection(name: newName) {
        case .success(let section):
            // 建完直接用它——用户的意图就是「建一个并放进去」，
            // 再让他从列表里点一次是多余的一步。
            onPick(section.id)
        case .failure(let error):
            errorText = error.message
        }
    }

    private func confirmDelete() {
        guard let target = pendingDelete else { return }
        let removed = store.deleteSection(target.id)
        pendingDelete = nil
        if !removed { errorText = SectionEditError.builtin.message }
    }
}
