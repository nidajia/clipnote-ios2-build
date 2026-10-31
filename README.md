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

## 接上 CI 的三步

这个目录必须单独成一个仓库——GitHub Actions 只读仓库根目录下的 `.github/workflows/`。
不要塞进 `clipnote-ios-build` 的子目录，那样 workflow 不会被识别。

```bash
cd ios2
git init -b main
git add .
git commit -m "feat: 组件层 + 截图验收链路"
git remote add origin https://github.com/<你的账号>/clipnote-ios2-build.git
git push -u origin main
```

推之前先在 GitHub 上建好空仓库。**不要**把 token 写进任何脚本或 remote URL，
用 `gh auth login` 或 credential helper。

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
