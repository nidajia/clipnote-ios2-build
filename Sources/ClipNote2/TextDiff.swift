import Foundation

/// 逐字差异。预览卡靠它把「哪里改了」标出来。
///
/// 为什么需要：只给一份结果文本，用户没法判断模型改了什么、有没有偷偷动他的字。
/// 上一版就是这样——用户只能点「采用」，然后自己比对。
enum DiffKind: Equatable {
    case same
    case insert
    case delete
}

struct DiffSegment: Equatable {
    var kind: DiffKind
    var text: String
}

enum TextDiff {

    /// 超过这个长度就退回按行比对：字符级 LCS 是 O(n×m)，
    /// 4000 字的笔记要几十兆内存，手机上不值得。
    static let charLimit = 800

    static func segments(from old: String, to new: String) -> [DiffSegment] {
        let left = Array(old)
        let right = Array(new)
        if left.count <= charLimit, right.count <= charLimit {
            return merge(characterDiff(left, right))
        }
        return merge(lineDiff(old, new))
    }

    // MARK: - 字符级

    private static func characterDiff(_ a: [Character], _ b: [Character]) -> [DiffSegment] {
        let n = a.count
        let m = b.count
        // table[i][j] = a[i...] 与 b[j...] 的最长公共子序列长度
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var out: [DiffSegment] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(DiffSegment(kind: .same, text: String(a[i])))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(DiffSegment(kind: .delete, text: String(a[i])))
                i += 1
            } else {
                out.append(DiffSegment(kind: .insert, text: String(b[j])))
                j += 1
            }
        }
        while i < n {
            out.append(DiffSegment(kind: .delete, text: String(a[i])))
            i += 1
        }
        while j < m {
            out.append(DiffSegment(kind: .insert, text: String(b[j])))
            j += 1
        }
        return out
    }

    // MARK: - 行级（长文本兜底）

    private static func lineDiff(_ old: String, _ new: String) -> [DiffSegment] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count
        let m = b.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var ops: [(DiffKind, String)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                ops.append((.same, a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append((.delete, a[i])); i += 1
            } else {
                ops.append((.insert, b[j])); j += 1
            }
        }
        while i < n { ops.append((.delete, a[i])); i += 1 }
        while j < m { ops.append((.insert, b[j])); j += 1 }

        // 同一类的相邻行用换行拼回去，否则预览里所有行会粘成一长条
        var out: [DiffSegment] = []
        for (kind, line) in ops {
            if !out.isEmpty, out[out.count - 1].kind == kind {
                out[out.count - 1].text += "\n" + line
            } else {
                out.append(DiffSegment(kind: kind, text: line))
            }
        }
        return out
    }

    /// 把相邻同类合并，否则会出现几万个单字片段，渲染直接卡死。
    private static func merge(_ raw: [DiffSegment]) -> [DiffSegment] {
        var out: [DiffSegment] = []
        for seg in raw {
            if !out.isEmpty, out[out.count - 1].kind == seg.kind {
                out[out.count - 1].text += seg.text
            } else {
                out.append(seg)
            }
        }
        return out
    }
}
