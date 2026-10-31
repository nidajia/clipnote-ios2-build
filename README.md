# ClipNote v2 —— 第一包重建

与旧的 `ios/` 完全独立：新 Bundle ID（`com.clipnote.v2`）、新目录、不读旧工程任何文件，
两边可以并存，互不影响。

## 为什么要重做

旧 App 的病根不是功能缺失，而是**手工复刻了一份 Web 业务规则**：服务端改一次，客户端
就漂移一次，三次事故全是抄漏。所以这一版的结构是：

```
服务端 /api/v2/*  ← 唯一事实来源（含字段映射、平台名、时长格式化）
      ↓
客户端            ← 只做 调用 → 解码 → 渲染 → 本地持久化
```

对应到代码上就是一条纪律：**`Item` 里没有任何「拼装」行为**。`metaLine`（`"B 站 · 老蒋巨靠谱"`）
和 `durationText`（`"12:57"`）都是服务端给的成品字符串，客户端不拼分隔符、不算秒数。

## 现在有什么

| 文件 | 内容 |
|---|---|
| `Sources/ClipNote2/LibraryAPI.swift` | 服务端形状解码 + `ClipNoteClient` + `LibraryStore` 三态 |
| `Sources/ClipNote2/Model.swift` | `Item`（纯展示模型，id 是服务端字符串）+ 占位色派生 |
| `Sources/ClipNote2/Components.swift` | 条目行、已下载徽标、主按钮、筛选 Chip |
| `Sources/ClipNote2/HomeScreen.swift` | 列表 / 空态 / 无结果 / 加载中 / 失败可重试 |
| `Sources/ClipNote2/DetailScreen.swift` | 播放、简介、下载三态 |
| `Sources/ClipNote2/DownloadStore.swift` | 真实下载 + `downloads.json` 索引 + 启动时与磁盘对账 |
| `Sources/ClipNote2/MeScreen.swift` | 同步入口、存储、日志（排障面） |
| `Sources/ClipNote2/DesignTokens.swift` | 颜色 / 字体 / 尺寸 Token，无一处裸字号 |
| `Sources/ClipNote2/Resources/library-sample.json` | 截图用样本库（与线上同一套形状） |
| `Tests/.../LibraryDecodingTests.swift` | 用线上真实响应钉住契约 |
| `Tests/.../ClipNoteClientTests.swift` | 拦 URLSession，验网关 403 / HTML 回落 / 409 |
| `Tests/.../DownloadStoreTests.swift` | 验收⑤：重启后状态仍在、文件消失后索引清理 |
| `.github/workflows/screenshots.yml` | macOS runner 跑测试 + `simctl` 出 13 张图 |

App 启动会真的去拉 `https://clipnote.app.workbuddy.host/api/v2/library`。

## 怎么跑

**本地（需要 macOS + Xcode 16）**

```bash
cd ios2
brew install xcodegen
xcodegen generate
xcodebuild test -project ClipNote2.xcodeproj -scheme ClipNote2 \
  -destination 'platform=iOS Simulator,name=iPhone 16'
bash Tools/screenshot.sh booted
```

**CI**

推上去自动触发 `Component Screenshots`，产物在 `component-screenshots` artifact。

## 推代码：本机 `git push` 用不了

github.com:443 直连和走代理都超时，只有 api.github.com 通。所以提交走 Git Data API：

```bash
cd ../           # 回到 clipnote/
GH_TOKEN=<pat> python tools/push_api.py "commit message"
```

这个脚本是**镜像**语义：以本地 `ios2/` 为准，远端多出来的文件会被删掉。
（早先版本带 `base_tree` 打补丁，只增不删，结果本地删掉的测试文件一直留在远端编译报错。）

**不要把 token 写进任何脚本或 remote URL。** 旧的 `ios/push.py` 就是反例。

## 截图有两条路，不要混用

| 层级 | 手段 | 产物 |
|---|---|---|
| 组件 / 画廊 | `ImageRenderer`（单元测试内） | `gallery-light.png` / `gallery-dark.png` |
| 整屏（含导航栏、Tab 栏） | `simctl` 真机启动后截屏 | 其余 11 张 |

**`ImageRenderer` 画不出 `List` / `TabView` / `NavigationStack`。** 这几个容器由 UIKit
背书，离屏渲染会整张变成系统「不可用」占位符（黄底红禁的图）。

整屏图走 `Tools/screenshot.sh`：装 App → 固定状态栏 9:41 → 按启动参数逐个进状态 → 截屏。
App 通过 `-snapshotState` 与 `-snapshotAppearance` 进入指定状态，**正常启动不经过它**。

截图数据来自 bundle 里的 `library-sample.json`，走的是**与线上相同的解码器**。
所以每张图同时证明两件事：解码没错，渲染没错；而且不依赖网络，任何时候截都一样。

## 踩过的坑

| 现象 | 原因 |
|---|---|
| `actool` 报 "no matching app icon set named AppIcon" | 资源目录缺 `AppIcon.appiconset`，这是 error 不是 warning |
| 加载按钮里出现橙色占位方块 | `ImageRenderer` 光栅化不了 `ProgressView`，改用纯 Shape 环 |
| 深色下选中 Chip 白字看不清 | 只修了主按钮没修 Chip，同一处 2.4:1 对比度漏了一处 |
| 四张整屏图字节数完全一样 | `ImageRenderer` 渲染 `TabView` 失败，输出的是系统占位符 |
| `listRowInsets` 失效、行贴到屏幕边缘 | 行被套了 `Button`，内边距挂在 label 内部会被忽略 |
| `loading` / `failed` 截出来是列表 | 截图入口先无条件加载数据再切状态，「拍到了」，但拍的是别的东西 |
| 线上封面指向 `3000-xxx.sandbox…` | 拿反代传进来的内网 `Host` 拼绝对地址，改用 `PUBLIC_ORIGIN` |
| 线上未知路径返回 200 + 首页 HTML | 客户端必须校验 `Content-Type`，否则把 HTML 当 JSON 解 |
| 删掉的文件仍在 CI 里编译 | `push_api.py` 原先只增不删 |

## 状态

**已验证**：编译通过、单测（解码契约 / 客户端三种失败 / 下载持久化）、
模拟器截图逐张看过、线上 `/api/v2/*` 实测。

**`/playback` 现在是真的能用**（2026-10-31 修）：

```
GET /api/v2/items/mvrl0axm2j64w/playback   2.17s（首次）→ 720P / 130257119 bytes（约 130 MB）
第二次                                       0.72s（命中 5 分钟缓存）
拉那个地址                                   HTTP 206 · video/mp4 · ftypisom
                                            Content-Range: bytes 0-65535/130257119
```

之前是「返回一个格式正确但已失效的地址」，用户 100% 拿到 403。
根因是快照里的 `streamUrl` 是 10 月 26 日写的，B 站签名早就过期；
而当时的实现只是把快照里那份转发出去。现在改成每次重新解析。

**仍未验证**：

1. **真机点一次播放**。拉流已验证（206 + 真 MP4 头），但 `AVPlayer` 在设备上
   解码播放这一层，截图和 curl 都证明不了。
2. **横屏全屏**（画布 06）。`simctl` 截不了旋转态。
3. **下载完整跑完**。130 MB 全量下载未实测，只有首块 Range 验证。

## 已知缺口

1. `/playback` 只支持 B 站。抖音/小红书返回 501，需要接第三方聚合并验证。
2. `POST /api/v2/parse` 未实现，导入面板的「解析链接」还是空的。
3. 第二包全部（摘要 / 标签 / 笔记编辑 / 脑图 / 书签 / 回收站）。
