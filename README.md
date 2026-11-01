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
2. **真机上「点全屏真的会转」**。截图证明的是「横屏尺寸下排得对」，
   而旋转这个动作在模拟器里是靠 App 自己请求的，真机是否同样成立要上手看。
3. **下载完整跑完**。130 MB 全量下载未实测，只有首块 Range 验证。

## 导入（2026-10-31 加）

`POST /api/v2/parse` 解析 + 写库一次完成。线上实测：

```
POST /api/v2/parse {"url": "【标题-哔哩哔哩】 https://b23.tv/wRhcDCU"}
  1.91s  →  created: true
            标题 / 平台 · 作者 / 16:57 / 封面 全部正确
同一条再导一次  →  created: false（库里仍 1 条）
```

两条设计约束：

- **客户端不清洗 URL**。用户粘的是「【标题】 短链」分享文案，各家格式都不一样，
  清洗规则属于服务端。这一版所有平台都靠这一条。
- **`created: false` 不是失败**。库里已经有这条，用户要的结果已经成立，界面说
  「这条已经在库里了」，不弹红字。

去重按 `(platform, videoId)`，所以短链与完整链接指向同一 bvid 会被拦住。
旧条目没有 `videoId`，不参与去重——补历史要从旧 url 反推 bvid，得联网展开，不划算。

**已知冲突**：`/api/sync/push` 是整份覆盖，Web 端下次 push 会冲掉 App 刚导入的条目。
彻底解决要把 push 改成合并协议。

## 运行日志（2026-10-31 加）

「我 · 运行日志」之前是纯装饰（写着「最近 0 条」，背后什么都没有）。现在是真入口。

三条设计约束：

**本地为准。** 日志落 `Caches/clipnote-log.json`，环形 200 条，重启后还在。
真机出问题时网络往往同时不通——若日志只存服务端，最需要它的那一刻恰好是它不存在的时候。

**只记「看得出不对但看不出原因」的事。** 失败全记（网络、播放、下载、导入），
成功只记四个节点（同步完成 / 播放开始 / 下载完成 / 导入完成）。
每条成功请求都记的话一天几十条，真正的问题会被埋掉。

**共享码绝不进日志。** `sharecode` / `code` / `token` / `cookie` 一律替换成 `<redacted>`。
日志会被上报到服务端，凭证不能跟着走。

上报策略：`error` 自动上报（fire-and-forget），`info`/`warn` 只留本地，
等用户在日志页点「上报」——手动上报的价值是 **info 也在里面**，
因为「最后一次成功同步是什么时候」只能靠它。

测试钉住三条底线：脱敏不漏、环形上限生效、重启后还在。

## 删除与回收站（2026-10-31 加）

顺带修了一处**文案承诺了不存在的功能**：详情页原本写着「删除条目不会自动删除文件。
清理请在『我 · 下载与存储』里进行」——但既没有删除，也没有下载与存储页。那句已删。

删除是**软删**：条目打 `deletedAt` 标记，`/library` 不再返回它，但它还在快照里。
硬删之后想恢复只能靠用户重新导入，而那条内容可能已经找不回来了。

| 操作 | 在哪 | 做什么 |
|---|---|---|
| 删除 | 首页左滑 | 打标记，进回收站，文件保留 |
| 恢复 | 回收站左滑 | 清标记，回到列表 |
| 彻底删除 | 回收站右滑（带确认） | 从快照移除 + 删本地文件 |

两个刻意的选择：

- **`allowsFullSwipe: false`**。整条划过就删太容易误触，而这条可能是花 130 MB 流量下的。
- **先删云端、成功后才删文件**。反过来的话服务端失败就会出现「条目还在列表里但文件没了」，
  点开播不了，用户不会理解为什么。

线上实测（临时共享码）：导入 → 删除（library 0 / 回收站 1，带 `deletedAt`）→ 恢复（library 1）
→ 彻底删除（全空）。

## 横屏全屏（2026-11-01 加，画布 06）

App **默认锁竖屏**，只有全屏播放页在屏幕上时才放开横屏。

为什么不是「在 Info.plist 里放开横屏」：那样列表页、导入面板、回收站、日志页
都会在横屏下出现，而这些状态画布从没画过、也没验证过。
`Info.plist` 里写横屏是**必要条件，不是充分条件**——真正决定「现在能不能转」的是
`AppDelegate.supportedInterfaceOrientationsFor`。

全屏是**自建页**（`.fullScreenCover`）而不是 AVKit 控制条里那个 ⤢：
系统全屏是它的私有弹层，旋转时机、关闭按钮、状态栏都不在手里，而且截不到图。
自绘的只有外壳（关闭按钮 + 片名），播放控制条仍是系统的 `AVPlayerViewController`。

三个容易踩的地方，都写在 `OrientationLock.swift` 的注释里：

1. **先 `setNeedsUpdateOfSupportedInterfaceOrientations()`，再 `requestGeometryUpdate`。** 反过来是静默失败。
2. **「允许集合」与「请求方向」必须分开。** 只请求 `.allButUpsideDown` 而当时是竖屏，
   系统会认为「竖屏也在允许范围内」，于是原地不动，且不报错。
3. **静默失败要留痕。** 旋转请求失败会进日志（`orientation.failed`），
   否则用户只会看到「点了全屏，没反应」。

不做「转手机自动进全屏」：要监听设备姿态，而 `simctl` 没有旋转设备的命令，
等于交付一段我永远无法验证的代码。要补的话在真机上试完再说。

截图怎么拍：`simctl` 也没有旋转命令，所以是 App 自己请求横屏，
内容按 874×402 布局但被画进竖屏缓冲，脚本检测到宽高颠倒后用 `sips -r 90` 转正。
转正后是一张诚实的横屏截图——它确实是按横屏尺寸排的，不是把页面塞进竖屏里假装。

## 引导（2026-11-01 加，画布 01 / 02）

首次启动走：**欢迎 → 首次同步 → 首页**。只有第一次出现
（`@AppStorage("clipnote.onboarded")`），想再看一遍得删掉 App 重装。

**02 的三步是真的**，不是定时器：

| 步骤 | 什么时候点亮的 |
|---|---|
| 连接服务端 | `GET /api/v2/library` 发出前 |
| 读取收藏列表 | 响应解出来之后 |
| 准备就绪 | 状态写入之后 |

后两步通常在同一帧完成、会**一起打勾**——那是事实，不是动画没调好。

**不显示每步耗时**：那两步只有几毫秒，写出来是两个「0.0s」，看着像坏了；
凑个好看的数字又是编。只报一个总耗时。

失败时停在 02，给「重试」和「先离线进入」两条路。首次装 App 往往在地铁或电梯里，
没网时不能把人困在引导里，也不能把他扔回一个空首页。

「先离线进入」同样写已引导标记——否则下次启动又回欢迎页，
而用户会觉得自己明明点过。

一次冷启动只打一次接口：首次同步由引导页发起，首页的 `.task` 只在
`library.phase == .idle` 时补拉。

顺带修了一处：`RingSpinner` 之前是个**不会转**的圆弧，截图里像加载中，
真机上就是个卡住的圈。现在真的在转。

## 打包与真机（2026-11-01 加）

**最低系统降到 iOS 16.0。** 装机走 TrollStore（未签名 ipa），而它覆盖到 16.6.1。
为此替换掉四处 iOS 17 专属写法，行为不变：

| 原写法 | 16 的替代 |
|---|---|
| `navigationDestination(item:)` | `navigationDestination(isPresented:)` + 可选值投影 |
| `.topBarTrailing` | `.navigationBarTrailing` |
| `onChange(of:) { old, new in }` | `onChange(of:) { new in }` |
| `.presentationBackground` | 自己铺底色 |
| `#Preview` | `PreviewProvider` |

**ipa 怎么出**：`.github/workflows/build-ipa.yml`，手动触发或打 `v*` tag。
产物是未签名 ipa + `BUILD.txt`（含构建号与提交），Artifact 下载后 TrollStore 直接装。
workflow 里有一条硬校验：`MinimumOSVersion` 不是 16.0 就直接失败——
部署目标被谁改回 17，会在 CI 里当场发现，而不是等装不上才发现。

**版本号**：原来「我」页脚注写死 `8.0.0 (1)`，两个分支还是同一个字符串。
现在读 `Bundle` 的版本与构建号，CI 用运行号覆盖构建号，装两台机器能分清。

**真机走查**：见 `真机走查清单.md`。按编号走，卡住就停，出问题走日志页「上报」。

## 已知缺口

1. `/playback` 和 `/parse` 都只支持 B 站链路。抖音/小红书返回 501，需要接第三方聚合并验证。
2. 「从文件导入视频 / 音频」暂时隐藏——存本机会让首页变成双源，上传又要新端点与配额。
3. 旧条目没有 `videoId`，可能被重复导入。
4. 「我 · 下载与存储」仍只是展示，点不动（存储清理页未做）。
5. 第二包全部（摘要 / 标签 / 笔记编辑 / 脑图 / 书签）。
