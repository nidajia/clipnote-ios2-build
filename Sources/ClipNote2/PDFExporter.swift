import UIKit
import CoreText

/// 把一条内容排成 PDF。
///
/// 为什么先做 PDF 而不是 Word：Word 要生成 OOXML，iOS 上没有官方实现，
/// 只能靠 HTML→docx 转换，而且样式会失真。PDF 用系统 `UIGraphicsPDFRenderer`
/// 就能排，分页、断行、中文字体都在系统里，没有额外依赖，离线也能用。
///
/// 为什么用 `CTFramesetter` 逐页切，而不是把整段画进一张超长图：
/// 长图没有页概念，打印会被裁；PDF 要的是「A4 一页一页」。
/// CoreText 的 Framesetter 能告诉我们哪一页排到哪个字符，天然支持分页。
enum PDFExporter {

    /// A4 纵向，单位 pt。留 48pt 页边距——打印后不会被裁掉。
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 48

    private static var textRect: CGRect {
        CGRect(x: margin, y: margin,
               width: pageSize.width - margin * 2,
               height: pageSize.height - margin * 2)
    }

    static func fileName(for item: Item) -> String {
        let safe = item.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe.prefix(40)).pdf"
    }

    /// 生成并写到临时目录。失败返回 nil。
    static func write(_ item: Item, now: Date = Date()) -> URL? {
        guard let data = makeData(item, now: now) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(for: item))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func makeData(_ item: Item, now: Date = Date()) -> Data? {
        let text = attributedText(for: item, now: now)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))

        return renderer.pdfData { ctx in
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var location = 0
            let total = text.length
            var pageIndex = 0

            while location < total {
                ctx.beginPage()

                // 页脚：不抢正文空间，画在页边距里
                drawFooter(page: pageIndex + 1, in: ctx)

                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: location, length: 0),
                    path,
                    nil
                )
                let context = ctx.cgContext
                context.saveGState()
                // PDF 坐标系原点在左下，CoreText 要翻转后才是正常阅读方向
                context.textMatrix = .identity
                context.translateBy(x: 0, y: pageSize.height)
                context.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, context)
                context.restoreGState()

                let visible = CTFrameGetVisibleStringRange(frame)
                // 一页一个字都排不下说明框太小或字号太大，直接停，
                // 否则会在这里死循环并把内存吃光。
                if visible.length <= 0 { break }
                location += visible.length
                pageIndex += 1
                if pageIndex > 500 { break }
            }
        }
    }

    private static func drawFooter(page: Int, in ctx: UIGraphicsPDFRendererContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor(white: 0.6, alpha: 1),
        ]
        let text = "片记 · 第 \(page) 页" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: pageSize.width - margin - size.width,
                              y: pageSize.height - 28),
                  withAttributes: attrs)
    }

    // MARK: - 排版

    /// 全文拼成一份富文本。分节靠字号与间距，不靠插图。
    static func attributedText(for item: Item, now: Date = Date()) -> NSAttributedString {
        let out = NSMutableAttributedString()

        func append(_ text: String, font: UIFont, color: UIColor, spaceAfter: CGFloat) {
            guard !text.isEmpty else { return }
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph(spacing: spaceAfter),
            ]))
        }

        append(item.title, font: .systemFont(ofSize: 20, weight: .semibold),
               color: .black, spaceAfter: 6)

        var meta: [String] = []
        if !item.author.isEmpty { meta.append(item.author) }
        if !item.platform.isEmpty { meta.append(item.platform == "bilibili" ? "B 站" : item.platform) }
        if !item.durationText.isEmpty { meta.append(item.durationText) }
        append(meta.joined(separator: " · "), font: .systemFont(ofSize: 10),
               color: .gray, spaceAfter: 10)

        if !item.labels.isEmpty {
            append(item.labels.map { "#\($0)" }.joined(separator: "  "),
                   font: .systemFont(ofSize: 10), color: .gray, spaceAfter: 14)
        }

        func section(_ title: String) {
            append(title, font: .systemFont(ofSize: 13, weight: .semibold),
                   color: .black, spaceAfter: 6)
        }

        if !item.aiSummary.isEmpty {
            section("摘要")
            append(item.aiSummary, font: .systemFont(ofSize: 11.5),
                   color: .darkGray, spaceAfter: 6)
            if !item.keyPoints.isEmpty {
                for point in item.keyPoints {
                    append("· \(point)", font: .systemFont(ofSize: 11.5),
                           color: .darkGray, spaceAfter: 2)
                }
            }
            out.append(NSAttributedString(string: "\n"))
        }

        if !item.note.isEmpty {
            section("我的笔记")
            append(item.note, font: .systemFont(ofSize: 11.5),
                   color: .darkGray, spaceAfter: 8)
            out.append(NSAttributedString(string: "\n"))
        }

        if !item.segments.isEmpty {
            section("分段")
            for segment in item.segments {
                let line = "\(mmss(segment.t))　\(segment.title)"
                    + (segment.summary.isEmpty ? "" : "　\(segment.summary)")
                append(line, font: .systemFont(ofSize: 11),
                       color: .darkGray, spaceAfter: 2)
            }
            out.append(NSAttributedString(string: "\n"))
        }

        if !item.bookmarks.isEmpty {
            section("书签")
            for bookmark in item.bookmarks.sorted(by: { $0.t < $1.t }) {
                let note = bookmark.note.isEmpty ? "（无备注）" : bookmark.note
                append("\(mmss(bookmark.t))　\(note)",
                       font: .systemFont(ofSize: 11), color: .darkGray, spaceAfter: 2)
            }
            out.append(NSAttributedString(string: "\n"))
        }

        if !item.annotations.isEmpty {
            section("批注")
            for annotation in item.annotations.sorted(by: { $0.t < $1.t }) {
                if !annotation.quote.isEmpty {
                    append("「\(annotation.quote)」\(mmss(annotation.t))",
                           font: .systemFont(ofSize: 10), color: .gray, spaceAfter: 1)
                }
                append(annotation.note, font: .systemFont(ofSize: 11),
                       color: .darkGray, spaceAfter: 4)
            }
            out.append(NSAttributedString(string: "\n"))
        }

        if !item.outline.isEmpty {
            section("脑图")
            for node in item.outline {
                appendNode(node, depth: 0, into: out, append: append)
            }
            out.append(NSAttributedString(string: "\n"))
        }

        if !item.summary.isEmpty {
            section("原简介")
            append(item.summary, font: .systemFont(ofSize: 10.5),
                   color: .gray, spaceAfter: 4)
        }

        append("导出于 \(dateText(now))　仅含文字，不含封面与视频。",
               font: .systemFont(ofSize: 9), color: .gray, spaceAfter: 0)

        return out
    }

    private static func appendNode(
        _ node: OutlineNode, depth: Int,
        into out: NSMutableAttributedString,
        append: (String, UIFont, UIColor, CGFloat) -> Void
    ) {
        let indent = String(repeating: "　", count: depth)
        append("\(indent)\(depth == 0 ? "■ " : "· ")\(node.title)",
               font: .systemFont(ofSize: depth == 0 ? 11.5 : 11),
               color: depth == 0 ? .black : .darkGray,
               spaceAfter: 1)
        if !node.note.isEmpty {
            append("\(indent)　\(node.note)", font: .systemFont(ofSize: 10),
                   color: .gray, spaceAfter: 1)
        }
        for child in node.children {
            appendNode(child, depth: depth + 1, into: out, append: append)
        }
    }

    private static func paragraph(spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // 行距 1.5 倍：中文密排时不加行距，打印出来是一块灰
        style.lineSpacing = 5
        style.paragraphSpacing = spacing
        return style
    }

    private static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: date)
    }
}
