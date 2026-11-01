import Foundation

/// 「我装的到底是哪一版」——装机实测时这个问题必须有答案。
///
/// 之前这里写死成 `"8.0.0 (1)"`，两个分支还写的是同一个字符串：
/// 装两台机器、或者隔天再装一次，界面上一模一样，日志里也分不出来。
/// 现在读 Bundle 的真实版本与构建号，CI 会把构建号覆盖成运行号。
enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        // 构建号每次 ipa 自增，但它说不清「哪次提交」。CI 会塞一个 ClipNoteCommit，
        // 取前 7 位显示——真机上出问题时，这一串就是我能在仓库里定位到的东西。
        if let sha = info?["ClipNoteCommit"] as? String, sha.count >= 7 {
            return "\(short) (\(build)) · \(sha.prefix(7))"
        }
        return "\(short) (\(build))"
    }
}
