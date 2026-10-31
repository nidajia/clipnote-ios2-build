import SwiftUI

/// 组件画廊：把基础组件的所有状态平铺出来。
///
/// 用途：
/// 1. 装机后肉眼比对画布（不需要走业务路径）
/// 2. CI 快照测试的渲染源（GallerySnapshotTests）
///
/// 刻意不用 ScrollView：`ImageRenderer` 只渲染可见区域，
/// 滚动容器会让截图缺掉下半截。
struct ComponentGallery: View {

    private var samples: [Item] { Array(Item.demoLibrary.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.space6) {
            header
            rowSection
            badgeSection
            buttonSection
            chipSection
            footer
        }
        .padding(.vertical, Metric.space6)
        .frame(width: 390, alignment: .leading)
        .background(Color.cnBg)
    }

    // MARK: 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            Text("组件画廊")
                .font(.cnLargeTitle)
                .foregroundStyle(Color.cnInk)
            Text("第一包 · 四个基础组件 · 浅色 / 深色两套 token")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metric.pagePad)
    }

    private var rowSection: some View {
        section("条目行 · ItemRow · 已下载 / 未下载") {
            VStack(spacing: 0) {
                ForEach(Array(samples.enumerated()), id: \.element.id) { index, item in
                    ItemRow(model: item)
                    if index < samples.count - 1 {
                        Rectangle()
                            .fill(Color.cnCard2)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, Metric.pagePad)
        }
    }

    private var badgeSection: some View {
        section("已下载徽标 · DownloadBadge") {
            HStack(spacing: Metric.space3) {
                DownloadBadge()
                Text("徽标必须带文字，不能只用一个绿点")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }
            .padding(.horizontal, Metric.pagePad)
        }
    }

    private var buttonSection: some View {
        section("主按钮 · PrimaryButton · 默认 / 禁用 / 加载中") {
            VStack(spacing: Metric.space3) {
                PrimaryButton(title: "下载到本地")
                PrimaryButton(title: "下载到本地", isEnabled: false)
                PrimaryButton(title: "正在同步…", isLoading: true)
            }
            .padding(.horizontal, Metric.pagePad)
        }
    }

    private var chipSection: some View {
        section("筛选 Chip · FilterChip · 选中 / 未选中") {
            HStack(spacing: Metric.space2) {
                FilterChip(title: "全部", isSelected: true)
                FilterChip(title: "视频", isSelected: false)
                FilterChip(title: "笔记", isSelected: false)
                FilterChip(title: "已下载", isSelected: false)
            }
            .padding(.horizontal, Metric.pagePad)
        }
    }

    private var footer: some View {
        Text("尺寸与色值见 DESIGN-SPEC.md 第 1、2 节")
            .font(.cnMeta)
            .foregroundStyle(Color.cnInk3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.pagePad)
    }

    // MARK: 小工具

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            Text(title)
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metric.pagePad)

            content()
        }
    }
}

#Preview("浅色") {
    ComponentGallery()
        .preferredColorScheme(.light)
}

#Preview("深色") {
    ComponentGallery()
        .preferredColorScheme(.dark)
}
