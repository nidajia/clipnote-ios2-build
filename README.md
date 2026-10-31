# 片记 ClipNote v2

第一包的**重建起点**。当前只做到第一步：把「组件 + CI 截图验收」这条链路跑通。

不是最终 App。首页、详情、下载那些都还没写。

## 为什么不在 `ios/` 上改

`ios/` 是上一版，交接文档写了不要在它上面继续打补丁。这里换新目录、新 Bundle ID
（`com.clipnote.v2`）、不读旧工程任何文件，两边可以并存，互不影响。

## 现在有什么

| 文件 | 内容 |
|---|---|
| `Sources/ClipNote2/DesignTokens.swift` | 颜色 / 字体 / 尺寸 Token，无一处裸字号 |
| `Sources/ClipNote2/Components.swift` | 条目行、已下载徽标、主按钮、筛选 Chip |
| `Sources/ClipNote2/ComponentGallery.swift` | 把四个组件的所有状态平铺 |
| `Tests/.../GallerySnapshotTests.swift` | 渲染成 PNG，浅色 / 深色各一张 |
| `.github/workflows/screenshots.yml` | macOS runner 跑测试并上传截图 |

App 启动后直接显示组件画廊——装机即可肉眼比对，不必走业务路径。

颜色是 `Assets.xcassets` 里的 15 个 Color Set，浅深两套自动切换。
要改色改 `Tools/gen_colors.py` 再重跑，不要手改 `Contents.json`。

## 怎么跑

**本地（需要 macOS + Xcode 16）**

```bash
cd ios2
brew install xcodegen
xcodegen generate
xcodebuild test -project ClipNote2.xcodeproj -scheme ClipNote2 \
  -destination 'platform=iOS Simulator,name=iPhone 16'
open screenshots/gallery-light.png
```

**CI**

推到 GitHub 后在 Actions 里手动触发 `Component Screenshots`，
产物在 `component-screenshots` artifact 里，含两张 PNG 和 xcresult。

## 接上 CI

这个目录已经是独立仓库：`github.com/nidajia/clipnote-ios2-build`（私有）。
GitHub Actions 只读仓库根目录下的 `.github/workflows/`，所以它不能塞进
`clipnote-ios-build` 的子目录。

⚠️ **本机 `git push` 用不了**：github.com:443 直连和走代理都超时，
只有 api.github.com 通。所以提交走 Git Data API：

```bash
cd ../           # 回到 clipnote/
GH_TOKEN=<pat> python tools/push_api.py "commit message"
```

推上去会自动触发 `Component Screenshots`。产物在 Actions 的
`component-screenshots` artifact 里，含 `gallery-light.png` / `gallery-dark.png`
和 xcresult。

**不要把 token 写进任何脚本或 remote URL。** 旧的 `ios/push.py` 就是反例。

## 截图有两条路，不要混用

| 层级 | 手段 | 产物 |
|---|---|---|
| 组件 / 画廊 | `ImageRenderer`（单元测试内） | `gallery-light.png` / `gallery-dark.png` |
| 整屏（含导航栏、Tab 栏） | `simctl` 真机启动后截屏 | `home-list` / `home-empty` / `me` / `home-dark` |

**`ImageRenderer` 画不出 `List` / `TabView` / `NavigationStack`。** 这几个容器由 UIKit
背书，离屏渲染会整张变成系统「不可用」占位符（黄底红禁的图）。整屏图必须走 `simctl`：
`Tools/screenshot.sh` 负责 装 App → 固定状态栏 9:41 → 按启动参数逐个进状态 → 截屏。

App 通过 `-snapshotState list|empty|me` 与 `-snapshotAppearance light|dark` 进入指定状态。
这条路径只在截图时启用，正常启动不经过它。

## 踩过的坑

| 现象 | 原因 |
|---|---|
| `actool` 报 "no matching app icon set named AppIcon" | 资源目录缺 `AppIcon.appiconset`，这是 error 不是 warning |
| 加载按钮里出现橙色占位方块 | `ImageRenderer` 光栅化不了 `ProgressView`，改用纯 Shape 环 |
| 深色下选中 Chip 白字看不清 | 只修了主按钮没修 Chip，同一处 2.4:1 对比度漏了一处 |
| 四张整屏图字节数完全一样 | `ImageRenderer` 渲染 `TabView` 失败，输出的是系统占位符 |

## 状态：未编译验证

写这份代码的机器是 Windows，没有 Xcode。所有 Swift 代码都**没有经过编译**，
第一次推 CI 大概率还要修几处编译错误（这类错误通常很浅，比如访问级别、
`.tint` 的可用平台）。

在没有跑通之前，请把它当成「已完成但未验证」，不要当成可交付。

## 已知阻塞

1. 旧的 `ios/push.py` 里硬编码了一个 GitHub token，建议吊销重发。
2. 旧 workflow 钉在 `macos-14`，该镜像已退役，需要迁到 `macos-15`。
3. 这个目录要单独成一个仓库（或作为子目录并调整 workflow 的 `working-directory`），
   才能被 GitHub Actions 识别——Actions 只读仓库根目录下的 `.github/workflows/`。
