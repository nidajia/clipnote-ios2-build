import Foundation

/// SRT 字幕格式。
///
/// 抽成纯函数是因为这个格式**一旦错一格就导入失败**，而导入方（剪映、Premiere）
/// 只会说"格式不支持"，不会告诉你哪一行错了。这类东西必须有测试盯着。
///
/// 标准形态：
/// ```
/// 1
/// 00:00:12,000 --> 00:00:30,000
/// 第一句
/// ```
enum SRTFormat {

    /// 结束时间取下一句的开始；最后一句用总时长兜底，且至少 2 秒，
    /// 否则某些剪辑软件会认为该条时长为 0 并丢弃。
    static func text(lines: [TranscriptLine], duration: Int) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            let start = max(0, line.t)
            let end = index + 1 < lines.count
                ? max(lines[index + 1].t, start + 1)
                : max(line.t + 2, duration)
            out += "\(index + 1)\n"
            out += "\(time(start)) --> \(time(end))\n"
            out += "\(line.text)\n\n"
        }
        return out
    }

    /// `HH:MM:SS,mmm`。逗号是 SRT 的规定，不是笔误。
    static func time(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d,000", s / 3600, (s % 3600) / 60, s % 60)
    }
}
