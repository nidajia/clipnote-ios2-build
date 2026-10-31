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
  local name="$1" state="$2" appearance="$3"

  xcrun simctl ui "$UDID" appearance "$appearance" >/dev/null 2>&1 || true
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    -snapshotState "$state" -snapshotAppearance "$appearance" >/dev/null

  # 等首帧稳定；冷启动比热启动慢
  sleep 4
  xcrun simctl io "$UDID" screenshot "screenshots/$name.png"
  echo "  -> screenshots/$name.png"
}

shot home-list  list  light
shot home-empty empty light
shot me         me    light
shot home-dark  list  dark

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

ls -la screenshots
