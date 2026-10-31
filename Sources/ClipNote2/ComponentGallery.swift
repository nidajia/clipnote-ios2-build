import SwiftUI

/// 组件画廊：把四个基础组件的所有状态平铺出来。
///
/// 两个用途：
/// 1. 装机后肉眼比对画布（不需要走业务路径）
/// 2. CI 快照测试的渲染源（GallerySnapshotTests）
///
/// 刻意不用 ScrollView：`ImageRenderer` 只渲染可见区域，
/// 滚动容器会让截图缺掉下半截。
struct ComponentGallery: View {

    private let samples: [ItemRowModel] = [
        ItemRowModel(
            title: "为什么大多数人的笔记系统最后都会废掉",
            platform: "B 站", author: "老蒋巨靠谱", duration: "12:34",
            isDownloaded: true,
            coverTop: Color(red: 0.24, green: 0.30, blue: 0.44),
            coverBottom: Color(red: 0.11, green: 0.13, blue: 0.20)
        ),
        ItemRowModel(
            title: "一次讲清楚：为什么你收藏的视频从来不看第二遍",
            platform: "抖音", author: "视频号研究院", duration: "08:12",
            isDownloaded: false,
            coverTop: Color(red: 0.42, green: 0.23, blue: 0.23),
            coverBottom: Color(red: 0.16, green: 0.09, blue: 0.09)
        ),
        ItemRowModel(
            title: "笔记工具选型的三个真实标准",
            platform: "小红书", author: "顾屿", duration: "05:48",
            isDownloaded: true,
            coverTop: Color(red: 0.35, green: 0.29, blue: 0.18),
            coverBottom: Color(red: 0.14, green: 0.11, blue: 0.07)
        )
    ]

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
