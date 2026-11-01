import AVKit
import SwiftUI

/// 横屏全屏播放页（画布 06）。
///
/// 为什么自建而不是用 AVKit 控制条里那个 ⤢：系统全屏是 AVKit 自己的弹层，
/// 旋转时机、关闭按钮、状态栏都不在手里，而且**截不到图**——
/// 这一轮要交付的正是这一页，拍不出来等于没有证据。
///
/// 自绘的只有外壳：关闭按钮与片名。播放控制条仍然是系统的
/// （`AVPlayerViewController`），这是 DESIGN-SPEC 2.8 的硬要求：
/// scrubber、音量、字幕这些细节自己画一遍只会更差。
struct PlayerScreen: View {
    var item: Item

    /// 传 nil 表示没有真实播放器（截图与预览）。此时画封面渐变，
    /// 而不是一块沉默的黑——纯黑的截图看不出这一页的布局对不对。
    var player: AVPlayer?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoSurface
            topScrim
            chrome
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // 进出各锁一次。写在 onAppear / onDisappear 而不是 init：
        // 视图可能被重建（init 会跑），但只有真的出现在屏幕上才该动方向。
        .onAppear { OrientationLock.shared.enterFullscreenPlayer() }
        .onDisappear { OrientationLock.shared.exitFullscreenPlayer() }
        // 截图与预览路径：没有播放器也就没有转场动画，首帧时 scene 未必就绪，
        // 第一次请求可能落空。补一次——只在这一条路径上补，真机不受影响。
        .task {
            guard player == nil else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            // 和第一次请求保持同一个掩码（`.landscape`）。改成 `.landscapeRight`
            // 会让系统可能翻 180°，而截图脚本的转正方向是按实测定的——
            // 请求一变，那个实测结论就作废了。
            OrientationLock.shared.force(.landscape)
        }
    }

    // MARK: - 画面

    @ViewBuilder
    private var videoSurface: some View {
        if let player {
            PlayerView(player: player)
                .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [item.coverTop, item.coverBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
    }

    // MARK: - 外壳

    /// 顶部渐变：视频亮的时候白字会糊。
    ///
    /// 单独一层而不是挂在顶栏的 `.background` 上——挂在顶栏上时，它的宽度
    /// 会被横屏的安全区（刘海那一侧）切掉一截，截图里表现为左侧突然断开的黑边。
    private var topScrim: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Color.black.opacity(0.6), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 顶栏常显而不是「几秒后自动隐藏」。
    ///
    /// 自动隐藏要接管点击事件，而点击已经是 AVKit 用来显隐它自己控制条的——
    /// 两套显隐叠在一起，用户点一下会看到两个东西同时出现，比常显更乱。
    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("退出全屏")

                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 18)

            Spacer(minLength: 0)
        }
    }
}

/// `AVPlayerViewController` 的 SwiftUI 外壳。
///
/// 用它而不是 `VideoPlayer`：全屏页需要系统控制条（scrubber / 音量 / 字幕），
/// 自己画一套只会更差；而 `VideoPlayer` 的控制条在跨页面共享同一个播放器时
/// 会重建播放器状态，正在播的会被打断。
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        // 已经在自己的全屏页里：再让 AVKit 自己进全屏只会多一层弹层，
        // 用户得多按一次 Done 才回到详情页。
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
