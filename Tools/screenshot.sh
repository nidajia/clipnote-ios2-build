#!/usr/bin/env bash
# 把 App 装进模拟器，按状态逐个启动并截屏。
#
# 为什么不用 XCTest：`ImageRenderer` 画不出 List / TabView / NavigationStack，
# 整张会变成系统「不可用」占位符。要拿到真实界面，只能真的启动 App 再截屏。
#
# 用法：bash Tools/screenshot.sh <SIM_UDID> [build 目录]

set -euo pipefail

UDID="${1:?需要模拟器 UDID}"
BUILD_DIR="${2:-build}"
BUNDLE_ID="com.clipnote.v2"

APP_PATH="$(find "$BUILD_DIR/Build/Products" -maxdepth 2 -name "ClipNote2.app" -type d | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "找不到 ClipNote2.app，先跑 xcodebuild build -derivedDataPath $BUILD_DIR"
  exit 1
fi
echo "App: $APP_PATH"

mkdir -p screenshots

# 等模拟器就绪
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"

# 状态栏固定成画布里的 9:41，避免每张图时间都不一样
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true

shot() {
  local name="$1" state="$2" appearance="$3" rotate="${4:-}"

  # 关掉模拟器键盘的「滑动输入」教学弹窗：它会在第一次弹键盘时盖住整个编辑区，
# 拍出来的图看不出编辑器长什么样（V79 的 note-new 就被它盖了）。
for domain in com.apple.keyboard.preferences com.apple.Preferences; do
  xcrun simctl spawn "$UDID" defaults write "$domain" DidShowContinuousPathIntroduction -bool true >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" defaults write "$domain" KeyboardContinuousPathEnabled -bool false >/dev/null 2>&1 || true
done
xcrun simctl ui "$UDID" appearance "$appearance" >/dev/null 2>&1 || true
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    -snapshotState "$state" -snapshotAppearance "$appearance" >/dev/null

  # 等首帧稳定；冷启动比热启动慢。
  # 横屏那张还要等 App 自己请求转方向，多给两秒。
  # note-editor 要等 WebView 把 1.1MB 内联页面解析完——4 秒拍到的只是转圈，
  # 那样这张图就证明不了"最终能不能出来"。
  if [ "$state" = "note-editor" ]; then
    sleep 25
  elif [ "$rotate" = "landscape" ]; then sleep 6; else sleep 4; fi
  xcrun simctl io "$UDID" screenshot "screenshots/$name.png"

  if [ "$rotate" = "landscape" ]; then
    upright_if_sideways "screenshots/$name.png"
  fi
  echo "  -> screenshots/$name.png"
}

# `simctl` 没有「旋转设备」这个命令，所以是 App 自己喊「我要横屏」。
# 此时内容会按 874×402 的横屏尺寸布局，但被画进竖屏缓冲里——拍出来是一张
# 躺着内容的竖图。宽高颠倒就转回来：转正后是一张诚实的横屏截图，
# 因为它确实是按横屏尺寸排的，不是把页面塞进竖屏里假装。
upright_if_sideways() {
  local file="$1"
  local w h
  w=$(sips -g pixelWidth "$file" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$file" | awk '/pixelHeight/{print $2}')
  if [ -n "$w" ] && [ -n "$h" ] && [ "$w" -lt "$h" ]; then
    # 270 而不是 90：实测这一版是逆时针躺着，顺转 90 会得到一张倒图（已踩）。
    # 这个数字依赖 App 请求的方向，改了 OrientationLock 的请求就要重新核对。
    sips -r 270 "$file" >/dev/null
    echo "     (内容躺在竖屏缓冲里，已转正：${w}x${h})"
  fi
}

# 走真实解码路径：App 从 bundle 里的 library-sample.json 解码后渲染，
# 所以每张图同时证明「解码对不对」和「渲染对不对」，且不依赖网络。
# 首启引导（画布 01 / 02）。放在最前面：它们本来就发生在首页之前。
shot onboarding-welcome onboarding-welcome light
shot onboarding-syncing onboarding-syncing light
shot onboarding-done    onboarding-done    light
shot onboarding-failed  onboarding-failed  light

shot home-list    list    light
shot home-loading loading light
shot home-failed  failed  light
shot home-empty   empty   light
shot me           me      light
shot tags         tags    light
shot ai-settings  ai-settings light
shot ai-models    ai-models   light
shot import-sheet import  light
shot logs         logs    light
shot trash        trash   light

shot detail-idle        detail             light
shot detail-ready       detail-ready       light
shot detail-note        detail-note        light
shot detail-downloading detail-downloading light
shot detail-downloaded  detail-downloaded  light
shot detail-summary     detail-summary     light
shot detail-segments    detail-segments    light
shot detail-bookmarks   detail-bookmarks   light
shot outline            outline            light
shot note-editor      note-editor      light
# 深色：编辑器在深色下的底色/工具栏/弹层（之前一直是白的）
shot note-dark        note-editor      dark
# 新建笔记的默认形态：大标题 + 三个小标题
shot note-new         note-new         light
shot note-probe       note-probe       light
shot home-selecting     home-selecting     light
# 6.1 分区：一张验筛选条和行内标记，一张验选择面板本身。
# 分区归属在 SnapshotRoot 里种好（故意留几条未分区），
# 否则「未分区」那条筛选在图上永远不出现，等于没验。
shot home-section       home-section       light
shot section-picker     section-picker     light
# 笔记筛选：只收真有内容的，行内带修改时间
shot home-notes         home-notes         light
shot segments           segments           light
shot infographic        infographic        light
# 发现页：验筛选栏始终在（切「合集」也回得去）、热榜能渲染、合集入口可见
shot discover              discover              light
shot discover-collections  discover-collections  light
# 合集目录：点合集先进这一页（有集数/时间/播放量/正在看），点某一集才播
shot collection            collection            light
# 本机转写面板（sheet，只能作为根呈现）。
# 模拟器上真跑只会停在「这台设备暂时不行」，所以这几张全走 preview 注入。
# 除了「转写中 / 完成」，另外四张是**失败路径**：真机上它们要么看运气
# （权限被拒、系统听写停住），要么根本复现不了，只能在这里把文案看一遍。
shot transcribe            transcribe            light
shot transcribe-running    transcribe-running    light
# 云端转写（默认路径）：验引擎行文案与分段进度
shot transcribe-cloud      transcribe-cloud      light
shot transcribe-blocked    transcribe-blocked    light
shot transcribe-permission transcribe-permission light
shot transcribe-stalled    transcribe-stalled    light
shot transcribe-failed     transcribe-failed     light

# 画布 06。第 4 个参数让脚本把它转正（见 upright_if_sideways）
shot player-landscape player-landscape light landscape

shot home-dark   list   dark
shot detail-dark detail dark

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

ls -la screenshots
