import AVFoundation
import Combine
import SwiftUI

/// 背景音乐的播放器。图文作品没有视频音轨，看图时的配乐由它来放。
///
/// 独立于视频播放器，但共用 `AudioFocus` 的「换人先掐旧的」——
/// 否则视频起播时图文 BGM 还在响，两路声音叠在一起。
final class BGMController: ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0        // 0~1，喂给 Slider
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?

    func play(url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        AudioFocus.shared.adopt(p)
        player = p
        isPlaying = true
        p.play()
        observe(p)
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to fraction: Double) {
        guard let player, durationSeconds > 0 else { return }
        let t = CMTime(seconds: durationSeconds * fraction, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        AudioFocus.shared.resign(player)
        player = nil
        isPlaying = false
        progress = 0
        currentSeconds = 0
        durationSeconds = 0
    }

    private func observe(_ p: AVPlayer) {
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let dur = p.currentItem?.duration.seconds ?? 0
            let cur = time.seconds
            self.currentSeconds = cur.isFinite ? max(0, cur) : 0
            self.durationSeconds = (dur.isFinite && dur > 0) ? dur : 0
            self.progress = self.durationSeconds > 0
                ? min(1, self.currentSeconds / self.durationSeconds) : 0
            // 放完自动停；不在这里做任何 UI，避免和拖动进度条打架
            if self.durationSeconds > 0, self.currentSeconds >= self.durationSeconds - 0.2 {
                self.isPlaying = false
            }
        }
    }
}

/// 图文的背景音乐控制条：播放/暂停 + 进度条 + 时间。
struct BGMBar: View {
    @ObservedObject var controller: BGMController
    var title: String
    var author: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: Metric.space2) {
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.cnBrand)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isPlaying ? "暂停背景音乐" : "播放背景音乐")

                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? "背景音乐" : title)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(1)
                    if !author.isEmpty {
                        Text(author)
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text("\(Self.mmss(controller.currentSeconds)) / \(Self.mmss(controller.durationSeconds))")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .monospacedDigit()
            }

            Slider(value: Binding(
                get: { controller.progress },
                set: { controller.seek(to: $0) }
            ), in: 0 ... 1)
            .tint(Color.cnBrand)
        }
        .padding(Metric.space3)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairlineSoft, lineWidth: 1)
        )
    }

    static func mmss(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
